# Operating the dual Radeon VII box — keep-hot, boot chain, and the traps

Hard-won runbook for running two Radeon VII (gfx906) eGPUs on a Mac Mini 2018 (T2, **16 GB
RAM**) as a persistent LLM host. Read the traps — most of them cost hours.

## Boot chain (cold boot → both models hot)

```
GRUB (T2 kernel + amdgpu.rebar=0 pcie_aspm=off …)
  → egpu-init.service        # doorbell-BAR fix, programs BOTH cards, loads amdgpu
  → docker.service           # containers auto-start (--restart unless-stopped)
  → fleet-vii-warmer.service # warms card0 then card1 sequentially, pins them
```

Services (see [`ollama/`](ollama/) + [`egpu-init.service`](egpu-init.service)):
- `egpu-init.service` → `/usr/local/bin/egpu-init.sh` (the VII doorbell version).
- `fleet-vii-warmer.service` (`After=egpu-init.service docker.service`) → `/usr/local/bin/vii-warm.sh`.

## Keep both models hot

- `OLLAMA_KEEP_ALIVE=-1` + `keep_alive:-1` on the warm request → model stays `Forever`.
- `--restart unless-stopped` on the containers → survive reboots / docker restarts.
- `vii-warm.sh` loads **card0, then card1, sequentially** and retries+verifies each.
- Once both are loaded they coexist fine (steady state is stable); the fragile part is
  *loading*, so the warmer exists to make loading deterministic.

## The traps (each cost real debugging time)

### 1. Cold-boot eGPU enumeration is a race — wait for BOTH cards
The two Thunderbolt enclosures authorize at slightly different times. If `egpu-init` grabs
the first VII it sees and proceeds, the second card is left unprogrammed and unbound:
`amdgpu` binds one, only `/sys/class/drm/card0` appears, and any container pinned to the
missing card silently falls back to **100 % CPU**. `egpu-init.sh` now waits for a stable
count of 2 (`VII_EXPECT` override). **Always verify `ls /sys/class/drm/ | grep card` shows
`card0 card1` before trusting a boot.**

### 2. NEVER reprogram a card's BAR while amdgpu is bound to it
If a card is already `amdgpu`-bound and you re-run the setpci BAR programming on it, it can
leave the card **enumerated but compute-dead** — it discovers as a ROCm gfx906 agent, but
`llama-server` won't run on it (loads fail). It is *not* a clean way to fix a half-up boot.
To re-init cleanly: **stop the containers, `rmmod amdgpu; rmmod egpu_bar`, then run
`egpu-init.sh`** so both cards are programmed *before* amdgpu binds. If that doesn't clear a
compute-dead card, **a cold reboot does** (fresh program before bind). This is recoverable
state, not hardware.

### 3. `SVM mapping failed, exceeds resident system memory limit` is a RED HERRING
This dmesg line appears when a model load fails, and it *looks* like a 16 GB-RAM ceiling on
keeping two 15 GB models resident. **It is not the real constraint** — there was 13 GB RAM
and 7.7 GB GTT free the whole time. Do **not** burn time on `HSA_XNACK`, `--ulimit
memlock`, GTT tuning, or "two models don't fit RAM." The actual failures were #2 (dead
card) and #4 (registry corruption). Both models *do* fit and stay hot.

### 4. Concurrent `ollama rm`/`create` on the SHARED store corrupts the registry
Both containers bind-mount the same `~/.ollama`. Thrashing it with repeated `ollama
rm`/`create` (or racing two containers) can empty a model's manifest dir while `ollama
list` still shows it (cached) → `{"error":"model 'X' not found"}` on load, even though the
blob is present and `ollama show` works. **Fix:** recreate the model once
(`ollama create qwen38-vii -f Modelfile`) and stop churning it. Don't run create/rm from
one container while the other serves.

### 5. card1 (82:00.0) loads noticeably slower than card0 (45:00.0)
Its Thunderbolt controller is slower — a cold 15 GB load can take ~7 min vs ~5 min. Give
warm/load requests a ≥600 s timeout. A load that times out mid-way leaves **orphaned VRAM**
(VRAM shows ~14 GB used but the model isn't served) — `docker restart` that container to
clear it before retrying.

### 6. No GPU P2P across the two Thunderbolt controllers
`amdgpu: PCIe P2P access from peer device … is not supported by the chipset` — expected.
Tensor-split a single model across both cards segfaults. Run one model per card.

## Recovery cookbook

| Symptom | Fix |
|---|---|
| Only `card0` in `/sys/class/drm` after boot | Re-run `egpu-init.sh` **after** `rmmod amdgpu egpu_bar` and stopping containers; or reboot (egpu-init now waits for both). |
| Card enumerates but every model load fails | Compute-dead from a BAR reprogram while bound (#2) → clean re-init or reboot. |
| `model 'X' not found` but blob exists / `ollama show` works | Registry corruption (#4) → `ollama create` the model once. |
| VRAM ~14 GB used but model not served | Orphaned load (#5) → `docker restart` that container. |
| Container serves on 100 % CPU | Its card didn't bind (#1) → fix enumeration, restart container. |

## Health check one-liner

```sh
ls /sys/class/drm/ | grep -c '^card[0-9]'          # want 2
for p in 11435 11436; do docker exec ollama-vii$([ $p = 11436 ] && echo 2) ollama ps; done   # want both Forever, 100% GPU
```
