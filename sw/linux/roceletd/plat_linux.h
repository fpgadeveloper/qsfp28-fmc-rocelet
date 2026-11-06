/*
 * plat_linux.h - the Linux side of the console's platform layer (plat_linux.c), as roceletd
 * uses it: the UIO mappings, the console output sink and the daemon log.
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#ifndef PLAT_LINUX_H_
#define PLAT_LINUX_H_

#include "xil_types.h"

#define REGS_PA     0x80000000u            /* rsys_aon_0: rocelet_sys (guarded) + always-on registers */

/* map the register window (UIO named regs_name, waits up to wait_s seconds for it); the PS DDR
 * window carve-out (UIO ddr_name) is mapped by plat_ddr_init(). 0 = ok */
int  plat_linux_open(const char *regs_name, const char *ddr_name, int wait_s);
/* map further register blocks: the UIO devices named in names (comma separated; absent ones are
 * skipped), every map of each; returns the number of windows added */
int  plat_linux_map(const char *names);
int  plat_regs_fd(void);                   /* the register window's UIO fd (interrupt) */
u32  plat_regs_size(void);

/* console output: while a command runs for a client, xil_printf goes to its socket (CR removed);
 * otherwise to stdout (the journal) and to the daemon log ring */
void out_begin(int fd);
void out_end(void);
int  out_client(void);                     /* the fd output currently goes to, -1 = journal */
void dlog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));   /* daemon message: journal + ring */
int  dlog_dump(int fd, int max);           /* the last max lines of the ring to fd */

/* I2C adapter (/dev/i2c-N) of the AXI IIC at base; -1 if not found */
int  plat_i2c_bus(UINTPTR base);

#endif
