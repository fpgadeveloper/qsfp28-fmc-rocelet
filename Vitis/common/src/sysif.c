/*
 * sysif.c - the system side of rocelet_sys (see sysif.h).
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#include <string.h>
#include "xil_printf.h"
#include "sleep.h"
#include "hw.h"
#include "util.h"
#include "eng.h"
#include "sysif.h"

const u8 HOST_MAC[6] = { 0x02, 0x00, 0x00, 0x00, 0x00, 0x99 };

/* ---------------- work requests and completions ---------------- */
int wq_post(int qp, int op, u64 va, u32 rkey, u32 len, u32 imm, u64 laddr, u16 id)
{
	if (sv(RSYS_S_WQ_STATUS) & (1u << 16)) return -1;          /* queue full */
	cfg_set(RSYS_C_WQ_QP, (u32)qp);
	cfg_set(RSYS_C_WQ_OP, (u32)op);
	cfg_set(RSYS_C_WQ_VA_LO, (u32)va);
	cfg_set(RSYS_C_WQ_VA_HI, (u32)(va >> 32));
	cfg_set(RSYS_C_WQ_RKEY, rkey);
	cfg_set(RSYS_C_WQ_LEN, len);
	cfg_set(RSYS_C_WQ_IMM, imm);
	cfg_set(RSYS_C_WQ_LA_LO, (u32)laddr);
	cfg_set(RSYS_C_WQ_LA_HI, (u32)(laddr >> 32));
	cfg_set(RSYS_C_WQ_ID, id);
	cfg_set(RSYS_C_WQ_POST, 1);
	return 0;
}

void cq_enable(int wc, int rc) { cfg_set(RSYS_C_CQ_CTRL, (wc ? 1u : 0u) | (rc ? 2u : 0u)); }

int wcq_pop(u32 *rec)
{
	u32 h = sv(RSYS_S_WCQ);
	if (!(h >> 31)) return 0;
	*rec = h & 0x7FFFFFFFu;
	cfg_set(RSYS_C_CQ_POP, 1);
	return 1;
}

int rcq_pop(u32 *rec, u32 *imm, u32 *len)
{
	u32 h = sv(RSYS_S_RCQ);
	if (!(h >> 31)) return 0;
	*rec = h & 0x7FFFFFFFu;
	*imm = sv(RSYS_S_RCQ_IMM);
	*len = sv(RSYS_S_RCQ_LEN);
	cfg_set(RSYS_C_CQ_POP, 2);
	return 1;
}

/* ---------------- WR generator ---------------- */
void wg_start(int qp0, int nqp, int op, u64 va, u32 window, u32 len, u32 rkey, u32 count, u32 gap, u32 imm0)
{
	cfg_set(RSYS_C_WG_QP, (u32)(qp0 & 0xFF) | ((u32)(nqp & 0xFF) << 8));
	cfg_set(RSYS_C_WG_OP, (u32)op);
	cfg_set(RSYS_C_WG_VA_LO, (u32)va);
	cfg_set(RSYS_C_WG_VA_HI, (u32)(va >> 32));
	cfg_set(RSYS_C_WG_WINDOW, window);
	cfg_set(RSYS_C_WG_LEN, len);
	cfg_set(RSYS_C_WG_RKEY, rkey);
	cfg_set(RSYS_C_WG_COUNT, count);
	cfg_set(RSYS_C_WG_GAP, gap);
	cfg_set(RSYS_C_WG_IMM, imm0);
	cfg_set(RSYS_C_WC_BASE_LO, (u32)va);
	cfg_set(RSYS_C_WC_BASE_HI, (u32)(va >> 32));
	cfg_set(RSYS_C_WG_CTRL, 1);
}

void wg_stop(void)    { cfg_set(RSYS_C_WG_CTRL, 2); }
int  wg_running(void) { return (sv(RSYS_S_STATUS) >> 1) & 1; }

/* ---------------- injectors ---------------- */
void inj_set(int rx, int action, int mode, int cls, u32 skip, u32 count, u32 period, u32 thresh, u32 byte)
{
	int b = rx ? RSYS_C_RINJ_CTRL : RSYS_C_INJ_CTRL;
	cfg_set(b + 1, (u32)cls);
	cfg_set(b + 2, skip);
	cfg_set(b + 3, count);
	cfg_set(b + 4, period);
	cfg_set(b + 5, thresh);
	cfg_set(b + 6, byte);
	cfg_set(b, 0x100u | ((u32)(mode & 3) << 2) | (u32)(action & 3));
}

void inj_off(void)
{
	cfg_set(RSYS_C_INJ_CTRL, 0);
	cfg_set(RSYS_C_RINJ_CTRL, 0);
}

