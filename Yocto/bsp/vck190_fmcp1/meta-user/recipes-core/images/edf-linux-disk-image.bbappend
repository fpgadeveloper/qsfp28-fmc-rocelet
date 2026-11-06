# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

# A self-contained SD image for the VCK190: the stock EDF 2025.2 Versal wic ships an esp without
# BOOT.BIN (the BootROM finds nothing to boot) and with an empty EFI/BOOT/ (U-Boot's EFI boot
# finds no systemd-boot). Both go onto the esp here:
#   - BOOT.BIN: IMAGE_EFI_BOOT_FILES (deploy name boot.bin -> BOOT.BIN on the esp);
#   - EFI/BOOT/BOOTAA64.EFI: the bootimg-efi-amd wic plugin copies every deployed systemd-*.efi
#     into EFI/BOOT/ (systemd-bootaa64.efi -> bootaa64.efi), but on Versal nothing makes the wic
#     wait for systemd-boot's do_deploy (WKS_FILE_DEPENDS_BOOTLOADERS is x86-only).
# build.py's package stage still ships BOOT.BIN and BOOTAA64.EFI next to the wic for cards
# written by other means.
IMAGE_EFI_BOOT_FILES:append = " boot.bin;BOOT.BIN"
do_image_wic[depends] += "virtual/boot-bin:do_deploy systemd-boot:do_deploy"
