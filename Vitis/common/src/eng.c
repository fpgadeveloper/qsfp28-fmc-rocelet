/*
 * eng.c - the rocelet engine as the firmware uses it (see eng.h).
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#include "xil_printf.h"
#include "sleep.h"
#include "hw.h"
#include "util.h"
#include "eng.h"

eng_cfg_t ENG;
u8  MY_MAC[6] = { 0x02, 0x0a, 0x35, 0x72, 0x6c, 0x01 };  /* locally administered */
u32 MY_IP     = 0xC0A81402u;                              /* 192.168.20.2 */
u32 g_link_grace = LINK_GRACE_DEF;

#define F(v, name) (((v) & ROCELET_##name##_MASK) >> ROCELET_##name##_SHIFT)

const char *rtx_name(int m) { return m == 0 ? "RING" : m == 1 ? "REREAD" : m == 2 ? "LOSSY" : "?"; }

int eng_probe(void)
{
	if (eng_rd(ROCELET_ID) != ROCELET_ID_VALUE || sys_rd(RSYS_SV(RSYS_S_ID)) != 0x52535953u) return -1;
	u32 b0 = eng_rd(ROCELET_BUILD0), b1 = eng_rd(ROCELET_BUILD1), sc = sv(RSYS_S_SYS_CFG);
	ENG.version    = eng_rd(ROCELET_VERSION);
	ENG.num_qp     = (int)F(b0, BUILD0_NUM_QP);
	ENG.num_mr     = (int)F(b0, BUILD0_NUM_MR);
	ENG.read_depth = (int)F(b0, BUILD0_READ_DEPTH);
	ENG.rtx_mode   = (int)F(b0, BUILD0_RTX_MODE);
	ENG.rx_icrc    = (int)F(b0, BUILD0_RX_ICRC_EN);
	ENG.hsb        = (int)F(b0, BUILD0_HSB_EN);
	ENG.ring_kb    = (int)F(b1, BUILD1_RING_KB);
	ENG.max_wr     = (int)F(b1, BUILD1_MAX_WR);
	ENG.pmtu_log2  = (int)F(b1, BUILD1_PMTU_LOG2);
	ENG.qpn_base   = F(eng_rd(ROCELET_BUILD2), BUILD2_QPN_BASE);
	ENG.selftest   = (int)(sc & 1);
	ENG.pattern    = (int)((sc >> 1) & 1);
	ENG.mem_log2   = (int)((sc >> 8) & 0xFF);
	return 0;
}

u32 eng_ctrl_set(u32 set, u32 clr)
{
	u32 c = (eng_rd(ROCELET_CTRL) & ~clr) | set;
	eng_wr(ROCELET_CTRL, c);
	return c;
}

void eng_clear(void)
{
	eng_wr(ROCELET_CMD, ROCELET_CMD_CLR_COUNTERS_MASK | ROCELET_CMD_CLR_ERR_MASK);
	cfg_set(RSYS_C_CTRL, 2u);          /* system statistics clear (pulse) */
	cfg_set(RSYS_C_CTRL, 0u);
}

void eng_global(void)
{
	eng_wr(ROCELET_MAC_LO, ((u32)MY_MAC[2] << 24) | ((u32)MY_MAC[3] << 16) | ((u32)MY_MAC[4] << 8) | MY_MAC[5]);
	eng_wr(ROCELET_MAC_HI, ((u32)MY_MAC[0] << 8) | MY_MAC[1]);
	eng_wr(ROCELET_IP4, MY_IP);
	eng_wr(ROCELET_IP_HDR, 64u << 8);              /* TTL 64, TOS 0 */
	eng_wr(ROCELET_TICK_DIV, F_CLK_HZ / 1000000u);    /* 1 tick = 1 us: ACK timeout, RNR wait, LINK_GRACE */
	eng_clear();
}

