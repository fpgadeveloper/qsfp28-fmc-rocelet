/*
 * si5328.c — Program the 2x QSFP28 FMC's Si5328 clock generator
 *
 * Opsero 2x QSFP28 FMC reference design.
 *
 * The Si5328 sources BOTH GT reference clocks: CKOUT1 -> GBTCLK0 (QSFP
 * port 0) and CKOUT2 -> GBTCLK1 (QSFP port 1). Unlike the Quad SFP28 FMC
 * it sits DIRECTLY on the design's clock AXI IIC bus (no PCA9548 mux).
 * This module programs it for FREE-RUN operation from the card's
 * 114.285 MHz crystal, with both outputs at the design's GT refclk:
 *
 *   100G targets (CAUI-4):   322.265625 MHz
 *     f3   = 114285000 / 7619       = 15.000 kHz
 *     fosc = 15000 * (11 * 31250)   = 5156.250 MHz
 *     fout = fosc / (8 * 2)         = 322.265625 MHz
 *     N1_HS = 8, NC1_LS = NC2_LS = 2, N2_HS = 11, N2_LS = 31250, N3 = 7619
 *
 *   40G targets (40GBASE-R4): 156.25 MHz
 *     f3   = 114285000 / 7619       = 15.000 kHz
 *     fosc = 15000 * (10 * 37500)   = 5625.000 MHz
 *     fout = fosc / (9 * 4)         = 156.25 MHz
 *     N1_HS = 9, NC1_LS = NC2_LS = 4, N2_HS = 10, N2_LS = 37500, N3 = 7619
 *
 * Both plans are EXACT and keep the same f3 (15 kHz) as the hardware-proven
 * Quad SFP28 FMC plan, so the same loop bandwidth setting (BWSEL = 6, the
 * value the Xilinx si5324drv uses for all plans) applies. Both outputs are
 * enabled as LVDS with identical output dividers — the same configuration
 * the design's Linux flow programs (see the BSPs'
 * 0001-clk-si5324-enable-ckout2-for-2x-qsfp28-fmc.patch).
 *
 * Register encodings follow the Si5328 datasheet (and the Linux driver):
 * N1_HS/N2_HS are stored as value-4, NC1_LS/NC2_LS/N2_LS/N3 as value-1.
 * The write sequence mirrors the Linux driver's probe + set_rate path,
 * ending with an internal calibration (ICAL) which the device needs to
 * start its outputs.
 */

#include <stdio.h>
#include "xil_printf.h"
#include "xparameters.h"
#include "xiic_l.h"
#include "sleep.h"
#include "si5328.h"

#define SI5328_ADDR         0x68

typedef struct { u8 reg; u8 val; } reg_write_t;

/* Free-run, CKIN2 (XA/XB), CKOUT1 + CKOUT2 enabled (LVDS), common plan */
static const reg_write_t si5328_common_writes[] = {
	{ 0,   0x54 },  /* FREE_RUN = 1 (XA/XB -> CKIN2) */
	{ 2,   0x62 },  /* BWSEL = 6 */
	{ 3,   0x55 },  /* CKSEL_REG = CKIN2, SQ_ICAL = 1 */
	{ 4,   0x12 },  /* AUTOSEL_REG = manual */
	{ 6,   0x3F },  /* SFOUT2 = LVDS, SFOUT1 = LVDS (both outputs used) */
	{ 10,  0x00 },  /* DSBL_CLKOUT2 = 0: CKOUT2 enabled (GBTCLK1, port 1) */
	{ 11,  0x41 },  /* PD_CK1 = 1: power down CKIN1 (free-run uses CKIN2) */
	{ 19,  0x23 },  /* FOS defaults */
	{ 21,  0xFC },  /* CKSEL_PIN = 0: ignore CS_CA pin, select input from
			 * CKSEL_REG. Without this the input selection follows
			 * the (floating/strapped) CS_CA pin and can sit on the
			 * powered-down CKIN1: ICAL never completes and the
			 * outputs stay squelched (no GT refclk). */
	{ 43,  0x00 },  /* N31 = 7619 -> 7618 = 0x001DC2 (CKIN1; unused, legal) */
	{ 44,  0x1D },
	{ 45,  0xC2 },
	{ 46,  0x00 },  /* N32 = 7619 (CKIN2 = XA/XB in free-run: the active input) */
	{ 47,  0x1D },
	{ 48,  0xC2 },
	{ 137, 0x01 },  /* FASTLOCK = 1 */
};

