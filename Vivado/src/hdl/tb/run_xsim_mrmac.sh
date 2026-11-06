#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# run_xsim_mrmac.sh - compile and run tb_mrmac100g (mac_mrmac100g: the VCK190 MRMAC adapter
# against a behavioural MRMAC 100G independent-384 client model) in xsim. SEED=<n> picks the
# random seed (default 1).
# Copyright (c) 2026 Opsero Electronic Design Inc.
if ! command -v xvlog >/dev/null 2>&1; then
    for s in "${VIVADO_SETTINGS:-}" "$HOME"/Xilinx/2025.2/Vivado/settings64.sh /tools/Xilinx/2025.2/Vivado/settings64.sh; do
        [ -n "$s" ] && [ -f "$s" ] && { source "$s"; break; }
    done
fi
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED="${SEED:-1}"
B="$HERE/build_mrmac"; mkdir -p "$B"; cd "$B"
xvlog "$HERE/../mac/mrmac_rx_packer.v" "$HERE/../mac/mac_mrmac100g.v" "$XILINX_VIVADO/data/verilog/src/glbl.v" > xvlog_v.log 2>&1 || { grep ERROR xvlog_v.log | head -20; exit 1; }
xvlog --sv "$HERE/tb_mrmac100g.sv" > xvlog.log 2>&1 || { grep ERROR xvlog.log | head -20; exit 1; }
xelab -debug off --timescale 1ns/1ps -L xpm -L unisims_ver tb_mrmac100g glbl -s snap > xelab.log 2>&1 || { grep ERROR xelab.log | head -20; exit 1; }
xsim snap -R -sv_seed "$SEED" > xsim.log 2>&1 || true
grep -E "^(====|FAIL|SIM |TIMEOUT|  ok|  RX|  TX)|ERROR|Fatal" xsim.log | head -120