/* The settings the console and the tests change, back to the defaults: READ continuation on
 * (required by the ConnectX-6 Dx), loss recovery (not fatal), retry limits, RNR wait
 * clamp and NAK timer, AckReq interval, no rate limit, LINK_GRACE (the console's 'grace' value,
 * default 2 s), ACK timeout 5 ms (rocelet's reset values since v0.2.2 / v0.2.1; 0.2.1 of this
 * console used 5 ms / 6 s, 0.2.0 1 ms / 3 s, earlier versions 200 us). The
 * PAUSE and 802.1Q bits of CTRL stay as 'pause' / 'vlan' set them (the CMAC's PAUSE
 * configuration goes with them). */
void eng_defaults(void)
{
	eng_ctrl_set(ROCELET_CTRL_READ_CONT_MASK, ROCELET_CTRL_LOSS_FATAL_MASK);
	eng_wr(ROCELET_ACK_TIMEOUT, ACK_TIMEOUT_DEF);
	eng_wr(ROCELET_RETRY, 0x77u);                   /* retry_cnt 7, rnr_retry 7 */
	eng_wr(ROCELET_RNR_MIN, 10u);
	eng_wr(ROCELET_RNR_MAX, 655360u);
	eng_wr(ROCELET_RNR_NAK_TIMER, 10u);             /* the RNR NAKs this responder sends */
	eng_wr(ROCELET_ACKREQ_N, 16u);
	eng_pace_default();
	eng_wr(ROCELET_LINK_GRACE, g_link_grace & ROCELET_LINK_GRACE_TICKS_MASK);
}

/* No requester rate limit ('pace'), 16 KB burst: part of eng_defaults() and of 'mac' (which
 * reset the rate limit through eng_global() until console 0.2.0 moved it to eng_defaults()). */
void eng_pace_default(void)
{
	eng_wr(ROCELET_PACE_RATE, 0);
	eng_wr(ROCELET_PACE_BURST, 0x4000u);
}

u32 eng_sq_psn0(int qp) { return (0x010000u * (u32)(qp + 1) + 0x123u) & 0xFFFFFF; }

void eng_qp(int qp, int type, u32 sq_psn, u32 rq_psn, int pmtu_log2, u32 dqpn,
            const u8 *m, u32 dip, u32 sport, u32 dport)
{
	eng_wr(ROCELET_QP_INDEX, (u32)qp);
	eng_wr(ROCELET_QP_FLAGS, 1u | ((u32)type << ROCELET_QP_FLAGS_TYPE_SHIFT));
	eng_wr(ROCELET_QP_SQ_PSN, sq_psn & 0xFFFFFF);
	eng_wr(ROCELET_QP_RQ_PSN, rq_psn & 0xFFFFFF);
	eng_wr(ROCELET_QP_PMTU, (u32)pmtu_log2);
	eng_wr(ROCELET_QP_DMAC_LO, ((u32)m[2] << 24) | ((u32)m[3] << 16) | ((u32)m[4] << 8) | m[5]);
	eng_wr(ROCELET_QP_DMAC_HI, ((u32)m[0] << 8) | m[1]);
	eng_wr(ROCELET_QP_DIP0, dip);
	eng_wr(ROCELET_QP_DQPN, dqpn & 0xFFFFFF);
	eng_wr(ROCELET_QP_UDP, ((sport & 0xFFFF) << ROCELET_QP_UDP_SPORT_SHIFT) | ((dport & 0xFFFF) << ROCELET_QP_UDP_DPORT_SHIFT));
	eng_wr(ROCELET_QP_IPV6, 0);
	eng_wr(ROCELET_QP_COMMIT, 1);
}

void eng_qp_disable(int qp)
{
	eng_wr(ROCELET_QP_INDEX, (u32)qp);
	eng_wr(ROCELET_QP_FLAGS, 0);
	eng_wr(ROCELET_QP_COMMIT, 1);
}

u32 eng_qp_status(int qp)
{
	eng_wr(ROCELET_QP_INDEX, (u32)qp);
	return eng_rd(ROCELET_QP_STATUS);
}

