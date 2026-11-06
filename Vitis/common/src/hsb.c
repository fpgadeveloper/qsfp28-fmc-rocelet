/*
 * hsb.c - Holoscan Sensor Bridge (HSB) device mode (see hsb.h, docs/source/hsb.md).
 *
 * Wire formats (from the HSB 3.0.0 host sources, protocol facts only; no NVIDIA code):
 *  - enumeration: a 342-byte BOOTP request broadcast once a second from UDP 12268 to 12267,
 *    vendor area "enumeration version 2": tag 0xE0, "NVDA" (a protocol constant the host
 *    requires), data plane 0, version 2, compat-id 0x2603 (LE), the Opsero UUID, a 7-byte
 *    serial number unique per board (from the device DNA), HSB IP version 0x2603 (LE);
 *  - register protocol on UDP 8192: commands 0x04 WR_DWORD, 0x09 WR_BLOCK, 0x14 RD_DWORD,
 *    0x19 RD_BLOCK; flags [0] ACK_REQUEST [1] SEQUENCE_CHECK; 16-bit sequence; reply =
 *    command | 0x80, flags, sequence, status, 0, the {address, value} pairs, the latched
 *    sequence (BE16) and two zero bytes;
 *  - optional BOOTP reply on UDP 12268 (hololink-set-ip): op 2, chaddr = our MAC -> new IP.
 * Transport: standalone, frames arrive through the control-plane receive FIFO (rsys_crx: UDP
 * 8192 / 12268 of the engine's other-traffic port) and leave through the raw TX buffer (rsys_raw),
 * with the Ethernet / IPv4 / UDP headers built here. Linux (PLAT_LINUX, roceletd): the port's IP
 * belongs to Linux (rl0), so the same protocol runs over plain UDP sockets bound to rl0
 * (sw/linux/roceletd/hsb_net.c); everything above the datagram is this file, unchanged.
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
#include "selftest.h"
#include "hsb.h"
#include "hsb_regs.h"
#include "plat.h"

#define HSB_IP_VERSION   0x2603u           /* claimed HSB IP version = compat-id */
#define HSB_COMPAT_ID    0x2603u
#define HSB_SPORT_DEF    12288u
#define HSB_RATE_DEF     1000u             /* Mb/s of frames (payload + metadata) */
#define OPS_ID_VAL       0x4F505352u       /* "OPSR" */

static const u8 UUID[16] = { 0x98, 0x18, 0x3d, 0x0f, 0x18, 0xee, 0x47, 0x19,
                             0xa3, 0xb4, 0xca, 0x69, 0xe9, 0xb9, 0x4c, 0x97 };

/* 100 MHz free-running time base of the platform layer (plat.c: MicroBlaze axi_timer_0, A53 XTime) */
#define TICKS_S  PLAT_TICKS_S
#define TICKS_MS (PLAT_TICKS_S / 1000u)
static u32 now_ticks(void) { return plat_ticks(); }

/* ---------------- state ---------------- */
static int g_on;
static u32 g_t_bootp, g_t_on, g_bootp_seq, g_bootp_n;
static u16 g_latched;
static u8  g_serial[7];
static int g_serial_hw;
static int g_dp_on;                        /* producer running for the host */
static int g_reset_pending;
static int g_start_pending;                /* DP_VP_MASK 0 -> 1: start after the reply (H3, 2026-10-31) */
static u32 g_resets;                       /* HSB resets (0x4 bit 3) since 'hsb on' */
static u32 g_req, g_rep, g_err, g_seqerr, g_setip, g_last_ip, g_last_port, g_last_st;
static u8  g_last_mac[6];
static int g_qp_own;                       /* QP 13 configured by the data plane ('qp 13' says so) */
/* producer watchdog (0.3.0): keepalive timeout and link pause */
static u32 g_ka_to, g_ka_ms, g_t_ms;       /* KEEPALIVE_TIMEOUT_MS, ms since the last restart, ms tick anchor */
static u32 g_wd_n, g_lp_n, g_ld;           /* WATCHDOG_COUNT, LINKPAUSE_COUNT, last CNT_LINK_DOWN */
static int g_lp_en = 1, g_lp;              /* link pause enabled (default), producer paused for the link */

/* register file (the addresses a stock HSB 3.0.0 host touches, spec b.5) */
static u32 r_rst[2];                       /* 0x0004, 0x0008 */
static u32 r_ptp[8];                       /* 0x0100..0x011C */
static u32 r_sync[2];                      /* 0x0180, 0x0184 (0x0188 / 0x018C read 0) */
static u32 r_evt[13];                      /* 0x0200..0x0230 (incl. TSN VLAN 0x0230) */
static u32 r_vp[64];                       /* 0x1000 + 0x40 n + 0x00..0x3C, sensors 0..3 */
static u32 r_apb[1024];                    /* 0x2000..0x2FFF sequencer / APB RAM */
static u32 r_hif[8];                       /* 0x02000300 + 0x10000 d + 0x0..0xC, data planes 0..1 */
static u32 r_sif[16];                      /* 0x01000000 + 0x10000 s + 0x0..0xC, SIFs 0..3 */
static u32 r_vsync[6];                     /* 0x70000000..0x70000014 */
static u32 r_ops[4] = { 0, 0, HSB_RATE_DEF, 1 };   /* Opsero 0x7F000000: -, SOURCE, RATE_MBPS, SCENE */

