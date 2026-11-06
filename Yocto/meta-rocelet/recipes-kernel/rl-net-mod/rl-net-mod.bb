# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "qsfp28-fmc-rocelet network interface driver (rl_net.ko: rl0)"
DESCRIPTION = "Out-of-tree kernel module for the design's netdev DMA channel: every frame of QSFP28 \
port 0 that the rocelet engine does not terminate (not RoCE v2) reaches Linux as rl0 through the \
AXI DMA (dmaengine / xilinx_dma: tx = MM2S, rx = S2MM); carrier from the always-on block. Binds to \
compatible \"opsero,rocelet-net-1.0\" (bsp system-user.dtsi)."
HOMEPAGE = "https://github.com/fpgadeveloper/qsfp28-fmc-rocelet"
SECTION = "kernel/modules"
LICENSE = "GPL-2.0-only | MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6 \
                    file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit module

PV = "1.0"

# Sources straight from this repository (ROCELET_REPO_ROOT: meta-rocelet/conf/layer.conf).
FILESEXTRAPATHS:prepend := "${ROCELET_REPO_ROOT}:"
SRC_URI = "file://sw/linux/rl-net"
S = "${WORKDIR}/sw/linux/rl-net"

EXTRA_OEMAKE += "KDIR=${STAGING_KERNEL_DIR}"

# Loaded at boot: binds the "opsero,rocelet-net-1.0" node of the device tree.
KERNEL_MODULE_AUTOLOAD += "rl_net"

RPROVIDES:${PN} += "kernel-module-rl-net"
