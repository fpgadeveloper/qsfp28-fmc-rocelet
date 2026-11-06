/* compat/xiic_l.h - XIic_Send() of the standalone AXI IIC driver over Linux i2c-dev: the AXI IIC
 * at that base address is the Linux i2c-xiic adapter whose device is "<base>.i2c"
 * (plat_linux.c). Copyright (c) 2026 Opsero Electronic Design Inc. SPDX-License-Identifier: MIT */
#ifndef XIIC_L_H
#define XIIC_L_H
#include "xil_types.h"
#define XIIC_STOP     0x00
#define XIIC_REPEATED_START 0x01
unsigned XIic_Send(UINTPTR base, u8 addr, u8 *buf, unsigned n, u8 option);
unsigned XIic_Recv(UINTPTR base, u8 addr, u8 *buf, unsigned n, u8 option);
#endif
