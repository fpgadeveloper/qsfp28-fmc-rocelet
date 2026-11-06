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
#include "plat.h"

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
static void mac_lanes_clear(void) { }
#else
/* ------------------------------------------------------------------ */
/* PS targets: resets, link status and the MAC clock state from the    */
/* always-on block (rsys_aon, pl_clk0)                                 */
/*   ZCU106: omac_10g / omac_40g on GTH, GT TXUSRCLK2 = rocelet_sys clock */
/*   VCK190: the hard MRMAC on a GTY quad, configured through its own   */
/*     registers (MRMAC_BASE); rocelet_sys on the free-running engine clock */
/* ------------------------------------------------------------------ */
#if defined(MAC_MRMAC)
#define REFCLK_PLAN  SI5328_OUT_322M266
#define REFCLK_TEXT  "322.265625 MHz"
#define GT_NAME      "GTY quad"
#define CLK_LABEL    "engine clock"
#else
#define REFCLK_PLAN  SI5328_OUT_156M25
#define REFCLK_TEXT  "156.25 MHz"
#define GT_NAME      "GTH"
#define CLK_LABEL    "MAC clock"
#endif
int mac_clk_ok(void)
{
	u32 s = aon_rd(AON_STATUS);
	return (s & AON_ST_ALIVE) && !(aon_rd(AON_CTRL) & (AON_CTRL_MAC_RST | AON_CTRL_SYS_RST));
}
int mac_link_up(void) { return (aon_rd(AON_STATUS) & AON_ST_LINK) && mac_clk_ok(); }

/* wait for the GT's TX side (reset done on every lane) after a GT reset release */
static int gt_wait_tx(void)
{
	for (int i = 0; i < 1000; i++) {
		if ((aon_rd(AON_STATUS) & (AON_ST_TXRDY | AON_ST_ALIVE)) == (AON_ST_TXRDY | AON_ST_ALIVE)) return 0;
		usleep(1000);
	}
	u32 s = aon_rd(AON_STATUS);
	xil_printf("ERROR: GT not ready (status 0x%05x%s%s)\r\n", s, (s & AON_ST_GTPG) ? "" : ", no power-good",
		   (s & AON_ST_LOS) ? ", Si5328 LOS" : "");
	return -1;
}

#if defined(MAC_MRMAC)
/* MRMAC registers, port-0 page (PG314; the mrmac_v3_2 register map). Sequence: the Opsero
 * qsfp28-fmc-zircon mrmac.c (HW-proven at 100G RS-FEC on this board) + the PAUSE registers that
 * the CMAC had as IP parameters / ports (Vivado/src/hdl/mac/mac_mrmac100g.md) */
