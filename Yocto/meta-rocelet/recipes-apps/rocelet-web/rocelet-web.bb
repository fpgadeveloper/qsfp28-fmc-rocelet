# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "qsfp28-fmc-rocelet web UI (rocelet-web, port 80)"
DESCRIPTION = "Browser UI on the board in front of roceletd's console socket: link, rl0, counters \
with rates, queue pairs and the out-of-band records (show RLF, paste RLH), self-test, Holoscan Sensor \
Bridge mode / source / rate, a console line. Python standard library only; systemd service \
rocelet-web as the unprivileged user rocelet."
HOMEPAGE = "https://github.com/fpgadeveloper/qsfp28-fmc-rocelet"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PV = "1.0"

FILESEXTRAPATHS:prepend := "${ROCELET_REPO_ROOT}:${THISDIR}/files:"
SRC_URI = "file://sw/linux/web \
           file://rocelet-web.service \
           file://rocelet-web.sh \
           file://rocelet-web.conf \
          "
S = "${WORKDIR}"

inherit systemd useradd allarch

USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "--system rocelet"
USERADD_PARAM:${PN} = "--system --no-create-home --home-dir /nonexistent --shell /sbin/nologin -g rocelet rocelet"

SYSTEMD_SERVICE:${PN} = "rocelet-web.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${datadir}/rocelet/web ${D}${bindir}
    install -m 0755 ${S}/sw/linux/web/rocelet_web.py ${D}${datadir}/rocelet/
    install -m 0644 ${S}/sw/linux/web/web/* ${D}${datadir}/rocelet/web/
    install -m 0755 ${S}/rocelet-web.sh ${D}${bindir}/rocelet-web
    install -d ${D}${sysconfdir}/rocelet
    install -m 0644 ${S}/rocelet-web.conf ${D}${sysconfdir}/rocelet/rocelet-web.conf
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/rocelet-web.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += "${datadir}/rocelet ${systemd_system_unitdir}/rocelet-web.service ${sysconfdir}/rocelet/rocelet-web.conf"
CONFFILES:${PN} += "${sysconfdir}/rocelet/rocelet-web.conf"

# Python 3 standard library (http.server, socketserver, json, socket, argparse, urllib)
RDEPENDS:${PN} = "python3-modules bash"
