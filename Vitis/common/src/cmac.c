/*
 * cmac.c - 100G CMAC on QSFP28 port 0 (see cmac.h).
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#include "xil_printf.h"
#include "sleep.h"
#include "hw.h"
#include "util.h"
#include "si5328.h"
#include "cmac.h"

/* C_MAC_CTL bits */
#define MC_RX_EN     (1u << 0)
#define MC_TX_EN     (1u << 1)
#define MC_RSFEC     (1u << 5)
#define MC_PAUSE_RX  (1u << 6)
#define MC_PAUSE_TX  (1u << 7)
#define MC_LOOP_SH   8

static u32 g_mac_ctl = MC_RX_EN | MC_TX_EN | MC_RSFEC;   /* what the firmware wants */

const char *loop_name(int loop)
{
	return loop == LOOP_PCS ? "GT near-end PCS" : loop == LOOP_PMA ? "GT near-end PMA" : "off (external)";
}

int cmac_clk_ok(void) { return !(Xil_In32(GPIO_IN) & (1u << 2)); }

int cmac_link_up(void)
{
	if (!(Xil_In32(GPIO_IN) & (1u << 4)) || !cmac_clk_ok()) return 0;
	return (sv(RSYS_S_MAC_STAT) & 3u) == 3u;
}

int cmac_fec(void)  { return (g_mac_ctl & MC_RSFEC) != 0; }
int cmac_loop(void) { return (int)((g_mac_ctl >> MC_LOOP_SH) & 7u); }

static void cmac_reset_pulse(void)
{
	Xil_Out32(GPIO_OUT, GPIO_OUT_DFLT | GPIO_CMAC_RST);
	usleep(1000);
	Xil_Out32(GPIO_OUT, GPIO_OUT_DFLT);
}

static int wait_clk(int ms)
{
	for (int i = 0; i < ms; i++) {
		if (cmac_clk_ok()) return 1;
		usleep(1000);
	}
	return cmac_clk_ok();
}

/* write the wanted configuration while the user clock runs; 1 if it changed */
static int apply_cfg(void)
{
	if (!cmac_clk_ok()) return 0;
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
	cmac_reset_pulse();
	if (!wait_clk(1000)) {
		xil_printf("CMAC: user clock not running after reset (GT reference clock?)\r\n");
		return -1;
	}
	if (apply_cfg()) {          /* RS-FEC / loopback changed: reset again with it applied */
		cmac_reset_pulse();
		wait_clk(1000);
	}
	for (t = 0; t < 100; t++) {
		usleep(100000);
		if (cmac_link_up()) break;
		if (t % 10 == 9) {
			cmac_reset_pulse();
			wait_clk(1000);
		}
	}
	return cmac_link_up() ? t * 100 : -1;
}

int cmac_bringup(int fec, int loop)
{
	Xil_Out32(GPIO_OUT, GPIO_OUT_DFLT);
	if (si5328_init(IIC_CLK_BASE, SI5328_OUT_322M266) != 0) {
		xil_printf("ERROR: Si5328 programming failed - no GT reference clock\r\n");
		return -1;
	}
	xil_printf("Si5328 programmed: GT reference clock 322.265625 MHz\r\n");
	usleep(20000);
	return cmac_relink(fec, loop);
}

int cmac_relink(int fec, int loop)
{
	g_mac_ctl = (g_mac_ctl & ~(MC_RSFEC | (7u << MC_LOOP_SH))) | (fec ? MC_RSFEC : 0) |
		    ((u32)(loop & 7) << MC_LOOP_SH);
	int ms = link_loop();
	if (ms < 0) {
		xil_printf("Port 0: link DOWN (RS-FEC %s, loopback %s, GPIO 0x%02x)\r\n", fec ? "on" : "off",
			   loop_name(loop), Xil_In32(GPIO_IN));
		return -1;
	}
	xil_printf("Port 0: link up, 100 Gb/s, RS-FEC %s, loopback %s (%d ms)\r\n", fec ? "on" : "off",
		   loop_name(loop), ms);
	return 0;
}

void cmac_pause(int rx, int tx, u32 quanta, u32 refresh)
{
	g_mac_ctl = (g_mac_ctl & ~(MC_PAUSE_RX | MC_PAUSE_TX)) | (rx ? MC_PAUSE_RX : 0) | (tx ? MC_PAUSE_TX : 0);
	if (!cmac_clk_ok()) return;
	cfg_set(RSYS_C_MAC_PZ, (quanta & 0xFFFF) | ((refresh & 0xFFFF) << 16));
	cfg_set(RSYS_C_MAC_CTL, g_mac_ctl);
}

void cmac_status(void)
{
	u32 g = Xil_In32(GPIO_IN);
	xil_printf("link %s | RS-FEC %s | loopback %s | QSFP module %s | GPIO 0x%02x",
		   cmac_link_up() ? "UP" : "DOWN", cmac_fec() ? "on" : "off", loop_name(cmac_loop()),
		   (g & 1) ? "absent" : "present", g);
	if (!cmac_clk_ok()) { xil_printf(" | CMAC user clock stopped\r\n"); return; }
	u32 s = sv(RSYS_S_MAC_STAT);
	xil_printf(" | stat 0x%03x%s%s%s%s\r\n", s, (s & 4) ? " local-fault" : "", (s & 8) ? " remote-fault" : "",
		   (s & 0x40) ? " hi-BER" : "", (s & 0x100) ? " FEC-hi-SER" : "");
	xil_printf("  CMAC rx frames "); pr_u64(bc(RSYS_B_MAC_RX_PKTS));
	xil_printf(" bad FCS "); pr_u64(bc(RSYS_B_MAC_RX_BAD_FCS));
	xil_printf(" bad code "); pr_u64(bc(RSYS_B_MAC_RX_BAD_CODE));
	xil_printf(" | tx frames "); pr_u64(bc(RSYS_B_MAC_TX_PKTS));
	xil_printf(" | RS-FEC corrected %u uncorrected %u | link drops %u | TX underflow %u\r\n",
		   eng_rd(ROCELET_CNT_RSFEC_CORR), eng_rd(ROCELET_CNT_RSFEC_UNCORR), cnt(RSYS_E_MAC_ALIGN_LOST),
		   cnt(RSYS_E_MAC_TX_UNF));
}
