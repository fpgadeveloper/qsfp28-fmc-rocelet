/*
 * main.c - console of the qsfp28-fmc-rocelet reference design (KCU116 + 2x QSFP28
 * FMC OP120, port 0, 100G CMAC + the rocelet RoCE v2 engine).
 *
 * Brings up the Si5328 and the CMAC, configures the engine, and offers a UART
 * console (115200 8N1):
 *  - status and counters (st, dump, clr), link control (fec, loop, link, pause), the
 *    requester's ACK timeout and its hold after a link loss (to, grace);
 *  - connection to a host through the out-of-band parameter records of the host
 *    helper: the console prints "RLF" / "RLFM" records (qp <n>) and accepts
 *    "RLH" / "RLHM" records (pasted or typed);
 *  - transfers: firmware work requests from the memory window (post), the
 *    self-test WR generator (wg), completions (cq), memory access (peek, poke);
 *  - Holoscan Sensor Bridge mode per QP (qp <n> type hsb, hsb <n>) and the HSB device mode
 *    (hsb on|off|st|serial|src|rate|scene|wd|lpause, hsb.c): enumeration, register protocol,
 *    data plane -> UC-HSB QP + frame producer, keepalive watchdog, link pause;
 *  - the built-in self-test (t) through a QSFP28 loopback plug or the GT
 *    near-end loopback, ending with one "SELFTEST PASS|FAIL ..." line.
 *
 * console_init() brings the hardware up, console_exec() runs one command line (console.h).
 * On the standalone BSPs main() below feeds it from the UART; on Linux the daemon roceletd
 * (sw/linux/roceletd, PLAT_LINUX) feeds it from its control socket (the CLI rl, the web UI).
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#include <string.h>
#include "xil_printf.h"
#include "xparameters.h"
#include "bspconfig.h"
#include "sleep.h"
#include "hw.h"
#include "util.h"
#include "plat.h"
#include "mac.h"
#include "eng.h"
#include "sysif.h"
#include "selftest.h"
#include "hsb.h"
#include "console.h"

#define VERSION "0.6.0"
#define MAXQP   64

static int g_fec = HAS_FEC, g_loop = LOOP_OFF;

/* the remote side of each QP, from the last RLH record (re-commit with another type) */
typedef struct { int set; u8 mac[6]; u32 ip, qpn, psn; int pmtu, type; u32 dport; } peer_t;
static peer_t peer[MAXQP];

/* the host window the generator / posted WRs write into (RLHM) */
static u32 g_hm_rkey = RKEY_PAT;
static u64 g_hm_va   = PAT_REGION;
static u32 g_hm_len  = 64u << 20;

static int bad_qp(int n)
{
	int max = ENG.num_qp < MAXQP ? ENG.num_qp : MAXQP;
	if (n < 0 || n >= max) { xil_printf("bad QP %d (0..%d)\r\n", n, max - 1); return 1; }
	return 0;
}

/* ------------------------------------------------------------------ */
/* status                                                              */
/* ------------------------------------------------------------------ */
static void status(void)
{
	xil_printf("qsfp28-fmc-rocelet %s | rocelet %d.%d.%d: %d QPs, %d MRs, %s", VERSION, (ENG.version >> 16) & 0xFF,
		   (ENG.version >> 8) & 0xFF, ENG.version & 0xFF, ENG.num_qp, ENG.num_mr, rtx_name(ENG.rtx_mode));
	if (ENG.rtx_mode == 0) xil_printf(" %d KB", ENG.ring_kb);
	xil_printf(", %d WRs, READ depth %d, RX ICRC %s, HSB %s, QPN base 0x%x | memory window %u KB | self-test logic %s\r\n",
		   ENG.max_wr, ENG.read_depth, ENG.rx_icrc ? "on" : "off", ENG.hsb ? "yes" : "no", ENG.qpn_base,
		   (1u << ENG.mem_log2) >> 10, ENG.selftest ? "built in" : "not built");
	xil_printf("FPGA ip "); pr_ip(MY_IP); xil_printf(" mac "); pr_mac(MY_MAC); xil_printf("\r\n");
	mac_status();
	if (!mac_clk_ok()) return;
	eng_errors();
	u32 ps = eng_rd(ROCELET_PAUSE_STATUS), wq = sv(RSYS_S_WQ_STATUS), cq = sv(RSYS_S_CQ_LEVEL);
	u32 ctl = eng_rd(ROCELET_CTRL), est = eng_rd(ROCELET_STATUS);
	xil_printf("CTRL 0x%04x (READ continuation %s) | PAUSE gate %d req %d | WR queue %u%s | completions queued: work %u"
		   " receive %u\r\n", ctl, (ctl & ROCELET_CTRL_READ_CONT_MASK) ? "on" : "OFF", (ps >> 16) & 1, (ps >> 17) & 1,
		   wq & 0x1FF, (wq >> 17) & 1 ? " (payload pending)" : "", cq & 0xFF, (cq >> 16) & 0xFF);
	xil_printf("requester: ACK timeout %u us, retry 0x%02x | engine link %s, ACK timeouts %s (LINK_GRACE %u us),"
		   " link drops %u\r\n", eng_rd(ROCELET_ACK_TIMEOUT), eng_rd(ROCELET_RETRY) & 0xFF,
		   (est & ROCELET_STATUS_LINK_UP_MASK) ? "up" : "DOWN", (est & ROCELET_STATUS_TIMER_HOLD_MASK) ? "HELD" : "running",
		   eng_rd(ROCELET_LINK_GRACE) & ROCELET_LINK_GRACE_TICKS_MASK, eng_rd(ROCELET_CNT_LINK_DOWN));
	xil_printf("engine counters:\r\n");
	eng_dump();
	xil_printf("system counters:\r\n");
	sys_dump();
}

/* ------------------------------------------------------------------ */
/* the out-of-band records (host helper: rl_host)                      */
/* ------------------------------------------------------------------ */
static u32 qp_sq_psn(int n);

