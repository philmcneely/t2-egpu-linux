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
#
# Fails closed, per card:
#   - a card amdgpu already drives is never reprogrammed (rewriting BARs under a
#     live driver hangs the box); its window stays as it is
#   - every register written is read back; a card whose bridge chain or BARs do
#     not read back as written gets memory decode turned off and driver_override
#     "none", so amdgpu never touches it
#   - nothing loads (egpu_bar, amdgpu) unless at least one card verified
# The GPU's HDMI audio function (.1) is unbound and pinned to no driver: the box
# runs headless with amdgpu.dc=0, so it has no use and should not probe a card
# behind a hand-built window.
#
# Exit: 0 = at least one card up, or no eGPU attached
#       1 = cards found but none came up (not root, all failed checks, load failure)
#       3 = EGPU_VERIFY_ONLY=1 and a register does not match
# Env:  EGPU_EXPECT (cards to wait for, default 2), EGPU_SETTLE_TRIES (default 150, 2s each)
#       EGPU_VERIFY_ONLY=1: read and compare every register, write and load nothing
#       EGPU_SYSFS / EGPU_DEVROOT: alternate /sys and /dev (tests only)
LOG_TAG="egpu-init"; log(){ logger -t "$LOG_TAG" "$1"; echo "$1"; }
SYS=${EGPU_SYSFS:-/sys}; DEV=${EGPU_DEVROOT:-/dev}
VERIFY_ONLY=${EGPU_VERIFY_ONLY:-0}
log "=== eGPU Init (RX6800 + doorbell BAR2)$([ "$VERIFY_ONLY" = 1 ] && echo ' VERIFY-ONLY') ==="

if [ -z "$EGPU_SYSFS" ] && [ "$(id -u)" != 0 ]; then
	log "ERROR: must run as root"; exit 1
fi

# Wait for BOTH cards to enumerate. The 2nd TB enclosure (Razer on the 2nd
# controller) can authorize up to ~190s into a cold boot; grabbing only the first
# leaves the 2nd card unprogrammed. amdgpu is blacklisted and loaded below,
# so a late card never gets a poisoned no-BAR auto-probe. Wait up to ~300s.
GPU_BUSES=""; EXPECT=${EGPU_EXPECT:-2}; PREV_CNT=-1; TRIES=${EGPU_SETTLE_TRIES:-150}
case "$TRIES" in ''|*[!0-9]*|0) log "  EGPU_SETTLE_TRIES='$TRIES' is not a positive number — using 150"; TRIES=150 ;; esac
case "$EXPECT" in ''|*[!0-9]*|0) EXPECT=2 ;; esac
[ "$VERIFY_ONLY" = 1 ] && TRIES=1
for i in $(seq 1 "$TRIES"); do
	GPU_BUSES=$(lspci -d 1002:73bf 2>/dev/null | awk '{print $1}' | sort)
	CNT=$(printf '%s\n' "$GPU_BUSES" | grep -c .)
	log "  settle wait: $CNT/$EXPECT card(s) (i=$i)"
	if [ "$CNT" -ge "$EXPECT" ] && [ "$CNT" -eq "$PREV_CNT" ]; then break; fi
	PREV_CNT=$CNT
	sleep 2
done
if [ -z "$GPU_BUSES" ]; then
	log "no eGPU attached (no 1002:73bf on the bus) — nothing to do"; exit 0
fi
log "Found $(echo "$GPU_BUSES" | wc -l) card(s): $(echo $GPU_BUSES | tr '\n' ' ')"

# check_reg <bdf> <reg> <expected-hex>: 0 if the register reads back as expected
MISMATCH=""
check_reg() {
	local got; got=$(setpci -s "$1" "$2" 2>/dev/null | tr 'A-F' 'a-f')
	local want; want=$(echo "$3" | tr 'A-F' 'a-f')
	if [ "$got" != "$want" ]; then
		MISMATCH="$MISMATCH $1 $2 want=$want got=${got:-none};"
		return 1
	fi
	return 0
}

# card_bridges <bdf>: the PCI bridges between the root and the card (empty if no sysfs entry)
card_bridges() {
	[ -d "$SYS/bus/pci/devices/0000:$1" ] || return 1
	local path; path=$(readlink -f "$SYS/bus/pci/devices/0000:$1" 2>/dev/null) || return 1
	[ -n "$path" ] || return 1
	echo "$path" | tr '/' '\n' | grep '^0000:' | head -n-1 | sed 's/^0000://' | while read -r br; do
		[ "$(cut -c1-6 "$SYS/bus/pci/devices/0000:$br/class" 2>/dev/null)" = "0x0604" ] && echo "$br"
	done
}

