# The Thunderbolt 2 eGPU Disaster: Why It Can Never Work on a Mac Pro 2013

This is the prequel. Before I got GPU inference working on a Mac Mini 2018, I spent weeks and too much money trying to make it work on a 2013 Mac Pro. It failed — hardware, firmware, and kernel — and the failure is permanent. If you're considering a Thunderbolt 2 eGPU for compute on a Mac Pro 2013, this is the article that saves you from learning what I learned the expensive way.

## The Machine

The 2013 Mac Pro — the "trash can." Dual AMD D700 GPUs, 12-core Xeon E5 v2, 128GB of RAM, six Thunderbolt 2 ports. Apple charged a premium for it, and for a few years it earned that premium. Then Apple forgot about it.

By 2025, Sequoia is the last macOS it'll run and it has its issues. The RAM and Xeons still work fine — it's the video drivers that cause most of the problems. Sequoia's D700 support is rough, and the machine can't get anything newer.

The RAM and Xeons worked fine under macOS — it was the video drivers that caused most of the issues. Sequoia's D700 support is rough. I put Ubuntu on it for the eGPU path, and the D700s are too old for ROCm anyway — GCN 3rd gen (Hawaii), and AMD's compute stack starts at GCN 5th gen (Vega). I needed a modern GPU.

## The Plan

The Mac Pro 2013 has six Thunderbolt 2 ports. The plan was to attach modern RDNA 2 GPUs via eGPU enclosures and use ROCm for compute. I bought:

- **AKiTiO Node Titan** — Thunderbolt 3 eGPU enclosure with a 650W PSU. Thunderbolt 3 to 2 adapters exist, and the AKiTiO is one of the few enclosures that works through them.
- **AMD Radeon RX 6800** — Navi 21, 16GB GDDR6, gfx1030. Well-supported by ROCm on Linux.
- **Thunderbolt 2 cables and TB3-to-TB2 adapters** — Apple only, to rule out cable compatibility issues.

The endgame was two RX 6800s for 32GB of total VRAM across two of the six TB2 ports. Enough to run quantized 14-27B models with tensor parallelism.

Not a cheap experiment (between the enclosure, adapters, and Apple TB2 cables — more than I want to repeat).

## What Happened

### The GPU Appeared

The first boot with the eGPU connected was actually promising. `lspci` showed the RX 6800 — Navi 21, device ID 0x73bf, 16GB VRAM detected. The kernel found it on the PCI bus at `1b:00.0`. The hardware was physically connected and enumerated.

Then `amdgpu` tried to initialize it, and everything fell apart.

### Blocker 1: The Memory Window

The Thunderbolt 2 controller in the Mac Pro 2013 is Intel's Falcon Ridge chipset. When it enumerates downstream devices, it creates a PCI bridge with a prefetchable memory window. On this hardware, that window is approximately 3MB.

The RX 6800's BAR 0 — the minimum memory aperture the GPU needs to initialize — requires 256MB.

Three megabytes allocated. Two hundred fifty-six megabytes needed. The bridge hardware can't map enough address space for the GPU to even start.

I tried every kernel parameter Linux offers for PCI memory reallocation:

- `pci=realloc` — supposed to allow the kernel to reallocate PCI resources at boot. Did nothing. The kernel can only reallocate within the memory windows the firmware established, and the firmware established a 3MB window.
- `hpmmioprefsize=512M` — tells the kernel to reserve 512MB for hotplug prefetchable memory. Failed. The upstream bridge's memory range is set by the Thunderbolt controller, not the kernel.
- `pci=assign-busses,realloc,hpmmiosize=256M,hpmmioprefsize=16G` — the nuclear option. Tells the kernel to reassign bus numbers, reallocate everything, and reserve 16GB of prefetchable space. This hung the machine on boot. Not just with the eGPU connected — it hung even without the Thunderbolt cable plugged in. The PCI parameters corrupted the boot configuration badly enough that GRUB couldn't hand off to the kernel.

That last one required a reload. No GRUB menu — the Mac Pro 2013 doesn't reliably show the GRUB menu with Shift or Escape the way a normal PC does. I had to boot from a live USB, mount the root partition, manually edit `/etc/default/grub` to remove the broken parameters, and run `update-grub` from the recovery environment.

### Blocker 2: PCIe Atomics

