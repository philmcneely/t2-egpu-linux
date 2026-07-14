# How I Got a Mac Mini 2018 to Run GPU Inference Over Thunderbolt 3

I run local LLM inference as a hobby that's gotten slightly out of hand. I have a couple of inference machines already (a full write-up of the home lab is coming), but they're usually busy with the models I actually need - 70B, 200B+, the stuff that eats VRAM. What I wanted was a dedicated node for slow, unattended work. Metadata enrichment on tens of thousands of files. Long-running batch jobs that take hours. The kind of tasks where I don't care if inference is a little slower, as long as it's not tying up a GPU I need for something else.

I had a Mac Mini 2018 with 64GB of RAM, an AMD RX 6800 with 16GB of VRAM, and a Thunderbolt 3 eGPU enclosure. Should be straightforward, right? (It was not.)

It took weeks, two reloaded machines, and a custom kernel module. But it works.

## The Expensive Mistake: Starting with the Wrong Machine

I didn't start with the Mac Mini. I started with a 2013 Mac Pro - the "trash can." It had 128GB of RAM, a 12-core Xeon, and six Thunderbolt 2 ports. Sequoia is the last macOS it can run, and it has its issues - that path felt dead. I wanted to use the eGPU hardware I had, so I put Ubuntu on it. It worked - the Xeon and 128GB of RAM were usable again.

The plan was simple: plug the RX 6800 into an AKiTiO Node Titan eGPU enclosure, connect it via Thunderbolt 2 (with a TB3-to-TB2 adapter, since the AKiTiO is TB3), install ROCm, run Ollama. I already had the GPU and the enclosure. The expensive part was the Thunderbolt 2 cables and TB2-to-TB3 adapters - Apple only, to rule out weird cable compatibility issues.

The GPU showed up in `lspci`. It was right there. And then nothing worked. Three independent, unfixable hardware blockers in the Thunderbolt 2 controller silicon - the memory window is too small, PCIe Atomics don't route, and EFI crashes on display handshake. I had to reload the machine twice trying to force it. The [full story](mac-pro-2013-tb2-failure.md) is worth reading if you're considering eGPU on any Thunderbolt 2 Mac, because the answer is: don't.

Some expensive Thunderbolt cables and adapters, sitting in a drawer. They might find a second life as Thunderbolt networking between the three trash cans I have, or bridging to USB 3 disk arrays as a cheap NAS - but that's a project for a slower weekend.

## The Pivot

The Mac Mini 2018 has Thunderbolt 3. Different controller silicon. The TB3 controller has wider memory windows, supports PCIe Atomics, and doesn't have the EFI handshake issue. On paper, it fixes every problem that killed the Mac Pro 2013 attempt.