# card_values <window-index>: 512MB window per card; bridge pref fields are 1MB-granular (bits 31:20)
card_values() {
	local base20=$(( 0x100 + $1 * 0x200 ))     # 0x100, 0x300, ...
	local limit20=$(( base20 + 0x1FF ))        # +512MB
	REG24=$(printf '%04X%04X' $(( (limit20 << 4) | 1 )) $(( (base20 << 4) | 1 )))
	BAR0_LO=$(printf '%08X' $(( (0x10000000 + $1 * 0x20000000) | 0xC )))   # base
	BAR2_LO=$(printf '%08X' $(( (0x20000000 + $1 * 0x20000000) | 0xC )))   # base+256MB
	WIN_BASE20=$base20
}

# verify_card <bdf> <window-index> <bridges...>: every register reads back as written
verify_card() {
	local bus=$1 i=$2 br ok=0; shift 2
	card_values "$i"; MISMATCH=""
	for br in "$@"; do
		check_reg "$br" 24.L "$REG24" || ok=1
		check_reg "$br" 28.L 00000040 || ok=1
		check_reg "$br" 2C.L 00000040 || ok=1
	done
	check_reg "$bus" 10.L "$BAR0_LO" || ok=1
	check_reg "$bus" 14.L 00000040 || ok=1
	check_reg "$bus" 18.L "$BAR2_LO" || ok=1
	check_reg "$bus" 1C.L 00000040 || ok=1
	return $ok
}

# keep_off <bdf> <reason>: decode off and amdgpu kept away. If driver_override
# cannot be written, nothing may load (amdgpu would probe the broken card).
UNSAFE=0
keep_off() {
	setpci -s "$1" COMMAND.W=0000
	if ! echo none > "$SYS/bus/pci/devices/0000:$1/driver_override" 2>/dev/null; then
		log "  ERROR: cannot set driver_override for $1 — will not load amdgpu"; UNSAFE=1
	fi
	log "  ERROR: $1 $2 — card left off and unbound"
	FAILED="$FAILED $1"
}

declare -A IDX BRS
GOOD=""; KEPT=""; KEPT_BRIDGES=" "; FAILED=""; VERIFY_BAD=0
idx=0
for GPU_BUS in $GPU_BUSES; do
	IDX[$GPU_BUS]=$idx; idx=$((idx + 1))
	BRS[$GPU_BUS]=$(card_bridges "$GPU_BUS" | tr '\n' ' ')
	if [ "$VERIFY_ONLY" != 1 ] && [ -e "$SYS/bus/pci/devices/0000:$GPU_BUS/driver" ]; then
		KEPT="$KEPT $GPU_BUS"; KEPT_BRIDGES="$KEPT_BRIDGES${BRS[$GPU_BUS]}"
		log "GPU $GPU_BUS already bound to $(basename "$(readlink "$SYS/bus/pci/devices/0000:$GPU_BUS/driver")") — leaving its window alone"
	fi
done

