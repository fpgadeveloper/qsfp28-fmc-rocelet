/*
 * test_hsb.c - host-side test of the console's HSB device mode (Vitis/common/src/hsb.c) with
 * the hardware mocked (register window, receive FIFO, raw TX, engine QP calls): BOOTP layout
 * and timing, the register protocol (read / write / block, sequence check, status codes,
 * replies), the register file, the DP_* -> QP / producer translation (configure_roce as an
 * HSB 3.0.0 host issues it), the producer watchdog (keepalive timeout, link pause / resume with a
 * mocked engine STATUS / CNT_LINK_DOWN), the 'qp 13' label, reset and set-ip, the beam array
 * generator's Opsero window (0x7F000100.. -> system 0x0200.., status 0x7F000300.. -> 0x04E4..,
 * SOURCE 2). Run: ./run.sh.
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "hw.h"
#include "eng.h"
#include "sysif.h"
#include "selftest.h"
#include "util.h"
#include "hsb.h"
#include "hsb_regs.h"

eng_cfg_t ENG;
u8 MY_MAC[6] = { 0x02, 0x0a, 0x35, 0x72, 0x6c, 0x01 };
u32 MY_IP = 0xC0A81402u;
u8 cbuf[8200];
static u32 cfgv[256], tick, engctrl, ip4, engstatus = ROCELET_STATUS_LINK_UP_MASK, linkdown;
static int nqp;
static u8 rxq[8][2048]; static int rxl[8], rxn;
static u8 txf[2048]; static int txl, txcount;
static struct { int qp, type, pm; u32 sq, rq, dqpn, dip, sp, dp; u8 mac[6]; } lastqp;
static int fails;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL %s:%d ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); fails++; } } while (0)

u32 Xil_In32(u32 a)
{
	if (a == 0x41C00008u) return tick;
	if (a >= SYS_BASE && a < SYS_BASE + 0x10000) {
		u32 o = a - SYS_BASE;
		if (o >= 0x8000 && o < 0x8800) { u32 w = (o - 0x8000) / 4, v = 0; for (int b = 0; b < 4; b++) v |= (u32)rxq[0][4 * w + b] << (8 * b); return v; }
		if (o < 0x400) return cfgv[o / 4];
		if (o == RSYS_SV(RSYS_S_CRX_STATUS)) return rxn ? ((u32)rxl[0] << 16) | (u32)rxn : 0;
		if (o == RSYS_SV(RSYS_S_HP_STATUS)) return 8;
		if (o == RSYS_SV(RSYS_S_DNA0)) return 0x0F1E2D3Cu;
		if (o == RSYS_SV(RSYS_S_DNA1)) return 0x89ABCDEFu;
		if (o == RSYS_SV(RSYS_S_DNA2)) return 0x01234567u;
		if (o == RSYS_SV(RSYS_S_BM_CAPS)) return 0x01440808u;
		if (o == RSYS_SV(RSYS_S_BM_APPLIED_ID)) return 0xA5A50001u;
		return 0;
	}
	if (a == ENG_BASE + ROCELET_CTRL) return engctrl;
	if (a == ENG_BASE + ROCELET_STATUS) return engstatus;
	if (a == ENG_BASE + ROCELET_CNT_LINK_DOWN) return linkdown;
	return 0;
}
void Xil_Out32(u32 a, u32 v)
{
	if (a >= SYS_BASE && a < SYS_BASE + 0x400) {
		u32 i = (a - SYS_BASE) / 4;
		cfgv[i] = v;
		if (i == RSYS_C_CRX_POP && rxn) { memmove(rxq[0], rxq[1], sizeof(rxq[0]) * 7); memmove(rxl, rxl + 1, sizeof(int) * 7); rxn--; }
	}
	if (a == ENG_BASE + ROCELET_IP4) ip4 = v;
}
u32 eng_ctrl_set(u32 s, u32 c) { engctrl = (engctrl & ~c) | s; return engctrl; }
void eng_qp(int qp, int type, u32 sq, u32 rq, int pm, u32 dqpn, const u8 *m, u32 dip, u32 sp, u32 dp)
{ nqp++; lastqp.qp = qp; lastqp.type = type; lastqp.sq = sq; lastqp.rq = rq; lastqp.pm = pm; lastqp.dqpn = dqpn; memcpy(lastqp.mac, m, 6); lastqp.dip = dip; lastqp.sp = sp; lastqp.dp = dp; }
u32 eng_qp_status(int qp) { (void)qp; return 1; }
void raw_send(const u8 *f, int len) { memcpy(txf, f, (size_t)len); txl = len; txcount++; }
int log2u(u32 v) { int n = 0; while (v > 1) { v >>= 1; n++; } return n; }
void pr_ip(u32 ip) { printf("%u.%u.%u.%u", ip >> 24, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255); }
void pr_mac(const u8 *m) { for (int i = 0; i < 6; i++) printf("%02x", m[i]); }
void pr_u64(u64 v) { printf("%llu", (unsigned long long)v); }
void pr_hex64(u64 v) { printf("0x%llx", (unsigned long long)v); }
u32 arg_u(char **argv, int argc, int i, u32 d) { return i < argc ? (u32)strtoul(argv[i], 0, 0) : d; }
u64 bc(int i) { (void)i; return 0; }

static u32 be32(const u8 *p) { return ((u32)p[0] << 24) | ((u32)p[1] << 16) | ((u32)p[2] << 8) | p[3]; }
static u16 seq = 0x1234;

/* queue a UDP request to dport with payload p[n]; poll; return reply UDP payload length (0 none) */
static int xact(u32 dport, const u8 *p, int n, u32 dip)
{
	u8 *f = rxq[rxn];
	memset(f, 0, 2048);
	f[0] = 0x02; f[1] = 0x0a; f[2] = 0x35; f[3] = 0x72; f[4] = 0x6c; f[5] = 0x01;
	f[6] = 0x10; f[7] = 0x70; f[8] = 0xfd; f[9] = 0x01; f[10] = 0x02; f[11] = 0x03;
	f[12] = 8; f[13] = 0; f[14] = 0x45; f[23] = 17;
	f[26] = 192; f[27] = 168; f[28] = 20; f[29] = 1;
	f[30] = (u8)(dip >> 24); f[31] = (u8)(dip >> 16); f[32] = (u8)(dip >> 8); f[33] = (u8)dip;
	f[34] = 0xAB; f[35] = 0xCD; f[36] = (u8)(dport >> 8); f[37] = (u8)dport;
	f[38] = (u8)((n + 8) >> 8); f[39] = (u8)(n + 8);
	memcpy(f + 42, p, (size_t)n);
	rxl[rxn] = 42 + n < 60 ? 60 : 42 + n; rxn++;
	int c0 = txcount;
	hsb_poll();
	if (txcount == c0 || dport != 8192) return 0;
	CHECK(txf[36] == 0xAB && txf[37] == 0xCD && txf[34] == 0x20 && txf[35] == 0x00, "reply ports");
	CHECK(!memcmp(txf, "\x10\x70\xfd\x01\x02\x03", 6), "reply dst mac");
	return ((txf[38] << 8) | txf[39]) - 8;
}
static int req(u8 cmd, u8 fl, u16 s, const u32 *pairs, int np, int vals)
{
	u8 b[1500]; int n = 6;
	b[0] = cmd; b[1] = fl; b[2] = (u8)(s >> 8); b[3] = (u8)s; b[4] = 0; b[5] = 0;
	for (int i = 0; i < np; i++) {
		u32 a = pairs[2 * i], v = vals ? pairs[2 * i + 1] : 0;
		b[n] = (u8)(a >> 24); b[n + 1] = (u8)(a >> 16); b[n + 2] = (u8)(a >> 8); b[n + 3] = (u8)a; n += 4;
		if (cmd != 0x14) { b[n] = (u8)(v >> 24); b[n + 1] = (u8)(v >> 16); b[n + 2] = (u8)(v >> 8); b[n + 3] = (u8)v; n += 4; }
	}
	return xact(8192, b, n, MY_IP);
}
#define R (txf + 42)
static u32 rd(u32 a, int chk) { u32 p[2] = { a, 0 }; seq++; int l = req(0x14, chk ? 3 : 1, seq, p, 1, 0); CHECK(l == 18, "rd len %d", l); CHECK(R[4] == 0, "rd 0x%x status 0x%x", a, R[4]); return be32(R + 10); }
static int wr(u32 a, u32 v) { u32 p[2] = { a, v }; seq++; req(0x04, 3, seq, p, 1, 1); return R[4]; }
/* let ms milliseconds pass in 50-ms polls */
static void adv(u32 ms) { for (u32 t = 0; t < ms; t += 50) { tick += 50 * 100000u; hsb_poll(); } }
static int prun(void) { return (int)(cfgv[RSYS_C_HP_CTRL] & 1); }