/* VP slice 0 (sensor 0) and HIF slice 0 (data plane 0) words */
#define DP_QP          (r_vp[0x00 / 4])
#define DP_RKEY        (r_vp[0x04 / 4])
#define DP_PAGE_LSB    (r_vp[0x08 / 4])
#define DP_PAGE_MSB    (r_vp[0x0C / 4])
#define DP_PAGE_INC    (r_vp[0x10 / 4])
#define DP_MAX_BUFF    (r_vp[0x14 / 4])
#define DP_BUFFER_LEN  (r_vp[0x18 / 4])
#define DP_HOST_MAC_LO (r_vp[0x20 / 4])
#define DP_HOST_MAC_HI (r_vp[0x24 / 4])
#define DP_HOST_IP     (r_vp[0x28 / 4])
#define DP_HOST_PORT   (r_vp[0x2C / 4])
#define DP_PACKET_SIZE (r_hif[0x04 / 4])
#define DP_PACKET_PORT (r_hif[0x08 / 4])
#define DP_VP_MASK     (r_hif[0x0C / 4])

static int hsb_qp(void) { return ENG.num_qp - 3; }   /* QP 13 with 16 QPs (tests use the last two) */

/* ---------------- helpers ---------------- */
static u32  be32(const u8 *p) { return ((u32)p[0] << 24) | ((u32)p[1] << 16) | ((u32)p[2] << 8) | p[3]; }
static void pb16(u8 *p, u32 v) { p[0] = (u8)(v >> 8); p[1] = (u8)v; }
static void pb32(u8 *p, u32 v) { p[0] = (u8)(v >> 24); p[1] = (u8)(v >> 16); p[2] = (u8)(v >> 8); p[3] = (u8)v; }

/* FPGA_DATE from the firmware build date: 0xYYYYMMDD (BCD-like, as HSB's dates read) */
static u32 build_date(void)
{
	static const char m[] = "JanFebMarAprMayJunJulAugSepOctNovDec";
	const char *d = __DATE__;               /* "Oct 31 2026" */
	int mo = 0;
	for (int i = 0; i < 12; i++) if (!strncmp(d, m + 3 * i, 3)) mo = i + 1;
	u32 day = (u32)((d[4] == ' ' ? 0 : d[4] - '0') * 16 + (d[5] - '0'));
	u32 yr = ((u32)(d[7] - '0') << 12) | ((u32)(d[8] - '0') << 8) | ((u32)(d[9] - '0') << 4) | (u32)(d[10] - '0');
	return (yr << 16) | ((u32)(mo / 10 * 16 + mo % 10) << 8) | day;
}

/* serial number: the 96-bit device DNA folded to 56 bits, DNA[55:0] ^ DNA[95:56], big-endian;
 * without a DNA (not read yet): 0x00 + the MAC address (status bit "hardware serial" = 0) */
static void make_serial(void)
{
	if (sv(RSYS_S_HP_STATUS) & 8u) {
		u32 d0 = sv(RSYS_S_DNA0), d1 = sv(RSYS_S_DNA1), d2 = sv(RSYS_S_DNA2);
		u64 lo = (((u64)d1 << 32) | d0) & 0x00FFFFFFFFFFFFFFull;
		u64 hi = (((u64)d2 << 8) | (d1 >> 24)) & 0xFFFFFFFFFFull;
		u64 s = lo ^ hi;
		for (int i = 0; i < 7; i++) g_serial[i] = (u8)(s >> (48 - 8 * i));
		g_serial_hw = 1;
	} else {
		g_serial[0] = 0;
		memcpy(g_serial + 1, MY_MAC, 6);
		g_serial_hw = 0;
	}
}

static void pr_serial(void) { for (int i = 0; i < 7; i++) xil_printf("%02x", g_serial[i]); }

#if !defined(PLAT_LINUX)
/* Ethernet + IPv4 + UDP headers (checksum 0) in f, payload length n; returns the frame length */
static int udp_hdr(u8 *f, const u8 *dmac, u32 dip, u32 sport, u32 dport, int n)
{
	u32 sum = 0;
	memcpy(f, dmac, 6);
	memcpy(f + 6, MY_MAC, 6);
	pb16(f + 12, 0x0800);
	f[14] = 0x45; f[15] = 0; pb16(f + 16, (u32)(28 + n)); pb16(f + 18, 0); pb16(f + 20, 0x4000);
	f[22] = 64; f[23] = 17; pb16(f + 24, 0); pb32(f + 26, MY_IP); pb32(f + 30, dip);
	for (int i = 14; i < 34; i += 2) sum += ((u32)f[i] << 8) | f[i + 1];
	while (sum >> 16) sum = (sum & 0xFFFF) + (sum >> 16);
	pb16(f + 24, ~sum & 0xFFFF);
	pb16(f + 34, sport); pb16(f + 36, dport); pb16(f + 38, (u32)(8 + n)); pb16(f + 40, 0);
	int len = 42 + n;
	while (len < 60) f[len++] = 0;
	return len;
}
#endif

static u8 *txb(void) { return cbuf + 4096; }       /* reply frame (cbuf: 8200 B, shared with capd) */
static u8 *rxb(void) { return cbuf; }              /* received frame */

/* send the UDP payload f[42 .. 42+n) to dip:dport from our sport (dmac: the next hop's MAC) */
#if defined(PLAT_LINUX)
#include "hsb_net.h"
static void hsb_tx(u8 *f, const u8 *dmac, u32 dip, u32 sport, u32 dport, int n)
{
	(void)dmac;                                    /* the kernel resolves the next hop */
	hsb_net_send(dip, sport, dport, f + 42, n);
}
#else
static void hsb_tx(u8 *f, const u8 *dmac, u32 dip, u32 sport, u32 dport, int n)
{
	raw_send(f, udp_hdr(f, dmac, dip, sport, dport, n));
}
#endif

