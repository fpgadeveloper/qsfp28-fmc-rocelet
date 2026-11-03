/*
 * selftest.c - loopback configuration and the built-in self-test (see selftest.h).
 * Every test prints "TEST <name>: PASS|FAIL" plus its numbers; selftest() ends
 * with one line "SELFTEST PASS|FAIL <passed>/<run> ..." for the bench loop.
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#include <string.h>
#include "xil_printf.h"
#include "sleep.h"
#include "hw.h"
#include "util.h"
#include "cmac.h"
#include "eng.h"
#include "sysif.h"
#include "selftest.h"

#define HOST_PSN0       0x400000u

static int g_pass, g_fail;
static u8 fbuf[8200];
u8 cbuf[8200];                  /* capture buffer, shared with the console */

static int verdict(const char *name, int ok)
{
	xil_printf("TEST %s: %s\r\n", name, ok ? "PASS" : "FAIL");
	if (ok) g_pass++; else g_fail++;
	return ok ? 0 : -1;
}

/* rocelet v0.2 holds the requester's ACK timeouts while the link is down and for LINK_GRACE
 * (default 2 s) after it comes back (STATUS.TIMER_HOLD). Right after a relink ('t pma', 'loop',
 * 'link', power-up) the tests that recover by an ACK timeout would wait out the grace, so every
 * test first waits for the hold to end (bounded: the grace plus 1 s). */
static void hold_wait(void)
{
	if (!(eng_rd(ROCELET_STATUS) & ROCELET_STATUS_TIMER_HOLD_MASK)) return;
	u32 lim = (eng_rd(ROCELET_LINK_GRACE) & ROCELET_LINK_GRACE_TICKS_MASK) / 1000u + 1000u, ms = 0;
	while ((eng_rd(ROCELET_STATUS) & ROCELET_STATUS_TIMER_HOLD_MASK) && ms < lim) { usleep(1000); ms++; }
	xil_printf("  (ACK timeouts held after the link came up (LINK_GRACE): waited %u ms%s)\r\n", ms,
		   ms >= lim ? ", STILL HELD" : "");
}

static int link_ok(void)
{
	if (!cmac_link_up()) { xil_printf("link down - test not run\r\n"); return 0; }
	hold_wait();
	return 1;
}

static u32 be24(const u8 *p) { return ((u32)p[0] << 16) | ((u32)p[1] << 8) | p[2]; }

static void reth(u8 *e, u64 va, u32 rkey, u32 len)
{
	for (int i = 0; i < 8; i++) e[i] = (u8)(va >> (56 - 8 * i));
	e[8] = (u8)(rkey >> 24); e[9] = (u8)(rkey >> 16); e[10] = (u8)(rkey >> 8); e[11] = (u8)rkey;
	e[12] = (u8)(len >> 24); e[13] = (u8)(len >> 16); e[14] = (u8)(len >> 8); e[15] = (u8)len;
}

/* a frame from the firmware's "host" QP to engine QP n-1 */
static int host_frame(u8 *f, u8 op, u32 psn, int ackreq, const u8 *ext, int ext_len, const u8 *pay, int pay_len)
{
	return build_roce(f, MY_MAC, HOST_MAC, HOST_IP, MY_IP, 0xC0DE, op, ENG.qpn_base + (u32)ENG.num_qp - 1u,
			  psn, ackreq, ext, ext_len, pay, pay_len);
}

/* fill [a, a + len) of the memory window with pattern(address) */
void mem_fill_pat(u32 a, u32 len, u32 seed)
{
	u8 pb[64];
	for (u32 o = 0; o < len; o += 64) {
		pat_beat(a + o, seed, pb);
		for (int w = 0; w < 16; w++)
			mem_wr(a + o + 4u * (u32)w, (u32)pb[4 * w] | ((u32)pb[4 * w + 1] << 8) |
			       ((u32)pb[4 * w + 2] << 16) | ((u32)pb[4 * w + 3] << 24));
	}
}

/* ------------------------------------------------------------------ */
/* loopback configuration                                              */
/* ------------------------------------------------------------------ */
void loop_setup(int pmtu_log2)
{
	int n = ENG.num_qp;
	if (ENG.selftest) wg_stop();
	wait_idle(100);
	inj_off();
	cq_enable(0, 0);
	eng_global();
	eng_defaults();                     /* READ_CONT on, ACK timeout 5 ms, retry / RNR / pace / LINK_GRACE */
	/* QPs 0..n-3 are connected pairs (q <-> q^1); n-2 loops to itself; n-1 is the
	 * responder QP of the firmware's "host" QP (raw READ / WRITE requests) */
	for (int q = 0; q < n; q++) {
		if (q == n - 1)
			eng_qp(q, QP_RC, eng_sq_psn0(q), HOST_PSN0, pmtu_log2, HOST_QPN, HOST_MAC, HOST_IP, 0xC000u | (u32)q, 0);
		else if (q == n - 2)
			eng_qp(q, QP_RC, eng_sq_psn0(q), eng_sq_psn0(q), pmtu_log2, ENG.qpn_base + (u32)q, MY_MAC, MY_IP,
			       0xC000u | (u32)q, 0);
		else
			eng_qp(q, QP_RC, eng_sq_psn0(q), eng_sq_psn0(q ^ 1), pmtu_log2, ENG.qpn_base + (u32)(q ^ 1), MY_MAC,
			       MY_IP, 0xC000u | (u32)q, 0);
	}
	eng_mrs_default();
	cfg_set(RSYS_C_WG_SEED, PAT_SEED);
	cfg_set(RSYS_C_WC_SEED, PAT_SEED);
	cfg_set(RSYS_C_WC_BASE_LO, (u32)PAT_REGION);
	cfg_set(RSYS_C_WC_BASE_HI, (u32)(PAT_REGION >> 32));
	eng_clear();
}