for GPU_BUS in $GPU_BUSES; do
	case " $KEPT " in *" $GPU_BUS "*) continue ;; esac
	card_values "${IDX[$GPU_BUS]}"
	DEVDIR="$SYS/bus/pci/devices/0000:$GPU_BUS"
	read -r -a BRIDGES <<< "${BRS[$GPU_BUS]}"
	log "GPU $GPU_BUS win base20=0x$(printf %X "$WIN_BASE20") reg24=$REG24 bar0=$BAR0_LO bar2=$BAR2_LO"

	if [ ${#BRIDGES[@]} -eq 0 ]; then
		log "  ERROR: no sysfs bridge chain for $GPU_BUS — skipping it (nothing written)"; FAILED="$FAILED $GPU_BUS"; continue
	fi

	if [ "$VERIFY_ONLY" = 1 ]; then
		if verify_card "$GPU_BUS" "${IDX[$GPU_BUS]}" "${BRIDGES[@]}"; then log "  $GPU_BUS OK: ${#BRIDGES[@]} bridges + BAR0/BAR2 match"
		else log "  $GPU_BUS MISMATCH:$MISMATCH"; VERIFY_BAD=1; fi
		continue
	fi

	shared=""
	for br in "${BRIDGES[@]}"; do case "$KEPT_BRIDGES" in *" $br "*) shared=$br ;; esac; done
	if [ -n "$shared" ]; then
		keep_off "$GPU_BUS" "shares bridge $shared with a card amdgpu drives; rewriting it would move that card's window (nothing written)"
		continue
	fi

	# a card skipped on an earlier run may still carry driver_override=none
	echo > "$DEVDIR/driver_override" 2>/dev/null
	for br in "${BRIDGES[@]}"; do
		setpci -s "$br" 24.L="$REG24" 2>/dev/null
		setpci -s "$br" 28.L=00000040 2>/dev/null
		setpci -s "$br" 2C.L=00000040 2>/dev/null
	done
	setpci -s "$GPU_BUS" COMMAND.W=0000
	setpci -s "$GPU_BUS" 10.L="$BAR0_LO"    # BAR0 low  (framebuffer)
	setpci -s "$GPU_BUS" 14.L=00000040      # BAR0 high
	setpci -s "$GPU_BUS" 18.L="$BAR2_LO"    # BAR2 low  (doorbell)
	setpci -s "$GPU_BUS" 1C.L=00000040      # BAR2 high

	if verify_card "$GPU_BUS" "${IDX[$GPU_BUS]}" "${BRIDGES[@]}"; then
		log "  $GPU_BUS verified: ${#BRIDGES[@]} bridges + BAR0/BAR2 read back as written"
		GOOD="$GOOD $GPU_BUS"
	else
		keep_off "$GPU_BUS" "registers did not read back —$MISMATCH"
	fi
done

if [ "$VERIFY_ONLY" = 1 ]; then
	[ $VERIFY_BAD = 0 ] && { log "VERIFY: all cards match"; exit 0; }
	log "VERIFY: mismatch found"; exit 3
fi

# re-check every card after all writes: a later card can rewrite a bridge an earlier
# card shares, and the earlier card's window is then no longer forwarded
STILL_GOOD=""
for GPU_BUS in $GOOD; do
	read -r -a BRIDGES <<< "${BRS[$GPU_BUS]}"
	if verify_card "$GPU_BUS" "${IDX[$GPU_BUS]}" "${BRIDGES[@]}"; then STILL_GOOD="$STILL_GOOD $GPU_BUS"
	else keep_off "$GPU_BUS" "failed the re-check after all cards were written —$MISMATCH"; fi
done
GOOD=$STILL_GOOD
for GPU_BUS in $GOOD; do setpci -s "$GPU_BUS" COMMAND.W=0007; done

if [ "$UNSAFE" = 1 ]; then
	log "FAILED: a skipped card could not be kept away from amdgpu — not loading egpu_bar or amdgpu"; exit 1
fi
if [ -z "$GOOD" ] && [ -z "$KEPT" ]; then
	log "FAILED: no card passed its checks ($FAILED ) — not loading egpu_bar or amdgpu"; exit 1
fi

# HDMI audio functions of the cards we bring up: unbind and pin to no driver
for GPU_BUS in $GOOD; do
	AUD="$SYS/bus/pci/devices/0000:${GPU_BUS%.*}.1"
	[ -e "$AUD" ] || continue
	if [ "$(cut -c1-6 "$AUD/class" 2>/dev/null)" != 0x0403 ] || [ "$(cat "$AUD/vendor" 2>/dev/null)" != 0x1002 ]; then
		log "  ${GPU_BUS%.*}.1 is not AMD HDMI audio — leaving it alone"; continue
	fi
	echo none > "$AUD/driver_override" 2>/dev/null
	if [ -e "$AUD/driver" ]; then
		echo "0000:${GPU_BUS%.*}.1" > "$AUD/driver/unbind" 2>/dev/null
		log "  ${GPU_BUS%.*}.1 audio unbound"
	fi
done

if [ -n "$GOOD" ]; then
	log "Loading egpu_bar module..."
	modprobe egpu_bar 2>&1 || insmod "/lib/modules/$(uname -r)/extra/egpu_bar.ko" 2>&1 || {
		log "FAILED: egpu_bar load failed — not loading amdgpu"; exit 1; }

	log "Loading amdgpu..."
	modprobe amdgpu 2>&1
	sleep 4

	for GPU_BUS in $GOOD; do
		if [ ! -e "$SYS/bus/pci/devices/0000:$GPU_BUS/drm" ]; then
			echo "0000:$GPU_BUS" > "$SYS/bus/pci/drivers/amdgpu/bind" 2>/dev/null
			sleep 2
		fi
		f="$SYS/bus/pci/devices/0000:$GPU_BUS/power_dpm_force_performance_level"
		[ -f "$f" ] && echo high > "$f" 2>/dev/null && log "power mode high: $GPU_BUS"
	done
fi

# count only the eGPUs bound to amdgpu (the Mac's Intel iGPU also has a DRM card)
CARD_COUNT=0
for GPU_BUS in $GOOD $KEPT; do
	[ "$(basename "$(readlink "$SYS/bus/pci/devices/0000:$GPU_BUS/driver" 2>/dev/null)" 2>/dev/null)" = amdgpu ] && CARD_COUNT=$((CARD_COUNT + 1))
done
[ -n "$FAILED" ] && log "WARNING: skipped card(s):$FAILED"
if [ "$CARD_COUNT" -gt 0 ]; then
	log "SUCCESS: $CARD_COUNT amdgpu card(s) up; /dev/dri:"; ls -la "$DEV/dri/"
	exit 0
fi
log "FAILED: no amdgpu card came up"; dmesg | grep -iE "amdgpu|egpu_bar|kiq|ring|-110|gfx_v10" | tail -18
exit 1
