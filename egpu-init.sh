#!/bin/bash
# eGPU BAR initialization for RX 6800 on Mac Mini 2018 (T2)
# Programs bridge pref windows + GPU BAR 0 to 64-bit space,
# loads kernel module to patch resource tree, then loads amdgpu.
#
# Fails closed:
#   - a card amdgpu already drives is never reprogrammed
#   - every register written is read back; if any bridge or BAR 0 does not read
#     back as written, memory decode stays off and nothing is loaded
#   - the GPU's HDMI audio function (.1) is unbound and pinned to no driver
#     (headless, amdgpu.dc=0: it has no use)
# Exit: 0 = card up, or no eGPU attached; 1 = card found but not brought up;
#       3 = EGPU_VERIFY_ONLY=1 and a register does not match
# Env:  EGPU_SETTLE_TRIES (default 30, 2s each), EGPU_VERIFY_ONLY=1 (read and compare only),
#       EGPU_SYSFS / EGPU_DEVROOT (alternate /sys and /dev, tests only)

LOG_TAG="egpu-init"
log() { logger -t "$LOG_TAG" "$1"; echo "$1"; }
SYS=${EGPU_SYSFS:-/sys}; DEV=${EGPU_DEVROOT:-/dev}
VERIFY_ONLY=${EGPU_VERIFY_ONLY:-0}

log "=== eGPU Init Starting$([ "$VERIFY_ONLY" = 1 ] && echo ' (VERIFY-ONLY)') ==="

if [ -z "$EGPU_SYSFS" ] && [ "$(id -u)" != 0 ]; then
    log "ERROR: must run as root"; exit 1
fi

# Window: 0x4010000000-0x401FFFFFFF (256MB, 64-bit prefetchable)
# Register 0x24 = Prefetchable Memory Base/Limit (bits 31:16 = limit, 15:0 = base)
# Register 0x28 = Prefetchable Base Upper 32 bits
# Register 0x2C = Prefetchable Limit Upper 32 bits
REG24=1FF11001; UPPER=00000040; BAR0_LO=1000000C

# Wait for Thunderbolt GPU to appear (up to 60 seconds)
GPU_BUS=""
TRIES=${EGPU_SETTLE_TRIES:-30}
case "$TRIES" in ''|*[!0-9]*|0) log "EGPU_SETTLE_TRIES='$TRIES' is not a positive number — using 30"; TRIES=30 ;; esac
[ "$VERIFY_ONLY" = 1 ] && TRIES=1
for _ in $(seq 1 "$TRIES"); do
    GPU_BUS=$(lspci -d 1002:73bf 2>/dev/null | head -1 | awk '{print $1}')
    [ -n "$GPU_BUS" ] && break
    sleep 2
done

if [ -z "$GPU_BUS" ]; then
    log "no eGPU attached (no RX 6800 on the bus) — nothing to do"
    exit 0
fi
log "GPU found at $GPU_BUS"
DEVDIR="$SYS/bus/pci/devices/0000:$GPU_BUS"

# Walk the sysfs path to find all bridges from root to GPU
GPU_SYSFS=""
[ -d "$DEVDIR" ] && GPU_SYSFS=$(readlink -f "$DEVDIR" 2>/dev/null)
if [ -z "$GPU_SYSFS" ]; then
    log "ERROR: no sysfs entry for $GPU_BUS — nothing written"
    exit 1
fi
BRIDGES=""
for br in $(echo "$GPU_SYSFS" | tr '/' '\n' | grep '^0000:' | head -n-1 | sed 's/^0000://'); do
    [ "$(cut -c1-6 "$SYS/bus/pci/devices/0000:$br/class" 2>/dev/null)" = "0x0604" ] && BRIDGES="$BRIDGES $br"
done
log "Bridge chain:$BRIDGES -> $GPU_BUS"
if [ -z "$BRIDGES" ]; then
    log "ERROR: no PCI bridges found above $GPU_BUS — nothing written"
    exit 1
fi

if [ "$VERIFY_ONLY" != 1 ] && [ -e "$DEVDIR/driver" ]; then
    log "GPU already bound to $(basename "$(readlink "$DEVDIR/driver")") — leaving its window alone"
    exit 0
fi

