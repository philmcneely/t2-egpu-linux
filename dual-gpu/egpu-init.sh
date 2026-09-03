#!/bin/bash
# eGPU BAR init for RX 6800(s) (1002:73bf) on Mac Mini 2018 (T2).
# Programs BAR0 (256MB framebuffer) AND BAR2 (2MB doorbell) for each card
# into a 512MB 64-bit prefetchable window, loads the resource-tree module,
# then amdgpu. BAR2 is REQUIRED or the KIQ compute ring test times out (-110)
# because the GPU never sees ring doorbells (root cause of the 2nd-card fail).
#   card i: window base = 0x4010000000 + i*0x20000000 (512MB stride)
#     BAR0 -> base            (256MB)   reg 10/14
#     BAR2 -> base+0x10000000 (2MB)     reg 18/1C
# Window math must match egpu_bar.c.
LOG_TAG="egpu-init"; log(){ logger -t "$LOG_TAG" "$1"; echo "$1"; }
log "=== eGPU Init (RX6800 + doorbell BAR2) ==="

# Wait for BOTH cards to enumerate. The 2nd TB enclosure (Razer on the 2nd
# controller) can authorize up to ~135s into boot; grabbing only the first
# leaves the 2nd card unprogrammed. amdgpu is blacklisted and loaded below,
# so a late card never gets a poisoned no-BAR auto-probe. Wait up to ~200s.
GPU_BUSES=""; EXPECT=${EGPU_EXPECT:-2}; PREV_CNT=-1
for i in $(seq 1 100); do
	GPU_BUSES=$(lspci -d 1002:73bf 2>/dev/null | awk '{print $1}' | sort)
	CNT=$(printf '%s\n' "$GPU_BUSES" | grep -c .)
	log "  settle wait: $CNT/$EXPECT card(s) (i=$i)"
	if [ "$CNT" -ge "$EXPECT" ] && [ "$CNT" -eq "$PREV_CNT" ]; then break; fi
	PREV_CNT=$CNT
	sleep 2
done
[ -z "$GPU_BUSES" ] && { log "ERROR: no RX 6800 found after ~200s"; exit 1; }
log "Found $(echo "$GPU_BUSES" | wc -l) card(s): $(echo $GPU_BUSES | tr '\n' ' ')"

idx=0
for GPU_BUS in $GPU_BUSES; do
	# 512MB window per card; PCI bridge pref fields are 1MB-granular (bits 31:20)
	base20=$(( 0x100 + idx * 0x200 ))          # 0x100, 0x300, ...
	limit20=$(( base20 + 0x1FF ))              # +512MB
	base_reg=$(( (base20 << 4) | 1 ))
	limit_reg=$(( (limit20 << 4) | 1 ))
	REG24=$(printf '%04X%04X' $limit_reg $base_reg)
	BAR0_LO=$(printf '%08X' $(( (0x10000000 + idx * 0x20000000) | 0xC )))   # base
	BAR2_LO=$(printf '%08X' $(( (0x20000000 + idx * 0x20000000) | 0xC )))   # base+256MB
	log "GPU[$idx] $GPU_BUS win base20=0x$(printf %X $base20) reg24=$REG24 bar0=$BAR0_LO bar2=$BAR2_LO"

	GPU_SYSFS=$(readlink -f /sys/bus/pci/devices/0000:$GPU_BUS 2>/dev/null)
	[ -z "$GPU_SYSFS" ] && { log "ERROR: no sysfs for $GPU_BUS"; idx=$((idx+1)); continue; }
	BRIDGES=$(echo "$GPU_SYSFS" | tr '/' '\n' | grep '^0000:' | head -n-1 | sed 's/^0000://')
	for br in $BRIDGES; do
		CLASS=$(cat /sys/bus/pci/devices/0000:$br/class 2>/dev/null)
		if [ "${CLASS:0:6}" = "0x0604" ]; then
			setpci -s "$br" 24.L=$REG24 2>/dev/null
			setpci -s "$br" 28.L=00000040 2>/dev/null
			setpci -s "$br" 2C.L=00000040 2>/dev/null
			log "    $br: 512M pref window programmed"
		fi
	done

	setpci -s "$GPU_BUS" COMMAND.W=0000
	setpci -s "$GPU_BUS" 10.L=$BAR0_LO      # BAR0 low  (framebuffer)
	setpci -s "$GPU_BUS" 14.L=00000040      # BAR0 high
	setpci -s "$GPU_BUS" 18.L=$BAR2_LO      # BAR2 low  (doorbell)
	setpci -s "$GPU_BUS" 1C.L=00000040      # BAR2 high
	setpci -s "$GPU_BUS" COMMAND.W=0007
	log "  $GPU_BUS BAR0=$(setpci -s $GPU_BUS 10.L)/$(setpci -s $GPU_BUS 14.L) BAR2=$(setpci -s $GPU_BUS 18.L)/$(setpci -s $GPU_BUS 1C.L)"
	idx=$((idx + 1))
done

log "Loading egpu_bar module..."
modprobe egpu_bar 2>&1 || insmod /lib/modules/$(uname -r)/extra/egpu_bar.ko 2>&1 || { log "ERROR: egpu_bar load failed"; exit 1; }

log "Loading amdgpu..."
modprobe amdgpu 2>&1
sleep 4

for dev in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
	[ -f "$dev" ] && echo high > "$dev" 2>/dev/null && log "power mode high: $dev"
done
for GPU_BUS in $GPU_BUSES; do
	if [ ! -e "/sys/bus/pci/devices/0000:$GPU_BUS/drm" ]; then
		echo "0000:$GPU_BUS" > /sys/bus/pci/drivers/amdgpu/bind 2>/dev/null
		sleep 2
	fi
done

CARD_COUNT=$(ls -d /sys/class/drm/card[0-9]*/device/driver 2>/dev/null | while read p; do readlink "$p" | grep -q amdgpu && echo x; done | wc -l)
if ls /dev/dri/card* >/dev/null 2>&1; then
	log "SUCCESS: $CARD_COUNT amdgpu card(s) up; /dev/dri:"; ls -la /dev/dri/
else
	log "FAILED: no /dev/dri"; dmesg | grep -iE "amdgpu|egpu_bar|kiq|ring|-110|gfx_v10" | tail -18
fi
