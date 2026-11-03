/*
 * selftest.h - loopback configuration and the built-in self-test of the
 * qsfp28-fmc-rocelet design.
 *
 * The self-test needs the CMAC's TX to come back on its RX: a QSFP28 loopback
 * plug in port 0, or the GT near-end loopback (`loop pma`, no plug needed; the
 * frames are still transmitted on the fibre/cable, addressed to the FPGA itself).
 * The engine's requester then talks to its own responder: QP q sends to QP q^1
 * and QP q^1's ACKs come back to QP q; QP n-1 is the responder QP of the
 * firmware's "host" QP (QPN 0x50), which sends hand-built READ requests and
 * WRITEs with good and bad ICRCs through the raw frame path.
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#ifndef SELFTEST_H_
#define SELFTEST_H_

#include "xil_types.h"

void loop_setup(int pmtu_log2);            /* engine, QPs and MRs for loopback, counters cleared */
void mem_fill_pat(u32 a, u32 len, u32 seed);   /* memory window [a, a+len) = pattern(address) */
extern u8 cbuf[8200];                      /* capture buffer (also the console's capd) */
int  selftest(int quick);                  /* runs the suite, prints "SELFTEST PASS|FAIL ..." ; 0 = pass */

/* single tests, also available from the console */
int  t_arp(void);
int  t_wrq(void);
int  t_write(u32 len, int pmtu_log2, u32 n, int op);
int  t_tput(u32 len, int pmtu_log2, u32 ms, int nqp);
int  t_inject(int rx, int action, int cls, u32 skip, u32 count, u32 nwr, u32 len, int pmtu_log2);
int  t_read(u32 len, int pmtu_log2);
int  t_icrc(void);
int  t_cnp_vlan(void);
int  t_access(void);
int  t_lat(u32 n, u32 len, int pmtu_log2);
int  t_soak(u32 secs, u32 len, int pmtu_log2, u32 ppm);

#endif
