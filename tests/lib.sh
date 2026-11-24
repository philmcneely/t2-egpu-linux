# shellcheck shell=bash disable=SC2034
# Test helpers: a fake /sys tree plus stand-ins for lspci, setpci, modprobe, insmod,
# logger, sleep and dmesg, so egpu-init.sh runs end to end without touching hardware.
# Run inside a Linux container (tests/run.sh) — the scripts use GNU head/readlink.

PASS=0; FAIL=0; CUR=""

begin() { CUR="$1"; }
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL [$CUR] $1"; }
assert_eq() { [ "$1" = "$2" ] && ok || bad "$3: expected '$2', got '$1'"; }
assert_has() { grep -q -- "$2" "$1" 2>/dev/null && ok || bad "$3: '$2' not in $(basename "$1")"; }
assert_not_has() { grep -q -- "$2" "$1" 2>/dev/null && bad "$3: '$2' unexpectedly in $(basename "$1")" || ok; }

# mkenv: fresh fake machine in $T
mkenv() {
	T=$(mktemp -d); export FAKE=$T
	mkdir -p "$T/sys/bus/pci/devices" "$T/sys/bus/pci/drivers/amdgpu" "$T/sys/bus/pci/drivers/snd_hda_intel" \
		"$T/sys/class/drm" "$T/sys/devices/pci0000:00" "$T/dev/dri" "$T/bin" "$T/regs"
	: > "$T/sys/bus/pci/drivers/amdgpu/bind"; : > "$T/sys/bus/pci/drivers/snd_hda_intel/unbind"
	: > "$T/cards"; : > "$T/readonly"; : > "$T/calls"; : > "$T/setpci.log"
	install_stubs
	export EGPU_SYSFS="$T/sys" EGPU_DEVROOT="$T/dev" EGPU_SETTLE_TRIES=3 PATH="$T/bin:$PATH"
}

# add_card <gpu-bus> "<bridge> <bridge> ..." [audio-class]: GPU function .0 behind the
# bridge chain, with its function .1 (HDMI audio by default) bound to a driver.
add_card() {
	local gpu=$1 path="$T/sys/devices/pci0000:00" br aclass=${3:-0x040300}
	for br in $2; do
		path="$path/0000:$br"; mkdir -p "$path"; echo 0x060400 > "$path/class"
		ln -sfn "$path" "$T/sys/bus/pci/devices/0000:$br"
	done
	mkdir -p "$path/0000:$gpu"; echo 0x030000 > "$path/0000:$gpu/class"; echo 0x1002 > "$path/0000:$gpu/vendor"
	echo "(null)" > "$path/0000:$gpu/driver_override"
	ln -sfn "$path/0000:$gpu" "$T/sys/bus/pci/devices/0000:$gpu"
	local aud="${gpu%.*}.1"
	mkdir -p "$path/0000:$aud"; echo "$aclass" > "$path/0000:$aud/class"; echo 0x1002 > "$path/0000:$aud/vendor"
	echo "(null)" > "$path/0000:$aud/driver_override"
	# one fake driver dir per function, so each unbind write is checkable on its own
	mkdir -p "$T/sys/bus/pci/drivers/hda-$aud"; : > "$T/sys/bus/pci/drivers/hda-$aud/unbind"
	ln -sfn "$T/sys/bus/pci/drivers/hda-$aud" "$path/0000:$aud/driver"
	ln -sfn "$path/0000:$aud" "$T/sys/bus/pci/devices/0000:$aud"
	echo "$gpu" >> "$T/cards"
}

# ghost_card <gpu-bus>: lspci lists it but it has no sysfs entry
ghost_card() { echo "$1" >> "$T/cards"; }

# igpu: an Intel iGPU already owns /dev/dri/card0 (the Mac Mini has one)
igpu() { touch "$T/dev/dri/card0"; }

