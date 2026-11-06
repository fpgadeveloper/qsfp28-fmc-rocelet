/*
 * mac.c - the Ethernet MAC on QSFP28 port 0 (see mac.h).
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#include "xil_printf.h"
#include "sleep.h"
#include "hw.h"
#include "util.h"
#include "si5328.h"
#include "mac.h"

/* C_MAC_CTL bits */
#define MC_RX_EN     (1u << 0)
#define MC_TX_EN     (1u << 1)
#define MC_RSFEC     (1u << 5)
#define MC_PAUSE_RX  (1u << 6)
#define MC_PAUSE_TX  (1u << 7)
#define MC_LOOP_SH   8

#if HAS_FEC
static u32 g_mac_ctl = MC_RX_EN | MC_TX_EN | MC_RSFEC;   /* what the firmware wants */
#else
static u32 g_mac_ctl = MC_RX_EN | MC_TX_EN;
#endif

const char *loop_name(int loop)
{
	return loop == LOOP_PCS ? "GT near-end PCS" : loop == LOOP_PMA ? "GT near-end PMA" : "off (external)";
}

int mac_fec(void)  { return (g_mac_ctl & MC_RSFEC) != 0; }
int mac_loop(void) { return (int)((g_mac_ctl >> MC_LOOP_SH) & 7u); }

#if defined(MAC_CMAC)
/* ------------------------------------------------------------------ */
/* KCU116: 100G CMAC, reset and status through the QSFP0 GPIO           */
/* ------------------------------------------------------------------ */
#define REFCLK_PLAN  SI5328_OUT_322M266
#define REFCLK_TEXT  "322.265625 MHz"
static u32  gpio_in(void) { return Xil_In32(GPIO_IN); }
int mac_clk_ok(void) { return !(gpio_in() & (1u << 2)); }
int mac_link_up(void)
{
	if (!(gpio_in() & (1u << 4)) || !mac_clk_ok()) return 0;
	return (sv(RSYS_S_MAC_STAT) & 3u) == 3u;
}
static void mac_reset_pulse(void)
{
	Xil_Out32(GPIO_OUT, GPIO_OUT_DFLT | GPIO_CMAC_RST);
	usleep(1000);
	Xil_Out32(GPIO_OUT, GPIO_OUT_DFLT);
}
static void mac_hw_init(void) { Xil_Out32(GPIO_OUT, GPIO_OUT_DFLT); }
static int  mac_hw_start(void) { return 0; }
static u32  mac_io(void) { return gpio_in(); }
static int  qsfp_absent(void) { return gpio_in() & 1u; }
#define IO_NAME "GPIO"
static void mac_lanes(void) { }           /* one MAC, no lane status */
#else
/* ------------------------------------------------------------------ */
/* ZCU106: omac_10g on a GTH, resets and status in the always-on block  */
/* ------------------------------------------------------------------ */
#define REFCLK_PLAN  SI5328_OUT_156M25
#define REFCLK_TEXT  "156.25 MHz"
int mac_clk_ok(void)
{
	u32 s = aon_rd(AON_STATUS);
	return (s & AON_ST_ALIVE) && !(aon_rd(AON_CTRL) & (AON_CTRL_MAC_RST | AON_CTRL_SYS_RST));
}
int mac_link_up(void) { return (aon_rd(AON_STATUS) & AON_ST_LINK) && mac_clk_ok(); }
/* the omac reset alone: the GT keeps running (its user clock too); a GT reset is
 * needed only when the reference clock changed (mac_hw_start) */
