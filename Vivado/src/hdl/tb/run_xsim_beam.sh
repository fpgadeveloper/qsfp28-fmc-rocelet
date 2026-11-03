#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# run_xsim_beam.sh [T] - compile and run tb_beam_src (the beam array generator rsys_beam_src
# against the bit-exact model sw/beam/beam_model.py) in xsim. T = time samples per frame
# (default 4096 = the demo's 1 MiB frames). The vectors are written by beam_vectors.py (needs
# python3 + numpy) into the build directory Vivado/src/hdl/tb/build_beam/ (git-ignored).
# Prints the FAIL lines and the verdict.
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
T="${1:-4096}"
B="$HERE/build_beam"
mkdir -p "$B"
python3 "$HERE/beam_vectors.py" "$B" --t "$T"
cd "$B"
xvlog --sv "$HDL/rsys_pkg.sv" "$HDL/iq16_gen.sv" "$HDL/rsys_beam_src.sv" "$HERE/tb_beam_src.sv" > xvlog.log 2>&1 \
    || { grep -E "ERROR" xvlog.log | head -30; exit 1; }
xvlog "$XILINX_VIVADO/data/verilog/src/glbl.v" > xvlog_v.log 2>&1 || { grep -E "ERROR" xvlog_v.log | head; exit 1; }
xelab -debug off --timescale 1ns/1ps -L xpm -L unisims_ver tb_beam_src glbl -s snap > xelab.log 2>&1 \
    || { grep -E "ERROR" xelab.log | head -30; exit 1; }
xsim snap -R -testplusarg "T=$T" -testplusarg "vdir=$B" > xsim.log 2>&1 || true
grep -E "^(====|FAIL|SIM |TIMEOUT)|ERROR|Fatal" xsim.log | head -80
