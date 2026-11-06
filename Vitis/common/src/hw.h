/*
 * hw.h - target configuration, base addresses and register access of the
 * qsfp28-fmc-rocelet design. One source tree builds every target:
 *   KCU116 (MicroBlaze, 100G CMAC, BOARD_KCU116)
 *   ZCU106 (Cortex-A53 standalone, BOARD_ZCU106): target zcu106 with omac_40g (40GBASE-R4,
 *     the shipping MAC) or its 10G option omac_10g (10GBASE-R, data.json "mac"); one binary
 *     for both: the MAC type and the link speed are read from the always-on block's CAPS
 *     register (MAC_NAME, LINK_GBPS)
 *   VCK190 (Cortex-A72 standalone, BOARD_VCK190): target vck190_fmcp1, the Versal hard MRMAC
 *     (1x100GE CAUI-4, RS-FEC) behind the mac_mrmac100g adapter; the same always-on block and
 *     register map as the ZCU106 (M_AXI_LPD at 0x8000_0000), plus the MRMAC's own registers
 *     (MRMAC_BASE). rocelet_sys runs on its own free-running engine clock (300 MHz), not on a
 *     MAC user clock
 * board.h is generated per target by Vitis/py/build-vitis.py (BOARD_<NAME>, LINE_RATE).
 *
 * rocelet_sys_0 (MAC user clock, 512 KB window):
 *   +0x00000  the rocelet engine's register map (rocelet_regs.h, from the
 *             rocelet submodule)
 *   +0x10000  the system registers (rsys_regs.h): MAC control, work-request
 *             queue, completions, raw frames / capture, self-test logic
 *   +0x40000  the memory window (on-chip URAM; the engine's memory windows
 *             use local address 0 = the start of this window)
 * rocelet_sys runs on the MAC user clock: it can only be accessed while that
 * clock runs (mac_clk_ok()). On the ZynqMP targets the window sits behind the
 * always-on block's clock guard (rsys_aon, 1 MB: rocelet_sys at +0x00000, the
 * always-on registers at +0x80000; docs/source/zynqmp_hw.md): an access while
 * the MAC clock is stopped returns 0xDEADC10C instead of hanging the CPU.
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#ifndef HW_H_
#define HW_H_

#include "xil_types.h"
#include "xil_io.h"
#include "xparameters.h"
#include "board.h"
#include "rocelet_regs.h"
#include "rsys_regs.h"

#if defined(BOARD_ZCU106) || defined(BOARD_VCK190)
/* ---------------- PS targets: always-on block + clock guard (ZCU106, VCK190) ---------------- */
#define HAS_AON        1
/* the MAC of this bitstream, from the always-on CAPS ([7:0] link Gb/s, [19:16] MAC type) */
#define AON_CAPS_GBPS(c)  ((u32)(c) & 0xFFu)
#define AON_CAPS_MAC(c)   (((u32)(c) >> 16) & 0xFu)
#define AON_MAC_CMAC      1u
#define AON_MAC_OMAC10G   2u
#define AON_MAC_OMAC40G   3u
#define AON_MAC_MRMAC     4u
#define LINK_GBPS      AON_CAPS_GBPS(aon_rd(AON_CAPS))
#if defined(BOARD_ZCU106)
/* ZCU106: A53, omac_10g / omac_40g */
#define TARGET_NAME    "ZCU106"
#define MAC_OMAC       1
#define MAC_IS_40G     (AON_CAPS_MAC(aon_rd(AON_CAPS)) == AON_MAC_OMAC40G)
#define MAC_NAME       (MAC_IS_40G ? "omac_40g" : "omac_10g")
#define F_CLK_HZ       156250000u          /* GT TXUSRCLK2 = omac / rocelet_sys clock */
#define HAS_FEC        0
#else
/* VCK190: A72, hard MRMAC 100G (registers on its s_axi, port-0 page) */
#define TARGET_NAME    "VCK190"
#define MAC_MRMAC      1
#define MAC_NAME       "MRMAC"
#define F_CLK_HZ       300000000u          /* the engine clock (data.json clk_hz), free-running */
#define HAS_FEC        1                   /* RS-FEC CL91 RS(528,514) in the MRMAC, on after boot */
#if defined(XPAR_MRMAC_0_BASEADDR)
#define MRMAC_BASE     XPAR_MRMAC_0_BASEADDR
#else
#define MRMAC_BASE     0x80130000u         /* bd_versal.tcl: mrmac_0/s_axi, 64 KB */
#endif
#define VADJ_IIC_BASE  0xFF020000u         /* LPD I2C0 (PMC MIO 46/47): TCA9548 0x74 -> IR38164 0x1E */
#endif
/* PAUSE TX (802.3x frames from the engine's RX FIFO level) on after boot: a point-to-point link
 * to the host NIC, and the PS DDR window is the slower memory; 'pause tx 0' turns it off.
 * PAUSE RX (honour the host's PAUSE) stays off by default. */