static void mac_reset_pulse(void)
{
	u32 c = aon_rd(AON_CTRL);
	aon_wr(AON_CTRL, c | AON_CTRL_MAC_RST);
	usleep(1000);
	aon_wr(AON_CTRL, c & ~AON_CTRL_MAC_RST);
}
/* hold GT + MAC in reset while the reference clock is programmed */
static void mac_hw_init(void) { aon_wr(AON_CTRL, AON_CTRL_QSFP_DFLT | AON_CTRL_GT_RST | AON_CTRL_MAC_RST); }
/* the reference clock runs: release the GT, wait for its TX user clock, then the MAC */
static int mac_hw_start(void)
{
	aon_wr(AON_CTRL, AON_CTRL_QSFP_DFLT | AON_CTRL_MAC_RST);
	for (int i = 0; i < 1000; i++) {
		if ((aon_rd(AON_STATUS) & (AON_ST_TXRDY | AON_ST_ALIVE)) == (AON_ST_TXRDY | AON_ST_ALIVE)) break;
		usleep(1000);
	}
	u32 s = aon_rd(AON_STATUS);
	if (!(s & AON_ST_TXRDY)) {
		xil_printf("ERROR: GT not ready (status 0x%05x%s%s)\r\n", s, (s & AON_ST_GTPG) ? "" : ", no power-good",
			   (s & AON_ST_LOS) ? ", Si5328 LOS" : "");
		return -1;
	}
	aon_wr(AON_CTRL, AON_CTRL_QSFP_DFLT);
	usleep(2500);                               /* the clock meter integrates over 1 ms */
	xil_printf("GTH ready: MAC clock %u kHz\r\n", aon_rd(AON_MAC_KHZ));
	return 0;
}
static u32  mac_io(void) { return aon_rd(AON_STATUS); }
static int  qsfp_absent(void) { return (aon_rd(AON_STATUS) & AON_ST_MODPRSL) != 0; }
#define IO_NAME "status"
/* omac_40g: per-lane receive state (always-on block, readable while the MAC clock is
 * stopped too). Bring-up order: block lock per lane (bit order / polarity), alignment-marker
 * lock per lane, all lanes aligned (STATUS block lock) with the partner's lane order and the
 * skew, then BIP errors per lane (signal integrity) */
static void lane_bits(const char *name, u32 v)
{
	xil_printf(" %s ", name);
	for (int l = 0; l < 4; l++) xil_printf("%u", (v >> l) & 1u);
}
static void mac_lanes(void)
{
	if (!MAC_IS_40G) return;
	u32 ls = aon_rd(AON_LANE_STAT);
	xil_printf("  lanes 0-3:");
	lane_bits("block lock", ls);
	lane_bits("| AM lock", ls >> 4);
	xil_printf(" | PCS lane on QSFP lane 0-3:");
	for (int l = 0; l < 4; l++) xil_printf(" %u", (ls >> (8 + 2 * l)) & 3u);
	xil_printf(" | skew %u blocks | BIP errors", (ls >> 16) & 0x7Fu);
	for (int l = 0; l < 4; l++) xil_printf(" %u", aon_rd(AON_LANE_BIP(l)));
	xil_printf(" | skew fails %u | RX overflow %u\r\n", aon_rd(AON_SKEW_FAIL), aon_rd(AON_RX_OVF));
}
static void mac_lanes_clear(void) { aon_wr(AON_LANE_STAT, 0); }
#endif

static int wait_clk(int ms)
{
	for (int i = 0; i < ms; i++) {
		if (mac_clk_ok()) return 1;
		usleep(1000);
	}
	return mac_clk_ok();
}

/* write the wanted configuration while the user clock runs; 1 if it changed */
static int apply_cfg(void)
{
	if (!mac_clk_ok()) return 0;
	u32 cur = cfg_get(RSYS_C_MAC_CTL);
	if (cur == g_mac_ctl) return 0;
	cfg_set(RSYS_C_MAC_CTL, g_mac_ctl);
	return 1;
}

/* reset, configure, and wait up to 10 s for alignment, re-resetting about once a
 * second: the GT does not re-align on a partner (or reference clock) that came up
 * after its last reset */
static int link_loop(void)
{
	int t;
	mac_reset_pulse();
	if (!wait_clk(1000)) {
		xil_printf("%s: user clock not running after reset (GT reference clock?)\r\n", MAC_NAME);
		return -1;
	}
	if (apply_cfg()) {          /* FEC / loopback changed: reset again with it applied */
		mac_reset_pulse();
		wait_clk(1000);
	}
	for (t = 0; t < 100; t++) {
		usleep(100000);
		if (mac_link_up()) break;
		if (t % 10 == 9) {
			mac_reset_pulse();
			wait_clk(1000);
		}
	}
	return mac_link_up() ? t * 100 : -1;
}

int mac_bringup(int fec, int loop)
{
	mac_hw_init();
	if (si5328_init(IIC_CLK_BASE, REFCLK_PLAN) != 0) {
		xil_printf("ERROR: Si5328 programming failed - no GT reference clock\r\n");
		return -1;
	}
	xil_printf("Si5328 programmed: GT reference clock " REFCLK_TEXT "\r\n");
	usleep(20000);
	if (mac_hw_start() != 0) return -1;
	return mac_relink(fec, loop);
}

