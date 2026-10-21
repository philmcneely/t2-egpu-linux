# Running LLM inference on Radeon VII (gfx906) — the ollama/ROCm gotchas

Once the doorbell-BAR fix (see [`README.md`](README.md)) has both VIIs bound to `amdgpu`
with `/dev/dri/card0` + `card1`, this is everything needed to actually serve models on
them. All of it was non-obvious; each item cost real time.

Confirmed hardware: 2× Radeon VII (16 GB) eGPU on a Mac Mini 2018 (T2), **16 GB system
RAM**, Ubuntu 24.04, ROCm 7.2, model = Qwen3.8-27B (IQ4_XS GGUF, ~15 GB).

## 1. ROCm sees gfx906, but stock ollama's rocBLAS dropped it — use a gfx906 image

`rocminfo` shows the VIIs as `gfx906` agents on ROCm 7.2, but **stock ollama's *bundled*
rocBLAS no longer ships gfx906 kernels**:

```
dropping ROCm device — no rocblas support for gfx target gfx906
  supported=[gfx1030 gfx1100 gfx1101 gfx1102 gfx908 gfx90a gfx942 gfx950 ...]
```

Ollama then silently falls back to its **Vulkan/RADV** backend, which *works* but is
**~20× slower** for LLM compute on Vega:

| backend | Qwen3.8-27B | llama3.2:1b |
|---|---|---|
| Vulkan (RADV) | — | ~9 tok/s |
| **ROCm gfx906** | **~23 tok/s** | **~190 tok/s** |

Fix: run a gfx906-capable ROCm ollama image. We use **`xxdoman/ollama-mi50`** (ROCm 7.2 +
gfx906 rocBLAS; built for the MI50, same gfx906 silicon as the VII — the 32 GB-vs-16 GB
difference only matters for model size).

## 2. `HSA_XNACK=0` is mandatory to keep BOTH models resident on 16 GB RAM

The single hardest-won flag. Each VII has its own 16 GB VRAM, so both models fit VRAM
fine. But pinning **both** 15 GB models hot at once fails when the second loads:

```
amdgpu: SVM mapping failed, exceeds resident system memory limit
... timed out waiting for llama-server to start
```

This is **not** RAM exhaustion (there was 13 GB RAM + 7.7 GB GTT free) — it's the KFD
**SVM / unified-memory** path hitting a resident limit. These models don't use managed
memory, so disable it: **`-e HSA_XNACK=0`** on every container. With it, both models load
and stay `Forever`.

## 3. `think:false` — not `/no_think` — to stop Qwen's reasoning runaway

Qwen3.8-27B is a reasoning model. On a coding task it will "think" until it exhausts the
token budget and emit only a fragment. The `/no_think` prompt tag is **ignored** by this
GGUF's template. Use ollama's native API param instead:

```json
{"model":"qwen38-vii","prompt":"...","think":false,"stream":false,"options":{...}}
```

With `think:false` it emits code directly and finishes (`done_reason:stop`). (On the
macOS-Metal fork, forcing no-think produced *garbage* — that's a wave64-Metal bug, absent
on ROCm.)

## 4. Context: 16k fits, 32k does not

At `num_ctx=16384` the 15 GB model + KV stays 100 % on-GPU (`q4_0` KV cache). **32k does
not fit** — the activation/compute buffers push past 16 GB even with q4 KV, and the load
fails. Cap at 16k. For codegen set `num_predict` ~14000 (a full "sand physics" app is
~10k tokens; "dungeon" ~9k).

## 5. Stagger the model loads — never load both cold at once

Both containers read the same 15 GB blob from the same disk. Loading them **concurrently**
cold saturates disk I/O so both loads exceed their client timeout (`499, client
connection closed`). Always warm **card0 fully, then card1** (sequential). card1 (the
second TB controller) also just loads slower, so give it a generous timeout (≥600 s). A
load that times out mid-way leaves **orphaned VRAM** — `docker restart` that container to
clear it before retrying.

## 6. One instance per card; no tensor-split

Run a separate container per card, pinned with `ROCR_VISIBLE_DEVICES=0` / `=1` on separate
ports (11435 / 11436). A single model tensor-split across the two cards **segfaults** —
there's no GPU P2P across the two separate Thunderbolt controllers.

## 7. ollama ignores Qwen's MTP tensors

The GGUF carries `blk.64.nextn.*` (multi-token-prediction) tensors; ollama logs them as
`unused ... ignoring`. So **MTP speculative decoding is not available via ollama** — that
headroom needs a runtime that implements nextn (e.g. llama.cpp), not a flag.

## Deploy (both cards, keep-hot, staggered boot)

See [`ollama/`](ollama/):

- **`run-vii.sh`** — creates both containers (`--restart unless-stopped`, `HSA_XNACK=0`,
  `OLLAMA_KEEP_ALIVE=-1`, `q4_0` KV, flash-attn, per-card `ROCR_VISIBLE_DEVICES`).
- **`vii-warm.sh`** → `/usr/local/bin/vii-warm.sh` — waits for the GPUs, then warms
  card0 then card1 **sequentially** (staggered load) with `keep_alive:-1`.
- **`fleet-vii-warmer.service`** — runs the warmer on boot, `After=egpu-init.service
  docker.service`, so the order is: eGPU BAR fix → amdgpu → docker → staggered warm →
  both hot.

Import a raw GGUF into a container:
```sh
docker exec ollama-vii sh -c 'printf "FROM /root/.ollama/<model>.gguf\n" > /root/M && ollama create qwen38-vii -f /root/M'
```
(mount the GGUF via `-v <hostdir>:/root/.ollama`).

## Measured

- Qwen3.8-27B @ 16k, one card: **~23 tok/s**, 100 % GPU, fully resident — **beats the
  macOS-Metal ceiling (16.8 tok/s) by ~40 %.**
- Both cards generating simultaneously (pre-warmed): **~18–19 tok/s each**, complete apps.
- Clean-state staggered load of both 15 GB models: **~3.5 min total.**