if [ "$VERIFY_ONLY" != 1 ]; then
    log "Programming bridge pref windows..."
    for br in $BRIDGES; do
        setpci -s "$br" 24.L=$REG24 2>/dev/null   # base=0x10010000, limit=0x1FF10000
        setpci -s "$br" 28.L=$UPPER 2>/dev/null   # upper base = 0x40
        setpci -s "$br" 2C.L=$UPPER 2>/dev/null   # upper limit = 0x40
    done

    # Program GPU BAR 0 to 0x4010000000 (256MB, 64-bit prefetchable)
    # Disable bus mastering + memory access during BAR programming
    log "Programming GPU BAR 0..."
    setpci -s "$GPU_BUS" COMMAND.W=0000          # disable everything
    setpci -s "$GPU_BUS" 10.L=$BAR0_LO           # BAR 0 low: addr + 64-bit + prefetchable flags
    setpci -s "$GPU_BUS" 14.L=$UPPER             # BAR 0 high: 0x40
fi

# Read back every register written
MISMATCH=""
check_reg() {
    local got want
    got=$(setpci -s "$1" "$2" 2>/dev/null | tr 'A-F' 'a-f'); want=$(echo "$3" | tr 'A-F' 'a-f')
    [ "$got" = "$want" ] || MISMATCH="$MISMATCH $1 $2 want=$want got=${got:-none};"
}
for br in $BRIDGES; do
    check_reg "$br" 24.L $REG24; check_reg "$br" 28.L $UPPER; check_reg "$br" 2C.L $UPPER
done
check_reg "$GPU_BUS" 10.L $BAR0_LO; check_reg "$GPU_BUS" 14.L $UPPER

if [ "$VERIFY_ONLY" = 1 ]; then
    [ -z "$MISMATCH" ] && { log "VERIFY: bridges + BAR 0 match"; exit 0; }
    log "VERIFY: MISMATCH:$MISMATCH"; exit 3
fi
if [ -n "$MISMATCH" ]; then
    log "FAILED: registers did not read back —$MISMATCH memory decode left off, nothing loaded"
    exit 1
fi
setpci -s "$GPU_BUS" COMMAND.W=0007              # re-enable IO + Mem + BusMaster
log "BAR 0 and$(echo $BRIDGES | wc -w | sed 's/^/ /') bridge windows read back as written"

# HDMI audio function: unbind and keep it unbound
AUD="$SYS/bus/pci/devices/0000:${GPU_BUS%.*}.1"
if [ -e "$AUD" ] && { [ "$(cut -c1-6 "$AUD/class" 2>/dev/null)" != 0x0403 ] || [ "$(cat "$AUD/vendor" 2>/dev/null)" != 0x1002 ]; }; then
    log "${GPU_BUS%.*}.1 is not AMD HDMI audio — leaving it alone"
elif [ -e "$AUD" ]; then
    echo none > "$AUD/driver_override" 2>/dev/null
    [ -e "$AUD/driver" ] && echo "0000:${GPU_BUS%.*}.1" > "$AUD/driver/unbind" 2>/dev/null && log "audio function unbound"
fi

# Load kernel module to patch resource tree
log "Loading egpu_bar module..."
modprobe egpu_bar 2>&1 || {
    insmod "/lib/modules/$(uname -r)/extra/egpu_bar.ko" 2>&1 || {
        log "ERROR: Failed to load egpu_bar"
        exit 1
    }
}

# Load amdgpu driver (blacklisted from auto-loading)
log "Loading amdgpu..."
modprobe amdgpu 2>&1
sleep 3

# Force high-performance power mode (prevents memory clock from idling at 96MHz)
PERF="$DEVDIR/power_dpm_force_performance_level"

# Success = this GPU is bound to amdgpu. Not "/dev/dri/card* exists": the Mac's
# Intel iGPU has a DRM card of its own.
gpu_up() { [ "$(basename "$(readlink "$DEVDIR/driver" 2>/dev/null)" 2>/dev/null)" = amdgpu ]; }

if ! gpu_up; then
    # Try manual bind if auto-probe didn't work
    echo "0000:$GPU_BUS" > "$SYS/bus/pci/drivers/amdgpu/bind" 2>/dev/null
    sleep 3
fi
if gpu_up; then
    [ -f "$PERF" ] && echo high > "$PERF" 2>/dev/null && log "GPU power mode set to high"
    log "SUCCESS: eGPU initialized"
    ls -la "$DEV/dri/"
    exit 0
fi
log "FAILED: $GPU_BUS not bound to amdgpu"
dmesg | grep -i "amdgpu\|egpu_bar" | tail -10
exit 1
