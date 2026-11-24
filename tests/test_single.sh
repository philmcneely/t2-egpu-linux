#!/bin/bash
# Tests for the single-card egpu-init.sh at the repo root (the one the README walks through).
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
S=egpu-init.sh
C0="00:01.0 06:00.0 07:00.0 43:00.0 44:00.0"

begin "one card: programmed, verified, bound"
mkenv; add_card 45:00.0 "$C0"
run_init $S
assert_eq "$RC" 0 "exit"
assert_eq "$(getreg 45:00.0 10.L)" 1000000c "BAR0 low"
assert_eq "$(getreg 45:00.0 14.L)" 00000040 "BAR0 high"
assert_eq "$(getreg 44:00.0 24.L)" 1ff11001 "bridge window"
assert_eq "$(bound_to 45:00.0)" amdgpu "bound"
assert_has "$T/out" "SUCCESS" "success line"

begin "item 4: HDMI audio unbound"
assert_eq "$(override 45:00.1)" none "audio override"
assert_eq "$(unbound 45:00.1)" 0000:45:00.1 "audio unbound"

begin "item 2: no eGPU attached is not an error"
mkenv
run_init $S
assert_eq "$RC" 0 "exit"
assert_has "$T/out" "no eGPU attached" "log"
assert_eq "$(cat "$T/calls")" "" "nothing loaded"

begin "item 1: bridge register mismatch stops before any driver loads"
mkenv; add_card 45:00.0 "$C0"; readonly_reg 07:00.0 2C.L
run_init $S
assert_eq "$RC" 1 "exit"
assert_has "$T/out" "07:00.0 2C.L" "mismatch named"
assert_eq "$(getreg 45:00.0 COMMAND.W)" 0000 "decode left off"
assert_not_has "$T/calls" "egpu_bar" "module not loaded"
assert_not_has "$T/calls" "amdgpu" "amdgpu not loaded"

begin "item 1: already bound card is left alone"
mkenv; add_card 45:00.0 "$C0"; bind_amdgpu 45:00.0
run_init $S
assert_eq "$RC" 0 "exit"
assert_eq "$(cat "$T/setpci.log")" "" "no writes"
assert_has "$T/out" "already" "log says why"

begin "verify-only"
mkenv; add_card 45:00.0 "$C0"
run_init $S; : > "$T/setpci.log"; : > "$T/calls"
EGPU_VERIFY_ONLY=1 run_init $S
assert_eq "$RC" 0 "exit when registers match"
assert_eq "$(cat "$T/setpci.log")" "" "no writes"
setreg 45:00.0 10.L 00000000
EGPU_VERIFY_ONLY=1 run_init $S
assert_eq "$RC" 3 "exit on mismatch"

begin "a card lspci lists but sysfs does not: nothing written, nothing loaded"
mkenv; ghost_card 45:00.0
run_init $S
assert_eq "$RC" 1 "exit"
assert_eq "$(cat "$T/setpci.log")" "" "no writes"
assert_eq "$(cat "$T/calls")" "" "nothing loaded"

begin "the Intel iGPU's card0 does not count as success"
mkenv; add_card 45:00.0 "$C0"; igpu; touch "$T/fail_amdgpu"
run_init $S
assert_eq "$RC" 1 "exit"
assert_not_has "$T/out" "SUCCESS" "no false success"

begin "function .1 that is not HDMI audio is left alone"
mkenv; add_card 45:00.0 "$C0" 0x0c0330
run_init $S
assert_eq "$(override 45:00.1)" "(null)" "override untouched"

summary