/* ------------------------------------------------------------------ */
/* streams through the loopback                                        */
/* ------------------------------------------------------------------ */
typedef struct { u32 iss, cpl, lost, werr, mism, gaps, ibad, roce, naks, tos, rtx, inj; u64 landed; } res_t;

static void results(const snap_t *a, const snap_t *b, res_t *r)
{
	r->iss    = DC(a, b, RSYS_E_WG_ISSUED);
	r->cpl    = DC(a, b, RSYS_E_WC);
	r->lost   = DC(a, b, RSYS_E_WC_LOST);
	r->werr   = DC(a, b, RSYS_E_WC_ERR);
	r->mism   = DC(a, b, RSYS_E_WC_MISM) + DC(a, b, RSYS_E_SC_MISM);
	r->gaps   = DC(a, b, RSYS_E_WC_GAPS) + DC(a, b, RSYS_E_SC_GAPS);
	r->landed = DB(a, b, RSYS_B_WC_BYTES) + DB(a, b, RSYS_B_SC_BYTES);
	r->ibad   = DE(a, b, ROCELET_CNT_RX_ICRC_BAD);
	r->roce   = DC(a, b, RSYS_E_RX_ROCE);
	r->naks   = DE(a, b, ROCELET_CNT_RX_NAK_SEQ);
	r->tos    = DE(a, b, ROCELET_CNT_REQ_TIMEOUT);
	r->rtx    = DE(a, b, ROCELET_CNT_REQ_RTX);
	r->inj    = DC(a, b, RSYS_E_INJ_DONE) + DC(a, b, RSYS_E_RINJ_DONE);
}

static int check_stream(const res_t *r, u32 len, int idle)
{
	xil_printf("  WRs %u completions %u (errors %u, lost %u) | landed ", r->iss, r->cpl, r->werr, r->lost);
	pr_u64(r->landed);
	xil_printf(" B (expected "); pr_u64((u64)r->iss * len);
	xil_printf(") | mismatch %u gaps %u | ICRC bad %u of %u RoCE frames | NAK-seq %u timeouts %u recoveries %u"
		   " | injected %u | QP error %d | %s\r\n", r->mism, r->gaps, r->ibad, r->roce, r->naks, r->tos, r->rtx,
		   r->inj, eng_err(), idle ? "NOT IDLE" : "drained");
	return !idle && !r->mism && !r->gaps && !r->werr && !r->lost && r->cpl == r->iss &&
	       r->landed == (u64)r->iss * len && !eng_err();
}

static const char *op_name(int op)
{
	return op == OP_SEND ? "SEND" : op == OP_SEND_IMM ? "SEND_IMM" : op == OP_WRITE_IMM ? "WRITE_IMM" : "WRITE";
}

int t_write(u32 len, int pmtu_log2, u32 n, int op)
{
	snap_t a, b;
	res_t r;
	char name[64];
	if (!ENG.selftest || !link_ok()) return -1;
	loop_setup(pmtu_log2);
	snap(&a);
	wg_start(0, 1, op, PAT_REGION, 64u << 20, len, RKEY_PAT, n, 0, 0x10000);
	int idle = wait_idle(3000);
	snap(&b);
	results(&a, &b, &r);
	fmt(name, "%s len %u x %u pmtu %u", op_name(op), len, n, 1u << pmtu_log2);
	xil_printf("%s:\r\n", name);
	int ok = check_stream(&r, len, idle);
	if (op != OP_WRITE) {
		u32 rc = DC(&a, &b, RSYS_E_RC), rcs = DC(&a, &b, RSYS_E_RC_SEND), seq = DC(&a, &b, RSYS_E_RC_IMM_SEQ);
		u32 last = sv(RSYS_S_RC_IMM_LAST);
		xil_printf("  receive completions %u (SEND %u), immediate sequence breaks %u, last immediate 0x%08x\r\n",
			   rc, rcs, seq, last);
		if (rc != n) ok = 0;
		if ((op == OP_SEND || op == OP_SEND_IMM) && rcs != n) ok = 0;
		if ((op == OP_WRITE_IMM || op == OP_SEND_IMM) && (seq || last != 0x10000u + n - 1)) ok = 0;
	}
	return verdict(name, ok);
}

int t_tput(u32 len, int pmtu_log2, u32 ms, int nqp)
{
	snap_t a, b;
	res_t r;
	char name[64];
	if (!ENG.selftest || !link_ok()) return -1;
	loop_setup(pmtu_log2);
	snap(&a);
	wg_start(0, nqp, OP_WRITE, PAT_REGION, 64u << 20, len, RKEY_PAT, 0, 0, 0x10000);
	usleep(2000);
	u64 c0 = bc(RSYS_B_CYCLES), w0 = bc(RSYS_B_WC_BYTES), t0 = bc(RSYS_B_TX_BYTES);
	u32 f0 = cnt(RSYS_E_TX_FRAMES);
	usleep(ms * 1000);
	u64 c1 = bc(RSYS_B_CYCLES), w1 = bc(RSYS_B_WC_BYTES), t1 = bc(RSYS_B_TX_BYTES);
	u32 f1 = cnt(RSYS_E_TX_FRAMES);
	wg_stop();
	int idle = wait_idle(3000);
	snap(&b);
	results(&a, &b, &r);
	fmt(name, "tput WRITE len %u pmtu %u qps %d", len, 1u << pmtu_log2, nqp);
	xil_printf("%s: payload ", name); pr_gbps(w1 - w0, c1 - c0);
	xil_printf(" Gb/s, line "); pr_gbps((t1 - t0) + (u64)(f1 - f0) * 24u, c1 - c0);
	xil_printf(" Gb/s incl. ACKs, FCS, preamble, IFG (%u frames)\r\n", f1 - f0);
	return verdict(name, check_stream(&r, len, idle));
}

