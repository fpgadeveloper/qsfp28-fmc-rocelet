# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

# qsfp28-fmc-rocelet (PS control plane) additions to the EDF disk image: the rl0 network driver, the
# daemon + CLI, the web UI, and the bench set for bring-up and the autonomous test loop. sshd comes
# from the ssh-server-openssh image feature. No key or password is installed by this layer:
# provisioning is done over the UART, per board.
ROCELET_PACKAGES = " \
    rl-net-mod \
    rocelet-tools \
    rocelet-web \
"
ROCELET_BENCH_PACKAGES = " \
    devmem2 \
    i2c-tools \
    ethtool \
    iproute2 \
    iperf3 \
    phytool \
    tcpdump \
    curl \
"

IMAGE_FEATURES += "ssh-server-openssh"

IMAGE_INSTALL:append = " ${ROCELET_PACKAGES} ${ROCELET_BENCH_PACKAGES}"

# The EDF user may run the CLI rl (the console socket is root:rocelet 0660).
EXTRA_USERS_PARAMS:append = " usermod -a -G rocelet amd-edf;"