#define MR_RESET            0x004u   /* [3:0] RX serdes [4] TX serdes [5] RX [6] TX */
#define MR_RESET_ALL        0x7Fu
#define MR_MODE             0x008u
#define MR_MODE_RATE_MASK   0x00000E77u  /* CTL_AXIS_CFG [11:9], CTL_SERDES_WIDTH [6:4], CTL_DATA_RATE [2:0] */
#define MR_MODE_100G_IND384 ((5u << 9) | (6u << 4) | 4u)   /* independent 384-bit, 100G wide, 100G */
#define MR_MODE_TICK_REG    (1u << 30)   /* statistics latched by TICK_REG writes */
#define MR_CFG_TX           0x00Cu   /* 0xC03: enable, FCS insert, IPG 12 */
#define MR_CFG_RX           0x010u   /* 0x33: enable, FCS delete, SFD + preamble check */
#define MR_RX_MTU           0x014u   /* [7:0] min [30:16] max frame length */
#define MR_RX_MAX_LEN       9600u    /* frames with FCS: 9000-byte payloads + headers, as the omac / CMAC */
#define MR_TICK             0x02Cu
#define MR_TX_REFRESH8      0x05Cu   /* CTL_TX_PAUSE_REFRESH_TIMER8 [15:0] */
#define MR_TX_QUANTA8       0x070u   /* CTL_TX_PAUSE_QUANTA8 [15:0] */
#define MR_TX_GPP_ETYPE_OP  0x078u   /* opcode [31:16] ethertype [15:0] */
#define MR_TX_GPP_DA        0x07Cu   /* LSB, MSB at +4 */
#define MR_TX_GPP_SA        0x084u
#define MR_RX_FC1           0x09Cu   /* [0] enable GCP [2] enable GPP [4] check ACK */
#define MR_RX_FC1_PAUSE     0x15u
#define MR_RX_FC2           0x0A0u   /* GCP [0] mcast [3] etype [4] opcode, GPP [10] mcast [13] etype [14] opcode */
#define MR_RX_FC2_PAUSE     0x6419u
#define MR_RX_GCP_PCP_TYPE  0x0ACu   /* ethertype GCP [15:0], PCP [31:16] */
#define MR_RX_GCP_OP        0x0B4u   /* opcode max [31:16] min [15:0] */
#define MR_RX_DA_UCAST      0x0B8u
#define MR_RX_DA_MCAST      0x0C0u
#define MR_FEC_CFG1         0x0D0u   /* CTL_FEC_MODE [3:0], CTL_TX_FEC_FOUR_LANE_PMD [12] */
#define MR_FEC_RS528        0x1008u  /* RS(528,514) CL91 "KR4" (mrmac_v3_2's 100G CAUI-4 value) */
#define MR_FEC_OFF          0x0000u
#define MR_RX_RT_STATUS     0x74Cu   /* [0] status [1] block lock [2] aligned [5] hi BER [6] RF [7] LF */
#define MR_RX_FEC_RT_STATUS 0x788u   /* [0] aligned [1] hi SER [7:4] lane lock */

static u8  g_sa[6] = { 0x02, 0x0a, 0x35, 0x72, 0x6c, 0x01 };   /* PAUSE source = the port's MAC */
static u32 g_quanta = 0x100, g_refresh = 0x80;
static int g_gt_loop;                       /* the GT loopback of the last GT reset */

static inline u32  mr_rd(u32 off)        { return Xil_In32(MRMAC_BASE + off); }
static inline void mr_wr(u32 off, u32 v) { Xil_Out32(MRMAC_BASE + off, v); }
/* a 48-bit address register pair, the address's first byte in the MSB word (CMAC convention) */
static void mr_wr_mac(u32 off, const u8 *m)
{
	mr_wr(off, ((u32)m[2] << 24) | ((u32)m[3] << 16) | ((u32)m[4] << 8) | m[5]);
	mr_wr(off + 4u, ((u32)m[0] << 8) | m[1]);
}

/* 802.3x PAUSE: transmit quanta / refresh, frame fields, receive recognition (as the CMAC's
 * ctl_rx_pause did: GCP + GPP enabled and checked for the multicast DA, ethertype, opcode). The
 * enables themselves are the adapter's ports (mac_ctl [6] / [7]) */
static void mr_pause_cfg(void)
{
	static const u8 pause_da[6] = { 0x01, 0x80, 0xC2, 0x00, 0x00, 0x01 };
	int rx = (g_mac_ctl & MC_PAUSE_RX) != 0;
	mr_wr(MR_TX_QUANTA8, g_quanta & 0xFFFFu);
	mr_wr(MR_TX_REFRESH8, g_refresh & 0xFFFFu);
	mr_wr(MR_TX_GPP_ETYPE_OP, 0x00018808u);
	mr_wr_mac(MR_TX_GPP_DA, pause_da);
	mr_wr_mac(MR_TX_GPP_SA, g_sa);
	mr_wr(MR_RX_GCP_PCP_TYPE, (mr_rd(MR_RX_GCP_PCP_TYPE) & 0xFFFF0000u) | 0x8808u);
	mr_wr(MR_RX_GCP_OP, 0x00010001u);
	mr_wr_mac(MR_RX_DA_MCAST, pause_da);
	mr_wr_mac(MR_RX_DA_UCAST, g_sa);
	mr_wr(MR_RX_FC2, rx ? MR_RX_FC2_PAUSE : 0);
	mr_wr(MR_RX_FC1, rx ? MR_RX_FC1_PAUSE : 0);
}