/* drop / corrupt engine frames (TX, or RX with rx = 1); class mask [0] request [1] ACK [2] NAK [3] READ response */
int t_inject(int rx, int action, int cls, u32 skip, u32 count, u32 nwr, u32 len, int pmtu_log2)
{
	snap_t a, b;
	res_t r;
	char name[96];
	if (!ENG.selftest || !link_ok()) return -1;
	loop_setup(pmtu_log2);
	inj_set(rx, action, 0, cls, skip, count, 0, 0, 53);   /* byte 53 = BTH PSN low byte */
	snap(&a);
	wg_start(0, 1, OP_WRITE, PAT_REGION, 64u << 20, len, RKEY_PAT, nwr, 0, 0x10000);
	int idle = wait_idle(5000);
	snap(&b);
	inj_off();
	results(&a, &b, &r);
	fmt(name, "inject %s %s class 0x%x skip %u count %u (%u WRs of %u B)", rx ? "RX" : "TX",
	    action == 1 ? "drop" : "corrupt", cls, skip, count, nwr, len);
	xil_printf("%s:\r\n", name);
	int ok = check_stream(&r, len, idle);
	if (r.inj != count) ok = 0;
	if (action == 2 && ENG.rx_icrc && r.ibad != count) ok = 0;     /* every corrupted frame caught */
	if ((cls & 1) && r.rtx == 0) ok = 0;                          /* data hit: the requester recovered */
	return verdict(name, ok);
}

int t_soak(u32 secs, u32 len, int pmtu_log2, u32 ppm)
{
	snap_t a, b;
	res_t r;
	char name[64];
	if (!ENG.selftest || !link_ok()) return -1;
	loop_setup(pmtu_log2);
	if (ppm) inj_set(0, 1, 2, 0x3, 0, 0, 0, (u32)(((u64)ppm << 32) / 1000000ull), 53);
	snap(&a);
	wg_start(0, 1, OP_WRITE, PAT_REGION, 64u << 20, len, RKEY_PAT, 0, 0, 0x10000);
	u64 c0 = bc(RSYS_B_CYCLES), w0 = bc(RSYS_B_WC_BYTES);
	for (u32 s = 0; s < secs; s += 10) {
		for (int k = 0; k < 10 && s + (u32)k < secs; k++) usleep(1000000);
		u64 c1 = bc(RSYS_B_CYCLES), w1 = bc(RSYS_B_WC_BYTES);
		xil_printf("soak t=%us rate ", s + 10 > secs ? secs : s + 10); pr_gbps(w1 - w0, c1 - c0);
		xil_printf(" Gb/s | WRs %u mism %u ICRC bad %u recoveries %u | link %s\r\n", cnt(RSYS_E_WG_ISSUED),
			   cnt(RSYS_E_WC_MISM), eng_rd(ROCELET_CNT_RX_ICRC_BAD), eng_rd(ROCELET_CNT_REQ_RTX),
			   cmac_link_up() ? "up" : "DOWN");
		c0 = c1; w0 = w1;
	}
	wg_stop();
	int idle = wait_idle(5000);
	snap(&b);
	inj_off();
	results(&a, &b, &r);
	fmt(name, "soak %us len %u pmtu %u drops %u ppm", secs, len, 1u << pmtu_log2, ppm);
	xil_printf("%s:\r\n", name);
	return verdict(name, check_stream(&r, len, idle));
}

/* WR -> completion latency through the loopback, one WR at a time */
int t_lat(u32 n, u32 len, int pmtu_log2)
{
	const char *lbl[6] = { "WR->TX(data SOF)", "TX->RX data (CMAC+FEC+loop)", "RX data->TX ACK (responder)",
			       "TX->RX ACK", "RX ACK->completion", "total WR->completion" };
	u32 mn[6], mx[6], good = 0;
	u64 sm[6];
	char name[64];
	if (!ENG.selftest || !link_ok()) return -1;
	for (int i = 0; i < 6; i++) { mn[i] = 0xFFFFFFFFu; mx[i] = 0; sm[i] = 0; }
	loop_setup(pmtu_log2);
	for (u32 k = 0; k < n; k++) {
		cfg_set(RSYS_C_LP_ARM, 1);
		wg_start(0, 1, OP_WRITE, PAT_REGION, 1u << 20, len, RKEY_PAT, 1, 0, 0x10000);
		u32 f = 0;
		for (int t = 0; t < 1000; t++) {
			f = sv(RSYS_S_LP_FLAGS);
			if ((f & 0x200) && (f & 0x22) == 0x22) break;
			usleep(10);
		}
		u32 twr = sv(RSYS_S_LP_T_WR), tcpl = sv(RSYS_S_LP_T_CPL);
		u32 tx0 = sv(RSYS_S_LP_TX_T0), tx1 = sv(RSYS_S_LP_TX_T0 + 1);
		u32 rx0 = sv(RSYS_S_LP_RX_T0), rx1 = sv(RSYS_S_LP_RX_T0 + 1);
		if (!(f & 0x200) || (sv(RSYS_S_LP_TX_I0 + 1) & 0xFF) != 0x11) continue;
		u32 d[6] = { tx0 - twr, rx0 - tx0, tx1 - rx0, rx1 - tx1, tcpl - rx1, tcpl - twr };
		good++;
		for (int i = 0; i < 6; i++) {
			if (d[i] < mn[i]) mn[i] = d[i];
			if (d[i] > mx[i]) mx[i] = d[i];
			sm[i] += d[i];
		}
		usleep(50);
	}
	fmt(name, "lat len %u pmtu %u", len, 1u << pmtu_log2);
	xil_printf("%s: %u of %u samples (ns min / avg / max)\r\n", name, good, n);
	for (int i = 0; i < 6; i++) {
		xil_printf("  %s: ", lbl[i]);
		pr_ns(mn[i]); xil_printf(" / ");
		if (good) pr_ns(sm[i] / good);
		xil_printf(" / ");
		pr_ns(mx[i]); xil_printf("\r\n");
	}
	return verdict(name, good == n);
}