int main(void)
{
	ENG.num_qp = 16; ENG.hsb = 1; ENG.pmtu_log2 = 12;
	char *on[] = { "hsb", "on" };
	hsb_cmd(on, 2);
	tick = 5; hsb_poll();
	CHECK(txcount == 1 && txl == 342, "BOOTP sent, len %d", txl);
	u8 *b = txf + 42, *v = b + 236;
	CHECK(!memcmp(txf, "\xff\xff\xff\xff\xff\xff", 6) && txf[34] == 0x2F && txf[35] == 0xEC && txf[36] == 0x2F && txf[37] == 0xEB, "BOOTP eth/ports");
	CHECK(be32(txf + 30) == 0xFFFFFFFFu && be32(txf + 26) == MY_IP, "BOOTP IPs");
	CHECK(b[0] == 1 && b[1] == 1 && b[2] == 6 && be32(b + 12) == MY_IP && !memcmp(b + 28, MY_MAC, 6), "BOOTP header");
	CHECK(v[0] == 0xE0 && !memcmp(v + 2, "NVDA", 4) && v[6] == 0 && v[7] == 2 && v[8] == 0x03 && v[9] == 0x26, "vendor");
	CHECK(!memcmp(v + 10, "\x98\x18\x3d\x0f\x18\xee\x47\x19\xa3\xb4\xca\x69\xe9\xb9\x4c\x97", 16), "uuid");
	CHECK(v[37] == 0x03 && v[38] == 0x26 && v[57] == 2, "ip version / status");
	printf("serial %02x%02x%02x%02x%02x%02x%02x\n", v[30], v[31], v[32], v[33], v[34], v[35], v[36]);
	/* IPv4 header checksum */
	{ u32 s = 0; for (int i = 14; i < 34; i += 2) s += ((u32)txf[i] << 8) | txf[i + 1]; while (s >> 16) s = (s & 0xFFFF) + (s >> 16); CHECK(s == 0xFFFF, "ip csum"); }
	/* second BOOTP only after a second */
	tick = 50000000; hsb_poll(); CHECK(txcount == 1, "no BOOTP before 1 s");
	tick = 100000010; hsb_poll(); CHECK(txcount == 2, "BOOTP after 1 s");
	CHECK(((txf[42 + 236 + 55] << 8) | txf[42 + 236 + 56]) == 1, "bootp seq");

	/* register protocol */
	CHECK(rd(0x80, 0) == 0x2603, "version");
	CHECK(R[0] == 0x94 && R[1] == 1 && ((R[2] << 8) | R[3]) == seq && be32(R + 6) == 0x80, "reply header");
	CHECK(((R[14] << 8) | R[15]) == seq && R[16] == 0 && R[17] == 0, "latched trailer");
	printf("date 0x%08x\n", rd(0x84, 1));
	CHECK(wr(0x1000, 0x12345678) == 0, "write vp");
	CHECK(rd(0x1000, 1) == 0x12345678, "readback");
	/* sequence check failure */
	{ u32 p[2] = { 0x1004, 0xdead }; int l = req(0x04, 3, (u16)(seq + 5), p, 1, 1); CHECK(l > 0 && R[4] == 0x0B, "seq fail status 0x%x", R[4]);
	  CHECK(((R[l - 4] << 8) | R[l - 3]) == seq, "latch unchanged"); }
	CHECK(rd(0x1004, 1) == 0, "not executed");
	/* unknown address, ACK not requested */
	CHECK(wr(0x03000200, 1) == 0x03, "i2c not mapped");
	{ u32 p[2] = { 0x1008, 7 }; seq++; int l = req(0x04, 2, seq, p, 1, 1); CHECK(l == 0, "no reply without ACK_REQUEST"); }
	CHECK(rd(0x1008, 1) == 7, "executed without reply");
	/* block write + read, PTP domain, events, APB RAM, SIF, VSYNC, Opsero */
	{ u32 p[] = { 0x11C, 5, 0x22C, 9, 0x2080, 0xA5, 0x0100000C, 0, 0x70000004, 1, 0x7F000004, 1 };
	  seq++; int l = req(0x09, 3, seq, p, 6, 1); CHECK(l == 6 + 48 + 4 && R[4] == 0, "block write l=%d st=%x", l, R[4]);
	  u32 q[] = { 0x11C, 0, 0x22C, 0, 0x2080, 0, 0x188, 0, 0x7F000000, 0 };
	  seq++; l = req(0x19, 3, seq, q, 5, 1); CHECK(l == 6 + 40 + 4 && R[4] == 0, "block read");
	  CHECK(be32(R + 10) == 5 && be32(R + 18) == 9 && be32(R + 26) == 0xA5 && be32(R + 34) == 0 && be32(R + 42) == 0x4F505352, "block values"); }
	/* bad length, bad command */
	{ u8 bb[10] = { 0x04, 3, 0, 0, 0, 0, 0, 0, 0x10, 0 }; seq++; bb[2] = (u8)(seq >> 8); bb[3] = (u8)seq; xact(8192, bb, 10, MY_IP); CHECK(R[4] == 0x05, "bad len"); }
	{ u8 bb[10] = { 0x07, 3, 0, 0, 0, 0, 0, 0, 0x10, 0 }; seq++; bb[2] = (u8)(seq >> 8); bb[3] = (u8)seq; xact(8192, bb, 10, MY_IP); CHECK(R[4] == 0x04, "bad cmd"); }
	/* wrong destination IP: ignored */
	{ u32 p[2] = { 0x80, 0 }; int c0 = txcount; u8 bb[10] = { 0x14, 1, 0, 1, 0, 0, 0, 0, 0, 0x80 }; (void)p; xact(8192, bb, 10, 0xC0A81499u); CHECK(txcount == c0, "other IP ignored"); }

	/* configure_roce(0, 8192, 8320, 2, 4791) as the host does it: mask off, regs, mask on */
	CHECK(wr(0x0200030C, 0) == 0, "mask off");
	{ u32 p[] = { 0x1000, 0x000123, 0x1004, 0xBEEF, 0x1008, 0, 0x100C, 0, 0x1010, 65, 0x1014, 1, 0x1018, 8192,
	              0x1020, 0xAABBCCDD, 0x1024, 0x0011, 0x1028, 0xC0A81401, 0x102C, 4791, 0x1034, 0,
	              0x02000304, 32, 0x02000308, 12288 };
	  seq++; req(0x09, 3, seq, p, 14, 1); CHECK(R[4] == 0, "dp block"); }
	CHECK(wr(0x0200030C, 1) == 0, "mask on");
	CHECK(lastqp.qp == 13 && lastqp.type == 2 && lastqp.sq == 0 && lastqp.pm == 12 && lastqp.dqpn == 0x123 &&
	      lastqp.dip == 0xC0A81401u && lastqp.sp == 12288 && lastqp.dp == 0 &&
	      !memcmp(lastqp.mac, "\x00\x11\xAA\xBB\xCC\xDD", 6), "QP translation pm %d dp %u", lastqp.pm, lastqp.dp);
	CHECK(cfgv[RSYS_C_HP_QP] == 13 && cfgv[RSYS_C_HP_RKEY] == 0xBEEF && cfgv[RSYS_C_HP_STRIDE] == 65 * 128 &&
	      cfgv[RSYS_C_HP_PAGES] == 1 && cfgv[RSYS_C_HP_FRAME] == 8192 && (cfgv[RSYS_C_HP_CTRL] & 3) == 3, "producer cfg");
	printf("period %u clocks for 1000 Mb/s (8320 B frames: %u expected)\n", cfgv[RSYS_C_HP_PERIOD], (u32)(8320ull * 8 * 322265625 / 1000000000ull));
	CHECK(rd(0x0200030C, 1) == 1, "mask readable");
	/* RATE_MBPS is live: a write while the data plane runs rewrites C_HP_PERIOD (same formula as the start),
	 * the producer keeps running (no restart), 0 = back to back; the console 'hsb rate' does the same */
	{ u32 p0 = cfgv[RSYS_C_HP_PERIOD], c0 = cfgv[RSYS_C_HP_CTRL];
	  CHECK(p0 == (u32)(8320ull * 8 * 322265625 / 1000000000ull), "start period %u", p0);
	  CHECK(wr(0x7F000008, 4000) == 0, "rate write");
	  CHECK(cfgv[RSYS_C_HP_PERIOD] == (u32)(8320ull * 8 * 322265625 / 4000000000ull) && cfgv[RSYS_C_HP_CTRL] == c0 && prun(),
	        "live period %u at 4000 Mb/s", cfgv[RSYS_C_HP_PERIOD]);
	  CHECK(wr(0x7F000008, 0) == 0 && cfgv[RSYS_C_HP_PERIOD] == 0 && prun(), "rate 0: back to back");
	  { char *a[] = { "hsb", "rate", "1000" }; hsb_cmd(a, 3); }
	  CHECK(cfgv[RSYS_C_HP_PERIOD] == p0 && rd(0x7F000008, 1) == 1000 && prun(), "console rate live"); }

	/* 'qp 13' label: the data plane owns QP 13 */
	CHECK(hsb_qp_label(13) && strstr(hsb_qp_label(13), "UC-HSB") && !hsb_qp_label(12), "qp 13 label");
	printf("qp 13 label: %s\n", hsb_qp_label(13));

	/* Opsero registers of the watchdog */
	CHECK(rd(OPS_STATUS, 1) == (OPS_STATUS_DP_ON | OPS_STATUS_LPAUSE_EN), "status 0x%x", rd(OPS_STATUS, 1));
	CHECK(rd(OPS_KEEPALIVE_TIMEOUT_MS, 1) == 0 && rd(OPS_WATCHDOG_COUNT, 1) == 0 && rd(OPS_LINKPAUSE_COUNT, 1) == 0, "wd regs 0");
	CHECK(rd(0x7F000018, 1) == 0, "reserved");
	CHECK(wr(0x7F000030, 1) == 0x03, "beyond the Opsero block");
	CHECK(wr(OPS_WATCHDOG_COUNT, 5) == 0 && rd(OPS_WATCHDOG_COUNT, 1) == 0, "count read only");
	/* beam array generator window: plain address mapping (contract 4.1) */
	CHECK(wr(OPS_BM_SRC(1) + 0x18, 0x12345678) == 0 && cfgv[RSYS_C_BM_S0_U + RSYS_C_BM_SRC_STRIDE] == 0x12345678, "bm U1 -> cfg");
	CHECK(rd(OPS_BM_SRC(1) + 0x18, 1) == 0x12345678, "bm U1 readback");
	CHECK(wr(OPS_BM_GAIN(63), 0xC0004000u) == 0 && cfgv[RSYS_C_BM_GAIN0 + 63] == 0xC0004000u, "bm gain 63 -> cfg 255");
	CHECK(wr(OPS_BM_SCENE_ID, 7) == 0 && cfgv[RSYS_C_BM_SCENE_ID] == 7, "bm scene id");
	CHECK(rd(OPS_BM_CAPS, 1) == 0x01440808u && rd(OPS_BM_APPLIED_ID, 1) == 0xA5A50001u, "bm status -> sv");
	CHECK(wr(OPS_BM_CAPS, 5) == 0 && cfgv[(0x04F4 / 4) & 255] != 5, "bm status read only");
	CHECK(rd(0x7F000318, 1) == 0, "bm reserved status");
	CHECK(wr(0x7F00031C, 1) == 0x03, "beyond the bm status");
	CHECK(wr(OPS_BM_BASE + 2, 1) == 0x03, "bm unaligned");
	{ u32 p[] = { OPS_BM_SRC(0) + 0x18, 11, OPS_BM_SRC(0) + 0x1C, 22, OPS_BM_SCENE_ID, 8, OPS_BM_APPLY, 1 };
	  seq++; req(0x09, 3, seq, p, 4, 1); CHECK(R[4] == 0 && cfgv[RSYS_C_BM_S0_U] == 11 && cfgv[RSYS_C_BM_S0_V] == 22 &&
	  cfgv[RSYS_C_BM_SCENE_ID] == 8 && cfgv[RSYS_C_BM_APPLY] == 1, "bm block write (drag)"); }

	/* (a) keepalive: timeout 0 = stock behaviour, the producer keeps running */
	adv(10000);
	CHECK(prun() && rd(0x0200030C, 1) == 1, "no watchdog with timeout 0");
	/* armed: 2000 ms, refreshed after 1500, expires 2000 ms after the refresh */
	CHECK(wr(OPS_KEEPALIVE_TIMEOUT_MS, 2000) == 0, "arm");
	CHECK(rd(OPS_STATUS, 1) & OPS_STATUS_KA_ARMED, "armed bit");
	adv(1500);
	CHECK(wr(OPS_KEEPALIVE, 0x1234) == 0, "keepalive write");
	CHECK(rd(OPS_KEEPALIVE, 1) == 0, "timer restarted");
	adv(1500);
	CHECK(prun() && rd(OPS_WATCHDOG_COUNT, 1) == 0, "refresh kept it running");
	{ u32 e = rd(OPS_KEEPALIVE, 1); CHECK(e >= 1450 && e <= 1550, "ms since keepalive %u", e); }
	adv(600);
	CHECK(!prun(), "watchdog stopped the producer");
	CHECK(rd(0x0200030C, 1) == 0 && rd(OPS_WATCHDOG_COUNT, 1) == 1 && rd(OPS_KEEPALIVE_TIMEOUT_MS, 1) == 0, "VP_MASK 0, count 1, disarmed");
	CHECK(!(rd(OPS_STATUS, 1) & (OPS_STATUS_DP_ON | OPS_STATUS_KA_ARMED)), "status after watchdog");
	adv(3000);
	CHECK(!prun() && rd(OPS_WATCHDOG_COUNT, 1) == 1, "stays stopped");

	/* (b) link pause: re-enable, the engine counts a link drop (a whole relink between two polls) */
	{ int q0 = nqp; CHECK(wr(0x0200030C, 1) == 0 && prun() && nqp == q0 + 1, "re-enable");
	  CHECK(wr(OPS_KEEPALIVE_TIMEOUT_MS, 1000) == 0, "arm 1000");
	  linkdown++; engstatus = ROCELET_STATUS_LINK_UP_MASK | ROCELET_STATUS_TIMER_HOLD_MASK;
	  adv(50);
	  CHECK(!prun() && (rd(OPS_STATUS, 1) & OPS_STATUS_LINK_PAUSED) && rd(OPS_LINKPAUSE_COUNT, 1) == 1, "paused on the drop");
	  adv(3000);                                    /* longer than the keepalive timeout: frozen */
	  CHECK(!prun() && rd(OPS_WATCHDOG_COUNT, 1) == 1 && rd(0x0200030C, 1) == 1, "no watchdog during the pause, config kept");
	  engstatus = ROCELET_STATUS_LINK_UP_MASK;      /* hold over */
	  adv(50);
	  CHECK(prun() && !(rd(OPS_STATUS, 1) & OPS_STATUS_LINK_PAUSED) && nqp == q0 + 1, "resumed, QP not re-committed");
	  adv(900);
	  CHECK(prun(), "timer restarted at the resume");
	  CHECK(wr(OPS_KEEPALIVE_TIMEOUT_MS, 0) == 0, "disarm"); }
	/* link down (STATUS.LINK_UP = 0) -> pause; up with the hold -> still paused; hold over -> resume */
	engstatus = 0; adv(50);
	CHECK(!prun() && rd(OPS_LINKPAUSE_COUNT, 1) == 2, "paused on LINK_UP 0");
	engstatus = ROCELET_STATUS_LINK_UP_MASK | ROCELET_STATUS_TIMER_HOLD_MASK; linkdown++; adv(500);
	CHECK(!prun(), "held");
	engstatus = ROCELET_STATUS_LINK_UP_MASK; adv(50);
	CHECK(prun() && rd(OPS_LINKPAUSE_COUNT, 1) == 2, "resumed after the hold");
	/* link pause off: a drop does not stop the producer */
	{ char *a[] = { "hsb", "lpause", "off" }; hsb_cmd(a, 3); }
	CHECK(!(rd(OPS_STATUS, 1) & OPS_STATUS_LPAUSE_EN), "lpause off bit");
	linkdown++; engstatus = 0; adv(200);
	CHECK(prun() && rd(OPS_LINKPAUSE_COUNT, 1) == 2, "no pause when off");
	engstatus = ROCELET_STATUS_LINK_UP_MASK; adv(50);
	{ char *a[] = { "hsb", "lpause", "on" }; hsb_cmd(a, 3); }
	/* the console relinks ('link', 'fec', 'loop'): paused before the relink */
	hsb_link_event();
	CHECK(!prun() && rd(OPS_LINKPAUSE_COUNT, 1) == 3, "console relink pauses");
	adv(50);
	CHECK(prun(), "resumed after the console relink");
	/* console 'hsb wd' */
	{ char *a[] = { "hsb", "wd", "700" }; hsb_cmd(a, 3); }
	CHECK(rd(OPS_KEEPALIVE_TIMEOUT_MS, 1) == 700, "hsb wd");
	{ char *a[] = { "hsb", "st" }; hsb_cmd(a, 2); }
	/* SOURCE 2 (beam): C_HP_CTRL[2:1] = 2 at the next data-plane enable, no IQ16 commit */
	{ char *a[] = { "hsb", "src", "beam" }; hsb_cmd(a, 3); }
	CHECK(rd(OPS_SOURCE, 1) == 2, "source beam");
	cfgv[RSYS_C_IQ_CTRL] = 0;
	CHECK(wr(0x0200030C, 0) == 0 && wr(0x0200030C, 1) == 0, "mask off/on");
	adv(50);
	CHECK((cfgv[RSYS_C_HP_CTRL] & 7) == 5 && cfgv[RSYS_C_IQ_CTRL] == 0, "beam source in C_HP_CTRL 0x%x", cfgv[RSYS_C_HP_CTRL]);
	CHECK(wr(OPS_SOURCE, 3) == 0 && wr(0x0200030C, 0) == 0 && wr(0x0200030C, 1) == 0, "source 3");
	adv(50);
	CHECK((cfgv[RSYS_C_HP_CTRL] & 7) == 1, "source 3 behaves as 0: 0x%x", cfgv[RSYS_C_HP_CTRL]);
	CHECK(wr(OPS_SOURCE, 1) == 0 && wr(0x0200030C, 0) == 0, "back to counter, mask off");

	/* reset */
	{ u32 p[2] = { 0x4, 8 }; seq++; req(0x04, 1, seq, p, 1, 1); }
	CHECK(rd(0x1000, 0) == 0 && (cfgv[RSYS_C_HP_CTRL] & 1) == 0, "reset cleared");
	CHECK(rd(OPS_KEEPALIVE_TIMEOUT_MS, 1) == 0 && rd(OPS_WATCHDOG_COUNT, 1) == 1 && rd(OPS_LINKPAUSE_COUNT, 1) == 3,
	      "reset disarms, counters kept");
	adv(3000);
	CHECK(rd(OPS_WATCHDOG_COUNT, 1) == 1, "no watchdog after reset");
	/* set-ip */
	{ u8 bp[300]; memset(bp, 0, 300); bp[0] = 2; bp[16] = 192; bp[17] = 168; bp[18] = 20; bp[19] = 7; memcpy(bp + 28, MY_MAC, 6);
	  xact(12268, bp, 300, 0xC0A81407u); CHECK(MY_IP == 0xC0A81407u && ip4 == MY_IP, "set-ip"); }
	char *st[] = { "hsb", "st" };
	hsb_cmd(st, 2);
	hsb_tests_begin();
	CHECK(!hsb_qp_label(13), "label gone after a test / setup");
	hsb_qp_free(13);
	printf(fails ? "FWTEST FAIL %d\n" : "FWTEST PASS\n", fails);
	return fails != 0;
}