static void qp_show(int n)
{
	if (bad_qp(n)) return;
	int pm = peer[n].set ? peer[n].pmtu : 12;
	xil_printf("RLF qp=%d qpn=0x%x psn=0x%x ip=", n, ENG.qpn_base + (u32)n, qp_sq_psn(n)); pr_ip(MY_IP);
	xil_printf(" mac="); pr_mac(MY_MAC);
	xil_printf(" mtu=%d rd=%d seed=0x%x\r\n", 1 << pm, ENG.read_depth, PAT_SEED);
	u32 mem = 1u << ENG.mem_log2;
	if (ENG.pattern) {
		xil_printf("RLFM mr=0 rkey=0x%x va=", RKEY_PAT); pr_hex64(PAT_REGION);
		xil_printf(" len=0x40000000 pat="); pr_hex64(PAT_REGION); xil_printf(" acc=rw\r\n");
	}
	xil_printf("RLFM mr=1 rkey=0x%x va=0x0 len=0x%x acc=rw\r\n", RKEY_MEM, mem);
	xil_printf("RLFM mr=2 rkey=0x%x va=0x0 len=0x%x acc=r\r\n", RKEY_MEM_RO, mem);
#if defined(HAS_DDR_WIN)
	if (plat_ddr_bytes()) xil_printf("RLFM mr=3 rkey=0x%x va=0x0 len=0x%x acc=rw\r\n", RKEY_DDR, plat_ddr_bytes());
#endif
	u32 s = eng_qp_status(n);
	const char *hl = hsb_qp_label(n);
	xil_printf("(QP %d status 0x%08x: %s%s%s, type %s)\r\n", n, s, (s & 1) ? "valid" : "disabled",
		   (s & 2) ? ", requester error" : "", (s & 4) ? ", responder error" : "",
		   hl ? hl : peer[n].type == QP_UC_HSB ? "UC-HSB" : peer[n].type == QP_UC ? "UC" : "RC");
}

/* HSB QPs follow the Holoscan Sensor Bridge conventions: first PSN 0, UDP source port 12288 */
#define HSB_SPORT 12288u
static u32 qp_sq_psn(int n) { return ((peer[n].set && peer[n].type == QP_UC_HSB) || hsb_qp_label(n)) ? 0 : eng_sq_psn0(n); }

static void qp_commit(int n)
{
	peer_t *p = &peer[n];
	int hsb = p->type == QP_UC_HSB;
	hsb_qp_free(n);
	eng_qp(n, p->type, qp_sq_psn(n), p->psn, p->pmtu, p->qpn, p->mac, p->ip, hsb ? HSB_SPORT : (0xC000u | (u32)n),
	       p->dport);
}

/* "RLH qpn= psn= ip= mac= mtu= [ord=] [qp=]" -> FPGA QP n towards the host */
static void rlh(char **argv, int argc, int at)
{
	const char *v;
	peer_t p;
	int n = (v = kv(argv, argc, at, "qp")) ? (int)strtou64(v) : 0;
	if (bad_qp(n)) return;
	if (!(v = kv(argv, argc, at, "qpn"))) { xil_printf("RLH: missing qpn\r\n"); return; }
	p.qpn = (u32)strtou64(v) & 0xFFFFFF;
	if (!(v = kv(argv, argc, at, "psn"))) { xil_printf("RLH: missing psn\r\n"); return; }
	p.psn = (u32)strtou64(v) & 0xFFFFFF;
	if (!(v = kv(argv, argc, at, "ip")) || parse_ip(v, &p.ip)) { xil_printf("RLH: bad ip\r\n"); return; }
	if (!(v = kv(argv, argc, at, "mac")) || parse_mac(v, p.mac)) { xil_printf("RLH: bad mac\r\n"); return; }
	u32 mtu = (v = kv(argv, argc, at, "mtu")) ? (u32)strtou64(v) : 4096;
	if (mtu < 256 || mtu > 4096 || (mtu & (mtu - 1))) { xil_printf("RLH: bad mtu %u\r\n", mtu); return; }
	p.pmtu = log2u(mtu);
	p.type = peer[n].set ? peer[n].type : QP_RC;
	p.dport = peer[n].set ? peer[n].dport : 0;
	p.set = 1;
	peer[n] = p;
	qp_commit(n);
	xil_printf("ok qp %d -> host QPN 0x%x epsn 0x%x mtu %u ip ", n, p.qpn, p.psn, mtu);
	pr_ip(p.ip); xil_printf(" mac "); pr_mac(p.mac); xil_printf(" (FPGA sq psn 0x%x)\r\n", qp_sq_psn(n));
}

/* "RLHM rkey= va= len=" -> the host window for wg / post */
static void rlhm(char **argv, int argc, int at)
{
	const char *r = kv(argv, argc, at, "rkey"), *va = kv(argv, argc, at, "va"), *len = kv(argv, argc, at, "len");
	if (!r || !va || !len) { xil_printf("RLHM: need rkey= va= len=\r\n"); return; }
	g_hm_rkey = (u32)strtou64(r);
	g_hm_va = strtou64(va);
	g_hm_len = (u32)strtou64(len);
	xil_printf("ok host window rkey 0x%x va ", g_hm_rkey); pr_hex64(g_hm_va); xil_printf(" len 0x%x\r\n", g_hm_len);
}

/* qp <n> [show] | qp <n> type rc|uc|hsb [dport] */
static void qp_cmd(char **argv, int argc)
{
	int n = (int)arg_u(argv, argc, 1, 0);
	if (argc >= 4 && !strcmp(argv[2], "type")) {
		if (bad_qp(n)) return;
		int t = !strcmp(argv[3], "uc") ? QP_UC : !strcmp(argv[3], "hsb") ? QP_UC_HSB : QP_RC;
		if (t == QP_UC_HSB && !ENG.hsb) { xil_printf("this engine was built without HSB_EN\r\n"); return; }
		if (!peer[n].set) { xil_printf("QP %d has no peer yet (RLH first)\r\n", n); return; }
		peer[n].type = t;
		peer[n].dport = arg_u(argv, argc, 4, 0);       /* no port given: 4791 */
		qp_commit(n);
		xil_printf("ok qp %d type %s, UDP ports %u -> %u, first PSN 0x%x\r\n", n,
			   t == QP_UC_HSB ? "UC-HSB" : t == QP_UC ? "UC" : "RC", t == QP_UC_HSB ? HSB_SPORT : (0xC000u | (u32)n),
			   peer[n].dport ? peer[n].dport : 4791, qp_sq_psn(n));
		return;
	}
	qp_show(n);
}

/* ------------------------------------------------------------------ */
/* transfers                                                           */
/* ------------------------------------------------------------------ */
static int parse_op(const char *s)
{
	if (!strcmp(s, "write")) return OP_WRITE;
	if (!strcmp(s, "write_imm") || !strcmp(s, "writeimm")) return OP_WRITE_IMM;
	if (!strcmp(s, "send")) return OP_SEND;
	if (!strcmp(s, "send_imm") || !strcmp(s, "sendimm")) return OP_SEND_IMM;
	return (int)strtou64(s) & 0x3F;     /* a number: [3:0] opcode [4] SE [5] HSB metadata */
}