/* MAC reset + full MRMAC configuration (the zircon mrmac_port_init order); a changed GT loopback
 * (C_MAC_CTL [10:8] -> the quad's chN_loopback) first re-initialises the GT with it */
static void mac_reset_pulse(void)
{
	u32 c = aon_rd(AON_CTRL) & ~(AON_CTRL_GT_RST | AON_CTRL_MAC_RST);
	int loop = mac_clk_ok() ? (int)((cfg_get(RSYS_C_MAC_CTL) >> MC_LOOP_SH) & 7u) : g_gt_loop;
	aon_wr(AON_CTRL, c | AON_CTRL_MAC_RST);         /* the adapter holds the MRMAC core / serdes resets */
	if (loop != g_gt_loop) {
		aon_wr(AON_CTRL, c | AON_CTRL_MAC_RST | AON_CTRL_GT_RST);
		usleep(1000);
		aon_wr(AON_CTRL, c | AON_CTRL_MAC_RST);
		gt_wait_tx();
		g_gt_loop = loop;
	}
	mr_wr(MR_RESET, mr_rd(MR_RESET) | MR_RESET_ALL);
	usleep(1000);
	mr_wr(MR_MODE, (mr_rd(MR_MODE) & ~MR_MODE_RATE_MASK) | MR_MODE_100G_IND384 | MR_MODE_TICK_REG);
	mr_wr(MR_FEC_CFG1, (mr_rd(MR_FEC_CFG1) & ~0x1FFFu) | ((g_mac_ctl & MC_RSFEC) ? MR_FEC_RS528 : MR_FEC_OFF));
	{
		u32 mtu = mr_rd(MR_RX_MTU);
		if (((mtu >> 16) & 0x7FFFu) < MR_RX_MAX_LEN) mr_wr(MR_RX_MTU, (mtu & 0x8000FFFFu) | (MR_RX_MAX_LEN << 16));
	}
	mr_pause_cfg();
	mr_wr(MR_RESET, mr_rd(MR_RESET) & ~MR_RESET_ALL);
	aon_wr(AON_CTRL, c);
	usleep(1000);
	/* written whole: 0x3 alone would zero the TX IPG / the RX SFD + preamble checks */
	mr_wr(MR_CFG_TX, 0xC02u | ((g_mac_ctl & MC_TX_EN) ? 1u : 0u));
	mr_wr(MR_CFG_RX, 0x032u | ((g_mac_ctl & MC_RX_EN) ? 1u : 0u));
	mr_wr(MR_TICK, 1);
}
#else
/* the omac reset alone: the GT keeps running (its user clock too); a GT reset is
 * needed only when the reference clock changed (mac_hw_start) */
