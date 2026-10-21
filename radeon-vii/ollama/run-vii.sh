#!/bin/bash
# Create both Radeon VII ollama containers (gfx906 ROCm, models kept hot).
# Prereq: the doorbell-BAR fix is applied — both VIIs bound to amdgpu, /dev/dri/card0+card1 exist.
# Image: gfx906-capable ROCm ollama (stock ollama's rocBLAS dropped gfx906).
IMAGE=${IMAGE:-xxdoman/ollama-mi50:latest}
MODELS=${MODELS:-$HOME/.ollama}     # host dir holding models/ and your GGUF (mounted at /root/.ollama)

run(){  # name  rocr_device  port
  sudo docker rm -f "$1" 2>/dev/null
  sudo docker run -d --name "$1" --restart unless-stopped \
    --device=/dev/kfd --device=/dev/dri --device-cgroup-rule='c 226:* rmw' \
    -e HSA_OVERRIDE_GFX_VERSION=9.0.6 \
    -e HSA_XNACK=0 \
    -e OLLAMA_LLM_LIBRARY=rocm \
    -e OLLAMA_FLASH_ATTENTION=1 \
    -e OLLAMA_KV_CACHE_TYPE=q4_0 \
    -e OLLAMA_NUM_PARALLEL=1 \
    -e OLLAMA_KEEP_ALIVE=-1 \
    -e ROCR_VISIBLE_DEVICES="$2" \
    -v "$MODELS":/root/.ollama \
    -p "$3":11434 "$IMAGE"
}
run ollama-vii  0 11435   # card0 (45:00.0)
run ollama-vii2 1 11436   # card1 (82:00.0)
echo "containers created. Install + run the warmer:"
echo "  sudo cp vii-warm.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/vii-warm.sh && sudo /usr/local/bin/vii-warm.sh"