Even if the memory window were large enough, the RX 6800 requires PCIe Atomic operations for its memory controller (gmc_v10_0). Atomics are a PCIe 3.0 feature that allows the GPU to perform atomic read-modify-write operations across the PCI bus.

The Xeon E5 v2 doesn't support PCIe Atomics in its root complex. Neither does the Falcon Ridge Thunderbolt 2 controller. The GPU's memory controller initialization fails during the atomic capability check, and there's no driver workaround.

I tried `amdgpu.noretry=0` and `amdgpu.vm_update_mode=3` — both are supposed to change how the driver handles page table updates and could theoretically bypass the atomic requirement. They didn't. The driver's gmc_v10_0 init function checks for atomic support and fails hard.

### Blocker 3: EFI Display Handshake

If you connect a monitor to the eGPU, the Mac Pro's EFI firmware tries a display handshake during early boot. This crashes. Hard. The machine powers on, the screen flickers once, and then nothing. No boot, no GRUB, no recovery. You have to power cycle and disconnect the eGPU before the machine will boot again.

Headless mode — booting without any monitor connected to the eGPU — gets past this. But then you hit blockers 1 and 2. The display handshake crash is a separate, independent failure that would need to be solved in addition to the other two.

### The Desperation Attempts

I tried everything I could think of, and some things I found in obscure forum posts (you know how it goes):

**Hot-plug after boot.** If the OS is already running, maybe plugging in the eGPU would enumerate it with correct resources? The Thunderbolt controller detected the AKiTiO enclosure. The GPU never appeared on the PCI bus. The kernel's Thunderbolt driver established the tunnel, but PCI device enumeration didn't trigger.

**Hot-plug at GRUB.** Connect the eGPU cable while sitting at the GRUB boot menu, before Linux loads. GRUB froze immediately. Completely unresponsive. Required a hard power cycle.

**`nopat` kernel parameter.** Disables Page Attribute Tables, which can sometimes fix memory mapping issues with PCI devices. Crashed the kernel during early boot. Not a subtle failure — a hard panic.

**Full PCI rescan.** `echo 1 > /sys/bus/pci/rescan` — the command that tells the kernel to walk the entire PCI bus and look for new devices. On this hardware, it crashes the machine every time. EVERY time. I eventually learned to treat this command like a loaded gun on any system with Thunderbolt.

None of these were long shots. They were all documented solutions for various eGPU problems on various hardware. They just don't apply when the fundamental issue is in the Thunderbolt controller's silicon.

## Why It's Permanent

The three blockers aren't software bugs. They're hardware limitations:

1. **The Falcon Ridge TB2 controller** has a fixed, small memory window for downstream devices. The window size is determined by the controller's internal state machine, not by any configurable register. No driver, firmware update, or kernel parameter can change it.

2. **The Xeon E5 v2's root complex** doesn't implement PCIe Atomics. This is a silicon-level capability bit that's either present or not. It's not in the E5 v2. The Thunderbolt 2 controller doesn't route atomics even if the CPU supported them.

3. **The EFI firmware** performs a display handshake with any GPU it finds during POST. This behavior is in Apple's EFI implementation and can't be disabled or modified on T1-era Mac firmware.

Thunderbolt 3 fixed all three of these. Different controller silicon (Alpine Ridge, then Titan Ridge), wider memory windows, atomic routing, and different EFI behavior. That's why the Mac Mini 2018 works and the Mac Pro 2013 doesn't. It's not a question of drivers or software maturity. The physical hardware is different.

## The Aftermath

The AKiTiO Node Titan and the RX 6800 moved to the Mac Mini 2018, where they work. Getting them working there required a custom kernel module and PCI register reprogramming to deal with the T2 chip's firmware allocating 224MB instead of the 256MB the GPU needs — but at least that problem is solvable in software. The Mac Pro 2013's problems are in the silicon.

The Mac Pro 2013 itself is going to become a batch processing node — long-running file organization, metadata tagging, autonomous jobs that use the 128GB of RAM and 12 Xeon cores but don't need GPU compute. Good hardware for the right job — just not eGPU hardware.

If you have a Mac Pro 2013 and you're thinking about eGPU for ML inference: don't. Not over Thunderbolt 2, not with any RDNA GPU. The controller hardware can't support it. I hit it at full speed so you don't have to. If you have Thunderbolt 3 or later, the [Mac Mini 2018 setup guide](README.md) covers how to make that work, including the T2 firmware workaround.

*I used Claude to help draft and edit this article.*
