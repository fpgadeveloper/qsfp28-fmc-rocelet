/*
 * plat.c - platform layer of the rocelet console (see plat.h): the standalone BSPs.
 * The Linux daemon has its own implementation (sw/linux/roceletd/plat_linux.c).
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#include "xparameters.h"
#include "bspconfig.h"
#include "xil_io.h"
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

#elif defined(__aarch64__) || defined(__arm__)
/* ---------------- Cortex-A53 standalone: PS UART, generic timer ---------------- */
#include <string.h>
#include "xuartps_hw.h"
#include "xiltimer.h"                 /* XTime_GetTime, COUNTS_PER_SECOND (SDT BSP) */
#include "xil_cache.h"

#if !defined(STDIN_BASEADDRESS)
#define STDIN_BASEADDRESS 0xFF000000u               /* PS UART0 */
#endif

void plat_init(void)
{
	/* UART0 runs at 115200 8N1 from the FSBL / BSP; nothing else to set up */
}
int  plat_rx_ready(void) { return XUartPs_IsReceiveData(STDIN_BASEADDRESS) ? 1 : 0; }
char plat_rx_byte(void)  { return (char)XUartPs_ReadReg(STDIN_BASEADDRESS, XUARTPS_FIFO_OFFSET); }
u32  plat_ticks(void)
{
	XTime t;
	XTime_GetTime(&t);
	u64 cps = (u64)COUNTS_PER_SECOND;
	u64 q = t / cps, r = t % cps;
	return (u32)(q * PLAT_TICKS_S + (r * PLAT_TICKS_S) / cps);
}
const char *plat_cpu(void) { return "Cortex-A53"; }

/* PS DDR window: a 1 MB buffer of this program (cached; maintenance in for_cpu / for_dev) */
#define PLAT_DDR_BYTES (1u << 20)
static u8 ddr_buf[PLAT_DDR_BYTES] __attribute__((aligned(4096)));
/* The C start-up code zeroed the buffer (.bss) through the data cache: write those lines back now,
 * else a dirty line evicted later overwrites what the engine wrote into PS DDR (seen on the bench:
 * the first host WRITE into MR 3 after boot left beat 0 = zeros) */
int  plat_ddr_init(void)  { Xil_DCacheFlushRange((UINTPTR)ddr_buf, PLAT_DDR_BYTES); return 0; }
u64  plat_ddr_pa(void)    { return (u64)(UINTPTR)ddr_buf; }
u32  plat_ddr_bytes(void) { return PLAT_DDR_BYTES; }
void plat_ddr_for_cpu(u32 off, u32 n) { Xil_DCacheInvalidateRange((UINTPTR)&ddr_buf[off], n); }
void plat_ddr_for_dev(u32 off, u32 n) { Xil_DCacheFlushRange((UINTPTR)&ddr_buf[off], n); }
void plat_ddr_put64(u32 off, const u8 *src) { memcpy(&ddr_buf[off], src, 64); }
void plat_ddr_get64(u32 off, u8 *dst) { memcpy(dst, &ddr_buf[off], 64); }

#else
#error "plat.c: unsupported CPU"
#endif
