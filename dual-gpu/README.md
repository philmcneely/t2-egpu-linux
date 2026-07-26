# Dual-GPU variant

Multi-GPU version of the root `egpu_bar.c` / `egpu-init.sh`. The root files are
single-card; these loop over **every** RX 6800 and give each its own 256 MB
64-bit BAR window:

| Card index | BAR window | Confirmed hardware (DrTheopolis) |
|------------|------------|----------------------------------|
| 0 | `0x4010000000 – 0x401FFFFFFF` | 45:00.0 (Razer Core X, TB controller 0) |
| 1 | `0x4020000000 – 0x402FFFFFFF` | 82:00.0 (AKiTiO Node Titan, TB controller 1) |

Window assignment in `egpu-init.sh` and `egpu_bar.c` must stay in sync.

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

- **Boot-time only.** Swapping a Thunderbolt port or cable re-enumerates the card
  on a new bus with an unprogrammed BAR (amdgpu fails `-22`, no `/dev/dri`).
  Reboot to re-run the init.
- **Enroll TB enclosures, don't just authorize.** `boltctl enroll --policy auto <uuid>`
  so they auto-authorize every boot; a live `echo 1 > .../authorized` does not persist.

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