/* ------------------------------------------------------------------ */
/* firmware work requests through the memory window                    */
/* ------------------------------------------------------------------ */
static int wait_wc(u32 *rec, int ms)
{
	for (int t = 0; t < ms * 10; t++) {
		if (wcq_pop(rec)) return 1;
		usleep(100);
	}
	return 0;
}

static int wait_rc(u32 *rec, u32 *imm, u32 *len, int ms)
{
	for (int t = 0; t < ms * 10; t++) {
		if (rcq_pop(rec, imm, len)) return 1;
		usleep(100);
	}
	return 0;
}

int t_wrq(void)
{
	const u32 src = 0x10000, dst = 0x20000, n = 4096;
	u32 rec, imm, len;
	int bad = 0;
	if (!link_ok()) return -1;
	loop_setup(12);
	cq_enable(1, 1);
	/* payload at src = pattern(destination address): the self-test write checker
	 * sees good data, and a SEND carries consecutive embedded addresses */
	for (u32 o = 0; o < n; o += 4) mem_wr(dst + o, 0);
	u8 pb[64];
	for (u32 o = 0; o < n; o += 64) {
		pat_beat(dst + o, PAT_SEED, pb);
		for (int w = 0; w < 16; w++)
			mem_wr(src + o + 4u * (u32)w, (u32)pb[4 * w] | ((u32)pb[4 * w + 1] << 8) |
			       ((u32)pb[4 * w + 2] << 16) | ((u32)pb[4 * w + 3] << 24));
	}
	/* 1: RDMA WRITE QP0 -> QP1 (memory window, MR1) */
	if (wq_post(0, OP_WRITE, dst, RKEY_MEM, n, 0, src, 0x77) || !wait_wc(&rec, 100)) {
		xil_printf("  WRITE: no work completion\r\n");
		bad++;
	} else {
		int mm = 0;
		for (u32 o = 0; o < n; o += 4) if (mem_rd(dst + o) != mem_rd(src + o)) mm++;
		xil_printf("  WRITE 4096 B: completion id 0x%x qp %d status %d, %d words differ\r\n", rec & 0xFFFF,
			   (rec >> 16) & 0xFF, (rec >> 24) & 0x7F, mm);
		if ((rec & 0xFFFF) != 0x77 || ((rec >> 16) & 0xFF) != 0 || ((rec >> 24) & 0x7F) || mm) bad++;
	}
	/* 2: WRITE with immediate: a receive completion on QP1 */
	if (wq_post(0, OP_WRITE_IMM, dst, RKEY_MEM, 1024, 0xABCD0001u, src, 0x78) || !wait_wc(&rec, 100) ||
	    !wait_rc(&rec, &imm, &len, 100)) {
		xil_printf("  WRITE_IMM: completion missing\r\n");
		bad++;
	} else {
		xil_printf("  WRITE_IMM 1024 B: receive completion qp %d SEND %d imm 0x%08x len %u\r\n", (rec >> 16) & 0xFF,
			   (rec >> 30) & 1, imm, len);
		if (((rec >> 16) & 0xFF) != 1 || ((rec >> 30) & 1) || imm != 0xABCD0001u || len != 1024) bad++;
	}
	/* 3: SEND: a receive completion on QP1 */
	if (wq_post(0, OP_SEND, 0, 0, 512, 0, src, 0x79) || !wait_wc(&rec, 100) || !wait_rc(&rec, &imm, &len, 100)) {
		xil_printf("  SEND: completion missing\r\n");
		bad++;
	} else {
		xil_printf("  SEND 512 B: receive completion qp %d SEND %d len %u\r\n", (rec >> 16) & 0xFF, (rec >> 30) & 1,
			   len);
		if (((rec >> 16) & 0xFF) != 1 || !((rec >> 30) & 1) || len != 512) bad++;
	}
	if (cnt(RSYS_E_WC_MISM) || cnt(RSYS_E_SC_MISM) || eng_err()) bad++;
	cq_enable(0, 0);
	return verdict("firmware WRs through the memory window (WRITE, WRITE_IMM, SEND)", bad == 0);
}

/* ------------------------------------------------------------------ */
/* the firmware's "host" QP: READ requests, single WRITEs, ARP / ICMP  */
/* ------------------------------------------------------------------ */
/* captured frame without its 802.1Q tag (the engine tags its frames with 'vlan tx 1'): the
 * checks below use untagged offsets */
static int cap_get(u8 *buf, int max)
{
	int n = cap_read(buf, max);
	if (n > 18 && buf[12] == 0x81 && buf[13] == 0x00) {
		memmove(buf + 12, buf + 16, (size_t)(n - 16));
		n -= 4;
	}
	return n;
}