/* ---------------- raw frames, capture ---------------- */
void raw_send(const u8 *f, int len)
{
	/* the previous frame must have left the buffer (S_HP_STATUS[2] raw TX busy) */
	for (int t = 0; t < 100000 && (sv(RSYS_S_HP_STATUS) & 4u); t++)
		;
	for (int w = 0; w < (len + 3) / 4; w++) {
		u32 v = 0;
		for (int b = 0; b < 4; b++) if (4 * w + b < len) v |= (u32)f[4 * w + b] << (8 * b);
		sys_wr(RSYS_RAW_TX + 4u * (u32)w, v);
	}
	cfg_set(RSYS_C_RAW_LEN, (u32)len);
	cfg_set(RSYS_C_RAW_SEND, 1);
}

void cap_arm(int mode, u8 op, u32 dqpn, int tx)
{
	cfg_set(RSYS_C_CAP_MATCH, op | (dqpn << 8));
	cfg_set(RSYS_C_CAP_CTRL, 1u | ((u32)(mode & 3) << 1) | (tx ? 8u : 0u));
}

int cap_done(void) { return sv(RSYS_S_CAP_STATUS) & 1; }

int cap_wait(int ms)
{
	for (int t = 0; t < ms * 10; t++) {
		if (cap_done()) return 1;
		usleep(100);
	}
	return 0;
}

int cap_read(u8 *buf, int max)
{
	int len = (int)((sv(RSYS_S_CAP_STATUS) >> 4) & 0x1FFF);
	int n = len < max ? len : max;
	if (n > 8192) n = 8192;
	for (int w = 0; w < (n + 3) / 4; w++) {
		u32 v = sys_rd(RSYS_CAP + 4u * (u32)w);
		for (int b = 0; b < 4; b++) if (4 * w + b < n) buf[4 * w + b] = (u8)(v >> (8 * b));
	}
	return len;
}

static u32 crc_tab[256];
static int crc_init_done;
static void crc_init(void)
{
	for (u32 i = 0; i < 256; i++) {
		u32 c = i;
		for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
		crc_tab[i] = c;
	}
	crc_init_done = 1;
}

u32 icrc_calc(const u8 *f, int n)
{
	/* zlib CRC-32 over 8 x 0xFF + the masked IPv4 / UDP / BTH headers + the rest
	 * (IBTA A17): IPv4 TOS, TTL, checksum; UDP checksum; BTH byte 4 = 0xFF */
	u32 c = 0xFFFFFFFFu;
	if (!crc_init_done) crc_init();
	for (int i = 0; i < 8; i++) c = crc_tab[(c ^ 0xFF) & 0xFF] ^ (c >> 8);
	for (int i = 14; i < n; i++) {
		u8 b = f[i];
		int o = i - 14;
		if (o == 1 || o == 8 || o == 10 || o == 11) b = 0xFF;
		if (o == 26 || o == 27) b = 0xFF;
		if (o == 32) b = 0xFF;
		c = crc_tab[(c ^ b) & 0xFF] ^ (c >> 8);
	}
	return ~c;
}

static void put16(u8 *p, u32 v) { p[0] = (u8)(v >> 8); p[1] = (u8)v; }
static void put24(u8 *p, u32 v) { p[0] = (u8)(v >> 16); p[1] = (u8)(v >> 8); p[2] = (u8)v; }
static void put32(u8 *p, u32 v) { p[0] = (u8)(v >> 24); p[1] = (u8)(v >> 16); p[2] = (u8)(v >> 8); p[3] = (u8)v; }

int build_roce(u8 *f, const u8 *dmac, const u8 *smac, u32 sip, u32 dip, u16 sport, u8 op, u32 dqpn,
               u32 psn, int ackreq, const u8 *ext, int ext_len, const u8 *pay, int pay_len)
{
	int pad = (4 - (pay_len & 3)) & 3;
	int l4 = 8 + 12 + ext_len + pay_len + pad + 4;
	int n;
	u32 sum = 0;
	memcpy(f, dmac, 6);
	memcpy(f + 6, smac, 6);
	put16(f + 12, 0x0800);
	n = 14;
	f[n + 0] = 0x45; f[n + 1] = 0x00; put16(f + n + 2, (u32)(20 + l4));
	put16(f + n + 4, 0); put16(f + n + 6, 0x4000);
	f[n + 8] = 64; f[n + 9] = 17; put16(f + n + 10, 0);
	put32(f + n + 12, sip); put32(f + n + 16, dip);
	for (int i = 0; i < 20; i += 2) sum += ((u32)f[n + i] << 8) | f[n + i + 1];
	while (sum >> 16) sum = (sum & 0xFFFF) + (sum >> 16);
	put16(f + n + 10, ~sum & 0xFFFF);
	n += 20;
	put16(f + n, sport); put16(f + n + 2, 4791); put16(f + n + 4, (u32)l4); put16(f + n + 6, 0);
	n += 8;
	f[n + 0] = op; f[n + 1] = (u8)(0x40 | (pad << 4)); put16(f + n + 2, 0xFFFF);
	f[n + 4] = 0; put24(f + n + 5, dqpn); f[n + 8] = ackreq ? 0x80 : 0; put24(f + n + 9, psn);
	n += 12;
	if (ext_len) { memcpy(f + n, ext, (size_t)ext_len); n += ext_len; }
	if (pay_len) { memcpy(f + n, pay, (size_t)pay_len); n += pay_len; }
	for (int i = 0; i < pad; i++) f[n++] = 0;
	u32 ic = icrc_calc(f, n);
	f[n++] = (u8)ic; f[n++] = (u8)(ic >> 8); f[n++] = (u8)(ic >> 16); f[n++] = (u8)(ic >> 24);
	return n;
}