/* ---------------- enumeration ---------------- */
static void bootp_send(void)
{
	static const u8 bcast[6] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
	u8 *f = txb(), *b = f + 42, *v = b + 236;
	memset(b, 0, 300);
	b[0] = 1; b[1] = 1; b[2] = 6;                   /* BOOTREQUEST, Ethernet, hlen 6; xid 0 = data plane 0 */
	pb16(b + 8, (now_ticks() - g_t_on) / TICKS_S);  /* secs (wraps with the 43 s timer: informative only) */
	pb32(b + 12, MY_IP);                            /* ciaddr */
	memcpy(b + 28, MY_MAC, 6);                      /* chaddr */
	v[0] = 0xE0; v[1] = 0x38; v[2] = 'N'; v[3] = 'V'; v[4] = 'D'; v[5] = 'A';
	v[6] = 0;                                       /* data plane */
	v[7] = 2;                                       /* enumeration version */
	v[8] = (u8)HSB_COMPAT_ID; v[9] = (u8)(HSB_COMPAT_ID >> 8);
	memcpy(v + 10, UUID, 16);
	memcpy(v + 30, g_serial, 7);
	v[37] = (u8)HSB_IP_VERSION; v[38] = (u8)(HSB_IP_VERSION >> 8);
	pb16(v + 55, g_bootp_seq++);
	v[57] = g_serial_hw ? 2 : 0;                    /* [0] PTP time valid = 0 [1] hardware serial */
	hsb_tx(f, bcast, 0xFFFFFFFFu, 12268, 12267, 300);
	g_bootp_n++;
}

