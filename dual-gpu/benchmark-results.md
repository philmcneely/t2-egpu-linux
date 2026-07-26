# Dual-Card Benchmark — Raw Data

Host: DrTheopolis (Mac Mini 2018, T2, Ubuntu t2 kernel 7.0.9-1-t2-noble)
GPUs: 2× AMD RX 6800 (16 GB each, gfx1030), 32 GB total
- card0 / renderD128 = `0000:45:00.0` — Razer Core X — TB Controller 0 / domain0
- card1 / renderD129 = `0000:82:00.0` — AKiTiO Node Titan — TB Controller 1 / domain1
Ollama config: `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=q8_0`, `OLLAMA_KEEP_ALIVE=-1`
Pinning: `ROCR_VISIBLE_DEVICES=0` → card1 (82:00.0); `=1` → card0 (45:00.0); requires `OLLAMA_MODELS` set to the shared store.
Date: 2026-07-26

## Phase 1 — per-card parity (qwen3:14b-q4_K_M, pinned, num_ctx=4096)

| Card | Cold start | Warm avg (8 runs) | VRAM |
|------|-----------|-------------------|------|
| card1 / 82:00.0 (AKiTiO) | 23.3 tok/s (load 6.0 s) | 20.5 tok/s | 9207 MB |
| card0 / 45:00.0 (Core X) | 23.3 tok/s (load 7.8 s) | 20.5 tok/s | 9207 MB |

Both cards identical. No degradation on the second (Core X) card.

## Phase 2 — aggregate throughput (both cards concurrent)

8 concurrent requests (4 per card), qwen3:14b-q4_K_M:
- Aggregate: **164.3 tok/s**
- Wall time: 52.1 s
- VRAM during: card0=9207 MB, card1=9207 MB

## Single-card quant comparison

| Model | Weights | Single-card speed | VRAM (1 card) |
|-------|---------|-------------------|---------------|
| qwen3:14b-q4_K_M | Q4_K_M | 20.5 tok/s | 9.2 GB |
| qwen3-14b-q8kv | Q4_K_M + q8 KV cache | 21.0 tok/s | 9.2 GB |
| **qwen3:14b-q8_0** | **Q8_0 (true q8 weights)** | **10.2 tok/s** | **14.7 GB** |

True Q8 weights run at half the Q4 speed on this box — bandwidth-bound: Q8 moves ~2× the bytes per token over the Thunderbolt link. Q8 fits one 16 GB card with ~1.25 GB headroom (num_ctx 4096, q8 KV, flash attention).

## Phase 3 — MoE split across both cards (qwen3:30b-a3b-q8_0, 32.5 GB)

- Model loads across both cards: card0=14737 MB, card1=14913 MB (split confirmed)
- Inference: **llama-server SEGMENTATION FAULT** (every request)
- dmesg GPU errors: 0 (userspace crash, not a kernel GPU fault)
- Retest with `GGML_CUDA_NO_PEER_COPY=1` + `HSA_ENABLE_SDMA=0`: still segfaults (Ollama's bundled runner ignored the flag — system_info still showed `PEER_MAX_BATCH_SIZE=128`)

## Phase 4 — Dense split across both cards (gemma3:27b-it-q8_0, 29.6 GB)

- Model loads across both cards: card0=13965 MB, card1=12743 MB (split confirmed)
- Inference: **llama-server SEGMENTATION FAULT** (every request)
- dmesg GPU errors: 0

## Conclusion

- Single-card and per-card inference: rock solid, both cards full-speed peers.
- Aggregate (independent instances / batched concurrency): scales well, ~164 tok/s.
- Tensor-split of one large model across both cards: **not viable** on this topology. The two cards sit on separate Thunderbolt controllers with no GPU peer-to-peer, and llama.cpp's ROCm multi-GPU path assumes P2P — it loads onto both cards then crashes. Would require vLLM or a custom llama.cpp build to pursue.
- Production mode: 2× independent Ollama instances, one pinned per card, each with a model that fits 16 GB, both kept hot (`OLLAMA_KEEP_ALIVE=-1`).
