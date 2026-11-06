#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# run_xsim_ilv.sh - compile and run tb_axi_ilv (rsys_axi_ilv: the PS DDR window over two ports
# per direction) in xsim. Build directory build_ilv/ (git-ignored).
# Copyright (c) 2026 Opsero Electronic Design Inc.
if ! command -v xvlog >/dev/null 2>&1; then
    for s in "${VIVADO_SETTINGS:-}" "$HOME"/Xilinx/2025.2/Vivado/settings64.sh /tools/Xilinx/2025.2/Vivado/settings64.sh; do
        [ -n "$s" ] && [ -f "$s" ] && { source "$s"; break; }
    done
fi
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B="$HERE/build_ilv"; mkdir -p "$B"; cd "$B"
xvlog --sv "$HERE/../rsys_fifo.sv" "$HERE/../rsys_axi_ilv.sv" "$HERE/tb_axi_ilv.sv" > xvlog.log 2>&1 || { grep ERROR xvlog.log | head -20; exit 1; }
xelab -debug off --timescale 1ns/1ps tb_axi_ilv -s snap > xelab.log 2>&1 || { grep ERROR xelab.log | head -20; exit 1; }
xsim snap -R > xsim.log 2>&1 || true
grep -E "^(====|FAIL|SIM |TIMEOUT|  )|ERROR|Fatal" xsim.log | head -60
