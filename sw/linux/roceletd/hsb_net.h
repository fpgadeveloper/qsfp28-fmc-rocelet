/*
 * hsb_net.h - the Holoscan Sensor Bridge control plane's transport on Linux (roceletd): plain UDP
 * sockets on rl0 instead of the standalone build's frame path (rsys_crx / rsys_raw). Used by
 * Vitis/common/src/hsb.c under PLAT_LINUX.
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#ifndef HSB_NET_H_
#define HSB_NET_H_

#include "xil_types.h"

int  hsb_net_open(void);                   /* UDP 8192 (register protocol) + 12268 (enumeration) on rl0 */
void hsb_net_close(void);
void hsb_net_send(u32 dip, u32 sport, u32 dport, const u8 *p, int n);   /* from our sport */
/* one datagram (non-blocking): payload into p (max bytes), its source and our port; -1 = none */
int  hsb_net_recv(u32 *sip, u32 *sport, u32 *dport, u8 *smac, u8 *p, int max);
void hsb_net_set_ip(u32 ip);               /* hololink-set-ip: rl0 takes the new address (/24) */
void hsb_net_status(void);                 /* one status line (hsb st) */
int  hsb_net_fds(int *fds);                /* the open sockets, for the event loop; returns the count */

#endif
