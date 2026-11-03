/*
 * util.h - small helpers of the rocelet console: 64-bit and fixed-point printing
 * (xil_printf has no 64-bit formats), number / address parsing, console input.
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#ifndef UTIL_H_
#define UTIL_H_

#include "xil_types.h"

void pr_u64(u64 v);                        /* decimal */
void pr_hex64(u64 v);                      /* 0x..., no leading zeros */
void pr_fix(u64 num, u64 den, int dec);    /* num/den with dec decimals */
void pr_gbps(u64 bytes, u64 cycles);       /* bytes over CMAC clock cycles, Gb/s with 2 decimals */
void pr_ns(u64 cycles);                    /* CMAC clock cycles as ns with 1 decimal */
void pr_ip(u32 ip);
void pr_mac(const u8 *m);                  /* 12 hex digits */
void fmt(char *o, const char *f, ...);     /* %u %d %x %s into a buffer */

u64  strtou64(const char *p);              /* C syntax: 0x.. hex, else decimal */
int  parse_ip(const char *p, u32 *ip);
int  parse_mac(const char *p, u8 *m);
const char *kv(char **argv, int argc, int from, const char *key);   /* value of key=... */
u32  arg_u(char **argv, int argc, int i, u32 dflt);
int  log2u(u32 v);

int  getline_uart(char *buf, int max);     /* blocking, with echo and backspace */
int  getline_poll(char *buf, int max);     /* non-blocking: 1 = a line is complete */
void delay_us(u32 us);

#endif
