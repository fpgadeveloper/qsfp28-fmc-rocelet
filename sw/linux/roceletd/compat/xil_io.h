/* compat/xil_io.h - 32-bit register access for the Linux build of the console sources: the
 * physical addresses of the design (0x8000_0000 window) are translated to the UIO mapping of the
 * register window (plat_linux.c). Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT */
#ifndef XIL_IO_H
#define XIL_IO_H
#include "xil_types.h"
u32  Xil_In32(UINTPTR addr);
void Xil_Out32(UINTPTR addr, u32 value);
#endif