void eng_mr(int idx, u32 rkey, u64 va, u32 len, u64 laddr, int acc)
{
	eng_wr(ROCELET_MR_INDEX, (u32)idx);
	eng_wr(ROCELET_MR_RKEY, rkey);
	eng_wr(ROCELET_MR_VA_LO, (u32)va);
	eng_wr(ROCELET_MR_VA_HI, (u32)(va >> 32));
	eng_wr(ROCELET_MR_LEN, len);
	eng_wr(ROCELET_MR_LADDR_LO, (u32)laddr);
	eng_wr(ROCELET_MR_LADDR_HI, (u32)(laddr >> 32));
	eng_wr(ROCELET_MR_FLAGS, (acc ? ROCELET_MR_FLAGS_VALID_MASK : 0) |
	                         ((acc & 1) ? ROCELET_MR_FLAGS_REMOTE_WRITE_MASK : 0) |
	                         ((acc & 2) ? ROCELET_MR_FLAGS_REMOTE_READ_MASK : 0));
	eng_wr(ROCELET_MR_COMMIT, 1);
}

void eng_mrs_default(void)
{
	u32 mem = 1u << ENG.mem_log2;
	if (ENG.pattern) eng_mr(0, RKEY_PAT, PAT_REGION, 0x40000000u, PAT_REGION, 3);
	else             eng_mr(0, 0xDEAD0000u, 0, 0, 0, 0);
	eng_mr(1, RKEY_MEM, 0, mem, 0, 3);
	eng_mr(2, RKEY_MEM_RO, 0, mem, 0, 2);
	for (int i = 3; i < ENG.num_mr; i++) eng_mr(i, 0xDEAD0000u | (u32)i, 0, 0, 0, 0);
}

int eng_err(void) { return (eng_rd(ROCELET_STATUS) & ROCELET_STATUS_ERR_MASK) != 0; }

void eng_errors(void)
{
	u32 q = eng_rd(ROCELET_LAST_REQ_ERR), r = eng_rd(ROCELET_LAST_RESP_ERR);
	xil_printf("errors: latch %d | QP error map 0x%08x", eng_err(), eng_rd(ROCELET_QP_ERR_MAP0));
	if (ENG.num_qp > 32) xil_printf(" 0x%08x", eng_rd(ROCELET_QP_ERR_MAP1));
	xil_printf(" | last requester error %s qp %d code 0x%02x | last responder error %s qp %d code 0x%02x\r\n",
		   (q >> 31) ? "yes" : "no", (q >> 8) & 0xFF, q & 0xFF, (r >> 31) ? "yes" : "no", (r >> 8) & 0xFF, r & 0xFF);
}

static const char *cnt_name[] = { ROCELET_COUNTER_NAMES };

void eng_dump(void)
{
	int n = 0;
	for (int i = 0; i < ROCELET_NUM_COUNTERS; i++) {
		u32 v = eng_rd(ROCELET_CNT_BASE + 4u * (u32)i);
		if (!v) continue;
		xil_printf("  %s=%u", cnt_name[i], v);
		if (++n % 6 == 0) xil_printf("\r\n");
	}
	if (n % 6) xil_printf("\r\n");
	u64 cyc = eng_rd64(ROCELET_CYCLES_LO);
	xil_printf("  rx bytes "); pr_u64(eng_rd64(ROCELET_RX_BYTES_LO));
	xil_printf(" tx bytes "); pr_u64(eng_rd64(ROCELET_TX_BYTES_LO));
	xil_printf(" in "); pr_fix(cyc * 1000ull, F_CLK_HZ, 1);
	xil_printf(" ms | WRs outstanding %u, ring used %u beats, RX FIFO %u (max %u)\r\n",
		   eng_rd(ROCELET_WR_OUTSTANDING), eng_rd(ROCELET_RING_USED), eng_rd(ROCELET_RX_FIFO_LEVEL) & 0xFFFF,
		   eng_rd(ROCELET_RX_FIFO_LEVEL) >> 16);
}