/* 322.265625 MHz: N1_HS=8, NC1_LS=NC2_LS=2, N2_HS=11, N2_LS=31250 */
static const reg_write_t si5328_322m266_writes[] = {
	{ 25,  0x80 },  /* N1_HS  = 8      -> (8-4)<<5 */
	{ 31,  0x00 },  /* NC1_LS = 2      -> 1 = 0x000001 */
	{ 32,  0x00 },
	{ 33,  0x01 },
	{ 34,  0x00 },  /* NC2_LS = 2 (CKOUT2 mirrors CKOUT1) */
	{ 35,  0x00 },
	{ 36,  0x01 },
	{ 40,  0xE0 },  /* N2_HS  = 11     -> (11-4)<<5 ; N2_LS[19:16] = 0 */
	{ 41,  0x7A },  /* N2_LS  = 31250  -> 31249 = 0x007A11 */
	{ 42,  0x11 },
};

/* 156.25 MHz: N1_HS=9, NC1_LS=NC2_LS=4, N2_HS=10, N2_LS=37500 */
static const reg_write_t si5328_156m25_writes[] = {
	{ 25,  0xA0 },  /* N1_HS  = 9      -> (9-4)<<5 */
	{ 31,  0x00 },  /* NC1_LS = 4      -> 3 = 0x000003 */
	{ 32,  0x00 },
	{ 33,  0x03 },
	{ 34,  0x00 },  /* NC2_LS = 4 (CKOUT2 mirrors CKOUT1) */
	{ 35,  0x00 },
	{ 36,  0x03 },
	{ 40,  0xC0 },  /* N2_HS  = 10     -> (10-4)<<5 ; N2_LS[19:16] = 0 */
	{ 41,  0x92 },  /* N2_LS  = 37500  -> 37499 = 0x00927B */
	{ 42,  0x7B },
};

static int si5328_write_table(UINTPTR iic_base, const reg_write_t *t, unsigned int n)
{
	u8 buf[2];
	unsigned int sent, i;

	for (i = 0; i < n; i++) {
		buf[0] = t[i].reg;
		buf[1] = t[i].val;
		sent = XIic_Send(iic_base, SI5328_ADDR, buf, 2, XIIC_STOP);
		if (sent != 2) {
			xil_printf("si5328: write reg %u failed (sent %u)\r\n",
				   t[i].reg, sent);
			return -1;
		}
	}
	return 0;
}

/*
 * Program the Si5328 for the given plan on BOTH outputs.
 * iic_base: base address of the AXI IIC the Si5328 sits on (direct bus).
 * Returns 0 on success, -1 on I2C failure.
 */
int si5328_init(UINTPTR iic_base, int plan)
{
	u8 buf[2];
	unsigned int sent;
	int ret;

	/* Full device reset first (RST_ALL, reg 136 bit 7), as the Linux
	 * clk-si5324 driver does: makes programming deterministic regardless
	 * of prior state (e.g. JTAG re-runs without a power cycle). */
	buf[0] = 136; buf[1] = 0x80;
	sent = XIic_Send(iic_base, SI5328_ADDR, buf, 2, XIIC_STOP);
	if (sent != 2) {
		xil_printf("si5328: device reset write failed (sent %u)\r\n", sent);
		return -1;
	}
	usleep(20000);
	buf[0] = 136; buf[1] = 0x00;
	sent = XIic_Send(iic_base, SI5328_ADDR, buf, 2, XIIC_STOP);
	if (sent != 2) {
		xil_printf("si5328: device reset release failed (sent %u)\r\n", sent);
		return -1;
	}
	usleep(20000);

	ret = si5328_write_table(iic_base, si5328_common_writes,
				 sizeof(si5328_common_writes) / sizeof(reg_write_t));
	if (ret)
		return ret;

	if (plan == SI5328_OUT_156M25)
		ret = si5328_write_table(iic_base, si5328_156m25_writes,
					 sizeof(si5328_156m25_writes) / sizeof(reg_write_t));
	else
		ret = si5328_write_table(iic_base, si5328_322m266_writes,
					 sizeof(si5328_322m266_writes) / sizeof(reg_write_t));
	if (ret)
		return ret;

	/* ICAL: start internal calibration (must be LAST) */
	buf[0] = 136; buf[1] = 0x40;
	sent = XIic_Send(iic_base, SI5328_ADDR, buf, 2, XIIC_STOP);
	if (sent != 2) {
		xil_printf("si5328: ICAL write failed (sent %u)\r\n", sent);
		return -1;
	}

	/* Allow the internal calibration to complete (datasheet: ~1s worst
	 * case for low f3; typically much less). The GTs won't see a stable
	 * refclk until ICAL is done. */
	sleep(1);

	return 0;
}
