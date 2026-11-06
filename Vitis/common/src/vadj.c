/*
 * vadj.c - the FMC VADJ rail (plat_vadj_on, plat.h), the same code on the standalone BSP and in
 * the Linux daemon (the I2C transfers come from the platform layer: plat_pi2c_*).
 *
 * VCK190: nothing switches VADJ_FMC on after power-up (register 0x22 of the IR38164 regulator
 * U185 reads 0x00) unless the boot does (u-boot fragment vck190-vadj-bootcmd.cfg). Without
 * it the OP120's LA-pin signals (Si5328 I2C and LOS, QSFP28 control lines, LVCMOS15) are dead and
 * the GT never gets its reference clock. The regulator sits at 0x1E behind the TCA9548 at 0x74
 * (channel 0) on LPD I2C0. Voltage: 1.5 V = the upper end of the VCK190 FMCP1 VADJ range
 * (1.2 / 1.5 V; the OP120 accepts 1.2-3.3 V) and the I/O standard of the design's FMC pins
 * (LVCMOS15, vck190_fmcp1.xdc). The write sequence is AMD's VCK190 1.5 V profile (PetaLinux BSP
 * platform-top.h), as in the 2x-qsfp28-fmc / qsfp28-fmc-zircon designs; VOUT = 0x24:0x25 / 256 V.
 * Other boards: nothing to do.
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#include "xil_types.h"
#include "xil_printf.h"
#include "sleep.h"
#include "board.h"
#include "plat.h"

#if defined(BOARD_VCK190)

#define VADJ_BUS       0xFF020000u          /* LPD I2C0 (PMC MIO 46/47) */
#define VADJ_MUX       0x74u                /* TCA9548 */
#define VADJ_MUX_CH    0x01u                /* channel 0: the power controllers */
#define VADJ_REG       0x1Eu                /* IR38164 (VADJ_FMC) */
#define VADJ_EN        0x22u                /* [7] output on */
#define VADJ_VOUT_HI   0x24u
#define VADJ_VOUT_LO   0x25u

static const u8 vadj_1v5[][2] = {
	{ 0x24, 0x01 }, { 0x25, 0x80 },                 /* VOUT 0x0180 / 256 = 1.5 V */
	{ 0x3A, 0x01 }, { 0x3B, 0xF3 }, { 0x3D, 0x01 }, { 0x3E, 0xF3 },
	{ 0x3F, 0x00 }, { 0x40, 0x00 }, { 0x41, 0x00 }, { 0x42, 0x00 },
	{ 0x22, 0x80 },                                 /* output on, last */
};

int plat_vadj_on(void)
{
	u8 ch = VADJ_MUX_CH, op = 0, hi = 0, lo = 0;
	if (plat_pi2c_write(VADJ_BUS, VADJ_MUX, &ch, 1) != 0) {
		xil_printf("ERROR: VADJ: no answer from the TCA9548 (0x%02x) on LPD I2C0\r\n", VADJ_MUX);
		return -1;
	}
	if (plat_pi2c_read_reg(VADJ_BUS, VADJ_REG, VADJ_EN, &op) != 0 ||
	    plat_pi2c_read_reg(VADJ_BUS, VADJ_REG, VADJ_VOUT_HI, &hi) != 0 ||
	    plat_pi2c_read_reg(VADJ_BUS, VADJ_REG, VADJ_VOUT_LO, &lo) != 0) {
		xil_printf("ERROR: VADJ: no answer from the IR38164 (0x%02x) behind the TCA9548\r\n", VADJ_REG);
		return -1;
	}
	u32 mv = ((((u32)hi << 8) | lo) * 1000u) / 256u;
	if ((op & 0x80u) && hi == vadj_1v5[0][1] && lo == vadj_1v5[1][1]) {
		xil_printf("VADJ_FMC on, %u mV (already enabled)\r\n", mv);
		return 0;
	}
	if (op & 0x80u) xil_printf("VADJ_FMC on at %u mV: setting 1500 mV\r\n", mv);
	for (unsigned i = 0; i < sizeof(vadj_1v5) / sizeof(vadj_1v5[0]); i++) {
		if (plat_pi2c_write(VADJ_BUS, VADJ_REG, vadj_1v5[i], 2) != 0) {
			xil_printf("ERROR: VADJ: IR38164 write 0x%02x failed\r\n", vadj_1v5[i][0]);
			return -1;
		}
	}
	usleep(20000);                                  /* the rail ramps (soft start) */
	if (plat_pi2c_read_reg(VADJ_BUS, VADJ_REG, VADJ_EN, &op) != 0 || !(op & 0x80u))
		xil_printf("WARNING: VADJ: IR38164 reg 0x22 reads 0x%02x after the enable\r\n", op);
	xil_printf("VADJ_FMC enabled: 1500 mV (IR38164 0x%02x behind TCA9548 0x%02x, LPD I2C0)\r\n", VADJ_REG, VADJ_MUX);
	return 0;
}

#else

int plat_vadj_on(void) { return 0; }      /* the board (or its system controller) sets VADJ */

#endif
