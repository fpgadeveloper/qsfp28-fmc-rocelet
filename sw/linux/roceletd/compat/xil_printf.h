/* compat/xil_printf.h - console output of the Linux build: to the client of the current command
 * (control socket), else to the journal (plat_linux.c). Copyright (c) 2026 Opsero Electronic
 * Design Inc. SPDX-License-Identifier: MIT */
#ifndef XIL_PRINTF_H
#define XIL_PRINTF_H
void xil_printf(const char *fmt, ...);
#endif
