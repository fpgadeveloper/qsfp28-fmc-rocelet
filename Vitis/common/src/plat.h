/*
 * plat.h - the thin platform layer of the rocelet console: everything that differs
 * between the CPUs and operating systems the same sources run on. Register access,
 * printing (xil_printf) and delays (usleep) are common to the standalone BSPs and stay
 * in hw.h / util.c; the Linux daemon provides them through its own compatibility headers.
 *   MicroBlaze (KCU116): AXI UART 16550 console, AXI timer 0 time base
 *   Cortex-A53 standalone (ZCU106): PS UART0 console (set up by the FSBL), the
 *   generic timer (XTime) as time base, a 1 MB static buffer as the PS DDR window
 *   Cortex-A72 standalone (VCK190): as the A53 (PS UART0 set up by the PLM), plus the FMC
 *   VADJ rail (LPD I2C0, XIicPs) and the device DNA (the PMC eFUSE cache)
 *   Linux (ZCU106, VCK190; PLAT_LINUX: sw/linux/roceletd/plat_linux.c): the register
 *   windows and the PS DDR window through UIO, i2c-dev (VADJ too), the device DNA through
 *   the xilinx-secure-config nvmem device (Versal), clock_gettime; console lines arrive on
 *   the daemon's control socket (console.h), not through plat_rx_*.
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#ifndef PLAT_H_
#define PLAT_H_

#include "xil_types.h"

#define PLAT_TICKS_S   100000000u          /* plat_ticks() rate: 100 MHz */

void plat_init(void);                      /* console UART set-up, time base */
int  plat_rx_ready(void);                  /* a console character is waiting */
char plat_rx_byte(void);                   /* read it (call only when ready) */
u32  plat_ticks(void);                     /* free-running 32-bit count at PLAT_TICKS_S (wraps ~43 s) */
const char *plat_cpu(void);                /* "MicroBlaze" / "Cortex-A53" / "Cortex-A72" / "..., Linux" */

/* FMC VADJ: on boards where nothing else switches the FMC I/O rail on (VCK190: the IR38164
 * behind the TCA9548 on LPD I2C0, off after power-up unless u-boot enabled it). Idempotent:
 * reads the regulator first and only programs it when it is off or at another voltage; prints
 * what it did. 0 = VADJ on (or the board needs nothing), -1 = the regulator did not answer */
int  plat_vadj_on(void);

/* Device DNA from the processor side, for parts whose PL has no DNA port (Versal: the PMC's
 * 128-bit DNA, eFUSE cache DNA_0..3). 1 = dna[0..3] valid (dna[0] = bits 31:0), 0 = none */
int  plat_dna(u32 dna[4]);

/* The board's PS I2C controller at base (Versal LPD I2C0 0xFF020000: standalone XIicPs, Linux the
 * i2c-cadence adapter "<base>.i2c" through i2c-dev), for vadj.c. 0 = ok (every byte ACKed) */
int  plat_pi2c_write(UINTPTR base, u8 addr, const u8 *buf, unsigned n);
int  plat_pi2c_read_reg(UINTPTR base, u8 addr, u8 reg, u8 *val);   /* reg pointer, repeated start, 1 byte */

/* PS DDR window (targets with HAS_DDR_WIN): the buffer of PS DDR that is the engine's run-time
 * region (C_DDR_BASE / C_DDR_SIZE, MR 3). Standalone A53: a 1 MB static buffer, cached (the
 * for_cpu / for_dev calls do the cache maintenance); Linux: the reserved-memory carve-out mapped
 * uncached through UIO (no maintenance; aligned accesses only, hence the 64-byte copies). */
int  plat_ddr_init(void);                  /* 0 = the buffer is available */
u64  plat_ddr_pa(void);                    /* physical address (4 KB aligned) */
u32  plat_ddr_bytes(void);                 /* size, a multiple of 4 KB; 0 = no buffer */
void plat_ddr_for_cpu(u32 off, u32 n);     /* before the CPU reads what the PL wrote */
void plat_ddr_for_dev(u32 off, u32 n);     /* after the CPU wrote what the PL will read */
void plat_ddr_put64(u32 off, const u8 *src);   /* 64 bytes into the buffer at off (64-byte aligned) */
void plat_ddr_get64(u32 off, u8 *dst);     /* 64 bytes from the buffer at off */

#endif