/* wg <op> <len> <count> [gap] [qp] | wg stop : the self-test generator towards the host window */
static void wg_cmd(char **argv, int argc)
{
	if (!ENG.selftest) { xil_printf("the self-test logic is not built into this design\r\n"); return; }
	if (argc >= 2 && !strcmp(argv[1], "stop")) {
		wg_stop();
		xil_printf("ok wg stopped, issued %u\r\n", sv(RSYS_S_WG_ISSUED));
		return;
	}
	int op = argc > 1 ? parse_op(argv[1]) : OP_WRITE;
	u32 len = arg_u(argv, argc, 2, 4096), count = arg_u(argv, argc, 3, 1);
	u32 gap = arg_u(argv, argc, 4, 0), qp = arg_u(argv, argc, 5, 0);
	if (bad_qp((int)qp)) return;
	if (len > g_hm_len) { xil_printf("wg: len %u larger than the host window 0x%x\r\n", len, g_hm_len); return; }
	wg_start((int)qp, 1, op, g_hm_va, g_hm_len, len, g_hm_rkey, count, gap, 0x10000);
	/* host -> FPGA data is checked against the FPGA's own pattern region */
	cfg_set(RSYS_C_WC_BASE_LO, (u32)PAT_REGION);
	cfg_set(RSYS_C_WC_BASE_HI, (u32)(PAT_REGION >> 32));
	xil_printf("ok wg op 0x%x len %u count %u gap %u qp %u -> rkey 0x%x va ", op, len, count, gap, qp, g_hm_rkey);
	pr_hex64(g_hm_va); xil_printf("\r\n");
}

/* post <op> <len> [count] [laddr] [qp] : firmware WRs, payload from the memory window */
static void post_cmd(char **argv, int argc)
{
	int op = argc > 1 ? parse_op(argv[1]) : OP_WRITE;
	u32 len = arg_u(argv, argc, 2, 4096), count = arg_u(argv, argc, 3, 1);
	u32 la = arg_u(argv, argc, 4, 0), qp = arg_u(argv, argc, 5, 0);
	u32 mem = 1u << ENG.mem_log2;
	if (bad_qp((int)qp)) return;
	if ((la & 63) || la + len > mem || len > g_hm_len) {
		xil_printf("post: local address 64-byte aligned, payload inside the %u KB window, len <= host window\r\n", mem >> 10);
		return;
	}
	cq_enable(1, 1);
	u32 posted = 0, off = 0;
	for (u32 k = 0; k < count; k++) {
		while (wq_post((int)qp, op, g_hm_va + off, g_hm_rkey, len, 0x20000u + k, la, (u16)k)) {
			u32 rec;
			if (wcq_pop(&rec) && ((rec >> 24) & 0x7F))
				xil_printf("WC id 0x%x status %d\r\n", rec & 0xFFFF, (rec >> 24) & 0x7F);
		}
		posted++;
		off = (off + len + len > g_hm_len) ? 0 : off + len;
	}
	xil_printf("ok posted %u WRs (op 0x%x, %u B from memory window 0x%x, qp %u); 'cq' prints the completions\r\n",
		   posted, op, len, la, qp);
}

static void cq_cmd(void)
{
	u32 rec, imm, len;
	int n = 0;
	while (wcq_pop(&rec) && n < 64) {
		xil_printf("WC qp %d id 0x%x status %d%s\r\n", (rec >> 16) & 0xFF, rec & 0xFFFF, (rec >> 24) & 0x7F,
			   ((rec >> 24) & 0x7F) == 1 ? " (lost)" : ((rec >> 24) & 0x7F) == 2 ? " (flushed)" : "");
		n++;
	}
	while (rcq_pop(&rec, &imm, &len) && n < 128) {
		xil_printf("RC qp %d %s len %u", (rec >> 16) & 0xFF, ((rec >> 30) & 1) ? "SEND" : "WRITE_IMM", len);
		if ((rec >> 29) & 1) xil_printf(" imm 0x%08x", imm);
		xil_printf("\r\n");
		n++;
	}
	xil_printf("%d completion(s); queues overflowed: work %u receive %u\r\n", n, cnt(RSYS_E_WCQ_OVF), cnt(RSYS_E_RCQ_OVF));
}

/* ------------------------------------------------------------------ */
/* debug helpers                                                       */
/* ------------------------------------------------------------------ */
static void capd(void)
{
	int len = cap_read(cbuf, sizeof(cbuf));
	if (!cap_done()) xil_printf("(capture not done: armed or nothing matched yet)\r\n");
	int n = len < (int)sizeof(cbuf) ? len : (int)sizeof(cbuf);
	xil_printf("CAPF len=%d\r\n", len);
	for (int o = 0; o < n; o += 32) {
		xil_printf("%04x:", o);
		for (int i = o; i < o + 32 && i < n; i++) xil_printf(" %02x", cbuf[i]);
		xil_printf("\r\n");
	}
	xil_printf("CAPE\r\n");
}

/* PAUSE settings ('pause'): PAUSE RX off, PAUSE TX = PAUSE_TX_DEFAULT (hw.h) after boot */
static int g_prx = 0, g_ptx = PAUSE_TX_DEFAULT;
static u32 g_pq = 0x100, g_prf = 0x80;

static void pause_apply(void)
{
	mac_pause(g_prx, g_ptx, g_pq, g_prf);
	eng_ctrl_set((g_prx ? ROCELET_CTRL_PAUSE_RX_EN_MASK : 0) | (g_ptx ? ROCELET_CTRL_PAUSE_TX_EN_MASK : 0),
		     (g_prx ? 0 : ROCELET_CTRL_PAUSE_RX_EN_MASK) | (g_ptx ? 0 : ROCELET_CTRL_PAUSE_TX_EN_MASK));
}

static void pause_cmd(char **argv, int argc)
{
	int rx = g_prx, tx = g_ptx;
	u32 q = g_pq, rf = g_prf;
	for (int i = 1; i + 1 < argc; i += 2) {
		if (!strcmp(argv[i], "rx")) rx = (int)arg_u(argv, argc, i + 1, 0);
		else if (!strcmp(argv[i], "tx")) tx = (int)arg_u(argv, argc, i + 1, 0);
		else if (!strcmp(argv[i], "quanta")) q = arg_u(argv, argc, i + 1, 0x100);
		else if (!strcmp(argv[i], "refresh")) rf = arg_u(argv, argc, i + 1, 0x80);
		else if (!strcmp(argv[i], "xoff")) eng_wr(ROCELET_PAUSE_WM, (eng_rd(ROCELET_PAUSE_WM) & 0xFFFF0000u) | arg_u(argv, argc, i + 1, 128));
		else if (!strcmp(argv[i], "xon")) eng_wr(ROCELET_PAUSE_WM, (eng_rd(ROCELET_PAUSE_WM) & 0xFFFFu) | (arg_u(argv, argc, i + 1, 64) << 16));
	}
	g_prx = rx; g_ptx = tx; g_pq = q; g_prf = rf;
	pause_apply();
	u32 wm = eng_rd(ROCELET_PAUSE_WM), ps = eng_rd(ROCELET_PAUSE_STATUS);
	xil_printf("pause: receive (honour 802.3x) %s | send (from the RX FIFO level) %s, XOFF %u XON %u beats, quanta 0x%x"
		   " refresh 0x%x | now: gate %d req %d, last quanta 0x%x | frames rx %u tx %u\r\n", rx ? "on" : "off",
		   tx ? "on" : "off", wm & 0xFFFF, wm >> 16, q, rf, (ps >> 16) & 1, (ps >> 17) & 1, ps & 0xFFFF,
		   eng_rd(ROCELET_CNT_PAUSE_RX), eng_rd(ROCELET_CNT_PAUSE_TX));
}

