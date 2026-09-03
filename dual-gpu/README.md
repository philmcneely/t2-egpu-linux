# Dual-GPU variant

Multi-GPU version of the root `egpu_bar.c` / `egpu-init.sh`. The root files are
single-card; these loop over **every** RX 6800 and give each card its own
**512 MB** 64-bit prefetchable window holding **both** the framebuffer BAR (BAR0,
256 MB) and the doorbell BAR (BAR2, 2 MB):

| Card index | 512 MB window | BAR0 (framebuffer) | BAR2 (doorbell) | Hardware (DrTheopolis) |
|------------|---------------|--------------------|-----------------|------------------------|
| 0 | `0x4010000000 – 0x402FFFFFFF` | `0x4010000000` | `0x4020000000` | 45:00.0 (Razer Core X, TB controller 0) |
| 1 | `0x4030000000 – 0x404FFFFFFF` | `0x4030000000` | `0x4040000000` | 82:00.0 (AKiTiO Node Titan, TB controller 1) |

Window assignment in `egpu-init.sh` and `egpu_bar.c` must stay in sync.

> **Why 512 MB / two BARs?** The single-card code only relocated BAR0. That is
> enough for *one* card because the kernel happens to place its BAR2 in a
> forwarded window. The **second** card's doorbell BAR lands outside its bridge's
> forwarding window (e.g. `0xc0000000`), so the GPU never sees ring doorbells and
> `amdgpu` dies at `ring kiq_0 test failed (-110)` — the card is powered, firmware
> and SMU init fine, but the GFX/compute ring times out. Relocating BAR2 too, into
> the same widened window, fixes it. See the gotcha below.

## Deploy

```sh
# kernel module
make
sudo cp egpu_bar.ko /lib/modules/$(uname -r)/extra/egpu_bar.ko
sudo depmod -a
# boot script (overwrites the single-card version)
sudo cp egpu-init.sh /usr/local/bin/egpu-init.sh
sudo chmod +x /usr/local/bin/egpu-init.sh
sudo reboot     # BAR programming is boot-time only
```

## Gotchas

- **Relocate the doorbell BAR (BAR2), not just BAR0.** This is the one that costs
  real time. A second AMD eGPU behind a Thunderbolt bridge gets its 2 MB doorbell
  BAR placed *outside* its parent bridge's forwarding window, so KIQ ring doorbells
  go nowhere and `amdgpu` fails `ring kiq_0 test failed (-110)` / `hw_init of IP
  block <gfx_v10_0> failed -110` — even though the card is alive and its SMU
  initialized. The module widens each card's window to 512 MB and patches
  `resource[2]` (BAR2) alongside `resource[0]` (BAR0); the boot script `setpci`s
  both (`10/14` for BAR0, `18/1C` for BAR2). Confirm with `lspci -vv`: every card's
  `Region 2` must sit inside its bridge's *prefetchable memory behind bridge*
  window, and `Control:` must show `BusMaster+`. This is platform-, not
  Vega/Navi-specific — the sister box's two Radeon VIIs needed the identical fix.
- **Wait for *all* cards before loading amdgpu — and don't let systemd kill the
  wait.** The second enclosure (on the other Titan Ridge controller) can take
  ~130 s into boot to authorize on a warm reboot, and up to **~190 s on a cold
  boot**. Two things follow: (1) `egpu-init.sh` waits for a stable count of
  `EGPU_EXPECT` (default 2) cards — up to ~300 s — *before* it touches amdgpu, so a
  late card gets its BARs before the driver binds (a late card auto-probed with no
  BAR is left wedged); (2) `egpu-init.service` **must** set
  `TimeoutStartSec=infinity`. A finite timeout (the old 120 s) makes systemd kill
  the service before the 2nd card even arrives on a cold boot, so it never programs
  BARs or loads amdgpu and you boot with **zero** GPUs. This only shows up on a cold
  boot — warm reboots train Thunderbolt fast enough to hide it. If you run other
  services that need the GPUs (e.g. Ollama), order them `After=egpu-init.service`.
- **The BAR programming only happens at boot.** Swapping a Thunderbolt port or
  cable re-enumerates the card on a new bus with an unprogrammed BAR (amdgpu fails
  `-22`, no `/dev/dri`). Reboot to re-run the init.
- **Enroll TB enclosures, don't just authorize.** `boltctl enroll --policy auto <uuid>`
  so they auto-authorize every boot; a live `echo 1 > .../authorized` does not persist.
- **Drop `pci=realloc`.** It fights the manual BAR programming; the working config
  runs without it (`amdgpu.rebar=0` already keeps the framebuffer BAR at 256 MB).

## Per-card pinning (2× independent instances)

```sh
# card at 82:00.0
ROCR_VISIBLE_DEVICES=0 OLLAMA_MODELS=/usr/share/ollama/.ollama/models \
  OLLAMA_HOST=0.0.0.0:11435 OLLAMA_KEEP_ALIVE=-1 ollama serve
# card at 45:00.0
ROCR_VISIBLE_DEVICES=1 OLLAMA_MODELS=/usr/share/ollama/.ollama/models \
  OLLAMA_HOST=0.0.0.0:11434 OLLAMA_KEEP_ALIVE=-1 ollama serve
```

`OLLAMA_MODELS` must point at the store or the instance reports "model not found".

## Tensor-split across both cards: does not work here

A single large model split across both cards loads (VRAM fills on both) then
llama-server segfaults — no GPU peer-to-peer over the separate Thunderbolt
controllers. See [`benchmark-results.md`](benchmark-results.md). Use 2×
independent instances instead.
