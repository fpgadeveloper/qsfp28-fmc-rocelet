# Copyright (C) 2025-2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# VCK190: U-Boot switches the FMC VADJ rail on (IR38164 behind the TCA9548 on LPD I2C0) before
# every boot, then runs the distro boot (systemd-boot from the esp). See files/vck190-vadj-bootcmd.cfg.
# The Si5328 and the QSFP28 lines of the OP120 sit on FMC LA pins and are dead without VADJ;
# roceletd also checks and enables VADJ itself (vadj.c), so a boot that skips this still works.
#
# := captures the bbappend dir at parse time (${THISDIR} is unreliable at task time in a bbappend).
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://vck190-vadj-bootcmd.cfg"
