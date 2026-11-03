#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# gen_regs_h.py - regenerate Vitis/common/src/rsys_regs.h (the system register
# window of rocelet_sys, as the MicroBlaze application sees it) from
# Vivado/src/hdl/rsys_pkg.sv. Run it after changing the register map:
#   python3 Vivado/scripts/gen_regs_h.py
#
# Copyright (c) 2026 Opsero Electronic Design Inc.
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', 'src', 'hdl', 'rsys_pkg.sv')
DST = os.path.join(HERE, '..', '..', 'Vitis', 'common', 'src', 'rsys_regs.h')

src = open(SRC).read()
out = ["/*",
       " * rsys_regs.h - system register window of rocelet_sys (qsfp28-fmc-rocelet), byte",
       " * offsets from the window base (rocelet_sys base + 0x10000).",
       " * GENERATED from Vivado/src/hdl/rsys_pkg.sv by Vivado/scripts/gen_regs_h.py - do not edit.",
       " *",
       " * Copyright (c) 2026 Opsero Electronic Design Inc.",
       " * SPDX-License-Identifier: MIT",
       " */",
       "#ifndef RSYS_REGS_H_",
       "#define RSYS_REGS_H_",
       "",
       "#define RSYS_CFG(i)   (0x0000u + 4u * (i))",
       "#define RSYS_SV(i)    (0x0400u + 4u * (i))",
       "#define RSYS_CNT(i)   (0x0800u + 4u * (i))",
       "#define RSYS_BC(i)    (0x0C00u + 8u * (i))",
       "#define RSYS_RAW_TX   0x1000u",
       "#define RSYS_CAP      0x2000u",
       "#define RSYS_CAP_AUX  0x4000u",
       ""]
for m in re.finditer(r'localparam int (\w+)\s*=\s*(\d+);[ \t]*(//.*)?', src):
    name, val, com = m.group(1), m.group(2), m.group(3)
    line = f"#define RSYS_{name:<18} {val}"
    if com:
        line += f"   /* {com[2:].strip()} */"
    out.append(line)
out += ["", "#endif", ""]
open(DST, 'w').write("\n".join(out))
print(f"wrote {os.path.normpath(DST)}")