#define PAUSE_TX_DEFAULT 1
#define HAS_DDR_WIN    1                   /* PS DDR window: MR 3 over the platform's buffer (plat.h) */
#define DDR_WIN_LADDR  0x0000008000000000ull /* local address bit 39: offset into the PS DDR region */
#if defined(XPAR_RSYS_AON_0_BASEADDR)
#define AON_BASE       XPAR_RSYS_AON_0_BASEADDR
#else
#define AON_BASE       0x80000000u
#endif
#define RSYS_BASE      (AON_BASE + 0x00000u)
#define AON_REGS       (AON_BASE + 0x80000u)
#if defined(XPAR_AXI_IIC_CLK_BASEADDR)
#define IIC_CLK_BASE   XPAR_AXI_IIC_CLK_BASEADDR
#else
#define IIC_CLK_BASE   0x80100000u
#endif
/* always-on registers (docs/source/zynqmp_hw.md) */
#define AON_ID         0x00u               /* "RAON" */
#define AON_VERSION    0x04u
#define AON_BUILD_ID   0x08u
#define AON_TARGET     0x0Cu
#define AON_CAPS       0x10u
#define AON_MAC_KHZ    0x14u
#define AON_TIME_US    0x1Cu
#define AON_CTRL       0x20u               /* [0] GT reset [1] MAC reset [2] rocelet_sys reset [8] ModSelL [9] ResetL [10] LPMode */
#define AON_STATUS     0x24u
#define AON_LINK_EV    0x28u
#define AON_MAC_STAT   0x2Cu
#define AON_IRQ_STATUS 0x30u
#define AON_IRQ_ENABLE 0x34u
#define AON_IRQ_RAW    0x38u
#define AON_POISON_RD  0x40u
#define AON_DROP_WR    0x44u
#define AON_GUARD_TO   0x48u               /* forwarded accesses that timed out (write: clear) */
#define AON_GUARD_TMO  0x4Cu               /* forwarding time-out, pl_clk0 cycles */
/* lane status. omac_40g (zero on 10G): LANE_STAT [3:0] block lock per physical (QSFP)
 * lane [7:4] alignment-marker lock [15:8] PCS lane number found on QSFP lane p at [8+2p +: 2]
 * [22:16] lane skew of the last alignment (66-bit blocks) [31] four-lane MAC; a write clears
 * the lane event counters LANE_BIP(0..3) (BIP3 errors per QSFP lane), SKEW_FAIL (failed
 * alignment attempts) and RX_OVF (received frames cut / dropped at the clock crossing).
 * MRMAC (VCK190): LANE_STAT [3:0] RS-FEC lane lock per physical lane [5:4] FEC lane mapping
 * [6] FEC aligned [27:8] PCS lane block lock 0-19 [31] four-lane MAC; RX_OVF as above, the
 * other counters 0 */
#define AON_LANE_STAT  0x60u
#define AON_LANE_BIP(l) (0x64u + 4u * (u32)(l))
#define AON_SKEW_FAIL  0x74u
#define AON_RX_OVF     0x78u
#define AON_CTRL_GT_RST   (1u << 0)
#define AON_CTRL_MAC_RST  (1u << 1)
#define AON_CTRL_SYS_RST  (1u << 2)
#define AON_CTRL_QSFP_DFLT 0x200u          /* selected, out of reset, high power */
#define AON_ST_ALIVE   (1u << 0)
#define AON_ST_GTPG    (1u << 1)
#define AON_ST_TXRDY   (1u << 2)
#define AON_ST_RXRDY   (1u << 3)
#define AON_ST_LOCK    (1u << 4)
#define AON_ST_LINK    (1u << 5)
#define AON_ST_HIBER   (1u << 6)
#define AON_ST_LF      (1u << 7)
#define AON_ST_RF      (1u << 8)
#define AON_ST_MODPRSL (1u << 12)
#define AON_ST_LOS     (1u << 14)
static inline u32  aon_rd(u32 off)          { return Xil_In32(AON_REGS + off); }
static inline void aon_wr(u32 off, u32 v)   { Xil_Out32(AON_REGS + off, v); }
#else
/* ---------------- KCU116: MicroBlaze, 100G CMAC, QSFP0 GPIO ---------------- */
#define TARGET_NAME    "KCU116"
#define PAUSE_TX_DEFAULT 0                /* PAUSE off after boot ('pause tx 1' turns it on) */
#define MAC_CMAC       1
#define MAC_NAME       "CMAC"
#define LINK_GBPS      100u
#define F_CLK_HZ       322265625u          /* CMAC user clock = rocelet_sys clock */
#define HAS_FEC        1
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
/* QSFP0 GPIO: channel 1 out, channel 2 in */
#define GPIO_OUT       (GPIO_BASE + 0x0u)  /* [0] modsel_l [1] reset_l [2] lpmode [3] CMAC reset */
#define GPIO_IN        (GPIO_BASE + 0x8u)  /* [0] modprs_l [1] int_l [2] usr_tx_reset [3] usr_rx_reset [4] rx aligned [5] engine irq */
#define GPIO_OUT_DFLT  0x2u
#define GPIO_CMAC_RST  0x8u
#endif

#define ENG_BASE       (RSYS_BASE + 0x00000u)
#define SYS_BASE       (RSYS_BASE + 0x10000u)
#define MEM_BASE       (RSYS_BASE + 0x40000u)
#define POISON         0xDEADC10Cu         /* clock guard: read while the MAC clock was stopped */

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