int mac_relink(int fec, int loop)
{
#if !HAS_FEC
	fec = 0;
	if (loop == LOOP_PCS) loop = LOOP_PMA;      /* omac: GT loopback is near-end PMA */
#endif
	g_mac_ctl = (g_mac_ctl & ~(MC_RSFEC | (7u << MC_LOOP_SH))) | (fec ? MC_RSFEC : 0) |
		    ((u32)(loop & 7) << MC_LOOP_SH);
	int ms = link_loop();
	if (ms < 0) {
		xil_printf("Port 0: link DOWN (%s %s, loopback %s, " IO_NAME " 0x%02x)\r\n", HAS_FEC ? "RS-FEC" : "FEC",
			   fec ? "on" : "off", loop_name(loop), mac_io());
#if defined(MAC_OMAC)
		mac_lanes();
#endif
		return -1;
	}
	xil_printf("Port 0: link up, %u Gb/s, %s %s, loopback %s (%d ms)\r\n", LINK_GBPS, HAS_FEC ? "RS-FEC" : "FEC",
		   fec ? "on" : (HAS_FEC ? "off" : "none"), loop_name(loop), ms);
#if defined(MAC_OMAC)
	mac_lanes();
	mac_lanes_clear();          /* lane error counts from here on = errors on the running link */
#endif
	return 0;
}

void mac_pause(int rx, int tx, u32 quanta, u32 refresh)
{
	g_mac_ctl = (g_mac_ctl & ~(MC_PAUSE_RX | MC_PAUSE_TX)) | (rx ? MC_PAUSE_RX : 0) | (tx ? MC_PAUSE_TX : 0);
	if (!mac_clk_ok()) return;
	cfg_set(RSYS_C_MAC_PZ, (quanta & 0xFFFF) | ((refresh & 0xFFFF) << 16));
	cfg_set(RSYS_C_MAC_CTL, g_mac_ctl);
}

void mac_set_addr(const u8 *m)
{
	if (!mac_clk_ok()) return;
	cfg_set(RSYS_C_MAC_ADDR_LO, (u32)m[0] | ((u32)m[1] << 8) | ((u32)m[2] << 16) | ((u32)m[3] << 24));
	cfg_set(RSYS_C_MAC_ADDR_HI, (u32)m[4] | ((u32)m[5] << 8));
}

void mac_status(void)
{
	u32 g = mac_io();
	xil_printf("link %s | %s %s | loopback %s | QSFP module %s | " IO_NAME " 0x%02x", mac_link_up() ? "UP" : "DOWN",
		   HAS_FEC ? "RS-FEC" : "FEC", mac_fec() ? "on" : (HAS_FEC ? "off" : "none"), loop_name(mac_loop()),
		   qsfp_absent() ? "absent" : "present", g);
#if defined(MAC_OMAC)
	xil_printf(" | MAC clock %u kHz", aon_rd(AON_MAC_KHZ));
#endif
	if (!mac_clk_ok()) {
		xil_printf(" | %s user clock stopped\r\n", MAC_NAME);
		mac_lanes();
		return;
	}
	u32 s = sv(RSYS_S_MAC_STAT);
	xil_printf(" | stat 0x%03x%s%s%s%s\r\n", s, (s & 4) ? " local-fault" : "", (s & 8) ? " remote-fault" : "",
		   (s & 0x40) ? " hi-BER" : "", (s & 0x100) ? " FEC-hi-SER" : "");
	xil_printf("  %s rx frames ", MAC_NAME); pr_u64(bc(RSYS_B_MAC_RX_PKTS));
	xil_printf(" bad FCS "); pr_u64(bc(RSYS_B_MAC_RX_BAD_FCS));
	xil_printf(" bad code "); pr_u64(bc(RSYS_B_MAC_RX_BAD_CODE));
	xil_printf(" | tx frames "); pr_u64(bc(RSYS_B_MAC_TX_PKTS));
#if HAS_FEC
	xil_printf(" | RS-FEC corrected %u uncorrected %u", eng_rd(ROCELET_CNT_RSFEC_CORR), eng_rd(ROCELET_CNT_RSFEC_UNCORR));
#endif
	xil_printf(" | link drops %u | TX underflow %u\r\n", cnt(RSYS_E_MAC_ALIGN_LOST), cnt(RSYS_E_MAC_TX_UNF));
	mac_lanes();
}
