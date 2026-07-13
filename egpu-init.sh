#!/bin/bash
# eGPU BAR initialization for RX 6800 on Mac Mini 2018 (T2)
# Programs bridge pref windows + GPU BAR 0 to 64-bit space,
# loads kernel module to patch resource tree, then loads amdgpu.

LOG_TAG="egpu-init"
log() { logger -t "$LOG_TAG" "$1"; echo "$1"; }

log "=== eGPU Init Starting ==="

# Wait for Thunderbolt GPU to appear
GPU_BUS=""
for i in $(seq 1 30); do
    GPU_BUS=$(lspci -d 1002:73bf 2>/dev/null | head -1 | awk '{print $1}')
    [ -n "$GPU_BUS" ] && break
    sleep 2
done

if [ -z "$GPU_BUS" ]; then
    log "ERROR: RX 6800 not found after 60s"
    exit 1
fi
log "GPU found at $GPU_BUS"

# Walk the sysfs path to find all bridges from root to GPU
GPU_SYSFS=$(readlink -f /sys/bus/pci/devices/0000:$GPU_BUS 2>/dev/null)
if [ -z "$GPU_SYSFS" ]; then
    log "ERROR: Cannot resolve sysfs path for GPU"
    exit 1
fi

# Extract bridge BDFs from sysfs path (all 0000: entries except the GPU itself)
BRIDGES=$(echo "$GPU_SYSFS" | tr '/' '\n' | grep '^0000:' | head -n-1 | sed 's/^0000://')
log "Bridge chain: $BRIDGES -> $GPU_BUS"

# Program all bridges with 64-bit pref window: 0x4010000000-0x401FFFFFFF
log "Programming bridge pref windows..."
for br in $BRIDGES; do
    # Verify it's a bridge (class 0x0604xx)
    CLASS=$(cat /sys/bus/pci/devices/0000:$br/class 2>/dev/null)
    if [ "${CLASS:0:6}" = "0x0604" ]; then
        setpci -s "$br" 24.L=1FF11001 2>/dev/null
        setpci -s "$br" 28.L=00000040 2>/dev/null
        setpci -s "$br" 2C.L=00000040 2>/dev/null
        log "  $br: pref -> 0x4010000000-0x401FFFFFFF"
    fi
done

# Program GPU BAR 0 to 0x4010000000 (256MB, 64-bit prefetchable)
log "Programming GPU BAR 0..."
setpci -s "$GPU_BUS" COMMAND.W=0000
setpci -s "$GPU_BUS" 10.L=1000000C
setpci -s "$GPU_BUS" 14.L=00000040
setpci -s "$GPU_BUS" COMMAND.W=0007

BAR0_LO=$(setpci -s "$GPU_BUS" 10.L)
BAR0_HI=$(setpci -s "$GPU_BUS" 14.L)
log "BAR 0 programmed: low=$BAR0_LO high=$BAR0_HI"

# Load kernel module to patch resource tree
log "Loading egpu_bar module..."
modprobe egpu_bar 2>&1 || {
    insmod /lib/modules/$(uname -r)/extra/egpu_bar.ko 2>&1 || {
        log "ERROR: Failed to load egpu_bar"
        exit 1
    }
}

# Load amdgpu driver (blacklisted from auto-loading)
log "Loading amdgpu..."
modprobe amdgpu 2>&1
sleep 3

# Force high-performance power mode (prevents memory clock from idling at 96MHz)
if [ -f /sys/class/drm/card0/device/power_dpm_force_performance_level ]; then
    echo "high" > /sys/class/drm/card0/device/power_dpm_force_performance_level
    log "GPU power mode set to high"
fi

# Check result
if ls /dev/dri/card* >/dev/null 2>&1; then
    log "SUCCESS: eGPU initialized"
    ls -la /dev/dri/
else
    # Try manual bind if auto-probe didn't work
    echo "0000:$GPU_BUS" > /sys/bus/pci/drivers/amdgpu/bind 2>/dev/null
    sleep 3
    if ls /dev/dri/card* >/dev/null 2>&1; then
        log "SUCCESS: eGPU initialized (manual bind)"
    else
        log "FAILED: No /dev/dri devices"
        dmesg | grep -i "amdgpu\|egpu_bar" | tail -10
    fi
fi
