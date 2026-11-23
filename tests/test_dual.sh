#!/bin/bash
# Tests for dual-gpu/egpu-init.sh (the script deployed on the dual RX 6800 Mac Mini).
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
S=dual-gpu/egpu-init.sh
C0="00:01.0 06:00.0 07:00.0 43:00.0 44:00.0"
C1="00:01.1 7a:00.0 7b:00.0 80:00.0 81:00.0"

begin "two cards: both programmed, verified, bound"
mkenv; add_card 45:00.0 "$C0"; add_card 82:00.0 "$C1"; export EGPU_EXPECT=2
run_init $S
assert_eq "$RC" 0 "exit"
assert_eq "$(getreg 45:00.0 10.L)" 1000000c "card0 BAR0"
assert_eq "$(getreg 45:00.0 18.L)" 2000000c "card0 BAR2"
assert_eq "$(getreg 82:00.0 10.L)" 3000000c "card1 BAR0"
assert_eq "$(getreg 82:00.0 18.L)" 4000000c "card1 BAR2"
assert_eq "$(getreg 44:00.0 24.L)" 2ff11001 "card0 bridge window"
assert_eq "$(getreg 81:00.0 24.L)" 4ff13001 "card1 bridge window"
assert_eq "$(bound_to 45:00.0)" amdgpu "card0 bound"
assert_eq "$(bound_to 82:00.0)" amdgpu "card1 bound"
assert_has "$T/calls" "modprobe egpu_bar" "module loaded"
assert_has "$T/out" "SUCCESS: 2" "success line"

begin "item 4: HDMI audio functions are unbound and kept unbound"
assert_eq "$(override 45:00.1)" none "card0 audio override"
assert_eq "$(override 82:00.1)" none "card1 audio override"
assert_eq "$(unbound 45:00.1)" 0000:45:00.1 "card0 audio unbound"
assert_eq "$(unbound 82:00.1)" 0000:82:00.1 "card1 audio unbound"

begin "item 2: no eGPU attached is not an error"
mkenv; export EGPU_EXPECT=2
run_init $S
assert_eq "$RC" 0 "exit"
assert_has "$T/out" "no eGPU attached" "log"
assert_eq "$(cat "$T/calls")" "" "nothing loaded"

begin "item 1: a register that does not read back stops that card only"
mkenv; add_card 45:00.0 "$C0"; add_card 82:00.0 "$C1"; export EGPU_EXPECT=2
readonly_reg 81:00.0 28.L
run_init $S
assert_eq "$RC" 0 "exit (card0 still up)"
assert_has "$T/out" "81:00.0 28.L" "mismatch named"
assert_eq "$(getreg 82:00.0 COMMAND.W)" 0000 "card1 decode left off"
assert_eq "$(override 82:00.0)" none "card1 kept away from amdgpu"
assert_eq "$(bound_to 82:00.0)" "" "card1 not bound"
assert_eq "$(bound_to 45:00.0)" amdgpu "card0 bound"
assert_eq "$(override 82:00.1)" "(null)" "failed card's audio left alone"

begin "item 1: every card failing loads nothing and exits 1"
mkenv; add_card 45:00.0 "$C0"; export EGPU_EXPECT=1
readonly_reg 45:00.0 10.L
run_init $S
assert_eq "$RC" 1 "exit"
assert_not_has "$T/calls" "egpu_bar" "module not loaded"
assert_not_has "$T/calls" "amdgpu" "amdgpu not loaded"

begin "item 1: a card already driven by amdgpu is never reprogrammed"
mkenv; add_card 45:00.0 "$C0"; add_card 82:00.0 "$C1"; export EGPU_EXPECT=2
bind_amdgpu 45:00.0
run_init $S
assert_eq "$RC" 0 "exit"
assert_not_has "$T/setpci.log" "W 45:00.0" "no writes to bound card"
assert_not_has "$T/setpci.log" "W 44:00.0" "no writes to bound card's bridges"
assert_eq "$(getreg 82:00.0 10.L)" 3000000c "other card keeps its own window"
assert_eq "$(bound_to 82:00.0)" amdgpu "other card bound"

begin "item 1: egpu_bar failing to load stops before amdgpu"
mkenv; add_card 45:00.0 "$C0"; export EGPU_EXPECT=1; touch "$T/fail_egpu_bar"
run_init $S
assert_eq "$RC" 1 "exit"
assert_not_has "$T/calls" "modprobe amdgpu" "amdgpu not loaded"

