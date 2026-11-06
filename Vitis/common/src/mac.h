/*
 * mac.h - the Ethernet MAC on QSFP28 port 0: GT reference clock (Si5328), reset,
 * static configuration (FEC, PAUSE, GT loopback) and link status. Two backends,
 * selected per target in hw.h:
 *   MAC_CMAC (KCU116): the 100G CMAC, built without its AXI-Lite register block: its
 *     ctl_* inputs come from the system registers C_MAC_CTL / C_MAC_PZ (through the
 *     block design's mac_cmac_adapt), its reset is a QSFP0 GPIO bit (system clock),
 *     its status is read from the GPIO (always) and S_MAC_STAT (while the user clock runs);
 *     reference clock 322.265625 MHz.
 *   MAC_OMAC (ZCU106): omac_40g (40GBASE-R4, no FEC) on four GTH channels (target zcu106) or
 *     omac_10g (10GBASE-R, no FEC) on one (its 10G option; which one = the always-on CAPS, the
 *     40G lane status in the always-on block's LANE_* registers); GT and MAC
 *     resets, link status and the MAC clock state come from the always-on block
 *     (rsys_aon, pl_clk0), the static configuration from C_MAC_CTL / C_MAC_PZ /
 *     C_MAC_ADDR_*; reference clock 156.25 MHz. Received PAUSE is a level (the omac
 *     times the quanta): the engine's CTRL.PAUSE_RX_LEVEL is set.
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#ifndef MAC_H_
#define MAC_H_

#include "xil_types.h"

#define LOOP_OFF   0    /* external: cable or QSFP28 loopback plug */
#define LOOP_PCS   1    /* GT near-end PCS loopback (CMAC only) */
#define LOOP_PMA   2    /* GT near-end PMA loopback */

int  mac_bringup(int fec, int loop);   /* Si5328, reset, configuration, link; 0 = link up */
int  mac_relink(int fec, int loop);    /* apply FEC / loopback, reset, wait for the link */
int  mac_clk_ok(void);                 /* MAC user clock running (rocelet_sys accessible) */
int  mac_link_up(void);                /* RX aligned / block lock and RX status good */
int  mac_fec(void);
int  mac_loop(void);
void mac_pause(int rx, int tx, u32 quanta, u32 refresh);
void mac_set_addr(const u8 *mac);      /* station address for the MAC's PAUSE frames (omac) */
void mac_status(void);                 /* one-line link report + MAC fabric counters */
const char *loop_name(int loop);

#endif