# bind_amdgpu <gpu-bus>: card already driven by amdgpu (live system, recovery path)
bind_amdgpu() { ln -sfn "$T/sys/bus/pci/drivers/amdgpu" "$T/sys/bus/pci/devices/0000:$1/driver"; }

# readonly_reg <bus> <REG>: hardware ignores writes to this register
readonly_reg() { echo "$1 $2" >> "$T/readonly"; }
setreg() { echo "$3" > "$T/regs/$1_$2"; }
getreg() { cat "$T/regs/$1_$2" 2>/dev/null; }
unbound() { cat "$T/sys/bus/pci/drivers/hda-$1/unbind"; }
override() { cat "$T/sys/bus/pci/devices/0000:$1/driver_override"; }
bound_to() { basename "$(readlink "$T/sys/bus/pci/devices/0000:$1/driver" 2>/dev/null)" 2>/dev/null; }

install_stubs() {
	cat > "$T/bin/lspci" <<'EOF'
#!/bin/bash
[ "$1" = "-d" ] || exit 0
while read -r b; do [ -n "$b" ] && echo "$b VGA compatible controller: AMD Navi 21"; done < "$FAKE/cards"
EOF
	cat > "$T/bin/setpci" <<'EOF'
#!/bin/bash
# setpci -s BUS REG[=VAL]
bus=$2; arg=$3; reg=$(echo "${arg%%=*}" | tr a-z A-Z)
if [[ "$arg" == *=* ]]; then
	val=$(echo "${arg#*=}" | tr A-Z a-z)
	echo "W $bus $reg $val" >> "$FAKE/setpci.log"
	grep -qx "$bus $reg" "$FAKE/readonly" && exit 0
	echo "$val" > "$FAKE/regs/${bus}_$reg"
else
	cat "$FAKE/regs/${bus}_$reg" 2>/dev/null || echo 00000000
fi
EOF
	cat > "$T/bin/modprobe" <<'EOF'
#!/bin/bash
echo "modprobe $*" >> "$FAKE/calls"
[ "$1" = egpu_bar ] && [ -e "$FAKE/fail_egpu_bar" ] && exit 1
if [ "$1" = amdgpu ] && [ ! -e "$FAKE/fail_amdgpu" ]; then
	n=0
	while read -r b; do
		[ -n "$b" ] || continue
		d="$FAKE/sys/bus/pci/devices/0000:$b"; [ -e "$d" ] || continue
		if [ "$(cat "$d/driver_override")" != none ] && [ ! -e "$d/driver" ]; then
			ln -sfn "$FAKE/sys/bus/pci/drivers/amdgpu" "$d/driver"; mkdir -p "$d/drm"
		fi
		if [ "$(basename "$(readlink "$d/driver")")" = amdgpu ]; then
			mkdir -p "$FAKE/sys/class/drm/card$n"; ln -sfn "$d" "$FAKE/sys/class/drm/card$n/device"
			touch "$FAKE/dev/dri/card$n"; n=$((n+1))
		fi
	done < "$FAKE/cards"
fi
exit 0
EOF
	cat > "$T/bin/insmod" <<'EOF'
#!/bin/bash
echo "insmod $*" >> "$FAKE/calls"
[ -e "$FAKE/fail_egpu_bar" ] && exit 1
exit 0
EOF
	printf '#!/bin/bash\nexit 0\n' > "$T/bin/logger"
	printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"
	printf '#!/bin/bash\nexit 0\n' > "$T/bin/dmesg"
	chmod +x "$T/bin/"*
}

# run_init <script>: runs it, output to $T/out, exit code in $RC
# Refuses to run unless setpci/modprobe resolve to the stubs, so a broken setup
# can never reach real hardware.
run_init() {
	if [ "$(command -v setpci)" != "$T/bin/setpci" ] || [ "$(command -v modprobe)" != "$T/bin/modprobe" ]; then
		echo "ABORT: stubs not first on PATH"; exit 99
	fi
	bash "$1" > "$T/out" 2>&1; RC=$?
}

summary() { echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]; }