static int check_frame(const u8 *f, int len, u8 op, u32 psn, int hdr, u64 laddr, int paylen, const char *what)
{
	int bad = 0;
	u32 ic = icrc_calc(f, len - 4);
	u32 got = f[len - 4] | ((u32)f[len - 3] << 8) | ((u32)f[len - 2] << 16) | ((u32)f[len - 1] << 24);
	if (ic != got) { xil_printf("  %s: ICRC 0x%08x, software 0x%08x\r\n", what, got, ic); bad++; }
	if (f[42] != op) { xil_printf("  %s: opcode 0x%02x, expected 0x%02x\r\n", what, f[42], op); bad++; }
	if (be24(f + 47) != HOST_QPN) { xil_printf("  %s: dest QPN 0x%06x\r\n", what, be24(f + 47)); bad++; }
	if (be24(f + 51) != psn) { xil_printf("  %s: PSN 0x%06x, expected 0x%06x\r\n", what, be24(f + 51), psn); bad++; }
	if (paylen) {
		u8 pb[64];
		int mm = 0;
		for (int i = 0; i < paylen; i++) {
			if ((i & 63) == 0) pat_beat(laddr + (u64)i, PAT_SEED, pb);
			if (f[hdr + i] != pb[i & 63]) mm++;
		}
		if (mm) { xil_printf("  %s: %d payload bytes differ from the memory\r\n", what, mm); bad++; }
	}
	return bad;
}

int t_read(u32 len, int pmtu_log2)
{
	u8 e[16];
	snap_t a, b;
	char name[64];
	int bad = 0;
	const u32 va = 0x8000;
	if (!link_ok()) return -1;
	loop_setup(pmtu_log2);
	mem_fill_pat(va, 2 * len, PAT_SEED);
	u32 pm = 1u << pmtu_log2, npk = (len + pm - 1) / pm, psn = HOST_PSN0;
	fmt(name, "READ len %u pmtu %u (%u responses)", len, pm, npk);

	/* 1: READ, capture the first response */
	snap(&a);
	reth(e, va, RKEY_MEM, len);
	int fl = host_frame(fbuf, 0x0C, psn, 0, e, 16, NULL, 0);
	cap_arm(3, npk == 1 ? 0x10 : 0x0D, HOST_QPN, 0);
	raw_send(fbuf, fl);
	if (!cap_wait(100)) { xil_printf("  no READ response captured\r\n"); bad++; }
	else {
		int cl = cap_get(cbuf, sizeof(cbuf));
		u32 aeth = ((u32)cbuf[54] << 24) | be24(cbuf + 55);
		xil_printf("  first response: %d B, opcode 0x%02x, PSN 0x%06x, AETH 0x%08x\r\n", cl, cbuf[42], be24(cbuf + 51), aeth);
		bad += check_frame(cbuf, cl, npk == 1 ? 0x10 : 0x0D, psn, 58, va, npk == 1 ? (int)len : (int)pm, "first response");
		if ((aeth >> 24) != 0x1F) { xil_printf("  AETH syndrome 0x%02x\r\n", aeth >> 24); bad++; }
	}
	usleep(1000);
	snap(&b);
	u32 txr = DC(&a, &b, RSYS_E_TX_OP_RDRSP), rxr = DC(&a, &b, RSYS_E_RX_OP_RDRSP);
	u32 rdb = (u32)DB(&a, &b, RSYS_B_RD_BYTES);
	xil_printf("  READ responses: TX %u RX %u (expected %u), memory read %u B\r\n", txr, rxr, npk, rdb);
	if (txr != npk || rxr != npk || rdb != len) bad++;
	psn = (psn + npk) & 0xFFFFFF;

	/* 2: a second READ, capture its last response (multi-packet only) */
	if (npk > 1) {
		reth(e, va + len, RKEY_MEM, len);
		fl = host_frame(fbuf, 0x0C, psn, 0, e, 16, NULL, 0);
		cap_arm(3, 0x0F, HOST_QPN, 0);
		raw_send(fbuf, fl);
		if (!cap_wait(100)) { xil_printf("  no READ LAST captured\r\n"); bad++; }
		else {
			int cl = cap_get(cbuf, sizeof(cbuf));
			u32 lastlen = len - (npk - 1) * pm;
			xil_printf("  last response: %d B, opcode 0x%02x, PSN 0x%06x\r\n", cl, cbuf[42], be24(cbuf + 51));
			bad += check_frame(cbuf, cl, 0x0F, (psn + npk - 1) & 0xFFFFFF, 58, va + len + (npk - 1) * pm,
					   (int)lastlen, "last response");
		}
		psn = (psn + npk) & 0xFFFFFF;
	}

	/* 3: duplicate of READ 1 (its PSN is behind the responder's expected PSN): re-executed */
	reth(e, va, RKEY_MEM, len);
	fl = host_frame(fbuf, 0x0C, HOST_PSN0, 0, e, 16, NULL, 0);
	cap_arm(3, npk == 1 ? 0x10 : 0x0D, HOST_QPN, 0);
	raw_send(fbuf, fl);
	if (!cap_wait(100)) { xil_printf("  duplicate READ: no response\r\n"); bad++; }
	else {
		int cl = cap_get(cbuf, sizeof(cbuf));
		xil_printf("  duplicate READ re-executed: opcode 0x%02x PSN 0x%06x\r\n", cbuf[42], be24(cbuf + 51));
		bad += check_frame(cbuf, cl, npk == 1 ? 0x10 : 0x0D, HOST_PSN0, 58, va, npk == 1 ? (int)len : (int)pm,
				   "duplicate");
	}
	if (eng_err()) bad++;
	return verdict(name, bad == 0);
}

