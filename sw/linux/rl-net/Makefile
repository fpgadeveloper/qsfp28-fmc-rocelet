# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
#
# Out-of-tree build of the rl_net network driver (rl0). Also the shape the Yocto module.bbclass
# expects (KERNEL_SRC, O=, `modules`, `modules_install`).

obj-m += rl_net.o

ifneq ($(KERNEL_SRC),)
KDIR ?= $(KERNEL_SRC)
endif
KDIR ?= /lib/modules/$(shell uname -r)/build
SRC := $(shell pwd)

all: modules

modules:
	$(MAKE) -C $(KDIR) M=$(SRC) modules

modules_install:
	$(MAKE) -C $(KDIR) M=$(SRC) modules_install

clean:
	$(MAKE) -C $(KDIR) M=$(SRC) clean

.PHONY: all modules modules_install clean
