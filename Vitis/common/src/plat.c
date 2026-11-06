/*
 * plat.c - platform layer of the rocelet console (see plat.h): the standalone BSPs.
 * The FMC VADJ rail is vadj.c (common to both). The Linux daemon has its own implementation (sw/linux/roceletd/plat_linux.c).
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#include "xparameters.h"
#include "bspconfig.h"
#include "xil_io.h"
#include "board.h"
#include "plat.h"

#if defined(__MICROBLAZE__)
/* ---------------- MicroBlaze: AXI UART 16550, AXI timer ---------------- */
#include "xuartns550_l.h"

#if defined(XPAR_AXI_TIMER_0_BASEADDR)
#define TMR_BASE XPAR_AXI_TIMER_0_BASEADDR
#else
#define TMR_BASE 0x41C00000u
#endif

void plat_init(void)
{
	/* the UART 16550 divisor is not set at reset: program it before the first print */
	XUartNs550_SetBaud(STDOUT_BASEADDRESS, XPAR_AXI_UART16550_0_CLOCK_FREQ, 115200);
	XUartNs550_SetLineControlReg(STDOUT_BASEADDRESS, XUN_LCR_8_DATA_BITS);
	/* 16-byte FIFOs: the console loop also serves the HSB control plane between characters */
	XUartNs550_WriteReg(STDOUT_BASEADDRESS, XUN_FCR_OFFSET, XUN_FIFO_ENABLE | XUN_FIFO_RX_RESET | XUN_FIFO_TX_RESET);
	/* axi_timer_0 counter 0: free-running at 100 MHz (not used by the BSP: sleep is a loop) */
	Xil_Out32(TMR_BASE + 0x4u, 0);                  /* TLR0 */
	Xil_Out32(TMR_BASE + 0x0u, 0x20u);              /* TCSR0: LOAD0 */
	Xil_Out32(TMR_BASE + 0x0u, 0x90u);              /* TCSR0: ENT0 | ARHT0, count up */
}
int  plat_rx_ready(void) { return XUartNs550_IsReceiveData(STDIN_BASEADDRESS) ? 1 : 0; }
char plat_rx_byte(void)  { return (char)XUartNs550_RecvByte(STDIN_BASEADDRESS); }
u32  plat_ticks(void)    { return Xil_In32(TMR_BASE + 0x8u); }
const char *plat_cpu(void) { return "MicroBlaze"; }
int  plat_dna(u32 dna[4]) { (void)dna; return 0; }     /* the PL reads its DNA (rsys_dna) */

#elif defined(__aarch64__) || defined(__arm__)
/* ---------------- Cortex-A53 (ZynqMP) / Cortex-A72 (Versal) standalone: PS UART, generic timer ---------------- */
#include <string.h>
#if defined(BOARD_VCK190)
#include "xuartpsv_hw.h"              /* Versal PS UART = PL011 (uartpsv), not the ZynqMP Cadence UART */
#else
#include "xuartps_hw.h"
#endif
#include "xiltimer.h"                 /* XTime_GetTime, COUNTS_PER_SECOND (SDT BSP) */
#include "xil_cache.h"
#include "xil_printf.h"

#if !defined(STDIN_BASEADDRESS)
#define STDIN_BASEADDRESS 0xFF000000u               /* PS UART0 */
#endif

void plat_init(void)
{
	/* UART0 runs at 115200 8N1 from the FSBL (ZynqMP) / PLM (Versal) and the BSP; nothing else */
}
#if defined(BOARD_VCK190)
int  plat_rx_ready(void) { return XUartPsv_IsReceiveData(STDIN_BASEADDRESS) ? 1 : 0; }
char plat_rx_byte(void)  { return (char)(XUartPsv_ReadReg(STDIN_BASEADDRESS, XUARTPSV_UARTDR_OFFSET) & 0xFFu); }
#else
int  plat_rx_ready(void) { return XUartPs_IsReceiveData(STDIN_BASEADDRESS) ? 1 : 0; }
char plat_rx_byte(void)  { return (char)XUartPs_ReadReg(STDIN_BASEADDRESS, XUARTPS_FIFO_OFFSET); }
#endif
u32  plat_ticks(void)
{
	XTime t;
	XTime_GetTime(&t);
	u64 cps = (u64)COUNTS_PER_SECOND;
	u64 q = t / cps, r = t % cps;
	return (u32)(q * PLAT_TICKS_S + (r * PLAT_TICKS_S) / cps);
}
#if defined(BOARD_VCK190)
const char *plat_cpu(void) { return "Cortex-A72"; }

/* Versal: the 128-bit device DNA in the PMC's eFUSE cache (EFUSE_CACHE DNA_0..3, 0xF125_0020..2C;
 * the rows XilNvm's XNvm_EfuseReadDna returns), read directly: the A72 standalone runs secure
 * (EL3) and the design configures no PMC XPPU protection. Read once */