/* raw WRITE Only from the host QP: good ICRC (ACKed), bad ICRC (counted, dropped), good again */
int t_icrc(void)
{
	u8 e[16], pay[1024];
	int bad = 0;
	const u32 va = 0x30000;
	if (!link_ok()) return -1;
	loop_setup(12);
	for (int i = 0; i < 1024; i += 64) pat_beat(va + (u32)i, PAT_SEED, pay + i);
	for (u32 o = 0; o < 1024; o += 4) mem_wr(va + o, 0);
	reth(e, va, RKEY_MEM, 1024);
	u32 b0 = eng_rd(ROCELET_CNT_RX_ICRC_BAD);

	int fl = host_frame(fbuf, 0x0A, HOST_PSN0, 1, e, 16, pay, 1024);
	cap_arm(3, 0x11, HOST_QPN, 0);
	raw_send(fbuf, fl);
	int ack = cap_wait(50);
	if (ack) cap_get(cbuf, sizeof(cbuf));
	int mm = 0;
	for (u32 o = 0; o < 1024; o += 4)
		if (mem_rd(va + o) != ((u32)pay[o] | ((u32)pay[o + 1] << 8) | ((u32)pay[o + 2] << 16) | ((u32)pay[o + 3] << 24))) mm++;
	xil_printf("  good ICRC: ACK %s (syndrome 0x%02x PSN 0x%06x), %d words differ in memory\r\n",
		   ack ? "received" : "MISSING", ack ? cbuf[54] : 0, ack ? be24(cbuf + 51) : 0, mm);
	if (!ack || cbuf[54] != 0x1F || be24(cbuf + 51) != HOST_PSN0 || mm) bad++;

	fl = host_frame(fbuf, 0x0A, HOST_PSN0 + 1, 1, e, 16, pay, 1024);
	fbuf[fl - 1] ^= 0x01;
	cap_arm(3, 0x11, HOST_QPN, 0);
	raw_send(fbuf, fl);
	usleep(1000);
	u32 b1 = eng_rd(ROCELET_CNT_RX_ICRC_BAD);
	xil_printf("  bad ICRC: ICRC errors %u, ACK %s\r\n", b1 - b0, cap_done() ? "SENT (wrong)" : "none");
	if (b1 - b0 != 1 || cap_done()) bad++;

	fl = host_frame(fbuf, 0x0A, HOST_PSN0 + 1, 1, e, 16, pay, 1024);
	cap_arm(3, 0x11, HOST_QPN, 0);
	raw_send(fbuf, fl);
	ack = cap_wait(50);
	if (ack) cap_get(cbuf, sizeof(cbuf));
	xil_printf("  retry with a good ICRC: ACK PSN 0x%06x\r\n", ack ? be24(cbuf + 51) : 0);
	if (!ack || be24(cbuf + 51) != HOST_PSN0 + 1) bad++;
	if (eng_err()) bad++;
	return verdict("ICRC (host frames: good accepted, bad counted and dropped)", bad == 0);
}

/* insert an 802.1Q tag after the MACs (the ICRC covers the IP header onwards: unchanged) */
static int add_tag(u8 *f, int n, u32 tci)
{
	memmove(f + 16, f + 12, (size_t)(n - 12));
	f[12] = 0x81; f[13] = 0x00; f[14] = (u8)(tci >> 8); f[15] = (u8)tci;
	return n + 4;
}

/* host frames some NICs send and others do not: a CNP
 * (counted and dropped, never answered) and WRITEs with an 802.1Q tag: VID 0 (priority tag,
 * stripped, committed, ACKed) and VID 5 (not ours, dropped) */
int t_cnp_vlan(void)
{
	u8 e[16], pay[256], rsv[16];
	int bad = 0;
	const u32 va = 0x31000;
	if (!link_ok()) return -1;
	loop_setup(12);
	u32 ctrl0 = eng_rd(ROCELET_CTRL);     /* restored at the end */
	eng_ctrl_set(ROCELET_CTRL_VLAN_RX_STRIP_MASK, ROCELET_CTRL_VLAN_TX_TAG_MASK);
	for (int i = 0; i < 256; i += 64) pat_beat(va + (u32)i, PAT_SEED, pay + i);
	for (u32 o = 0; o < 512; o += 4) mem_wr(va + o, 0);
	memset(rsv, 0, sizeof(rsv));

	u32 c0 = eng_rd(ROCELET_CNT_RX_CNP), a0 = eng_rd(ROCELET_CNT_TX_ACK), n0 = eng_rd(ROCELET_CNT_TX_NAK);
	int fl = host_frame(fbuf, 0x81, 0, 0, NULL, 0, rsv, 16);
	raw_send(fbuf, fl);
	usleep(1000);
	u32 c1 = eng_rd(ROCELET_CNT_RX_CNP), a1 = eng_rd(ROCELET_CNT_TX_ACK), n1 = eng_rd(ROCELET_CNT_TX_NAK);
	xil_printf("  CNP: counted %u, answered %u\r\n", c1 - c0, (a1 - a0) + (n1 - n0));
	if (c1 - c0 != 1 || a1 != a0 || n1 != n0) bad++;

	u32 s0 = eng_rd(ROCELET_CNT_RX_VLAN_STRIP), o0 = eng_rd(ROCELET_CNT_RX_VLAN_OTHER);
	reth(e, va, RKEY_MEM, 256);
	fl = add_tag(fbuf, host_frame(fbuf, 0x0A, HOST_PSN0, 1, e, 16, pay, 256), 0xA000);   /* PCP 5, VID 0 */
	cap_arm(3, 0x11, HOST_QPN, 0);
	raw_send(fbuf, fl);
	int ack = cap_wait(50);
	if (ack) cap_get(cbuf, sizeof(cbuf));
	int mm = 0;
	for (u32 o = 0; o < 256; o += 4)
		if (mem_rd(va + o) != ((u32)pay[o] | ((u32)pay[o + 1] << 8) | ((u32)pay[o + 2] << 16) | ((u32)pay[o + 3] << 24))) mm++;
	u32 s1 = eng_rd(ROCELET_CNT_RX_VLAN_STRIP);
	xil_printf("  WRITE with a VID-0 tag: stripped %u, ACK %s (PSN 0x%06x), %d words differ in memory\r\n", s1 - s0,
		   ack ? "received" : "MISSING", ack ? be24(cbuf + 51) : 0, mm);
	if (s1 - s0 != 1 || !ack || cbuf[54] != 0x1F || be24(cbuf + 51) != HOST_PSN0 || mm) bad++;

	reth(e, va + 256, RKEY_MEM, 256);
	fl = add_tag(fbuf, host_frame(fbuf, 0x0A, HOST_PSN0 + 1, 1, e, 16, pay, 256), 0xA005);   /* VID 5 */
	cap_arm(3, 0x11, HOST_QPN, 0);
	raw_send(fbuf, fl);
	usleep(1000);
	u32 o1 = eng_rd(ROCELET_CNT_RX_VLAN_OTHER);
	int land = 0;
	for (u32 o = 256; o < 512; o += 4) if (mem_rd(va + o)) land++;
	xil_printf("  WRITE with VID 5: dropped as other VLAN %u, ACK %s, %d words landed\r\n", o1 - o0,
		   cap_done() ? "SENT (wrong)" : "none", land);
	if (o1 - o0 != 1 || cap_done() || land) bad++;
	if (eng_err()) bad++;
	eng_wr(ROCELET_CTRL, ctrl0);
	return verdict("CNP and 802.1Q tags in host frames (CNP dropped, VID 0 accepted, VID 5 dropped)", bad == 0);
}

