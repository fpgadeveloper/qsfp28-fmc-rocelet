/*
 * sysif.h - the system side of rocelet_sys: the firmware work-request queue
 * and completion queues, raw frames and capture, the memory window, and the
 * self-test logic (WR generator, fault injectors, pattern, counter snapshots).
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#ifndef SYSIF_H_
#define SYSIF_H_

#include "xil_types.h"
#include "rocelet_regs.h"
#include "rsys_regs.h"

/* WR opcodes (rocelet descriptor [11:8]) and flags */
#define OP_WRITE       0
#define OP_WRITE_IMM   1
#define OP_SEND        2
#define OP_SEND_IMM    3
#define OPF_SE         0x10
#define OPF_HSB_MD     0x20

/* the firmware's "host" QP in loopback tests (raw frames to engine QP n-1) */
#define HOST_QPN       0x000050u
#define HOST_IP        0xC0A81463u          /* 192.168.20.99 */
extern const u8 HOST_MAC[6];

/* ---- firmware work requests and completions ---- */
int  wq_post(int qp, int op, u64 va, u32 rkey, u32 len, u32 imm, u64 laddr, u16 id);   /* 0 = queued */
void cq_enable(int wc, int rc);
int  wcq_pop(u32 *rec);                    /* [30:24] status [23:16] qp [15:0] wr_id; 1 = got one */
int  rcq_pop(u32 *rec, u32 *imm, u32 *len);

/* ---- self-test WR generator ---- */
void wg_start(int qp0, int nqp, int op, u64 va, u32 window, u32 len, u32 rkey, u32 count, u32 gap, u32 imm0);
void wg_stop(void);
int  wg_running(void);

/* ---- fault injectors: action 0 off 1 drop 2 corrupt; mode 0 once 1 periodic 2 random ---- */
void inj_set(int rx, int action, int mode, int cls, u32 skip, u32 count, u32 period, u32 thresh, u32 byte);
void inj_off(void);

/* ---- raw frames and capture ---- */
void raw_send(const u8 *f, int len);
void cap_arm(int mode, u8 op, u32 dqpn, int tx);     /* mode 0 any 1 opcode 2 dest QPN 3 both */
int  cap_done(void);
int  cap_wait(int ms);
int  cap_read(u8 *buf, int max);           /* returns the captured length */
u32  icrc_calc(const u8 *f, int len_wo_icrc);
int  build_roce(u8 *f, const u8 *dmac, const u8 *smac, u32 sip, u32 dip, u16 sport, u8 op, u32 dqpn,
                u32 psn, int ackreq, const u8 *ext, int ext_len, const u8 *pay, int pay_len);
void pat_beat(u64 a, u32 seed, u8 *out64);
#define PAT_SEED       0x5EED1234u

/* ---- counter snapshots ---- */
typedef struct {
	u32 c[RSYS_NCNT];
	u64 b[RSYS_NBC];
	u32 e[ROCELET_NUM_COUNTERS];
} snap_t;
void snap(snap_t *s);
#define DC(x, y, i)  ((u32)((y)->c[i] - (x)->c[i]))           /* system counter delta */
#define DB(x, y, i)  ((y)->b[i] - (x)->b[i])                  /* system accumulator delta */
#define DE(x, y, off) ((u32)((y)->e[((off) - ROCELET_CNT_BASE) / 4] - (x)->e[((off) - ROCELET_CNT_BASE) / 4]))
int  wait_idle(u32 timeout_ms);            /* generator done, every WR completed, TX quiet; 0 = idle */
void sys_dump(void);                       /* non-zero system counters */

#endif
