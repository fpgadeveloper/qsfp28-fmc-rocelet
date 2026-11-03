/*
 * hsb.h - Holoscan Sensor Bridge (HSB) device mode of the qsfp28-fmc-rocelet console:
 * enumeration (BOOTP broadcast), the HSB register protocol (UDP 8192), the register file a
 * stock HSB 3.0.0 host programs, and the translation of a host's data-plane configuration
 * (DP_* registers) into a rocelet UC-HSB QP plus the RTL frame producer (IQ16 or counter
 * frames). Off by default; 'hsb on' starts it. See docs/source/hsb.md.
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#ifndef HSB_H_
#define HSB_H_

#include "xil_types.h"

int  hsb_on(void);                         /* 1 = HSB mode on */
void hsb_poll(void);                       /* console idle loop: control-plane frames, BOOTP timer */
void hsb_cmd(char **argv, int argc);       /* 'hsb on|off|st|serial|src|rate|scene|wd|lpause' */
void hsb_tests_begin(void);                /* a console test / setup takes the engine: stop the data plane */
void hsb_link_event(void);                 /* the console relinks: pause the producer (link pause on) */
const char *hsb_qp_label(int n);           /* QP n configured by the data plane: its type label, else NULL */
void hsb_qp_free(int n);                   /* the console re-configured QP n */

#endif
