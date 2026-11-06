#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# run_xsim_aon.sh - compile and run tb_aon (rsys_aon: always-on block + clock guard) in xsim.
# Copyright (c) 2026 Opsero Electronic Design Inc.
if ! command -v xvlog >/dev/null 2>&1; then
    for s in "${VIVADO_SETTINGS:-}" "$HOME"/Xilinx/2025.2/Vivado/settings64.sh /tools/Xilinx/2025.2/Vivado/settings64.sh; do
        [ -n "$s" ] && [ -f "$s" ] && { source "$s"; break; }
    done
fi
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B="$HERE/build_aon"; mkdir -p "$B"; cd "$B"
xvlog --sv "$HERE/../rsys_aon.sv" "$HERE/tb_aon.sv" > xvlog.log 2>&1 || { grep ERROR xvlog.log | head -20; exit 1; }
xvlog "$XILINX_VIVADO/data/verilog/src/glbl.v" > xvlog_v.log 2>&1 || { grep ERROR xvlog_v.log | head; exit 1; }
xelab -debug off --timescale 1ns/1ps -L xpm -L unisims_ver tb_aon glbl -s snap > xelab.log 2>&1 || { grep ERROR xelab.log | head -20; exit 1; }
xsim snap -R > xsim.log 2>&1 || true
grep -E "^(====|FAIL|SIM |TIMEOUT|  ok)|ERROR|Fatal" xsim.log | head -60
