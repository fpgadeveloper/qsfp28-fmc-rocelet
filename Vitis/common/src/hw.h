/*
 * hw.h - base addresses and register access of the qsfp28-fmc-rocelet design
 * (KCU116 + 2x QSFP28 FMC, MicroBlaze).
 *
 * rocelet_sys_0 (CMAC user clock, 512 KB window):
 *   +0x00000  the rocelet engine's register map (rocelet_regs.h, from the
 *             rocelet submodule)
 *   +0x10000  the system registers (rsys_regs.h): CMAC control, work-request
 *             queue, completions, raw frames / capture, self-test logic
 *   +0x40000  the memory window (on-chip URAM; the engine's memory windows
 *             use local address 0 = the start of this window)
 * rocelet_sys runs on the CMAC user clock: it can only be accessed while that
 * clock runs (cmac_clk_ok()).
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#ifndef HW_H_
#define HW_H_

#include "xil_types.h"
#include "xil_io.h"
#include "xparameters.h"
#include "rocelet_regs.h"
#include "rsys_regs.h"

/* xparameters names of the SDT flow, with the block design's addresses as fallback */
#if defined(XPAR_ROCELET_SYS_0_BASEADDR)
#define RSYS_BASE      XPAR_ROCELET_SYS_0_BASEADDR
#else
#define RSYS_BASE      0x44800000u
#endif
#if defined(XPAR_AXI_GPIO_QSFP0_BASEADDR)
#define GPIO_BASE      XPAR_AXI_GPIO_QSFP0_BASEADDR
#else
#define GPIO_BASE      0x40000000u
#endif
#if defined(XPAR_AXI_IIC_CLK_BASEADDR)
#define IIC_CLK_BASE   XPAR_AXI_IIC_CLK_BASEADDR
#else
#define IIC_CLK_BASE   0x40800000u
#endif

#define ENG_BASE       (RSYS_BASE + 0x00000u)
#define SYS_BASE       (RSYS_BASE + 0x10000u)
#define MEM_BASE       (RSYS_BASE + 0x40000u)

#define F_CLK_HZ       322265625u          /* CMAC user clock = rocelet_sys clock */

/* QSFP0 GPIO: channel 1 out, channel 2 in */
#define GPIO_OUT       (GPIO_BASE + 0x0u)  /* [0] modsel_l [1] reset_l [2] lpmode [3] CMAC reset */
#define GPIO_IN        (GPIO_BASE + 0x8u)  /* [0] modprs_l [1] int_l [2] usr_tx_reset [3] usr_rx_reset [4] rx aligned [5] engine irq */
#define GPIO_OUT_DFLT  0x2u
#define GPIO_CMAC_RST  0x8u

static inline u32  eng_rd(u32 off)          { return Xil_In32(ENG_BASE + off); }
static inline void eng_wr(u32 off, u32 v)   { Xil_Out32(ENG_BASE + off, v); }
static inline u32  sys_rd(u32 off)          { return Xil_In32(SYS_BASE + off); }
static inline void sys_wr(u32 off, u32 v)   { Xil_Out32(SYS_BASE + off, v); }
static inline u32  cfg_get(int i)           { return sys_rd(RSYS_CFG(i)); }
static inline void cfg_set(int i, u32 v)    { sys_wr(RSYS_CFG(i), v); }
static inline u32  sv(int i)                { return sys_rd(RSYS_SV(i)); }
static inline u32  cnt(int i)               { return sys_rd(RSYS_CNT(i)); }
static inline u32  mem_rd(u32 a)            { return Xil_In32(MEM_BASE + (a & ~3u)); }
static inline void mem_wr(u32 a, u32 v)     { Xil_Out32(MEM_BASE + (a & ~3u), v); }
u64 bc(int i);                              /* 64-bit system accumulator */
u64 eng_rd64(u32 off_lo);                   /* 64-bit engine counter (lo latches hi) */

#endif