static const u64 PAT_K[8] = {
	0x0000000000000000ull, 0x9E3779B97F4A7C15ull, 0x3C6EF372FE94F82Aull, 0xDAA66D2C7DDF743Full,
	0x78DDE6E5FD29F054ull, 0x1715609F7C746C69ull, 0xB54CDA58FBBEE87Eull, 0x538454127B096493ull
};

void pat_beat(u64 a, u32 seed, u8 *o)
{
	u64 x = a ^ (((u64)seed << 32) | (u64)(u32)~seed);
	for (int i = 0; i < 8; i++) {
		u64 w = (i == 0) ? a : x + PAT_K[i];
		for (int b = 0; b < 8; b++) o[8 * i + b] = (u8)(w >> (8 * b));
	}
}

/* ---------------- snapshots, idle, dump ---------------- */
void snap(snap_t *s)
{
	for (int i = 0; i < RSYS_NCNT; i++) s->c[i] = cnt(i);
	for (int i = 0; i < RSYS_NBC; i++) s->b[i] = bc(i);
	for (int i = 0; i < ROCELET_NUM_COUNTERS; i++) s->e[i] = eng_rd(ROCELET_CNT_BASE + 4u * (u32)i);
}

int wait_idle(u32 timeout_ms)
{
	u32 prev = 0xFFFFFFFFu;
	int stable = 0;
	for (u32 t = 0; t < timeout_ms * 10; t++) {
		usleep(100);
		u32 tx = cnt(RSYS_E_TX_FRAMES);
		if (!wg_running() && eng_rd(ROCELET_WR_OUTSTANDING) == 0 &&
		    !(sv(RSYS_S_WQ_STATUS) & 0x201FFu) && tx == prev) {
			if (++stable >= 3) return 0;
		} else {
			stable = 0;
		}
		prev = tx;
	}
	return -1;
}

static const char *sys_cnt_name[RSYS_NCNT] = {
	"wg_issued", "wc", "wc_err", "wc_lost", "rc", "rc_send", "rc_imm_seq", "wchk_bursts",
	"wc_mism", "wc_gaps", "sc_ok", "sc_bad", "sc_mism", "sc_gaps", "inj_seen", "inj_done",
	"rinj_seen", "rinj_done", "raw_sent", "cap_done", "lat_ovf", "tx_underrun", "mac_tx_unf", "mac_tx_bad_fcs",
	"mac_align_lost", "wcq_ovf", "rcq_ovf", "wq_posted", "wq_drop", "mem_wr_bursts", "mem_rd_bursts", "tx_frames",
	"rx_frames", "tx_op_req", "tx_op_ack", "tx_op_nak", "tx_op_rdrsp", "rx_op_req", "rx_op_ack", "rx_op_nak",
	"rx_op_rdrsp", "rx_roce", "tx_roce", "", "", "", "", ""
};
static const char *sys_bc_name[RSYS_NBC] = {
	"", "wg_bytes", "wc_bytes", "sc_bytes", "rd_bytes", "lat_sum", "tx_bytes", "rx_bytes",
	"mac_rx_pkts", "mac_rx_bad_fcs", "mac_rx_bad_code", "mac_tx_pkts", "", "", "", ""
};

void sys_dump(void)
{
	int n = 0;
	for (int i = 0; i < RSYS_NCNT; i++) {
		u32 v = cnt(i);
		if (!v || !sys_cnt_name[i][0]) continue;
		xil_printf("  %s=%u", sys_cnt_name[i], v);
		if (++n % 6 == 0) xil_printf("\r\n");
	}
	if (n % 6) xil_printf("\r\n");
	n = 0;
	for (int i = 1; i < RSYS_NBC; i++) {
		u64 v = bc(i);
		if (!v || !sys_bc_name[i][0]) continue;
		xil_printf("  %s=", sys_bc_name[i]); pr_u64(v);
		if (++n % 6 == 0) xil_printf("\r\n");
	}
	if (n % 6) xil_printf("\r\n");
}