/* ---------------- data plane: DP_* -> rocelet QP + producer ---------------- */
static const struct { u32 inc[4]; u16 amp[4]; u32 cstart, rate, per, camp, namp, seed; } SCENE[4] = {
	/* 1 survey: 4 tones, chirp -0.45..+0.45 Fs over 2.4e9 samples, noise */
	{ { 0xB3400000u, 0xE1400000u, 0x11E00000u, 0x40000000u }, { 6000, 3000, 1500, 750 },
	  0x8CD00000u, 105541u, 2400000000u, 3000, 200, 0x5EED0001u },
	/* 2 radar: chirp -0.4..+0.4 Fs over 2.4e6 samples, noise */
	{ { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, 0x99A00000u, 93802085u, 2400000u, 16000, 300, 0x5EED0002u },
	/* 3 tones: 4 tones in 6 dB steps */
	{ { 0xA0000000u, 0xE0000000u, 0x20000000u, 0x60000000u }, { 16000, 8000, 4000, 2000 }, 0, 0, 0, 0, 0, 0 },
	/* 4 noise */
	{ { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, 0, 0, 0, 0, 4000, 0x5EED0004u },
};

static const char *src_name(u32 s) { return s == 1 ? "counter" : (s == 2 ? "beam" : "IQ16"); }

static void iq_commit(u32 scene)
{
	int s = (scene >= 1 && scene <= 4) ? (int)scene - 1 : 0;
	cfg_set(RSYS_C_IQ_CFG_ID, (u32)s + 1);
	for (int t = 0; t < 4; t++) cfg_set(RSYS_C_IQ_TONE_INC0 + t, SCENE[s].inc[t]);
	cfg_set(RSYS_C_IQ_TONE_AMP01, SCENE[s].amp[0] | ((u32)SCENE[s].amp[1] << 16));
	cfg_set(RSYS_C_IQ_TONE_AMP23, SCENE[s].amp[2] | ((u32)SCENE[s].amp[3] << 16));
	cfg_set(RSYS_C_IQ_CHIRP_START, SCENE[s].cstart);
	cfg_set(RSYS_C_IQ_CHIRP_RATE_LO, SCENE[s].rate);
	cfg_set(RSYS_C_IQ_CHIRP_RATE_HI, 0);
	cfg_set(RSYS_C_IQ_CHIRP_PER_LO, SCENE[s].per);
	cfg_set(RSYS_C_IQ_CHIRP_PER_HI, 0);
	cfg_set(RSYS_C_IQ_AMPS, SCENE[s].camp | (SCENE[s].namp << 16));
	cfg_set(RSYS_C_IQ_SEED, SCENE[s].seed);
	cfg_set(RSYS_C_IQ_CTRL, 1);
}

static int dp_pmtu(void)
{
	u32 b = DP_PACKET_SIZE * 128u;
	int p = b ? log2u(b) : 10;
	if (p < 8) p = 8;
	if (p > ENG.pmtu_log2) p = ENG.pmtu_log2;
	return p;
}

static void dp_stop(void)
{
	cfg_set(RSYS_C_HP_CTRL, cfg_get(RSYS_C_HP_CTRL) & ~1u);       /* stop at the next frame boundary */
	for (int t = 0; t < 2000 && (sv(RSYS_S_HP_STATUS) & 1u); t++) usleep(50);
	for (int t = 0; t < 2000 && eng_rd(ROCELET_WR_OUTSTANDING); t++) usleep(50);
	g_dp_on = 0;
	g_lp = 0;
}

/* frame period in CMAC clocks for RATE_MBPS (frame + 128-byte record), 0 = back to back. The producer
 * samples C_HP_PERIOD at every frame start, so writing it while the stream runs changes the rate from
 * the next frame on (the frame size and the page ring stay latched for the run). */
static u32 dp_period(u32 frame)
{
	u32 rate = r_ops[2];
	return rate ? (u32)(((u64)(frame + 128u) * 8u * F_CLK_HZ) / ((u64)rate * 1000000u)) : 0;
}

/* RATE_MBPS written (register protocol or 'hsb rate'): a running producer follows at once */
static void dp_rate(void)
{
	if (g_dp_on) cfg_set(RSYS_C_HP_PERIOD, dp_period(cfg_get(RSYS_C_HP_FRAME)));
}

static void dp_start(void)
{
	u8 mac[6];
	int qp = hsb_qp(), pm = dp_pmtu();
	u32 first = (DP_MAX_BUFF >> 16) & 0xFFF, last = DP_MAX_BUFF & 0xFFF, stride = DP_PAGE_INC * 128u;
	u32 frame = DP_BUFFER_LEN, dport = DP_HOST_PORT & 0xFFFF, sport = DP_PACKET_PORT & 0xFFFF;
	u64 va0 = (((u64)DP_PAGE_MSB << 32) | DP_PAGE_LSB) + (u64)first * stride;
	if (!frame || last < first) { xil_printf("hsb: data plane not started (frame %u B, pages %u..%u)\r\n", frame, first, last); return; }
	mac[0] = (u8)(DP_HOST_MAC_HI >> 8); mac[1] = (u8)DP_HOST_MAC_HI;
	for (int i = 0; i < 4; i++) mac[2 + i] = (u8)(DP_HOST_MAC_LO >> (24 - 8 * i));
	if (g_dp_on) dp_stop();
	/* UC in HSB mode (type 2), first PSN 0 (the host QP's rq_psn), PMTU from DP_PACKET_SIZE */
	eng_qp(qp, QP_UC_HSB, 0, 0, pm, DP_QP, mac, DP_HOST_IP, sport ? sport : HSB_SPORT_DEF, dport == 4791 ? 0 : dport);
	u32 src = r_ops[1] <= 2u ? r_ops[1] : 0u;
	cfg_set(RSYS_C_HP_CTRL, src << 1);
	if (!src) iq_commit(r_ops[3]);
	cfg_set(RSYS_C_HP_QP, (u32)qp);
	cfg_set(RSYS_C_HP_RKEY, DP_RKEY);
	cfg_set(RSYS_C_HP_VA_LO, (u32)va0);
	cfg_set(RSYS_C_HP_VA_HI, (u32)(va0 >> 32));
	cfg_set(RSYS_C_HP_STRIDE, stride);
	cfg_set(RSYS_C_HP_PAGES, (first << 16) | last);
	cfg_set(RSYS_C_HP_FRAME, frame);
	cfg_set(RSYS_C_HP_WRMAX, 16384);
	cfg_set(RSYS_C_HP_PERIOD, dp_period(frame));
	cfg_set(RSYS_C_HP_COUNT, 0);
	cfg_set(RSYS_C_HP_CTRL, (src << 1) | 1u);
	g_dp_on = 1;
	g_qp_own = 1;
	g_lp = 0;
	g_ld = eng_rd(ROCELET_CNT_LINK_DOWN);
	g_ka_ms = 0;
	xil_printf("hsb: data plane on: QP %d -> host QPN 0x%x ", qp, DP_QP & 0xFFFFFF); pr_ip(DP_HOST_IP);
	xil_printf(":%u mac ", dport); pr_mac(mac);
	xil_printf(", frame %u B, pages %u..%u stride %u, PMTU %u, %s, %u Mb/s\r\n", frame, first, last, stride, 1u << pm,
		   src_name(src), r_ops[2]);
}

static void regs_clear(void)
{
	memset(r_rst, 0, sizeof(r_rst)); memset(r_ptp, 0, sizeof(r_ptp)); memset(r_sync, 0, sizeof(r_sync));
	memset(r_evt, 0, sizeof(r_evt)); memset(r_vp, 0, sizeof(r_vp)); memset(r_apb, 0, sizeof(r_apb));
	memset(r_hif, 0, sizeof(r_hif)); memset(r_sif, 0, sizeof(r_sif)); memset(r_vsync, 0, sizeof(r_vsync));
}

/* HSB reset (write 0x4 bit 3): data plane off, registers cleared, sequence latch 0; the IP
 * address, the Opsero registers and the BOOTP broadcast stay */
static void hsb_reset(void)
{
	if (g_dp_on) dp_stop();
	regs_clear();
	g_latched = 0;
	g_ka_to = 0;                                        /* a stock app after ours: no watchdog */
	g_t_bootp = now_ticks() - TICKS_S + TICKS_S / 20;   /* next BOOTP in ~50 ms */
}

/* ---------------- register file ---------------- */
#define ST_OK        0x00
#define ST_BAD_ADDR  0x03
#define ST_BAD_CMD   0x04
#define ST_BAD_LEN   0x05
#define ST_SEQ       0x0B

/* storage of a register (NULL: not mapped); *ro = 1 for computed read-only registers */
static u32 *reg_at(u32 a, int *ro)
{
	*ro = 0;
	if (a & 3) return NULL;
	if (a == 0x4 || a == 0x8) return &r_rst[a >> 3];
	if (a == 0x80 || a == 0x84 || a == 0x188 || a == 0x18C || a == 0x280) { *ro = 1; return NULL; }
	if (a >= 0x100 && a < 0x120) return &r_ptp[(a - 0x100) >> 2];
	if (a >= 0x180 && a < 0x188) return &r_sync[(a - 0x180) >> 2];
	if (a >= 0x200 && a < 0x234) return &r_evt[(a - 0x200) >> 2];
	if (a >= 0x1000 && a < 0x1100) return &r_vp[(a - 0x1000) >> 2];
	if (a >= 0x2000 && a < 0x3000) return &r_apb[(a - 0x2000) >> 2];
	if ((a & ~0x0001000Fu) == 0x02000300u) return &r_hif[((a >> 16) & 1) * 4 + ((a & 0xF) >> 2)];
	if ((a & ~0x0003000Fu) == 0x01000000u) return &r_sif[((a >> 16) & 3) * 4 + ((a & 0xF) >> 2)];
	if (a >= 0x70000000u && a <= 0x70000014u) return &r_vsync[(a - 0x70000000u) >> 2];
	if (a >= OPS_BASE && a < OPS_BASE + 0x30u) {
		if (a >= OPS_SOURCE && a <= OPS_SCENE) return &r_ops[(a & 0xF) >> 2];
		if (a == OPS_KEEPALIVE_TIMEOUT_MS) return &g_ka_to;
		*ro = 1;                                /* ID, FRAMES, STATUS, KEEPALIVE, counters, reserved */
	}
	return NULL;
}

/* beam array generator (docs/source/beam_contract.md 4.1): addresses only, no computation.
 * 0x7F000100..0x7F0002FF -> system 0x0200..0x03FF (RW), 0x7F000300..0x7F000318 -> 0x04E4.. (RO) */
static u32 bm_sys(u32 a, int *ro)
{
	*ro = a >= OPS_BM_STAT;
	if (a & 3) return 0;
	if (a - OPS_BM_BASE < 0x200u) return a - OPS_BM_BASE + 0x0200u;
	if (a - OPS_BM_STAT < 0x1Cu) return a - OPS_BM_STAT + 0x04E4u;
	return 0;
}

static int reg_rd(u32 a, u32 *v)
{
	int ro;
	u32 b = bm_sys(a, &ro);
	if (b) { *v = sys_rd(b); return ST_OK; }
	u32 *p = reg_at(a, &ro);
	*v = 0;
	if (p) { *v = *p; return ST_OK; }
	if (!ro) return ST_BAD_ADDR;
	switch (a) {
	case 0x80:        *v = HSB_IP_VERSION; break;
	case 0x84:        *v = build_date(); break;
	case OPS_ID:      *v = OPS_ID_VAL; break;
	case OPS_FRAMES:  *v = sv(RSYS_S_HP_FRAMES); break;
	case OPS_STATUS:  *v = (sv(RSYS_S_HP_STATUS) & 1u) | (g_dp_on ? OPS_STATUS_DP_ON : 0) | (g_lp ? OPS_STATUS_LINK_PAUSED : 0) |
			       (g_lp_en ? OPS_STATUS_LPAUSE_EN : 0) | (g_ka_to ? OPS_STATUS_KA_ARMED : 0); break;
	case OPS_KEEPALIVE:       *v = g_ka_ms; break;
	case OPS_WATCHDOG_COUNT:  *v = g_wd_n; break;
	case OPS_LINKPAUSE_COUNT: *v = g_lp_n; break;
	case OPS_LINK_GBPS:       *v = LINK_GBPS; break;
	default:          *v = 0; break;    /* PTP SYNC_STAT / OFM, CTRL_EVT_STAT: 0 (no PTP, no events) */
	}
	return ST_OK;
}

static int reg_wr(u32 a, u32 v)
{
	int ro;
	u32 b = bm_sys(a, &ro);
	if (b) { if (!ro) sys_wr(b, v); return ST_OK; }
	u32 *p = reg_at(a, &ro);
	if (a == OPS_KEEPALIVE) g_ka_ms = 0;            /* any value: restart the watchdog timer */
	if (!p) return ro ? ST_OK : ST_BAD_ADDR;        /* writes to read-only registers are ignored */
	u32 old = *p;
	*p = v;
	if (p == &g_ka_to) g_ka_ms = 0;
	if (p == &r_ops[2]) dp_rate();                  /* RATE_MBPS: live while the data plane runs */
	if (a == 0x4 && (v & 8u)) g_reset_pending = 1;
	if (p == &DP_VP_MASK && ((old ^ v) & 1u)) {
		/* The start waits until the reply has gone out: an unpaced data plane can fill the host
		 * NIC's buffers so that the reply to this write is lost (H3: P520 GPU path, 85 Gb/s) */
		if (v & 1u) g_start_pending = 1; else { g_start_pending = 0; dp_stop(); }
	}
	return ST_OK;
}

/* one register-protocol request q[0..n) -> reply r; returns the reply length (0: none) */
static int ecb(const u8 *q, int n, u8 *r)
{
	if (n < 6) return 0;
	u8 cmd = q[0], fl = q[1];
	u16 seq = (u16)(((u32)q[2] << 8) | q[3]);
	int st = ST_OK, o = 6;
	r[0] = cmd | 0x80; r[1] = fl; r[2] = q[2]; r[3] = q[3]; r[5] = 0;
	if ((fl & 2) && seq != (u16)(g_latched + 1)) {
		st = ST_SEQ;
		g_seqerr++;
	} else {
		g_latched = seq;
		int blk = (cmd == 0x09 || cmd == 0x19), rd = (cmd == 0x14 || cmd == 0x19);
		if (cmd != 0x04 && cmd != 0x09 && cmd != 0x14 && cmd != 0x19) st = ST_BAD_CMD;
		else if (n < (rd && !blk ? 10 : 14) || (blk && ((n - 6) & 7))) st = ST_BAD_LEN;
		else {
			int np = blk ? (n - 6) / 8 : 1;
			if (np > 183) np = 183;
			for (int i = 0; i < np; i++) {
				u32 a = be32(q + 6 + 8 * i), v = rd ? 0 : be32(q + 10 + 8 * i);
				int s = rd ? reg_rd(a, &v) : reg_wr(a, v);
				if (s && !st) st = s;
				pb32(r + o, a); pb32(r + o + 4, v);
				o += 8;
			}
		}
	}
	r[4] = (u8)st;
	if (st) g_err++;
	g_last_st = (u32)st;
	pb16(r + o, g_latched); r[o + 2] = 0; r[o + 3] = 0;
	o += 4;
	return (fl & 1) ? o : 0;
}

/* one control-plane datagram: payload p[0..plen) from smac / sip:sport to dip:dport */
static void rx_udp(const u8 *smac, u32 sip, u32 sport, u32 dip, u32 dport, const u8 *p, int plen)
{
	if (dport == 8192 && dip == MY_IP) {
		u8 *t = txb();
		g_req++;
		g_last_ip = sip; g_last_port = sport; memcpy(g_last_mac, smac, 6);
		int rl = ecb(p, plen, t + 42);
		if (rl) {
			u8 m[6];
			memcpy(m, smac, 6);
			hsb_tx(t, m, sip, 8192, sport, rl);
			g_rep++;
		}
		if (g_reset_pending) { g_reset_pending = 0; g_start_pending = 0; hsb_reset(); g_resets++; }
		if (g_start_pending) { g_start_pending = 0; dp_start(); }
	} else if (dport == 12268 && plen >= 236 && p[0] == 2 && !memcmp(p + 28, MY_MAC, 6)) {
		/* hololink-set-ip: adopt yiaddr */
		u32 ip = be32(p + 16);
		if (ip && ip != MY_IP) {
			MY_IP = ip;
			eng_wr(ROCELET_IP4, MY_IP);
#if defined(PLAT_LINUX)
			hsb_net_set_ip(MY_IP);                  /* rl0 follows (the engine answers RoCE for it) */
#endif
			g_setip++;
			xil_printf("hsb: set-ip -> "); pr_ip(MY_IP); xil_printf("\r\n");
		}
		g_t_bootp = now_ticks() - TICKS_S;              /* announce the new address now */
	}
}

#if !defined(PLAT_LINUX)
/* one control-plane frame f[0..n) (IPv4 / UDP 8192 or 12268, as the RTL filter passed it) */
static void rx_frame(const u8 *f, int n)
{
	if (n < 42) return;
	u32 dip = be32(f + 30), sip = be32(f + 26), sport = ((u32)f[34] << 8) | f[35], dport = ((u32)f[36] << 8) | f[37];
	int plen = (int)(((u32)f[38] << 8) | f[39]) - 8;
	if (plen < 0 || 42 + plen > n) plen = n - 42;
	rx_udp(f + 6, sip, sport, dip, dport, f + 42, plen);
}
#endif

/* ---------------- producer watchdog ---------------- */
/* Link pause: stop the producer at a frame boundary, keep the host's configuration. The RTL
 * restarts a run at the first page with frame number 0 (and IQ16 sample 0), as at enable. */
static void lp_pause(void)
{
	cfg_set(RSYS_C_HP_CTRL, cfg_get(RSYS_C_HP_CTRL) & ~1u);
	g_lp = 1;
	g_lp_n++;
	xil_printf("hsb: link down: producer paused after %u frames\r\n", sv(RSYS_S_HP_FRAMES));
}

/* the data plane runs: keepalive timeout (a) and link pause (b); called with the RX FIFO empty */
static void dp_watch(void)
{
	u32 d = now_ticks() - g_t_ms;
	if (d >= TICKS_MS) {
		u32 n = d / TICKS_MS;
		g_t_ms += n * TICKS_MS;
		if (g_dp_on && !g_lp) g_ka_ms += n;     /* the host cannot reach us during a link pause */
	}
	if (!g_dp_on) return;
	u32 es = eng_rd(ROCELET_STATUS), ld = eng_rd(ROCELET_CNT_LINK_DOWN);
	int dropped = ld > g_ld;                    /* a drop since the last look (also a whole relink) */
	g_ld = ld;
	if (!g_lp) {
		if (g_ka_to && g_ka_ms >= g_ka_to) {
			xil_printf("hsb: no keepalive for %u ms: data plane stopped (watchdog)\r\n", g_ka_ms);
			dp_stop();
			DP_VP_MASK &= ~1u;
			g_start_pending = 0;
			g_ka_to = 0;                        /* one-shot: the next application arms it again */
			g_wd_n++;
		} else if (g_lp_en && (dropped || !(es & ROCELET_STATUS_LINK_UP_MASK))) {
			lp_pause();
		}
	} else if (!(sv(RSYS_S_HP_STATUS) & 1u) && (!g_lp_en || ((es & ROCELET_STATUS_LINK_UP_MASK) &&
		   !(es & ROCELET_STATUS_TIMER_HOLD_MASK) && !dropped))) {
		cfg_set(RSYS_C_HP_CTRL, cfg_get(RSYS_C_HP_CTRL) | 1u);
		g_lp = 0;
		g_ka_ms = 0;
		xil_printf("hsb: link up: producer resumed (frame number 0, first page)\r\n");
	}
}

/* ---------------- console side ---------------- */
int hsb_on(void) { return g_on; }

void hsb_poll(void)
{
	if (!g_on) return;
#if defined(PLAT_LINUX)
	for (int k = 0; k < 4; k++) {
		u32 sip, sport, dport;
		u8 smac[6], *p = rxb() + 42;
		int n = hsb_net_recv(&sip, &sport, &dport, smac, p, 4096 - 42);
		if (n < 0) { dp_watch(); break; }
		rx_udp(smac, sip, sport, MY_IP, dport, p, n);
	}
#else
	for (int k = 0; ; k++) {
		u32 st = sv(RSYS_S_CRX_STATUS);
		if (!(st & 0xFF)) { dp_watch(); break; }
		if (k == 4) break;
		int n = (int)((st >> 16) & 0xFFF);
		if (n > 1536) n = 1536;
		u8 *f = rxb();
		for (int w = 0; w < (n + 3) / 4; w++) {
			u32 v = sys_rd(0x8000u + 4u * (u32)w);
			f[4 * w] = (u8)v; f[4 * w + 1] = (u8)(v >> 8); f[4 * w + 2] = (u8)(v >> 16); f[4 * w + 3] = (u8)(v >> 24);
		}
		cfg_set(RSYS_C_CRX_POP, 1);
		rx_frame(f, n);
	}
#endif
	if (now_ticks() - g_t_bootp >= TICKS_S) {
		g_t_bootp = now_ticks();
		bootp_send();
	}
}

void hsb_link_event(void)
{
	if (g_on && g_dp_on && g_lp_en && !g_lp) lp_pause();
}

const char *hsb_qp_label(int n) { return (g_qp_own && n == hsb_qp()) ? "UC-HSB, HSB data plane: 'hsb st'" : NULL; }
void hsb_qp_free(int n) { if (n == hsb_qp()) g_qp_own = 0; }

void hsb_tests_begin(void)
{
	g_qp_own = 0;
	if (!g_dp_on) return;
	dp_stop();
	DP_VP_MASK &= ~1u;
	xil_printf("(hsb: data plane stopped for the test; the host has to configure it again)\r\n");
}

static int hsb_start(void)
{
	/* the time base is started by plat_init() */
#if defined(PLAT_LINUX)
	if (hsb_net_open() != 0) return -1;
#endif
	make_serial();
	regs_clear();
	g_latched = 0;
	g_req = g_rep = g_err = g_seqerr = g_resets = 0;
	g_start_pending = 0;
	g_ka_to = g_ka_ms = g_wd_n = g_lp_n = 0;
	g_lp = 0;
#if !defined(PLAT_LINUX)
	cfg_set(RSYS_C_CRX_CTRL, 0);                    /* flush: re-enable below */
	while (sv(RSYS_S_CRX_STATUS) & 0xFF) cfg_set(RSYS_C_CRX_POP, 1);
	eng_ctrl_set(ROCELET_CTRL_OTHER_RX_EN_MASK, 0);
	cfg_set(RSYS_C_CRX_CTRL, 1);
#endif
	g_t_on = g_t_ms = now_ticks();
	g_t_bootp = g_t_on - TICKS_S;                   /* first BOOTP now */
	g_on = 1;
	return 0;
}

static void hsb_status(void)
{
	xil_printf("HSB %s | UUID 98183d0f-18ee-4719-a3b4-ca69e9b94c97, HSB IP version 0x%04x, compat 0x%04x, serial ",
		   g_on ? "on" : "off", HSB_IP_VERSION, HSB_COMPAT_ID);
	pr_serial(); xil_printf("%s | ip ", g_serial_hw ? " (DNA)" : " (MAC)"); pr_ip(MY_IP);
	xil_printf(" mac "); pr_mac(MY_MAC); xil_printf("\r\n");
	xil_printf("enumeration: %u BOOTP sent | register protocol: %u requests, %u replies, %u errors (last status 0x%02x),"
		   " %u sequence errors, latched sequence 0x%04x | set-ip %u\r\n", g_bootp_n, g_req, g_rep, g_err, g_last_st,
		   g_seqerr, g_latched, g_setip);
	if (g_req) { xil_printf("last host "); pr_ip(g_last_ip); xil_printf(":%u mac ", g_last_port); pr_mac(g_last_mac); xil_printf("\r\n"); }
#if defined(PLAT_LINUX)
	hsb_net_status();
#else
	u32 cs = sv(RSYS_S_CRX_STATUS);
	xil_printf("receive FIFO: %u queued | frames %u, dropped full %u, dropped long %u, not matching %u\r\n", cs & 0xFF,
		   cnt(RSYS_E_CRX_FRAMES), cnt(RSYS_E_CRX_DROP), cnt(RSYS_E_CRX_LONG), cnt(RSYS_E_CRX_FILT));
#endif
	xil_printf("registers: reset 0x%x 0x%x (%u HSB resets) | PTP", r_rst[0], r_rst[1], g_resets);
	for (int i = 1; i < 8; i++) xil_printf(" %x", r_ptp[i]);
	xil_printf(" | events");
	for (int i = 0; i < 13; i++) xil_printf(" %x", r_evt[i]);
	int nz = 0;
	for (int i = 0; i < 1024; i++) if (r_apb[i]) nz++;
	xil_printf(" | APB RAM %d non-zero words\r\n", nz);
	xil_printf("data plane 0 (0x02000300): PACKET_SIZE %u (x128 B) UDP_PORT %u VP_MASK 0x%x | sensor 0 (0x1000):",
		   DP_PACKET_SIZE, DP_PACKET_PORT, DP_VP_MASK);
	for (int i = 0; i < 14; i++) xil_printf(" %x", r_vp[i]);
	xil_printf("\r\nSIF");
	for (int i = 0; i < 16; i++) xil_printf(" %x", r_sif[i]);
	xil_printf(" | Opsero: source %s, rate %u Mb/s, scene %u\r\n", src_name(r_ops[1]), r_ops[2], r_ops[3]);
	/* C_BM_SCENE_ID is the staging register: it keeps the id last written, so after its APPLY it equals the
	 * active id (B5 showed "staged id N" = active after every run). Show it only while it means something:
	 * an APPLY not yet active, or an id written without an APPLY. */
	u32 bs = sv(RSYS_S_BM_STATUS), aid = sv(RSYS_S_BM_APPLIED_ID), sid = cfg_get(RSYS_C_BM_SCENE_ID);
	xil_printf("beam: scene %u active since frame %u (%u applies)%s%s", aid, sv(RSYS_S_BM_APPLIED_FRAME),
		   sv(RSYS_S_BM_APPLIES), (bs & 2) ? ", running" : "", (bs & 4) ? ", CLIPPED" : "");
	if (bs & 1) xil_printf(", APPLY pending (scene %u)", sid);
	else if (sid != aid) xil_printf(", scene %u staged without APPLY", sid);
	else xil_printf(", nothing staged");
	xil_printf("\r\n");
	u32 hs = sv(RSYS_S_HP_STATUS), pg = sv(RSYS_S_HP_PAGE);
	xil_printf("producer: %s, %u frames this run, page %u, next frame number %u, ", (hs & 1) ? "running" : "idle",
		   sv(RSYS_S_HP_FRAMES), pg & 0xFFF, pg >> 16);
	pr_u64(bc(RSYS_B_HP_BYTES)); xil_printf(" B, IQ waits "); pr_u64(bc(RSYS_B_HP_IQ_STALL));
	xil_printf(" clocks | QP %d status 0x%08x | time %u.%09u s\r\n", hsb_qp(), eng_qp_status(hsb_qp()),
		   sv(RSYS_S_TIME_S), sv(RSYS_S_TIME_NS));
	u32 es = eng_rd(ROCELET_STATUS);
	xil_printf("watchdog: keepalive timeout %u ms%s, %u ms since the last keepalive, %u stops | link pause %s%s, %u pauses"
		   " | link %s, ACK hold %s\r\n", g_ka_to, g_ka_to ? "" : " (off)", g_ka_ms, g_wd_n, g_lp_en ? "on" : "off",
		   g_lp ? " (PAUSED)" : "", g_lp_n, (es & ROCELET_STATUS_LINK_UP_MASK) ? "up" : "DOWN",
		   (es & ROCELET_STATUS_TIMER_HOLD_MASK) ? "on" : "off");
	if (g_dp_on) {
		/* what dp_start() gave the engine and the producer ('qp <n>' shows the console's own records) */
		u32 pk = cfg_get(RSYS_C_HP_PAGES);
		xil_printf("data plane -> QP %d: UC-HSB, host QPN 0x%x ", hsb_qp(), DP_QP & 0xFFFFFF); pr_ip(DP_HOST_IP);
		xil_printf(":%u, PMTU %u, R_Key 0x%x, VA ", DP_HOST_PORT & 0xFFFF, 1u << dp_pmtu(), cfg_get(RSYS_C_HP_RKEY));
		pr_hex64(((u64)cfg_get(RSYS_C_HP_VA_HI) << 32) | cfg_get(RSYS_C_HP_VA_LO));
		xil_printf(", stride %u, pages %u..%u, frame %u B, period %u clocks\r\n", cfg_get(RSYS_C_HP_STRIDE),
			   pk >> 16, pk & 0xFFF, cfg_get(RSYS_C_HP_FRAME), cfg_get(RSYS_C_HP_PERIOD));
	}
}

void hsb_cmd(char **argv, int argc)
{
	const char *a = argc > 1 ? argv[1] : "st";
	if (!strcmp(a, "on")) {
		if (!ENG.hsb) { xil_printf("this engine was built without HSB_EN\r\n"); return; }
		if (hsb_start() != 0) { xil_printf("error: HSB not started (control-plane sockets)\r\n"); return; }
		xil_printf("ok HSB on: BOOTP every second from ");
		pr_ip(MY_IP); xil_printf(", register protocol on UDP 8192, serial "); pr_serial(); xil_printf("\r\n");
	} else if (!strcmp(a, "off")) {
		if (g_dp_on) dp_stop();
#if defined(PLAT_LINUX)
		hsb_net_close();
#else
		cfg_set(RSYS_C_CRX_CTRL, 0);
		eng_ctrl_set(0, ROCELET_CTRL_OTHER_RX_EN_MASK);
#endif
		g_on = 0;
		xil_printf("ok HSB off\r\n");
	} else if (!strcmp(a, "serial")) {
		make_serial();
		xil_printf("device DNA %s 0x%08x_%08x_%08x -> HSB serial ", (sv(RSYS_S_HP_STATUS) & 8u) ? "" : "(not read)",
			   sv(RSYS_S_DNA2), sv(RSYS_S_DNA1), sv(RSYS_S_DNA0));
		pr_serial();
		xil_printf(" (DNA[55:0] xor DNA[95:56]; without a DNA 00 + MAC)\r\n");
	} else if (!strcmp(a, "src") && argc > 2) {
		r_ops[1] = !strcmp(argv[2], "beam") ? 2u : (strcmp(argv[2], "iq") ? 1u : 0u);
		xil_printf("ok source %s (applies at the next data-plane enable)\r\n", src_name(r_ops[1]));
	} else if (!strcmp(a, "rate") && argc > 2) {
		r_ops[2] = arg_u(argv, argc, 2, HSB_RATE_DEF);
		dp_rate();
		xil_printf("ok rate %u Mb/s (0 = no limit; %s)\r\n", r_ops[2], g_dp_on ? "from the next frame" : "at the data-plane enable");
	} else if (!strcmp(a, "wd") && argc > 2) {
		g_ka_to = arg_u(argv, argc, 2, 0);
		g_ka_ms = 0;
		xil_printf("ok keepalive timeout %u ms (0 = off)\r\n", g_ka_to);
	} else if (!strcmp(a, "lpause") && argc > 2) {
		g_lp_en = !strcmp(argv[2], "on");
		xil_printf("ok link pause %s\r\n", g_lp_en ? "on" : "off");
	} else if (!strcmp(a, "scene") && argc > 2) {
		r_ops[3] = arg_u(argv, argc, 2, 1);
		xil_printf("ok IQ16 scene %u (1 survey 2 radar 3 tones 4 noise; next data-plane enable)\r\n", r_ops[3]);
	} else {
		hsb_status();
	}
}
