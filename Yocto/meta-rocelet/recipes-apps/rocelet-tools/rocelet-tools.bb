# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "qsfp28-fmc-rocelet control plane on Linux: roceletd (daemon) and rl (CLI)"
DESCRIPTION = "roceletd owns the design's hardware (register window and PS DDR window through UIO, \
the FMC's Si5328 and the QSFP28 module through i2c-dev) and runs the same console sources as the \
standalone builds (Vitis/common/src): bring-up, engine setup, the console commands, the self-test and \
the Holoscan Sensor Bridge device mode (UDP sockets on rl0). rl is its command-line client \
(Unix socket /run/rocelet/roceletd.sock). Also the rl0 network configuration (systemd-networkd) \
and the udev rules of the UIO devices."
HOMEPAGE = "https://github.com/fpgadeveloper/qsfp28-fmc-rocelet"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PV = "1.0"

# Sources straight from this repository (ROCELET_REPO_ROOT: meta-rocelet/conf/layer.conf): the
# daemon, the console sources it shares with the standalone builds, the engine's register header.
FILESEXTRAPATHS:prepend := "${ROCELET_REPO_ROOT}:${THISDIR}/files:"
SRC_URI = "file://sw/linux/roceletd \
           file://Vitis/common/src \
           file://submodules/rocelet/sw/rocelet_regs.h \
           file://roceletd.service \
           file://roceletd.sh \
           file://rocelet.conf \
           file://10-rl0.network \
           file://99-rocelet.rules \
          "
S = "${WORKDIR}"

inherit systemd useradd

USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "--system rocelet"

SYSTEMD_SERVICE:${PN} = "roceletd.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

# BOARD / LINE_RATE of the console build (board.h) from the manifest, config/data.json: the entry
# whose label is this MACHINE's suffix (configure-build.sh generates MACHINE <bd_name>-<label>,
# e.g. rocelet-zcu106 -> zcu106): "boardname" (upper case) and "link_gbps" (the MAC the target
# is built with, 40 for zcu106 = omac_40g; 10 with the 10G option). The console reads the MAC
# type and rate of the running bitstream from the always-on CAPS register anyway; LINE_RATE is
# the build-time default. data.json is a parse dependency: an edit re-parses this recipe.
def rocelet_manifest(d, key, default):
    import json, os
    path = os.path.join(d.getVar('ROCELET_REPO_ROOT'), 'config', 'data.json')
    bb.parse.mark_dependency(d, path)
    label = (d.getVar('MACHINE') or '').split('-', 1)[-1]
    try:
        with open(path) as f:
            designs = json.load(f).get('designs', [])
    except (OSError, ValueError):
        return str(default)
    for t in designs:
        if t.get('label') == label:
            return str(t.get(key, default))
    return str(default)

ROCELET_BOARD = "${@rocelet_manifest(d, 'boardname', 'zcu106').upper()}"
ROCELET_LINE_RATE = "${@rocelet_manifest(d, 'link_gbps', '40')}"

do_compile() {
    oe_runmake -C ${S}/sw/linux/roceletd REPO=${S} BOARD=${ROCELET_BOARD} LINE_RATE=${ROCELET_LINE_RATE}
}

do_install() {
    # the binaries made by do_compile (no make here: a make under pseudo re-checks the tree)
    install -d ${D}${bindir}
    install -m 0755 ${S}/sw/linux/roceletd/build/roceletd ${S}/sw/linux/roceletd/build/rl ${D}${bindir}/
    install -m 0755 ${S}/roceletd.sh ${D}${bindir}/roceletd-start
    install -d ${D}${sysconfdir}/rocelet
    install -m 0644 ${S}/rocelet.conf ${D}${sysconfdir}/rocelet/rocelet.conf
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/roceletd.service ${D}${systemd_system_unitdir}/
    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${S}/10-rl0.network ${D}${sysconfdir}/systemd/network/
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${S}/99-rocelet.rules ${D}${sysconfdir}/udev/rules.d/
}

FILES:${PN} += "${systemd_system_unitdir}/roceletd.service ${sysconfdir}/rocelet \
                ${sysconfdir}/systemd/network/10-rl0.network ${sysconfdir}/udev/rules.d/99-rocelet.rules"
CONFFILES:${PN} += "${sysconfdir}/rocelet/rocelet.conf ${sysconfdir}/systemd/network/10-rl0.network"

RDEPENDS:${PN} = "bash"
RRECOMMENDS:${PN} = "rl-net-mod"
