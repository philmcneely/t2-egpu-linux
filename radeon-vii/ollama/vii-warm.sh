#!/bin/bash
# Stagger the two 15GB VII model loads so they never collide on disk, and pin them hot.
# Wait for the eGPUs (amdgpu) to be present first.
for i in $(seq 1 90); do [ -e /dev/kfd ] && [ -e /dev/dri/card0 ] && [ -e /dev/dri/card1 ] && break; sleep 2; done
warm(){  # container  port
  logger -t vii-warmer "loading $1 on :$2"
  for i in $(seq 1 60); do curl -s -m3 "http://127.0.0.1:$2/api/version" >/dev/null 2>&1 && break; sleep 2; done
  # card1 (2nd TB controller) loads slower — give it a generous timeout
  curl -s -m600 "http://127.0.0.1:$2/api/generate" \
    -d '{"model":"qwen38-vii","prompt":"hi","think":false,"stream":false,"keep_alive":-1,"options":{"num_ctx":16384,"num_predict":3}}' >/dev/null 2>&1
  logger -t vii-warmer "$1 hot"
}
warm ollama-vii  11435    # card0 FIRST
warm ollama-vii2 11436    # card1 only AFTER card0 finished loading (staggered)
logger -t vii-warmer "both VII models hot (staggered load complete)"
