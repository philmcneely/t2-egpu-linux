# Radeon VII (Vega 20 / gfx906) variant

Port of the `dual-gpu/` RX 6800 setup to the **AMD Radeon VII** (Vega 20, gfx906,
`1002:66af`) over Thunderbolt 3 on the Mac Mini 2018 (T2). Confirmed on 2× Radeon VII
eGPUs (Razer Core X + Razer Core), Ubuntu 24.04, kernel `7.0.9-1-t2-noble`.

## What's different from the RX 6800 (Navi 21)

The Navi cards only need **BAR 0** (framebuffer) reprogrammed into a 64-bit window. The
Radeon VII additionally needs its **doorbell BAR (BAR 2)** mapped — and this is the whole
game. Without it, `amdgpu` gets all the way through memory-controller, GART, PSP and
firmware init, then the **compute engine's KIQ ring test times out**:

```
amdgpu 0000:xx:00.0: ring kiq_0.2.1.0 test failed (-110)
amdgpu 0000:xx:00.0: KCQ enable failed
amdgpu 0000:xx:00.0: hw_init of IP block <gfx_v9_0> failed -110
amdgpu 0000:xx:00.0: Fatal error during GPU init
```

The KIQ (Kernel Interface Queue) signals the GPU through **doorbells**, which live in
BAR 2 (2 MB, 64-bit prefetchable). The T2 firmware leaves BAR 2 unassigned, so the ring
never sees its doorbell and the test times out. Navi's setup never hits this because the
Navi ring/doorbell path was already satisfied by the BAR 0 window; Vega's is not.

## The fix

Each card gets a **512 MB** 64-bit prefetchable window (stride `0x20000000`):

| Region | Offset in window | Size | setpci reg |
|---|---|---|---|
| BAR 0 (framebuffer) | `base + 0x00000000` | 256 MB | `10/14` |
| BAR 2 (**doorbell**) | `base + 0x10000000` | 2 MB | `18/1C` |

```
card 0 window: 0x4010000000 - 0x402FFFFFFF   (BAR0 @ 0x4010000000, BAR2 @ 0x4020000000)
card 1 window: 0x4030000000 - 0x404FFFFFFF   (BAR0 @ 0x4030000000, BAR2 @ 0x4040000000)
```

`egpu-init.sh` programs both BARs + the bridge pref windows with `setpci`; `egpu_bar.c`
patches **both** `resource[0]` and `resource[2]` in the kernel's PCI resource tree (with
`parent` set) so `amdgpu` will enable them. Everything else (GRUB params, blacklist,
systemd unit) is identical to the root guide — `amdgpu.rebar=0`, `pcie_aspm=off`, etc.
still apply.

Result: both VIIs bind `amdgpu`, `/dev/dri/card0` + `card1`, 16 GB VRAM each.

## Deploy

```sh
make
sudo cp egpu_bar.ko /lib/modules/$(uname -r)/extra/egpu_bar.ko
sudo depmod -a
sudo cp egpu-init.sh /usr/local/bin/egpu-init.sh
sudo chmod +x /usr/local/bin/egpu-init.sh
sudo reboot   # BAR programming is boot-time only
```

Enroll the enclosures so they auto-authorize every boot:
```sh
boltctl enroll --policy auto <uuid>
```

## Inference on gfx906 — use ROCm, not Vulkan

- **ROCm 7.2** recognizes gfx906 natively (`rocminfo` shows `gfx906` agents). But **stock
  ollama's bundled rocBLAS dropped gfx906** (`"no rocblas support for gfx target gfx906"`)
  and silently falls back to **Vulkan/RADV**, which is ~20× slower for LLM compute
  (measured **9 tok/s** on a 1B via Vulkan).
- Use a gfx906-capable ROCm ollama (e.g. `xxdoman/ollama-mi50`, ROCm 7.2 + gfx906 rocBLAS):
  **190 tok/s** on a 1B, and **Qwen3.8-27B (IQ4_XS, 15 GB) at ~23 tok/s, 100% GPU, 16k ctx**
  fully resident on one 16 GB card. 32k context does **not** fit (activation buffers push
  past 16 GB even with q4 KV) — cap at 16k.
- Run one instance per card (`ROCR_VISIBLE_DEVICES=0/1`, separate ports); tensor-split
  across the two separate TB controllers does not work (no P2P).

## Files

| File | Purpose |
|---|---|
| `egpu_bar.c` | Kernel module — patches BAR0 **and** doorbell BAR2 resources for `1002:66af` |
| `egpu-init.sh` | Boot script — setpci-programs both BARs + bridge windows, loads module + amdgpu |
| `Makefile` | Builds the module |