static void vlan_cmd(char **argv, int argc)
{
	if (argc >= 3 && !strcmp(argv[1], "rx")) {
		u32 on = arg_u(argv, argc, 2, 1);
		eng_ctrl_set(on ? ROCELET_CTRL_VLAN_RX_STRIP_MASK : 0, on ? 0 : ROCELET_CTRL_VLAN_RX_STRIP_MASK);
	} else if (argc >= 3 && !strcmp(argv[1], "tx")) {
		u32 on = arg_u(argv, argc, 2, 0), pcp = arg_u(argv, argc, 3, 0) & 7, vid = arg_u(argv, argc, 4, 0) & 0xFFF;
		eng_wr(ROCELET_VLAN_TCI, (pcp << 13) | vid);
		eng_ctrl_set(on ? ROCELET_CTRL_VLAN_TX_TAG_MASK : 0, on ? 0 : ROCELET_CTRL_VLAN_TX_TAG_MASK);
	}
	u32 c = eng_rd(ROCELET_CTRL), t = eng_rd(ROCELET_VLAN_TCI);
	xil_printf("vlan: rx strip VID-0 tags %s (stripped %u, other tagged %u, last TCI 0x%04x) | tx tag %s TCI 0x%04x"
		   " (tagged %u)\r\n", (c & ROCELET_CTRL_VLAN_RX_STRIP_MASK) ? "on" : "off", eng_rd(ROCELET_CNT_RX_VLAN_STRIP),
		   eng_rd(ROCELET_CNT_RX_VLAN_OTHER), eng_rd(ROCELET_VLAN_LAST_TCI) & 0xFFFF,
		   (c & ROCELET_CTRL_VLAN_TX_TAG_MASK) ? "on" : "off", t & 0xFFFF, eng_rd(ROCELET_CNT_TX_VLAN_TAG));
}

/* injset <rx 0|1> <action 0 off|1 drop|2 corrupt> [mode 0 once|1 periodic|2 random] [class] [skip] [count]
 *        [period] [ppm] [byte] : arm a fault injector for traffic with a host (the self-test arms its own) */
static void injset_cmd(char **argv, int argc)
{
	if (!ENG.selftest) { xil_printf("the self-test logic is not built into this design\r\n"); return; }
	if (argc < 3) {
		xil_printf("injset <rx 0|1> <action 0 off|1 drop|2 corrupt> [mode 0 once|1 periodic|2 random] [class mask: 1 request"
			   " 2 ACK 4 NAK 8 READ response 16 other] [skip] [count, 0 = unlimited] [period] [ppm] [byte]\r\n");
		return;
	}
	int rx = (int)arg_u(argv, argc, 1, 0), act = (int)arg_u(argv, argc, 2, 0), mode = (int)arg_u(argv, argc, 3, 0);
	u32 cls = arg_u(argv, argc, 4, 1), skip = arg_u(argv, argc, 5, 0), count = arg_u(argv, argc, 6, 1);
	u32 period = arg_u(argv, argc, 7, 1), ppm = arg_u(argv, argc, 8, 0), byte = arg_u(argv, argc, 9, 53);
	if (act == 0) {
		cfg_set(rx ? RSYS_C_RINJ_CTRL : RSYS_C_INJ_CTRL, 0);
		xil_printf("ok %s injector off\r\n", rx ? "RX" : "TX");
		return;
	}
	u32 thresh = ppm >= 1000000u ? 0xFFFFFFFFu : (u32)(((u64)ppm << 32) / 1000000ull);
	inj_set(rx, act, mode, (int)cls, skip, count, period, thresh, byte);
	xil_printf("ok %s injector: %s, %s, class 0x%x, skip %u, count %u%s, period %u, %u ppm, byte %u%s\r\n",
		   rx ? "RX (host -> engine)" : "TX (engine -> CMAC)", act == 1 ? "drop" : "corrupt",
		   mode == 1 ? "periodic" : mode == 2 ? "random" : "once", cls, skip, count, count ? "" : " (unlimited)", period,
		   ppm, byte & 0x3F, (byte & 0x100) ? " of the last beat" : "");
}

/* lp arm | lp : first-event latency probe (first WR of the generator, first completion, first four
 * frames at the CMAC TX and RX ports) and the WR -> completion statistics of the generator */