#define EFUSE_CACHE_DNA0 0xF1250020u
int plat_dna(u32 dna[4])
{
	static u32 d[4];
	static int state;                       /* 0 not read, 1 valid, -1 none */
	if (!state) {
		u32 all = 0, any = 0;
		for (int i = 0; i < 4; i++) { d[i] = Xil_In32(EFUSE_CACHE_DNA0 + 4u * (u32)i); all |= d[i]; any |= ~d[i]; }
		state = (all && any) ? 1 : -1;      /* all zero / all ones: not a DNA */
	}
	if (state < 0) return 0;
	for (int i = 0; i < 4; i++) dna[i] = d[i];
	return 1;
}

/* LPD I2C0 (XIicPs, polled) for vadj.c */
#include "xiicps.h"
static XIicPs g_pi2c;
static UINTPTR g_pi2c_base;
static int pi2c(UINTPTR base)
{
	if (g_pi2c_base == base) return 0;
	XIicPs_Config *c = XIicPs_LookupConfig((u32)base);   /* SDT BSP: looked up by base address */
	if (!c || XIicPs_CfgInitialize(&g_pi2c, c, c->BaseAddress) != XST_SUCCESS) {
		xil_printf("ERROR: PS I2C at 0x%08lx not in the BSP\r\n", (unsigned long)base);
		return -1;
	}
	XIicPs_SetSClk(&g_pi2c, 100000);
	g_pi2c_base = base;
	return 0;
}
int plat_pi2c_write(UINTPTR base, u8 addr, const u8 *buf, unsigned n)
{
	u8 b[8];
	if (n > sizeof(b) || pi2c(base)) return -1;
	for (unsigned i = 0; i < n; i++) b[i] = buf[i];
	int st = XIicPs_MasterSendPolled(&g_pi2c, b, (s32)n, addr);
	while (XIicPs_BusIsBusy(&g_pi2c)) ;
	return st == XST_SUCCESS ? 0 : -1;
}
int plat_pi2c_read_reg(UINTPTR base, u8 addr, u8 reg, u8 *val)
{
	if (pi2c(base)) return -1;
	XIicPs_SetOptions(&g_pi2c, XIICPS_REP_START_OPTION);
	int st = XIicPs_MasterSendPolled(&g_pi2c, &reg, 1, addr);
	XIicPs_ClearOptions(&g_pi2c, XIICPS_REP_START_OPTION);
	if (st == XST_SUCCESS) st = XIicPs_MasterRecvPolled(&g_pi2c, val, 1, addr);
	while (XIicPs_BusIsBusy(&g_pi2c)) ;
	return st == XST_SUCCESS ? 0 : -1;
}
#else
const char *plat_cpu(void) { return "Cortex-A53"; }
int  plat_dna(u32 dna[4]) { (void)dna; return 0; }     /* the PL reads its DNA (rsys_dna) */
#endif

/* PS DDR window: a 1 MB buffer of this program (cached; maintenance in for_cpu / for_dev) */
#define PLAT_DDR_BYTES (1u << 20)
static u8 ddr_buf[PLAT_DDR_BYTES] __attribute__((aligned(4096)));
static int ddr_ok;
/* The C start-up code zeroed the buffer (.bss) through the data cache: write those lines back now,
 * else a dirty line evicted later overwrites what the engine wrote into PS DDR (seen on the bench:
 * the first host WRITE into MR 3 after boot left beat 0 = zeros) */
int  plat_ddr_init(void)
{
#if defined(BOARD_VCK190)
	/* the engine's DDR window masters reach DDR_LOW0 (0..2 GB) only (bd_versal.tcl) */
	if ((u64)(UINTPTR)ddr_buf + PLAT_DDR_BYTES > 0x80000000ull) {
		xil_printf("ERROR: PS DDR window buffer at 0x%x_%08x is above 2 GB (linker script)\r\n",
			   (u32)((u64)(UINTPTR)ddr_buf >> 32), (u32)(UINTPTR)ddr_buf);
		return -1;
	}
#endif
	Xil_DCacheFlushRange((UINTPTR)ddr_buf, PLAT_DDR_BYTES);
	ddr_ok = 1;
	return 0;
}
u64  plat_ddr_pa(void)    { return (u64)(UINTPTR)ddr_buf; }
u32  plat_ddr_bytes(void) { return ddr_ok ? PLAT_DDR_BYTES : 0; }
void plat_ddr_for_cpu(u32 off, u32 n) { Xil_DCacheInvalidateRange((UINTPTR)&ddr_buf[off], n); }
void plat_ddr_for_dev(u32 off, u32 n) { Xil_DCacheFlushRange((UINTPTR)&ddr_buf[off], n); }
void plat_ddr_put64(u32 off, const u8 *src) { memcpy(&ddr_buf[off], src, 64); }
void plat_ddr_get64(u32 off, u8 *dst) { memcpy(dst, &ddr_buf[off], 64); }

#else
#error "plat.c: unsupported CPU"
#endif
