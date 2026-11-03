#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# run_xsim_prod.sh - compile and run tb_hsb_prod (the HSB frame producer rsys_hsb_prod alone:
# live frame period sampled at every frame start, the rest latched per run) in xsim. Build
# directory: Vivado/src/hdl/tb/build_prod/ (git-ignored). Prints the FAIL lines and the verdict.
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
B="$HERE/build_prod"
mkdir -p "$B"
cd "$B"
xvlog --sv "$HDL/rsys_skid.sv" "$HDL/rsys_hsb_prod.sv" "$HERE/tb_hsb_prod.sv" > xvlog.log 2>&1 \
    || { grep -E "ERROR" xvlog.log | head -30; exit 1; }
xelab -debug off --timescale 1ns/1ps tb_hsb_prod -s snap > xelab.log 2>&1 || { grep -E "ERROR" xelab.log | head -30; exit 1; }
xsim snap -R > xsim.log 2>&1 || true
grep -E "^(====|FAIL|SIM |TIMEOUT)|ERROR|Fatal" xsim.log | head -80