static void lp_cmd(char **argv, int argc)
{
	if (!ENG.selftest) { xil_printf("the self-test logic is not built into this design\r\n"); return; }
	if (argc > 1 && !strcmp(argv[1], "arm")) { cfg_set(RSYS_C_LP_ARM, 1); xil_printf("ok latency probe armed\r\n"); return; }
	u32 f = sv(RSYS_S_LP_FLAGS), twr = sv(RSYS_S_LP_T_WR), tcpl = sv(RSYS_S_LP_T_CPL);
	u32 tx[4], ti[4], rx[4], ri[4];
	for (int i = 0; i < 4; i++) {
		tx[i] = sv(RSYS_S_LP_TX_T0 + i); ti[i] = sv(RSYS_S_LP_TX_I0 + i);
		rx[i] = sv(RSYS_S_LP_RX_T0 + i); ri[i] = sv(RSYS_S_LP_RX_I0 + i);
	}
	/* reference: the earliest captured event */
	u32 t0 = 0;
	int have = 0;
	if (f & 0x100) { t0 = twr; have = 1; }
	for (int i = 0; i < 4; i++) {
		if (((f >> i) & 1) && (!have || (s32)(tx[i] - t0) < 0)) { t0 = tx[i]; have = 1; }
		if (((f >> (4 + i)) & 1) && (!have || (s32)(rx[i] - t0) < 0)) { t0 = rx[i]; have = 1; }
	}
	xil_printf("LP flags 0x%03x (times in ns after the first event)\r\n", f);
	if (f & 0x100) { xil_printf("  WR   "); pr_ns(twr - t0); xil_printf("\r\n"); }
	for (int i = 0; i < 4; i++)
		if ((f >> i) & 1) { xil_printf("  TX%d  op 0x%02x psn 0x%06x  ", i, ti[i] & 0xFF, ti[i] >> 8); pr_ns(tx[i] - t0); xil_printf("\r\n"); }
	for (int i = 0; i < 4; i++)
		if ((f >> (4 + i)) & 1) { xil_printf("  RX%d  op 0x%02x psn 0x%06x  ", i, ri[i] & 0xFF, ri[i] >> 8); pr_ns(rx[i] - t0); xil_printf("\r\n"); }
	if (f & 0x200) { xil_printf("  CPL  "); pr_ns(tcpl - t0); xil_printf("\r\n"); }
	if ((f & 0x101) == 0x101) { xil_printf("  WR -> TX0 "); pr_ns(tx[0] - twr); xil_printf(" ns\r\n"); }
	if ((f & 0x11) == 0x11) {
		if ((s32)(rx[0] - tx[0]) >= 0) { xil_printf("  TX0 -> RX0 "); pr_ns(rx[0] - tx[0]); }
		else { xil_printf("  RX0 -> TX0 "); pr_ns(tx[0] - rx[0]); }
		xil_printf(" ns\r\n");
	}
	if ((f & 0x210) == 0x210) { xil_printf("  RX0 -> CPL "); pr_ns(tcpl - rx[0]); xil_printf(" ns\r\n"); }
	if ((f & 0x300) == 0x300) { xil_printf("  WR -> CPL "); pr_ns(tcpl - twr); xil_printf(" ns\r\n"); }
	u32 n = sv(RSYS_S_LAT_CNT);
	if (n) {
		/* the RTL adds at most 0xFFFF clocks (203.4 us) per WR to the 64-bit sum (16-bit counter-bank
		 * increment, rsys_lat lat_add): once a WR took longer the average is only a lower bound */
		int capped = sv(RSYS_S_LAT_MAX) > 0xFFFFu;
		xil_printf("  generator WR -> completion over %u WRs: min ", n); pr_ns(sv(RSYS_S_LAT_MIN));
		xil_printf(capped ? " avg >= " : " avg "); pr_ns(bc(RSYS_B_LAT_SUM) / n);
		xil_printf(" max "); pr_ns(sv(RSYS_S_LAT_MAX)); xil_printf(" ns%s%s\r\n", cnt(RSYS_E_LAT_OVF) ? " (tracker overflowed)" : "",
			   capped ? " (avg counts at most 203.4 us per WR)" : "");
	}
}

static void help(void)
{
	xil_printf("commands:\r\n"
		   "  st | dump | clr            status / counters / clear counters and the error latch\r\n"
		   "  t [full] [pma]             self-test (QSFP28 loopback plug; pma: in the GT loopback, then back)\r\n"
		   "  fec 0|1 | loop off|pcs|pma | link    RS-FEC, GT loopback, relink\r\n"
		   "  pause [rx 0|1] [tx 0|1] [xoff n] [xon n] [quanta n] [refresh n] | vlan rx 0|1 | vlan tx 0|1 [pcp] [vid]\r\n"
		   "  ip <a.b.c.d> | mac <12 hex> | to <us>   FPGA address, ACK timeout\r\n"
		   "  grace [us]                 ACK timeouts held this long after the link returns (default 2000000, max 16777215)\r\n"
		   " host (rl_host records): qp <n> | RLH ... | RLHM ... | qp <n> type rc|uc|hsb [dport] | hsb <n> [dport]\r\n"
		   " Holoscan Sensor Bridge device: hsb on|off | hsb [st] | hsb serial | hsb src iq|count|beam | hsb rate <Mb/s> | hsb scene <1-4> | hsb wd <ms> | hsb lpause on|off\r\n"
		   "  post <op> <len> [count] [laddr] [qp]   WRs from the memory window to the RLHM window\r\n"
		   "  wg <op> <len> <count> [gap] [qp] | wg stop   self-test generator (pattern) to the RLHM window\r\n"
		   "  cq | rnr <qp mask>         completions | QPs without receive buffers (RNR NAK)\r\n"
		   "    op: write | write_imm | send | send_imm, or a number ([3:0] opcode, 0x10 SE, 0x20 HSB metadata)\r\n"
		   " tests: setup [pmtu_log2] | arp | wrq | read <len> <pmtu_log2> | icrc | cnpvlan | access\r\n"
		   "  write <len> <pmtu_log2> <n> [op] | tput <len> <pmtu_log2> <ms> [nqp] | lat <n> <len> <pmtu_log2>\r\n"
		   "  inj <rx 0|1> <1 drop|2 corrupt> <class> <skip> <count> <nwr> <len> <pmtu_log2> | soak <s> <len> <pmtu_log2> [ppm]\r\n"
		   " debug: peek <addr> [n] | poke <addr> <val> | fill [addr] [len] (memory window; fill = pattern for rl_host reader)\r\n"
		   "  rd <addr> [n] | wr <addr> <val>   raw AXI\r\n"
		   "  cap <mode 0 any|1 op|2 qpn|3 both> [op] [qpn] [tx] [other] | capd | injoff\r\n"
		   "  injset <rx 0|1> <0 off|1 drop|2 corrupt> [mode] [class] [skip] [count] [period] [ppm] [byte]\r\n"
		   "  lp arm | lp   latency probe | rnrt [min_us] [max_us]   RNR wait | rcont [0|1]   READ continuation\r\n"
		   "  pace <Gb/s, 0 off> [burst]   requester rate limit (all QPs, wire bytes)\r\n"
#if defined(HAS_DDR_WIN)
		   " PS DDR window (mr=3): ddr | ddr fill [off] [n] | ddr check [off] [n]\r\n"
#endif
		   );
}

/* commands that work without the MAC user clock */
static int clock_free(const char *c)
{
	return !strcmp(c, "fec") || !strcmp(c, "loop") || !strcmp(c, "link") || !strcmp(c, "st") || !strcmp(c, "help") ||
	       !strcmp(c, "?") || !strcmp(c, "rd") || !strcmp(c, "wr");
}

static void relink(void)
{
	hsb_link_event();             /* a running HSB data plane pauses (link pause on) */
	mac_relink(g_fec, g_loop);
}

static int g_eng_ok;

/* the commands that run the loopback test suite (they re-configure every QP) */
static const char *const tests[] = { "t", "arp", "wrq", "read", "icrc", "cnpvlan", "access", "write", "tput",
				     "lat", "inj", "soak" };

int console_is_test(const char *c)
{
	for (unsigned k = 0; k < sizeof(tests) / sizeof(tests[0]); k++)
		if (!strcmp(c, tests[k])) return 1;
	return 0;
}