/* WRITE with a read-only R_Key: NAK remote access error, both QPs to error */
int t_access(void)
{
	snap_t a, b;
	if (!ENG.selftest || !link_ok()) return -1;
	loop_setup(12);
	snap(&a);
	wg_start(0, 1, OP_WRITE, 0x1000, 0x10000, 4096, RKEY_MEM_RO, 1, 0, 0x10000);
	usleep(20000);
	snap(&b);
	u32 q = eng_rd(ROCELET_LAST_REQ_ERR), r = eng_rd(ROCELET_LAST_RESP_ERR);
	u32 nak = DC(&a, &b, RSYS_E_TX_OP_NAK), werr = DC(&a, &b, RSYS_E_WC_ERR);
	u32 landed = (u32)DB(&a, &b, RSYS_B_WC_BYTES);
	xil_printf("access (WRITE with a read-only R_Key): NAK frames %u, completions with error %u, responder error"
		   " qp %d code 0x%02x, requester error qp %d code 0x%02x, landed %u B\r\n", nak, werr,
		   (r >> 8) & 0xFF, r & 0xFF, (q >> 8) & 0xFF, q & 0xFF, landed);
	int ok = nak == 1 && werr == 1 && (r >> 31) && (r & 0xFF) == 0x62 && ((r >> 8) & 0xFF) == 1 &&
		 (q >> 31) && (q & 0xFF) == 0x62 && ((q >> 8) & 0xFF) == 0 && landed == 0;
	loop_setup(12);              /* recommit the QPs, clear the error latch */
	return verdict("access error (NAK remote access, QP error)", ok);
}

/* ARP request for my IP -> reply; ICMP echo -> reply (sent as raw frames, looped back) */
int t_arp(void)
{
	u8 *f = fbuf;
	int bad = 0;
	if (!link_ok()) return -1;
	loop_setup(12);
	memset(f, 0, 64);
	memset(f, 0xFF, 6);
	memcpy(f + 6, HOST_MAC, 6);
	f[12] = 0x08; f[13] = 0x06;
	f[14] = 0; f[15] = 1; f[16] = 0x08; f[17] = 0; f[18] = 6; f[19] = 4; f[20] = 0; f[21] = 1;
	memcpy(f + 22, HOST_MAC, 6);
	f[28] = (u8)(HOST_IP >> 24); f[29] = (u8)(HOST_IP >> 16); f[30] = (u8)(HOST_IP >> 8); f[31] = (u8)HOST_IP;
	f[38] = (u8)(MY_IP >> 24); f[39] = (u8)(MY_IP >> 16); f[40] = (u8)(MY_IP >> 8); f[41] = (u8)MY_IP;
	for (int i = 42; i < 60; i++) f[i] = 0xA5;     /* request padding; the reply pads with zeros */
	u32 r0 = eng_rd(ROCELET_CNT_TX_ARP_ICMP);
	cap_arm(2, 0, 0, 0);                           /* bytes 47..49 == 0: the reply, not our request */
	raw_send(f, 60);
	int got = cap_wait(50);
	cap_get(cbuf, sizeof(cbuf));
	u32 r1 = eng_rd(ROCELET_CNT_TX_ARP_ICMP);
	int arp_ok = got && cbuf[12] == 0x08 && cbuf[13] == 0x06 && cbuf[21] == 2 && !memcmp(cbuf, HOST_MAC, 6) &&
		     !memcmp(cbuf + 6, MY_MAC, 6) && !memcmp(cbuf + 22, MY_MAC, 6) && !memcmp(cbuf + 28, f + 38, 4) &&
		     !memcmp(cbuf + 32, HOST_MAC, 6) && !memcmp(cbuf + 38, f + 28, 4);
	xil_printf("  ARP: replies sent %u, reply %s\r\n", r1 - r0, arp_ok ? "ok" : (got ? "WRONG" : "MISSING"));
	if (r1 - r0 != 1 || !arp_ok) bad++;
	/* ICMP echo request, 64 B payload */
	memset(f, 0, 200);
	memcpy(f, MY_MAC, 6); memcpy(f + 6, HOST_MAC, 6); f[12] = 0x08; f[13] = 0x00;
	f[14] = 0x45; f[16] = 0; f[17] = 28 + 64; f[20] = 0x40; f[22] = 64; f[23] = 1;
	f[26] = (u8)(HOST_IP >> 24); f[27] = (u8)(HOST_IP >> 16); f[28] = (u8)(HOST_IP >> 8); f[29] = (u8)HOST_IP;
	f[30] = (u8)(MY_IP >> 24); f[31] = (u8)(MY_IP >> 16); f[32] = (u8)(MY_IP >> 8); f[33] = (u8)MY_IP;
	u32 s = 0;
	for (int i = 14; i < 34; i += 2) s += ((u32)f[i] << 8) | f[i + 1];
	while (s >> 16) s = (s & 0xFFFF) + (s >> 16);
	f[24] = (u8)(~s >> 8); f[25] = (u8)~s;
	f[34] = 8; f[38] = 0x12; f[39] = 0x34; f[41] = 1;
	for (int i = 0; i < 64; i++) f[42 + i] = (u8)i;
	s = 0;
	for (int i = 34; i < 106; i += 2) s += ((u32)f[i] << 8) | f[i + 1];
	while (s >> 16) s = (s & 0xFFFF) + (s >> 16);
	f[36] = (u8)(~s >> 8); f[37] = (u8)~s;
	raw_send(f, 106);
	usleep(1000);
	u32 r2 = eng_rd(ROCELET_CNT_TX_ARP_ICMP);
	xil_printf("  ICMP: echo replies sent %u\r\n", r2 - r1);
	if (r2 - r1 != 1) bad++;
	return verdict("ARP / ICMP responder", bad == 0);
}

