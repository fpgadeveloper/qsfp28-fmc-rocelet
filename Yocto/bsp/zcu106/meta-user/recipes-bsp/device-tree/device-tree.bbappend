# Copyright (C) 2025-2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

# Board-level device-tree fixups layered on top of the gen-machineconf / lopper-generated
# CONFIG_DTFILE (conf/dts/rocelet-zcu106/cortexa53-linux.dts); see system-user.dtsi.
#
# meta-xilinx's device-tree.bb consumes EXTRA_DT_INCLUDE_FILES by copying each file into the DT
# build dir and appending a `#include "<file>"` to the base DTS. Only the Linux (APU) device tree
# gets it: the FSBL and PMU domain trees do not define the labels the overrides reference. Match on
# the DTS basename (...-cortexaN-linux.dts), not the full path, which may contain "linux" itself.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

EXTRA_DT_INCLUDE_FILES:append = "${@' system-user.dtsi' if 'linux' in os.path.basename(d.getVar('CONFIG_DTFILE') or '') else ''}"