begin "recovery: a stale driver_override from an earlier failed run is cleared"
mkenv; add_card 45:00.0 "$C0"; export EGPU_EXPECT=1
echo none > "$T/sys/bus/pci/devices/0000:45:00.0/driver_override"
run_init $S
assert_eq "$RC" 0 "exit"
assert_eq "$(bound_to 45:00.0)" amdgpu "bound after clearing"

begin "verify-only: reads registers, writes and loads nothing"
mkenv; add_card 45:00.0 "$C0"; add_card 82:00.0 "$C1"; export EGPU_EXPECT=2
run_init $S; : > "$T/setpci.log"; : > "$T/calls"
EGPU_VERIFY_ONLY=1 run_init $S
assert_eq "$RC" 0 "exit when registers match"
assert_eq "$(cat "$T/setpci.log")" "" "no writes"
assert_eq "$(cat "$T/calls")" "" "no module loads"
setreg 82:00.0 18.L 00000000
EGPU_VERIFY_ONLY=1 run_init $S
assert_eq "$RC" 3 "exit on mismatch"
assert_has "$T/out" "82:00.0 18.L" "mismatch named"

begin "re-check: a bridge shared by two cards cannot serve both; the first card is dropped"
mkenv; export EGPU_EXPECT=2
add_card 45:00.0 "00:01.0 06:00.0 07:00.0"; add_card 46:00.0 "00:01.0 06:00.0 08:00.0"
run_init $S
assert_eq "$RC" 0 "exit (second card up)"
assert_has "$T/out" "re-check" "re-check ran"
assert_eq "$(override 45:00.0)" none "first card kept away from amdgpu"
assert_eq "$(getreg 45:00.0 COMMAND.W)" 0000 "first card decode off"
assert_eq "$(bound_to 46:00.0)" amdgpu "second card bound"

begin "a bridge shared with a card amdgpu drives is never written"
mkenv; export EGPU_EXPECT=2
add_card 45:00.0 "00:01.0 06:00.0 07:00.0"; add_card 46:00.0 "00:01.0 06:00.0 08:00.0"
bind_amdgpu 45:00.0
run_init $S
assert_not_has "$T/setpci.log" "W 06:00.0" "shared bridge untouched"
assert_not_has "$T/setpci.log" "W 46:00.0 10.L" "no BAR written to the card behind it"
assert_eq "$(getreg 46:00.0 COMMAND.W)" 0000 "its decode turned off"
assert_eq "$(override 46:00.0)" none "that card kept away from amdgpu"
assert_has "$T/out" "shares bridge" "log says why"

begin "function .1 that is not HDMI audio is left alone"
mkenv; export EGPU_EXPECT=1; add_card 45:00.0 "$C0" 0x0c0330
run_init $S
assert_eq "$RC" 0 "exit"
assert_eq "$(override 45:00.1)" "(null)" "override untouched"
assert_eq "$(unbound 45:00.1)" "" "not unbound"

begin "a card lspci lists but sysfs does not is skipped"
mkenv; export EGPU_EXPECT=1; ghost_card 45:00.0
run_init $S
assert_eq "$RC" 1 "exit"
assert_eq "$(cat "$T/setpci.log")" "" "no writes"
assert_eq "$(cat "$T/calls")" "" "nothing loaded"

begin "a bad EGPU_SETTLE_TRIES falls back to the default instead of skipping the wait"
mkenv; export EGPU_EXPECT=1; add_card 45:00.0 "$C0"
EGPU_SETTLE_TRIES=abc run_init $S
assert_eq "$RC" 0 "exit"
assert_eq "$(bound_to 45:00.0)" amdgpu "bound"

begin "driver_override that cannot be written stops all loading"
mkenv; export EGPU_EXPECT=2; add_card 45:00.0 "$C0"; add_card 82:00.0 "$C1"
readonly_reg 82:00.0 10.L
rm "$T/sys/bus/pci/devices/0000:82:00.0/driver_override"; mkdir "$T/sys/bus/pci/devices/0000:82:00.0/driver_override"
run_init $S
assert_eq "$RC" 1 "exit"
assert_not_has "$T/calls" "amdgpu" "amdgpu not loaded"

summary
