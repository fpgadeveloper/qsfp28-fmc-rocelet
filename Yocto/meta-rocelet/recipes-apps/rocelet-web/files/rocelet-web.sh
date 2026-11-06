#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
# Start the web UI with the image's settings (/etc/rocelet/rocelet-web.conf) and, if present, the
# override on the SD card's FAT boot partition (rocelet-web.conf next to BOOT.BIN).
CFG="--config /etc/rocelet/rocelet-web.conf"
for f in /boot/rocelet-web.conf /boot/efi/rocelet-web.conf /run/media/boot-mmcblk0p1/rocelet-web.conf; do
    [ -r "$f" ] && CFG="$CFG --config $f"
done
exec /usr/bin/python3 /usr/share/rocelet/rocelet_web.py $CFG