I picked one up with 64GB of RAM and a 512GB SSD. Before anything else, I had to boot into macOS Recovery, open Startup Security Utility, and disable Secure Boot and allow booting from external media. The T2 chip locks this down by default - without changing these settings, the machine refuses to boot anything Apple hasn't signed. Then I installed the T2-patched Ubuntu kernel from the [t2linux](https://wiki.t2linux.org) project, which provides drivers for the T2-controlled SSD, keyboard, and other hardware that the generic Ubuntu kernel can't talk to (the generic kernel can't even see the SSD).

Plugged in the eGPU. Booted up. Ran `lspci`.

The GPU was there. Same BAR 0 failure.

## The T2 Firmware Problem Nobody Warns You About

The T2 chip doesn't just handle encryption and secure boot. It runs the Thunderbolt firmware. During early boot - before any operating system loads - the T2 decides how much memory to allocate for the Thunderbolt domain. The TB2 Falcon Ridge controller on the Mac Pro 2013 allocated 3MB - laughably small. The T2 on the Mac Mini does much better: 224MB. Progress.

The RX 6800's BAR 0 needs 256MB. Still thirty-two megabytes short.

This isn't a macOS limitation. It isn't a Linux limitation. It's firmware. The T2 makes this decision before the OS even exists. You can't change it or override it - there's no EFI variable, no NVRAM setting, no hidden configuration. The T2 decided 224MB is enough, and that's what you get.

I found people online who'd gotten eGPUs working on T2 Macs - a few Reddit posts, some Level1Techs forum threads, a GitHub repo with someone's Vega eGPU config. So it was possible. But nobody had documented a clean, reproducible process. Every solution was "I did these twelve things and it eventually worked."

## The Parameters That Cost Me Days

Before you can even attempt to fix the BAR problem, the GPU has to show up on the Thunderbolt bus. This requires kernel boot parameters, and getting them wrong means one of three outcomes: the GPU doesn't appear (silently), the kernel crashes, or the machine won't boot at all.

**`pcie_aspm=off`** was the worst one. PCIe Active State Power Management sounds like it should be completely unrelated to GPU initialization. What it actually does on this hardware: silently prevents the Thunderbolt link from establishing. The ASPM negotiation between the Mac Mini's TB3 controller and the AKiTiO enclosure fails without any error message. The GPU just doesn't show up in `lspci`. No log entry. No dmesg warning. Nothing. You're staring at a system that looks perfectly healthy, minus the GPU you know is physically connected and powered on. This one parameter cost me an ENTIRE day of debugging before I found a buried forum post that mentioned it.

**`amdgpu.rebar=0`** prevents Resizable BAR. Without it, the AMD driver automatically resizes BAR 0 from 256MB to the GPU's full 16GB on load. This immediately overflows every bridge memory window in the Thunderbolt chain and triggers a kernel BUG - GART page table corruption. The GPU has 16GB of VRAM, but we can only expose 256MB through the BAR. The driver manages the rest through internal page tables, and that's fine. But you have to tell it not to try to be clever (obviously).

**`GRUB_RECORDFAIL_TIMEOUT=5`** isn't a kernel parameter at all, but it might be the most important thing in the entire setup. Ubuntu's GRUB default behavior after a failed boot - a crash, a power loss, anything that prevented a clean shutdown - is to wait **forever** for keyboard input before proceeding. On a headless Mac Mini in a closet with no monitor, this means the machine never boots again until you physically connect a display and keyboard to press Enter at a GRUB prompt you couldn't see. Set the timeout.

## The Three-Layer Fix

Once the GPU reliably appears on the Thunderbolt bus, the BAR problem remains. The T2's 224MB allocation is still too small. The fix requires reprogramming hardware at three different levels, in order, before the GPU driver loads. Any single layer alone doesn't work. I learned this the hard way - each layer solved a problem just long enough to reveal the next one.

### Layer 1: Reprogram the PCI Bridge Registers

Seven PCI-to-PCI bridges sit between the CPU and the eGPU. Each bridge has a "prefetchable memory window" register that controls what address range it forwards downstream. The T2 firmware programs these windows based on its 224MB allocation - too small for the GPU.

Using `setpci`, I reprogram every bridge to forward a 256MB window at `0x4010000000` in 64-bit address space. The host bridge's 64-bit window starts at `0x4000000000`, but Intel's HDA controller already occupies the first chunk, so the GPU goes at a 256MB offset.

After this, the hardware registers are correct. The bridges will forward the right address range. The GPU's BAR 0 is programmed to an address within that window. In theory, the driver should now be able to enable the device, but it can't.

### Layer 2: The Kernel Doesn't Know

This took the longest to figure out, and I've never seen it clearly documented anywhere.

Linux's PCI subsystem maintains an internal resource tree - `struct resource` objects for every BAR, every bridge window, every memory region in the system. The kernel builds this tree during early boot by reading the PCI configuration registers. It reads what the T2 firmware programmed, caches it, and never looks at the hardware again.

When you reprogram bridge registers with `setpci`, the hardware changes. The kernel's cached copy doesn't. The AMD GPU driver (`amdgpu`) doesn't read hardware registers directly during initialization - it checks the kernel's resource tree. So even though the hardware is now correctly programmed, the driver sees the old, broken firmware values and refuses to enable the device.

There's no kernel API that says "please re-scan the PCI configuration registers." The kernel assumes firmware got it right. The T2 didn't.

The fix is a kernel module that directly patches the kernel's `struct resource` objects. It finds the GPU by vendor/device ID, walks up to its parent bridge, and overwrites the cached resource entries to match the values we programmed in the hardware. It's about 90 lines of C that reach into kernel data structures and rewrite them.

And there's one specific detail that was the difference between a working GPU and a doorstop: the `parent` pointer. Each BAR resource has a pointer to its parent bridge's resource. The kernel's `pci_enable_resources()` function checks that this pointer is non-NULL. Without `bar0->parent = bridge_pref`, you get "not claimed; can't enable device" and the driver gives up. One pointer assignment. That's it. Everything else in the three-layer stack exists to make this one pointer meaningful.

### Layer 3: Boot Sequencing

The AMD driver must not load automatically. If it loads before layers 1 and 2 complete, it sees the broken firmware values and fails. The driver is blacklisted via modprobe config and only loaded by a systemd service that runs after the bridges are programmed and the kernel module is loaded. The service also waits up to 60 seconds for the GPU to appear on the Thunderbolt bus - hot-plug detection isn't instant, and if you try to program registers before the device enumerates, you're programming nothing.

Ollama gets its own systemd dependency: `After=egpu-init.service`. Without this, Ollama starts, finds no GPU, falls back to CPU mode, and you're doing inference at 10 tokens per second on a machine with 16GB of unused VRAM. I debugged "why is Ollama using CPU" more times than I want to admit before realizing it was a race condition. Dumbest bug.

## The Result

Cold boot to accepting inference requests: 45 seconds. The eGPU initializes in about 12 seconds. Ollama detects the RX 6800 via ROCm, reports 16GB of VRAM at `gfx1030`, and loads models 100% on GPU.

The Mac Mini, the AKiTiO enclosure, and a network cable sit on a rack some distance form my desk. It reboots cleanly after power failures. It survives kernel updates (mostly - the custom module needs a rebuild when the kernel version changes). It just sits there, serving 7–8B models over the network, drawing maybe 300 watts under load.

The Mac Mini 2018 has four Thunderbolt 3 ports, but only two Titan Ridge controllers. Each controller manages a pair of ports. For maximum bandwidth, you want each eGPU on a separate controller - not sharing PCIe lanes with the other GPU.

Looking at the back of the Mac Mini:

```
                    Mac Mini 2018 - Rear Port Layout (sorta)

    ┌──────────────────────────────────────────────────────────┐
    │                                                          │
    │   ┌────┐  ┌────┐ ┌────┐  ┌────┐ ┌────┐  ┌──────┐         │
    │   │ ETH│  │TB 1│ │TB 2│  │TB 3│ │TB 4│  │ HDMI │         │
    │   └────┘  └────┘ └────┘  └────┘ └────┘  └──────┘         │
    │            ╰──┬──╯        ╰──┬──╯                        │
    │         Controller 0    Controller 1                     │
    │          (Bus 01.1)      (Bus 01.2)                      │
    │          ★ eGPU #1       ★ eGPU #2                       │
    │         (RX 6800)       (RX 6800)                        │
    │         [connected]     [planned]                        │
    │                                                          │
    └──────────────────────────────────────────────────────────┘

    ★ = Connect eGPUs to ports on DIFFERENT controllers
      eGPU #1 → TB 1 (far left, next to Ethernet)
      eGPU #2 → TB 3 or TB 4 (far right, next to HDMI)

    Both cards are RX 6800 (16GB each) = 32GB total VRAM
```

The first RX 6800 is on Controller 0, plugged into the far-left port next to the Ethernet jack. The plan is to put the second RX 6800 on Controller 1, far-right port next to HDMI. Each controller gets its own dedicated 4 PCIe 3.0 lanes to the CPU, so neither GPU should starve the other for bandwidth.

This hasn't been tested yet - it's the next step. But the boot script already walks the bridge chain dynamically, and the memory map has room: `0x4020000000` through `0x7FFFFFFFFF` is wide open for a second GPU's BAR. In theory, that's a 32GB inference node in a Mac Mini. We'll update this article when it's confirmed.

Is this the sensible way to do local inference? No. Buy a used workstation and put a GPU in a PCIe slot like a normal person. Or get an M-series Mac and use MLX. Both are way easier.

But I had the hardware. And after the Thunderbolt 2 disaster, I wasn't going to let Apple's firmware win twice.

It works. But "works" is a vague word. I wanted numbers.

## Benchmarking: How Stable Is This Actually?

Once the eGPU was initializing cleanly on every boot, I loaded Qwen3 14B (Q4_K_M quantization, 9.3GB) via Ollama and ran it hard to test its limits.

### Methodology

Three test phases, all automated, zero monitoring:

1. **Throughput baseline** - 20 warm inference runs with varied technical prompts, 256 token output cap. Measured generation speed, model load time, and variance.
2. **Stability soak** - 232 consecutive inferences over 72 minutes. Tracked tok/s drift, VRAM usage, GPU errors via `dmesg`, and Ollama process health.
3. **Context stress** - escalating context windows from 1K to 32K tokens using a generated technical corpus (not repeated sentences - actual varied paragraphs to prevent prompt caching from hiding real memory pressure). Each test used `num_ctx` set explicitly to force Ollama to pre-allocate the full KV cache.

### Results

**Throughput:** 15.4–15.5 tok/s, consistent across 20 runs. ±0.1 tok/s variance. Cold start: 1.38s model load, 15.8 tok/s first generation. Thunderbolt 3 bandwidth is not the bottleneck at this model size.

**Stability:** 232 inferences, zero failures, zero GPU errors in `dmesg`, no VRAM leak (9949MB → 9975MB over 72 minutes), no tok/s degradation. The eGPU via Thunderbolt 3 is stable under sustained load. The BAR programming fix from `egpu-init.service` has held through every reboot and extended run.

**Context ladder (default Ollama, FP16 KV cache):**

| Context | Prompt Tokens | Gen Speed  | Result  |
|---------|---------------|------------|---------|
| 1K      | 816           | 14.9 tok/s | OK      |
| 4K      | 3,009         | 13.9 tok/s | OK      |
| 8K      | 5,993         | 12.4 tok/s | OK      |
| 16K     | 12,068        | 10.2 tok/s | OK      |
| 24K     | ~18,000       | -          | **OOM** |
| 32K     | -             | -          | **OOM** |

Hard ceiling at ~16K tokens. At 24K, Ollama pre-allocates the KV cache for the full context window, exhausts the 16GB VRAM, and the process dies. No GPU fault - clean memory exhaustion.

### The Context Wall

Qwen3 14B supports 40,960 tokens natively, but model weights and KV cache compete for the same 16GB. The model takes ~9.6GB, leaving ~6.7GB. With FP16 key-value cache (Ollama's default), the KV vectors across all 40 layers eat that headroom fast. At 16K context you're at ~12.1GB. At 24K the math doesn't work anymore.

I initially assumed 6.7GB of headroom meant 32K was reachable (Actually Claude told me this, but it lied!). It wasn't. KV cache at FP16 precision scales faster than napkin math suggests when you account for all 40 layers of key and value tensors.

### Doubling the Context Window

Two environment variables in Ollama's systemd service:

```ini
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
```

**Q8 KV cache quantization** stores key-value vectors at 8-bit instead of 16-bit, cutting KV cache memory roughly in half. The quality impact is negligible - the model weights themselves are already quantized to Q4, so Q8 KV cache is actually *higher precision* than the weights.

**Flash attention** reorganizes the attention computation to reduce peak VRAM during the forward pass (say that 3 times fast. Or with a serious face while talking to your parents- I dare you!)

**After optimization:**

| Context | Prompt Tokens | Gen Speed | VRAM    | Result           |
|---------|---------------|-----------|---------|------------------|
| 24K     | 14,568        | 8.2 tok/s | 12.2 GB | **OK** (was OOM) |
| 32K     | 26,292        | 6.1 tok/s | 13.0 GB | **OK** (was OOM) |

VRAM at 32K: 13.0GB of 16.3GB - 3.2GB of headroom remaining. The usable context window doubled with no measurable quality loss (Yay!).

I also set `OLLAMA_KEEP_ALIVE=-1` to keep the model in VRAM permanently. On a dedicated inference node, the default 5-minute idle eviction means every request after a quiet period pays a cold-start penalty for no reason.

### Sustained Long Context

73 consecutive inferences at 8K context over 30 minutes. Zero failures. 12.4 tok/s constant. No VRAM drift.

One thing worth noting: Ollama caches KV states from previous requests. When the same prompt prefix repeats (which it does in a sustained test using the same corpus), Ollama skips re-evaluating those tokens and loads the cached KV vectors directly. That's why prompt evaluation jumped from 130 tok/s on the first run to 71,000 tok/s by run 3 - it's a cache hit, not actual compute. Generation speed (the number that matters for output) stayed at 12.4 tok/s throughout. This matters for real workloads: if your batch jobs share a long system prompt or document prefix, prompt evaluation becomes essentially free after the first request. Unique prompts every time? You're paying the full 130 tok/s each request.

### What the Numbers Mean

For batch and async workloads - metadata enrichment, document processing, long-running pipelines - 6–15 tok/s on a machine drawing 300W in a closet is exactly what I needed. Interactive use works fine up to 8K context (12.4 tok/s). At 32K context, 6.1 tok/s is slow for chat but perfectly usable for unattended jobs.

Full benchmark data: [stability test](benchmarks/benchmark-results.txt) (232 inferences, 72 minutes) and [context stress test](benchmarks/context-test-results.txt) (context ladder + 30-minute sustained 8K soak).

It works, and it's been stable for days now.

The entire setup - kernel module, boot scripts, systemd service, modprobe config, GRUB parameters, and a detailed step-by-step guide - is at [github.com/philmcneely/t2-egpu-linux](https://github.com/philmcneely/t2-egpu-linux).

*I used Claude to help draft and edit this article.*
