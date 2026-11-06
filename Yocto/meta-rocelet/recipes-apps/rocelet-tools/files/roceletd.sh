#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
# Start roceletd with the image's settings (/etc/rocelet/rocelet.conf) and, if present, the override
# on the SD card's FAT boot partition (rocelet.conf next to BOOT.BIN: editable from any PC).
CFG="-c /etc/rocelet/rocelet.conf"
for f in /boot/rocelet.conf /boot/efi/rocelet.conf /run/media/boot-mmcblk0p1/rocelet.conf; do
    [ -r "$f" ] && CFG="$CFG -c $f"
done
exec /usr/bin/roceletd $CFG