int console_eng_ok(void) { return g_eng_ok; }

void console_init(void)
{
	plat_init();                  /* console UART, time base */
#if defined(HAS_DDR_WIN)
	if (plat_ddr_init() != 0) xil_printf("WARNING: no PS DDR window buffer (MR 3 not set up)\r\n");
#endif

	xil_printf("\r\n----------------------------------------------------------------\r\n");
	xil_printf("qsfp28-fmc-rocelet console %s: rocelet RoCE v2 on " TARGET_NAME " + 2x QSFP28 FMC (%s, %s"
		   " %u Gb/s)\r\n", VERSION, plat_cpu(), MAC_NAME, LINK_GBPS);
	xil_printf("----------------------------------------------------------------\r\n");
#if defined(HAS_AON)
	{
		u32 id = aon_rd(AON_ID);
		if (id != 0x52414F4Eu) xil_printf("ERROR: always-on block not found at 0x%08x (ID 0x%08x)\r\n", AON_REGS, id);
		else xil_printf("always-on block v%u.%u, build %u, caps 0x%08x\r\n", aon_rd(AON_VERSION) >> 16,
				aon_rd(AON_VERSION) & 0xFFFF, aon_rd(AON_BUILD_ID), aon_rd(AON_CAPS));
	}
#endif
#if defined(MAC_OMAC)
	xil_printf("host NIC: QSFP28 port forced to %u Gb/s, auto-negotiation off, FEC off, MTU >= 4200 (ConnectX-6 Dx:\r\n"
		   "  ethtool -s <if> speed %u000 duplex full autoneg off; ethtool --set-fec <if> encoding off)\r\n",
		   LINK_GBPS, LINK_GBPS);
#elif defined(MAC_MRMAC)
	xil_printf("host NIC: QSFP28 port forced to 100 Gb/s, auto-negotiation off, FEC RS (ConnectX-6 Dx:\r\n"
		   "  ethtool -s <if> speed 100000 duplex full autoneg off; ethtool --set-fec <if> encoding rs;\r\n"
		   "  'fec 0' here needs 'encoding off' there)\r\n");
#endif
	if (mac_bringup(g_fec, g_loop) != 0)
		xil_printf("WARNING: link not up ('loop pma' runs the self-test without a cable)\r\n");
	g_eng_ok = 0;
	if (mac_clk_ok()) {
		if (eng_probe() != 0) xil_printf("ERROR: rocelet engine / system registers not found at 0x%08x\r\n", RSYS_BASE);
		else {
			g_eng_ok = 1;
			loop_setup(12);
			pause_apply();        /* the boot default (PAUSE_TX_DEFAULT) */
			if (g_ptx) xil_printf("PAUSE TX on (802.3x from the RX FIFO level; 'pause tx 0' turns it off)\r\n");
			status();
		}
	}
	help();
}

/* one command line (modified in place: tokenised); returns 0, or non-zero when a test failed
 * (the self-test verdict for 't', the single tests' results) */