/* does the link return the FPGA's own frames (plug or GT loopback)? A raw SEND Only to a QPN the
 * engine does not have is sent and looked for at the CMAC RX; a NIC (or any other partner) never
 * sends it back. The engine drops it (rx_qp_drop) if it does come back. */
static int loop_present(void)
{
	u8 pay[64];
	for (int i = 0; i < 64; i++) pay[i] = (u8)(0xA0 + i);
	for (int k = 0; k < 3; k++) {
		int fl = build_roce(fbuf, MY_MAC, HOST_MAC, HOST_IP, MY_IP, 0xC0DE, 0x04, 0xFFFFFEu, (u32)k, 0, NULL, 0, pay, 64);
		cap_arm(3, 0x04, 0xFFFFFEu, 0);
		raw_send(fbuf, fl);
		if (cap_wait(20)) return 1;
	}
	return 0;
}

/* ------------------------------------------------------------------ */
/* the suite                                                           */
/* ------------------------------------------------------------------ */
int selftest(int quick)
{
	g_pass = g_fail = 0;
	xil_printf("=== self-test: rocelet %d.%d.%d, %d QPs, %s, READ depth %d, self-test logic %s, RS-FEC %s,"
		   " loopback %s\r\n", (ENG.version >> 16) & 0xFF, (ENG.version >> 8) & 0xFF, ENG.version & 0xFF,
		   ENG.num_qp, rtx_name(ENG.rtx_mode), ENG.read_depth, ENG.selftest ? "built in" : "not built",
		   cmac_fec() ? "on" : "off", loop_name(cmac_loop()));
	verdict("link up", cmac_link_up());
	int looped = cmac_link_up() && loop_present();
	if (cmac_link_up()) {
		verdict("loopback path (the FPGA's frames come back)", looped);
		if (!looped)
			xil_printf("  the link partner does not return the FPGA's frames (a NIC?): the suite needs a QSFP28 loopback"
				   " plug or the GT near-end loopback ('loop pma'); remaining tests skipped\r\n");
	}
	if (looped) {
		t_arp();
		t_wrq();
		t_read(4096, 12);
		t_read(65536, 12);
		t_icrc();
		t_cnp_vlan();
		if (ENG.selftest) {
			t_write(4096, 12, 2000, OP_WRITE);
			t_write(65536, 10, 200, OP_WRITE);
			t_write(8192, 12, 500, OP_SEND);
			t_write(2048, 10, 500, OP_SEND_IMM);
			t_write(4096, 12, 500, OP_WRITE_IMM);
			if (ENG.rtx_mode != 2) {
				t_inject(0, 1, 0x1, 50, 1, 2000, 4096, 12);      /* drop one data frame */
				t_inject(0, 2, 0x1, 70, 3, 2000, 4096, 12);      /* corrupt three data frames (ICRC) */
				t_inject(0, 1, 0x2, 30, 5, 2000, 4096, 12);      /* drop five ACKs */
				t_inject(0, 1, 0x1, 1999, 1, 2000, 4096, 12);    /* drop the very last data frame (timeout) */
				t_inject(1, 1, 0x1, 40, 1, 2000, 4096, 12);      /* RX side: drop one received data frame */
			}
			t_access();
			if (!quick) {
				t_read(65536, 10);
				t_tput(4096, 12, 1000, 1);
				t_tput(65536, 12, 1000, 4);
				t_lat(200, 1024, 10);
			}
		}
	}
	loop_setup(12);
	xil_printf("SELFTEST %s %d/%d loop=%s fec=%d selftest_logic=%d\r\n", g_fail == 0 ? "PASS" : "FAIL", g_pass,
		   g_pass + g_fail, cmac_loop() == LOOP_PMA ? "pma" : cmac_loop() == LOOP_PCS ? "pcs" : "external",
		   cmac_fec(), ENG.selftest);
	return g_fail == 0 ? 0 : -1;
}