static void mac_reset_pulse(void)
{
	u32 c = aon_rd(AON_CTRL);
	aon_wr(AON_CTRL, c | AON_CTRL_MAC_RST);
	usleep(1000);
	aon_wr(AON_CTRL, c & ~AON_CTRL_MAC_RST);
}
#endif
/* hold GT + MAC in reset while the reference clock is programmed */
static void mac_hw_init(void) { aon_wr(AON_CTRL, AON_CTRL_QSFP_DFLT | AON_CTRL_GT_RST | AON_CTRL_MAC_RST); }
/* the reference clock runs: release the GT, wait for its TX side, then the MAC */
static int mac_hw_start(void)
{
	aon_wr(AON_CTRL, AON_CTRL_QSFP_DFLT | AON_CTRL_MAC_RST);
	if (gt_wait_tx() != 0) return -1;
#if defined(MAC_MRMAC)
	g_gt_loop = (int)((cfg_get(RSYS_C_MAC_CTL) >> MC_LOOP_SH) & 7u);   /* applied by that GT reset */
#endif
	aon_wr(AON_CTRL, AON_CTRL_QSFP_DFLT);
	usleep(2500);                               /* the clock meter integrates over 1 ms */
	xil_printf(GT_NAME " ready: " CLK_LABEL " %u kHz\r\n", aon_rd(AON_MAC_KHZ));
	return 0;
}
static u32  mac_io(void) { return aon_rd(AON_STATUS); }
static int  qsfp_absent(void) { return (aon_rd(AON_STATUS) & AON_ST_MODPRSL) != 0; }
#define IO_NAME "status"
static void lane_bits(const char *name, u32 v)
{
	xil_printf(" %s ", name);
	for (int l = 0; l < 4; l++) xil_printf("%u", (v >> l) & 1u);
}
#if defined(MAC_MRMAC)
/* MRMAC receive state: PCS lane block lock (20 virtual lanes), RS-FEC lane lock per physical
 * (QSFP) lane, FEC alignment (always-on LANE_STAT), the MRMAC's live status registers */
static void mac_lanes(void)
{
	u32 ls = aon_rd(AON_LANE_STAT);
	xil_printf("  PCS lanes 0-19 block lock 0x%05x |", (ls >> 8) & 0xFFFFFu);
	lane_bits("RS-FEC lane lock 0-3", ls);
	xil_printf(" aligned %u mapping %u | MRMAC RX status 0x%02x FEC cfg 0x%04x status 0x%02x | RX overflow %u\r\n",
		   (ls >> 6) & 1u, (ls >> 4) & 3u, mr_rd(MR_RX_RT_STATUS) & 0xFFu, mr_rd(MR_FEC_CFG1) & 0x1FFFu,
		   mr_rd(MR_RX_FEC_RT_STATUS) & 0xFFu, aon_rd(AON_RX_OVF));
}
#else
/* omac_40g: per-lane receive state (always-on block, readable while the MAC clock is
 * stopped too). Bring-up order: block lock per lane (bit order / polarity), alignment-marker
 * lock per lane, all lanes aligned (STATUS block lock) with the partner's lane order and the
 * skew, then BIP errors per lane (signal integrity) */
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
#endif
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
#if defined(HAS_VADJ)
	if (plat_vadj_on() != 0) xil_printf("WARNING: FMC VADJ not confirmed on: the Si5328 may not answer\r\n");
#endif
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
		mac_lanes();
		return -1;
	}
	xil_printf("Port 0: link up, %u Gb/s, %s %s, loopback %s (%d ms)\r\n", LINK_GBPS, HAS_FEC ? "RS-FEC" : "FEC",
		   fec ? "on" : (HAS_FEC ? "off" : "none"), loop_name(loop), ms);
	mac_lanes();
	mac_lanes_clear();          /* lane error counts from here on = errors on the running link */
	return 0;
}

void mac_pause(int rx, int tx, u32 quanta, u32 refresh)
{
	g_mac_ctl = (g_mac_ctl & ~(MC_PAUSE_RX | MC_PAUSE_TX)) | (rx ? MC_PAUSE_RX : 0) | (tx ? MC_PAUSE_TX : 0);
#if defined(MAC_MRMAC)
	g_quanta = quanta;
	g_refresh = refresh;
	mr_pause_cfg();                             /* MRMAC registers (control clock, always accessible) */
#endif
	if (!mac_clk_ok()) return;
	cfg_set(RSYS_C_MAC_PZ, (quanta & 0xFFFF) | ((refresh & 0xFFFF) << 16));
	cfg_set(RSYS_C_MAC_CTL, g_mac_ctl);
}

void mac_set_addr(const u8 *m)
{
#if defined(MAC_MRMAC)
	for (int i = 0; i < 6; i++) g_sa[i] = m[i];
	mr_pause_cfg();
#endif
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
#if defined(HAS_AON)
	xil_printf(" | " CLK_LABEL " %u kHz", aon_rd(AON_MAC_KHZ));
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
