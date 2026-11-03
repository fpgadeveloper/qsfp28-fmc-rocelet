/*
 * eng.h - the rocelet engine as the firmware uses it: build parameters, global
 * configuration, queue pairs, memory windows, counters and errors. Register map:
 * rocelet_regs.h (generated in the rocelet repository).
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#ifndef ENG_H_
#define ENG_H_

#include "xil_types.h"

typedef struct {
	int num_qp, num_mr, read_depth, rtx_mode, rx_icrc, hsb, max_wr, ring_kb, pmtu_log2;
	u32 qpn_base, version;
	int selftest, pattern, mem_log2;      /* from the system registers */
} eng_cfg_t;
extern eng_cfg_t ENG;

#define QP_RC      0
#define QP_UC      1
#define QP_UC_HSB  2

/* memory windows of the standard configuration (R_Key low bits = window index) */
#define PAT_REGION     0x0000010000000000ull  /* local address bit 40: self-test pattern region */
#define RKEY_PAT       0x00001000u            /* MR0: pattern region, identity, read+write (self-test builds) */
#define RKEY_MEM       0x00002001u            /* MR1: memory window, VA 0, read+write */
#define RKEY_MEM_RO    0x00003002u            /* MR2: memory window, VA 0, read only */

extern u8  MY_MAC[6];
extern u32 MY_IP;
extern u32 g_link_grace;                   /* LINK_GRACE ticks (us) restored by eng_defaults ('grace') */

/* defaults eng_defaults() restores (rocelet register reset values) */
#define LINK_GRACE_DEF  2000000u               /* 2 s: link_up includes the CMAC's remote fault, so the
                                                  grace starts at the partner's own link-up (ConnectX-6:
                                                  grace 0 / 1 / 3 s all survived 5 s drops); 2 s = margin */
#define ACK_TIMEOUT_MAX 0xFFFFFu               /* ACK_TIMEOUT is 20 bits: 1,048,575 us */
#define ACK_TIMEOUT_DEF 5000u                  /* us; x (retry_cnt 7 + 1) = 40 ms retry budget: covers a
                                                  ConnectX-6 that goes silent 15-25 ms before the FPGA
                                                  loses alignment (host-side port reconfiguration) */

int  eng_probe(void);                      /* read ID / build parameters; 0 = engine found */
const char *rtx_name(int m);
void eng_global(void);                     /* MAC, IP, IP header, timer tick; clears counters */
void eng_defaults(void);                   /* requester / responder settings back to their defaults (setup) */
void eng_pace_default(void);               /* requester rate limit off, burst 16 KB (setup, 'mac') */
void eng_clear(void);                      /* engine + system counters, error latch */
void eng_qp(int qp, int type, u32 sq_psn, u32 rq_psn, int pmtu_log2, u32 dqpn,
            const u8 *dmac, u32 dip, u32 sport, u32 dport);
void eng_qp_disable(int qp);
u32  eng_qp_status(int qp);
void eng_mr(int idx, u32 rkey, u64 va, u32 len, u64 laddr, int acc);   /* acc [0] write [1] read */
void eng_mrs_default(void);                /* MR0..MR2 as above, the rest invalid */
u32  eng_sq_psn0(int qp);                  /* first PSN the firmware gives a QP */
u32  eng_ctrl_set(u32 set, u32 clr);       /* CTRL read-modify-write, returns the new value */
void eng_dump(void);                       /* non-zero engine counters */
void eng_errors(void);                     /* error latch, QP error map, last errors */
int  eng_err(void);                        /* STATUS.ERR */

#endif
