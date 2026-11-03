#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# run_xsim.sh [test] [+plusargs] - compile and run tb_rocelet_sys (rocelet_sys with
# the rocelet engine from the submodule, through a QSFP28 loopback model) in xsim.
# Tests: all (default), arp, wrq, write, send, inject, vinject, read, icrc, access, crx, hsb
# (hsbiq: the IQ16 producer run alone; hsbbm: the beam array generator alone; +iqdbg prints the
# IQ16 source state). The beam reference (beam_reset.hex) is written by beam_vectors.py (python3 +
# numpy) into the build directory. Build directory:
# Vivado/src/hdl/tb/build/ (git-ignored). Prints the FAIL lines and the verdict.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.
if ! command -v xvlog >/dev/null 2>&1; then
    for s in "${VIVADO_SETTINGS:-}" "$HOME"/Xilinx/2025.2/Vivado/settings64.sh /tools/Xilinx/2025.2/Vivado/settings64.sh; do
        # shellcheck disable=SC1090
        [ -n "$s" ] && [ -f "$s" ] && { source "$s"; break; }
    done
fi
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HDL="$HERE/.."
RL="$HERE/../../../../submodules/rocelet"
TEST="${1:-all}"; shift || true
ENG=()
while read -r f; do
    f="${f%%#*}"; f="$(echo "$f" | xargs)"
    [ -n "$f" ] && ENG+=("$RL/$f")
done < "$RL/rtl/rocelet.f"
SYS=("$HDL/rsys_pkg.sv")
for f in "$HDL"/*.sv; do [ "$f" != "$HDL/rsys_pkg.sv" ] && SYS+=("$f"); done
B="$HERE/build"
mkdir -p "$B"
python3 "$HERE/beam_vectors.py" "$B" --t 32 > /dev/null
cd "$B"
xvlog --sv "${ENG[@]}" "${SYS[@]}" "$HERE/tb_rocelet_sys.sv" > xvlog.log 2>&1 || { grep -E "ERROR" xvlog.log | head -30; exit 1; }
xvlog "$XILINX_VIVADO/data/verilog/src/glbl.v" > xvlog_v.log 2>&1 || { grep -E "ERROR" xvlog_v.log | head; exit 1; }
xelab -debug off --timescale 1ns/1ps -L xpm -L unisims_ver tb_rocelet_sys glbl -s snap > xelab.log 2>&1 || { grep -E "ERROR" xelab.log | head -30; exit 1; }
PA=(-testplusarg "test=$TEST" -testplusarg "vdir=$B")
for a in "$@"; do PA+=(-testplusarg "${a#+}"); done
xsim snap -R "${PA[@]}" > "xsim_$TEST.log" 2>&1 || true
grep -E "^(====|FAIL|SIM |TIMEOUT)|ERROR|Fatal" "xsim_$TEST.log" | head -80