int console_exec(char *line)
{
	char *argv[12];
	int argc = 0, rc = 0;
	char *p = strtok(line, " \t\r\n");
	while (p && argc < 12) { argv[argc++] = p; p = strtok(NULL, " \t\r\n"); }
	if (argc == 0) return 0;
	if (!clock_free(argv[0]) && !mac_clk_ok()) {
		xil_printf("%s user clock not running (GT down): only fec, loop, link, st, rd, wr\r\n", MAC_NAME);
		return 0;
	}
	if (!g_eng_ok && mac_clk_ok()) {
		if (eng_probe() == 0) { g_eng_ok = 1; loop_setup(12); pause_apply(); }
	}
	{
		int rec = -1;
		for (int i = 0; i < argc; i++) if (!strcmp(argv[i], "RLH") || !strcmp(argv[i], "RLHM")) { rec = i; break; }
		const char *c = argv[0];
		/* the tests re-configure every QP for the loopback: forget the host peers (type, port) */
		if (console_is_test(c)) { memset(peer, 0, sizeof(peer)); hsb_tests_begin(); }
		if (rec >= 0 && !strcmp(argv[rec], "RLH")) rlh(argv, argc, rec + 1);
		else if (rec >= 0) rlhm(argv, argc, rec + 1);
		else if (!strcmp(c, "st")) { if (mac_clk_ok() && g_eng_ok) status(); else mac_status(); }
		else if (!strcmp(c, "dump")) { eng_dump(); sys_dump(); }
		else if (!strcmp(c, "clr")) { eng_clear(); xil_printf("ok counters cleared\r\n"); }
		else if (!strcmp(c, "t")) {
			/* t [full] [pma|pcs]: with pma/pcs the suite runs in the GT near-end loopback and the
			 * link returns to its previous mode afterwards (no plug needed, a cable may stay in) */
			int full = 0, lp = -1;
			for (int i = 1; i < argc; i++) {
				if (!strcmp(argv[i], "full")) full = 1;
				else if (!strcmp(argv[i], "pma")) lp = LOOP_PMA;
				else if (!strcmp(argv[i], "pcs")) lp = LOOP_PCS;
			}
			int old = g_loop;
			if (lp >= 0 && lp != g_loop) { g_loop = lp; relink(); }
			rc = selftest(!full) != 0;
			if (g_loop != old) { g_loop = old; relink(); }
		}
		else if (!strcmp(c, "fec")) { g_fec = arg_u(argv, argc, 1, 1) != 0; relink(); }
		else if (!strcmp(c, "loop")) {
			g_loop = (argc > 1 && !strcmp(argv[1], "pma")) ? LOOP_PMA : (argc > 1 && !strcmp(argv[1], "pcs")) ? LOOP_PCS : LOOP_OFF;
			relink();
		}
		else if (!strcmp(c, "link")) relink();
		else if (!strcmp(c, "pause")) pause_cmd(argv, argc);
		else if (!strcmp(c, "vlan")) vlan_cmd(argv, argc);
		else if (!strcmp(c, "ip") && argc > 1) {
			u32 ip;
			if (parse_ip(argv[1], &ip)) xil_printf("bad ip\r\n");
			else { MY_IP = ip; eng_wr(ROCELET_IP4, MY_IP); xil_printf("ok\r\n"); }
		}
		else if (!strcmp(c, "mac") && argc > 1) {
			if (parse_mac(argv[1], MY_MAC)) xil_printf("bad mac\r\n");
			else {
				/* MAC / IP / tick and counters (eng_global), and the rate limit back to off as before
				 * console 0.2.0; the other engine settings stay (use 'setup' for all defaults) */
				eng_global();
				eng_pace_default();
				xil_printf("ok, requester rate limit off (PAUSE frames keep the build-time source MAC)\r\n");
			}
		}
		else if (!strcmp(c, "to")) {
			u32 us = arg_u(argv, argc, 1, ACK_TIMEOUT_DEF);
			if (us > ACK_TIMEOUT_MAX)
				/* the register is 20 bits: refuse rather than truncate (1.05 s max) */
				xil_printf("error: to %u us is above the maximum %u us (1.05 s, 20-bit ACK_TIMEOUT) - not changed\r\n",
					   us, ACK_TIMEOUT_MAX);
			else { eng_wr(ROCELET_ACK_TIMEOUT, us); xil_printf("ok\r\n"); }
		}
		else if (!strcmp(c, "grace")) {
			/* LINK_GRACE: timer ticks = microseconds (TICK_DIV = clock MHz), 24 bits; kept by 'setup' */
			if (argc > 1) {
				u32 us = arg_u(argv, argc, 1, LINK_GRACE_DEF);
				if (us > ROCELET_LINK_GRACE_TICKS_MASK) {
					/* the register is 24 bits: refuse rather than truncate (16.7 s max) */
					xil_printf("error: grace %u us is above the maximum %u us (16.7 s, 24-bit LINK_GRACE)"
						   " - not changed\r\n", us, ROCELET_LINK_GRACE_TICKS_MASK);
				} else {
					g_link_grace = us;
					eng_wr(ROCELET_LINK_GRACE, us);
				}
			}
			u32 est = eng_rd(ROCELET_STATUS);
			xil_printf("ACK timeouts held while the link is down and for %u us after it returns (LINK_GRACE) | now: link"
				   " %s, ACK timeouts %s | link drops %u, ACK timeouts %u\r\n",
				   eng_rd(ROCELET_LINK_GRACE) & ROCELET_LINK_GRACE_TICKS_MASK,
				   (est & ROCELET_STATUS_LINK_UP_MASK) ? "up" : "DOWN",
				   (est & ROCELET_STATUS_TIMER_HOLD_MASK) ? "HELD" : "running", eng_rd(ROCELET_CNT_LINK_DOWN),
				   eng_rd(ROCELET_CNT_REQ_TIMEOUT));
		}
		else if (!strcmp(c, "qp")) qp_cmd(argv, argc);
		else if (!strcmp(c, "hsb") && argc > 1 && argv[1][0] >= '0' && argv[1][0] <= '9') {
			char *a[5] = { "qp", argv[1], "type", "hsb", argc > 2 ? argv[2] : "0" };
			qp_cmd(a, argc > 2 ? 5 : 4);
		}
		else if (!strcmp(c, "hsb")) hsb_cmd(argv, argc);
		else if (!strcmp(c, "wg")) wg_cmd(argv, argc);
		else if (!strcmp(c, "post")) post_cmd(argv, argc);
		else if (!strcmp(c, "cq")) cq_cmd();
		else if (!strcmp(c, "rnr")) { cfg_set(RSYS_C_SEND_RNR, arg_u(argv, argc, 1, 0)); xil_printf("ok\r\n"); }
		else if (!strcmp(c, "setup")) {
			/* every QP back to the loopback configuration: forget the host peers (type, port) too */
			memset(peer, 0, sizeof(peer));
			hsb_tests_begin();            /* HSB on/off stays; a running data plane stops */
			loop_setup((int)arg_u(argv, argc, 1, 12));
			xil_printf("ok loopback setup\r\n");
		}
		else if (!strcmp(c, "arp")) rc = t_arp() != 0;
		else if (!strcmp(c, "wrq")) rc = t_wrq() != 0;
		else if (!strcmp(c, "read")) rc = t_read(arg_u(argv, argc, 1, 4096), (int)arg_u(argv, argc, 2, 12)) != 0;
		else if (!strcmp(c, "icrc")) rc = t_icrc() != 0;
		else if (!strcmp(c, "cnpvlan")) rc = t_cnp_vlan() != 0;
		else if (!strcmp(c, "access")) rc = t_access() != 0;
		else if (!strcmp(c, "write"))
			rc = t_write(arg_u(argv, argc, 1, 4096), (int)arg_u(argv, argc, 2, 12), arg_u(argv, argc, 3, 1000),
				argc > 4 ? parse_op(argv[4]) : OP_WRITE) != 0;
		else if (!strcmp(c, "tput"))
			rc = t_tput(arg_u(argv, argc, 1, 4096), (int)arg_u(argv, argc, 2, 12), arg_u(argv, argc, 3, 1000),
			       (int)arg_u(argv, argc, 4, 1)) != 0;
		else if (!strcmp(c, "lat")) rc = t_lat(arg_u(argv, argc, 1, 100), arg_u(argv, argc, 2, 1024), (int)arg_u(argv, argc, 3, 10)) != 0;
		else if (!strcmp(c, "inj"))
			rc = t_inject((int)arg_u(argv, argc, 1, 0), (int)arg_u(argv, argc, 2, 1), (int)arg_u(argv, argc, 3, 1),
				 arg_u(argv, argc, 4, 50), arg_u(argv, argc, 5, 1), arg_u(argv, argc, 6, 2000),
				 arg_u(argv, argc, 7, 4096), (int)arg_u(argv, argc, 8, 12)) != 0;
		else if (!strcmp(c, "soak"))
			rc = t_soak(arg_u(argv, argc, 1, 60), arg_u(argv, argc, 2, 4096), (int)arg_u(argv, argc, 3, 12), arg_u(argv, argc, 4, 0)) != 0;
		else if (!strcmp(c, "injoff")) { inj_off(); xil_printf("ok injectors off\r\n"); }
		else if (!strcmp(c, "injset")) injset_cmd(argv, argc);
		else if (!strcmp(c, "lp")) lp_cmd(argv, argc);
		else if (!strcmp(c, "rnrt")) {
			if (argc > 1) eng_wr(ROCELET_RNR_MIN, arg_u(argv, argc, 1, 10));
			if (argc > 2) eng_wr(ROCELET_RNR_MAX, arg_u(argv, argc, 2, 655360));
			xil_printf("RNR wait (decoded from the RNR NAK timer) clamped to %u..%u us\r\n", eng_rd(ROCELET_RNR_MIN),
				   eng_rd(ROCELET_RNR_MAX));
		}
		else if (!strcmp(c, "pace")) {
			/* PACE_RATE: credit per clock in 1/256 byte of wire bytes (payload + 98 per packet) */
			if (argc > 1) eng_wr(ROCELET_PACE_RATE, (u32)(((u64)arg_u(argv, argc, 1, 0) * 32000000000ull) / F_CLK_HZ) &
					     ROCELET_PACE_RATE_INC_MASK);
			if (argc > 2) eng_wr(ROCELET_PACE_BURST, arg_u(argv, argc, 2, 16384) & ROCELET_PACE_BURST_BYTES_MASK);
			u32 inc = eng_rd(ROCELET_PACE_RATE);
			xil_printf("requester rate limit: ");
			if (inc) { pr_fix((u64)inc * F_CLK_HZ, 32000000000ull, 2); xil_printf(" Gb/s on the wire (PACE_RATE %u)", inc); }
			else xil_printf("off");
			xil_printf(", burst %u B\r\n", eng_rd(ROCELET_PACE_BURST));
		}
		else if (!strcmp(c, "rcont")) {
			if (argc > 1) eng_ctrl_set(arg_u(argv, argc, 1, 1) ? ROCELET_CTRL_READ_CONT_MASK : 0,
						   arg_u(argv, argc, 1, 1) ? 0 : ROCELET_CTRL_READ_CONT_MASK);
			xil_printf("READ continuation (answer a partial READ re-issue with MIDDLE..LAST) %s; answered so far %u\r\n",
				   (eng_rd(ROCELET_CTRL) & ROCELET_CTRL_READ_CONT_MASK) ? "on" : "off", eng_rd(ROCELET_CNT_RX_READ_CONT));
		}
		else if (!strcmp(c, "cap")) {
			cap_arm((int)arg_u(argv, argc, 1, 0), (u8)arg_u(argv, argc, 2, 0), arg_u(argv, argc, 3, 0),
				(int)arg_u(argv, argc, 4, 0));
			if (arg_u(argv, argc, 5, 0)) cfg_set(RSYS_C_CAP_CTRL, cfg_get(RSYS_C_CAP_CTRL) | 0x10u);
			xil_printf("ok capture armed\r\n");
		}
		else if (!strcmp(c, "capd")) capd();
		else if (!strcmp(c, "peek")) {
			u32 a = arg_u(argv, argc, 1, 0), n = arg_u(argv, argc, 2, 1);
			for (u32 k = 0; k < n && k < 64; k++) xil_printf("0x%05x: 0x%08x\r\n", a + 4 * k, mem_rd(a + 4 * k));
		}
		else if (!strcmp(c, "poke")) { mem_wr(arg_u(argv, argc, 1, 0), arg_u(argv, argc, 2, 0)); xil_printf("ok\r\n"); }
#if defined(HAS_DDR_WIN)
		else if (!strcmp(c, "ddr")) {
			/* ddr                 region, counters and the first words (CPU view after for_cpu)
			 * ddr fill [off] [n]  pattern(offset) into the buffer, then for_dev (host reader, mr=3)
			 * ddr check [off] [n] compare with pattern(offset) after a host WRITE (mr=3)
			 * n defaults to the whole buffer (standalone 1 MB, Linux the 256 MB carve-out) */
			u32 nb = plat_ddr_bytes();
			u32 off = arg_u(argv, argc, 2, 0) & ~63u, n = arg_u(argv, argc, 3, nb) & ~63u;
			if (off > nb) off = nb;
			if (off + n > nb || off + n < off) n = nb - off;
			if (!nb) xil_printf("no PS DDR window buffer\r\n");
			else if (argc > 1 && !strcmp(argv[1], "fill")) {
				u8 pb[64];
				for (u32 o = 0; o < n; o += 64) { pat_beat(off + o, PAT_SEED, pb); plat_ddr_put64(off + o, pb); }
				plat_ddr_for_dev(off, n);
				xil_printf("ok PS DDR window 0x%x..0x%x = pattern(offset), seed 0x%x\r\n", off, off + n, PAT_SEED);
			} else if (argc > 1 && !strcmp(argv[1], "check")) {
				u8 pb[64], db[64];
				u32 bad = 0, first = 0xFFFFFFFFu;
				plat_ddr_for_cpu(off, n);
				for (u32 o = 0; o < n; o += 64) {
					pat_beat(off + o, PAT_SEED, pb);
					plat_ddr_get64(off + o, db);
					if (memcmp(pb, db, 64)) { bad++; if (first == 0xFFFFFFFFu) first = off + o; }
				}
				xil_printf("PS DDR window 0x%x..0x%x: %u of %u beats differ from pattern(offset)", off, off + n, bad, n / 64);
				if (bad) xil_printf(", first at 0x%x", first);
				xil_printf("\r\n");
				if (bad) rc = 1;
			} else {
				u8 db[64];
				plat_ddr_for_cpu(0, 256);
				plat_ddr_get64(0, db);
				xil_printf("PS DDR region PA 0x%08x%08x size 0x%x (MR 3 rkey 0x%x) | DDR bursts wr %u rd %u outside %u\r\n",
					   (u32)(plat_ddr_pa() >> 32), (u32)plat_ddr_pa(), nb, RKEY_DDR, cnt(RSYS_E_DDR_WR_BURSTS),
					   cnt(RSYS_E_DDR_RD_BURSTS), cnt(RSYS_E_DDR_OOR));
				for (int k = 0; k < 8; k++)
					xil_printf(" %08x", (u32)db[4 * k] | ((u32)db[4 * k + 1] << 8) | ((u32)db[4 * k + 2] << 16) |
						   ((u32)db[4 * k + 3] << 24));
				xil_printf("\r\n");
			}
		}
#endif
		else if (!strcmp(c, "fill")) {
			u32 a = arg_u(argv, argc, 1, 0) & ~63u, n = arg_u(argv, argc, 2, 1u << ENG.mem_log2);
			if (a + n > (1u << ENG.mem_log2)) n = (1u << ENG.mem_log2) - a;
			mem_fill_pat(a, n, PAT_SEED);
			xil_printf("ok memory window 0x%x..0x%x = pattern(address), seed 0x%x\r\n", a, a + n, PAT_SEED);
		}
		else if (!strcmp(c, "rd")) {
			u32 a = arg_u(argv, argc, 1, 0), n = arg_u(argv, argc, 2, 1);
			for (u32 k = 0; k < n && k < 64; k++) xil_printf("0x%08x: 0x%08x\r\n", a + 4 * k, Xil_In32(a + 4 * k));
		}
		else if (!strcmp(c, "wr")) { Xil_Out32(arg_u(argv, argc, 1, 0), arg_u(argv, argc, 2, 0)); xil_printf("ok\r\n"); }
		else help();
	}
	return rc;
}

#if !defined(PLAT_LINUX)
/* standalone: the UART console; the HSB control plane is served between characters */
int main(void)
{
	char line[128];

	console_init();
	for (;;) {
		xil_printf("rl> ");
		while (!getline_poll(line, sizeof(line)))
			if (g_eng_ok && hsb_on() && mac_clk_ok() && !plat_rx_ready()) hsb_poll();
		console_exec(line);
	}
	return 0;
}
#endif
