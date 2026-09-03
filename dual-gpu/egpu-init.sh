#!/bin/bash
# eGPU BAR initialization for RX 6800(s) on Mac Mini 2018 (T2)
# Programs bridge pref windows + GPU BAR 0 to 64-bit space for every
# RX 6800 found, loads the kernel module to patch the resource tree,
# then loads amdgpu.
#
# Multi-GPU: card i is placed at 0x4010000000 + i*0x10000000 (256MB each):
#   card 0 -> 0x4010000000 - 0x401FFFFFFF   (reg24 1FF11001)
#   card 1 -> 0x4020000000 - 0x402FFFFFFF   (reg24 2FF12001)
# Window math must match egpu_bar.c.

LOG_TAG="egpu-init"
log() { logger -t "$LOG_TAG" "$1"; echo "$1"; }

log "=== eGPU Init Starting ==="

# Wait for at least one Thunderbolt GPU to appear
GPU_BUSES=""
PREV_CNT=-1; STABLE=0
for i in $(seq 1 45); do
    GPU_BUSES=$(lspci -d 1002:73bf 2>/dev/null | awk '{print $1}' | sort)
    CNT=$(printf '%s\n' "$GPU_BUSES" | grep -c .)
    log "  settle wait: $CNT card(s) (i=$i)"
    # CRITICAL: wait for a STABLE count (up to 2) before any setpci -- programming
    # bridges while a 2nd card is still enumerating clobbers its PCIe tunnel.
    if [ "$CNT" -ge 2 ] && [ "$CNT" -eq "$PREV_CNT" ]; then break; fi
    if [ "$CNT" -ge 1 ] && [ "$CNT" -eq "$PREV_CNT" ]; then STABLE=$((STABLE+1)); else STABLE=0; fi
    [ "$STABLE" -ge 8 ] && break
    PREV_CNT=$CNT
    sleep 2
done

if [ -z "$GPU_BUSES" ]; then
    log "ERROR: no RX 6800 found after 60s"
    exit 1
fi

GPU_COUNT=$(echo "$GPU_BUSES" | wc -l)
log "Found $GPU_COUNT GPU(s): $(echo $GPU_BUSES | tr '\n' ' ')"

idx=0
for GPU_BUS in $GPU_BUSES; do
    # Window for this card
    base20=$(( 0x100 * (idx + 1) ))          # 0x100, 0x200, ...
    limit20=$(( base20 + 0xFF ))             # 0x1FF, 0x2FF, ...
    base_reg=$(( (base20 << 4) | 1 ))        # 0x1001, 0x2001, ...
    limit_reg=$(( (limit20 << 4) | 1 ))      # 0x1FF1, 0x2FF1, ...
    REG24=$(printf '%04X%04X' $limit_reg $base_reg)   # 1FF11001, 2FF12001
    BAR0_LO=$(printf '%08X' $(( (0x10000000 * (idx + 1)) | 0xC )))  # 1000000C, 2000000C

    log "GPU[$idx] $GPU_BUS -> window base20=0x$(printf %X $base20) reg24=$REG24 bar0=$BAR0_LO"

    # Walk the sysfs path to find all bridges from root to this GPU
    GPU_SYSFS=$(readlink -f /sys/bus/pci/devices/0000:$GPU_BUS 2>/dev/null)
    if [ -z "$GPU_SYSFS" ]; then
        log "ERROR: cannot resolve sysfs path for GPU $GPU_BUS"
        idx=$((idx + 1))
        continue
    fi

    BRIDGES=$(echo "$GPU_SYSFS" | tr '/' '\n' | grep '^0000:' | head -n-1 | sed 's/^0000://')
    log "  bridge chain: $(echo $BRIDGES | tr '\n' ' ')-> $GPU_BUS"

    # Program each bridge in this GPU's chain with its 64-bit pref window
    for br in $BRIDGES; do
        CLASS=$(cat /sys/bus/pci/devices/0000:$br/class 2>/dev/null)
        if [ "${CLASS:0:6}" = "0x0604" ]; then
            setpci -s "$br" 24.L=$REG24 2>/dev/null
            setpci -s "$br" 28.L=00000040 2>/dev/null
            setpci -s "$br" 2C.L=00000040 2>/dev/null
            log "    $br: pref window programmed"
        fi
    done

    # Program GPU BAR 0 (256MB, 64-bit prefetchable)
    setpci -s "$GPU_BUS" COMMAND.W=0000
    setpci -s "$GPU_BUS" 10.L=$BAR0_LO
    setpci -s "$GPU_BUS" 14.L=00000040
    setpci -s "$GPU_BUS" COMMAND.W=0007

    B0LO=$(setpci -s "$GPU_BUS" 10.L)
    B0HI=$(setpci -s "$GPU_BUS" 14.L)
    log "  BAR 0 programmed: low=$B0LO high=$B0HI"

    idx=$((idx + 1))
done

# Load kernel module to patch resource tree (handles all GPUs)
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

# Force high-performance power mode on every card (prevents mem clock idling at 96MHz)
for dev in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
    [ -f "$dev" ] || continue
    echo "high" > "$dev" 2>/dev/null && log "power mode high: $dev"
done

# Bind any GPU the auto-probe missed, then report
for GPU_BUS in $GPU_BUSES; do
    if [ ! -e "/sys/bus/pci/devices/0000:$GPU_BUS/drm" ]; then
        echo "0000:$GPU_BUS" > /sys/bus/pci/drivers/amdgpu/bind 2>/dev/null
        sleep 2
    fi
done

CARD_COUNT=$(ls -d /sys/class/drm/card[0-9]*/device/driver 2>/dev/null | while read p; do
    readlink "$p" | grep -q amdgpu && echo x; done | wc -l)
if ls /dev/dri/card* >/dev/null 2>&1; then
    log "SUCCESS: $CARD_COUNT amdgpu card(s) up; /dev/dri:"
    ls -la /dev/dri/
else
    log "FAILED: No /dev/dri devices"
    dmesg | grep -i "amdgpu\|egpu_bar" | tail -15
fi
