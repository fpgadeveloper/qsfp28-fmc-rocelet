/*
 * cmac.h - 100G CMAC on QSFP28 port 0: GT reference clock (Si5328), reset,
 * static configuration (RS-FEC, PAUSE, GT loopback) and link status.
 *
 * The CMAC is built without its AXI-Lite register block: its ctl_* inputs come
 * from the system register C_MAC_CTL / C_MAC_PZ (rocelet_sys, CMAC user clock),
 * its reset is a QSFP0 GPIO bit (system clock), and its status is read from
 * the GPIO (always) and from S_MAC_STAT (while the user clock runs).
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#ifndef CMAC_H_
#define CMAC_H_

#include "xil_types.h"

#define LOOP_OFF   0    /* external: cable or QSFP28 loopback plug */
#define LOOP_PCS   1    /* GT near-end PCS loopback */
#define LOOP_PMA   2    /* GT near-end PMA loopback */

int  cmac_bringup(int fec, int loop);   /* Si5328, reset, configuration, link; 0 = link up */
int  cmac_relink(int fec, int loop);    /* apply RS-FEC / loopback, reset, wait for the link */
int  cmac_clk_ok(void);                 /* CMAC user clock running (rocelet_sys accessible) */
int  cmac_link_up(void);                /* RX aligned and RX status good */
int  cmac_fec(void);
int  cmac_loop(void);
void cmac_pause(int rx, int tx, u32 quanta, u32 refresh);
void cmac_status(void);                 /* one-line link report + CMAC fabric counters */
const char *loop_name(int loop);

#endif
