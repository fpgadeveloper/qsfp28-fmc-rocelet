/*
 * roceletd.h - what the daemon's other files need from roceletd.c.
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#ifndef ROCELETD_H_
#define ROCELETD_H_

#include "xil_types.h"

#define RLD_VERSION   "1.0"
#define RLD_SOCKET    "/run/rocelet/roceletd.sock"

const char *rld_iface(void);               /* the port's Linux interface (rl0) */
void rld_set_ip(u32 ip);                   /* give the interface this IPv4 address (/24) */

/* control-socket protocol (rl, the web UI): the client sends one command line ending in '\n';
 * the daemon answers with the command's output text, then a NUL byte, the exit status in
 * decimal and '\n'. A connection may carry any number of commands. */

#endif
