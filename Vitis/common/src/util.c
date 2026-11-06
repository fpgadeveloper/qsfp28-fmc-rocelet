/*
 * util.c - small helpers of the rocelet console.
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include "xil_printf.h"
#include "xparameters.h"
#include "bspconfig.h"
#include "sleep.h"
#include "hw.h"
#include "util.h"
#include "plat.h"

void pr_u64(u64 v)
{
	char b[24];
	int n = 0;
	if (v == 0) { xil_printf("0"); return; }
	while (v) { b[n++] = (char)('0' + (int)(v % 10)); v /= 10; }
	while (n) { char c[2] = { b[--n], 0 }; xil_printf("%s", c); }
}

void pr_hex64(u64 v)
{
	char b[20];
	int n = 0;
	do { int d = (int)(v & 15); b[n++] = (char)(d < 10 ? '0' + d : 'a' + d - 10); v >>= 4; } while (v);
	xil_printf("0x");
	while (n) { char c[2] = { b[--n], 0 }; xil_printf("%s", c); }
}

void pr_fix(u64 num, u64 den, int dec)
{
	u64 sc = 1;
	for (int i = 0; i < dec; i++) sc *= 10;
	if (den == 0) { xil_printf("n/a"); return; }
	u64 v = (num * sc + den / 2) / den;
	pr_u64(v / sc);
	if (dec) {
		u64 f = v % sc;
		char b[12];
		for (int i = dec - 1; i >= 0; i--) { b[i] = (char)('0' + (int)(f % 10)); f /= 10; }
		b[dec] = 0;
		xil_printf(".%s", b);
	}
}

void pr_gbps(u64 bytes, u64 cyc)
{
	/* Gb/s = bytes * 8 * F / cyc / 1e9, scaled to stay in 64 bits up to ~10 TB */
	pr_fix((bytes / 1000ull) * 8ull * (F_CLK_HZ / 1000ull), cyc * 1000ull, 2);
}

void pr_ns(u64 cyc) { pr_fix(cyc * 1000000000ull, F_CLK_HZ, 1); }

void pr_ip(u32 ip) { xil_printf("%d.%d.%d.%d", ip >> 24, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255); }

void pr_mac(const u8 *m) { for (int i = 0; i < 6; i++) xil_printf("%02x", m[i]); }

void fmt(char *o, const char *f, ...)
{
	va_list ap;
	va_start(ap, f);
	while (*f) {
		if (*f != '%') { *o++ = *f++; continue; }
		f++;
		if (*f == 's') { const char *t = va_arg(ap, const char *); while (*t) *o++ = *t++; }
		else if (*f == 'u' || *f == 'd' || *f == 'x') {
			u32 v = va_arg(ap, u32);
			char b[12]; int n = 0;
			if (*f == 'd' && (int)v < 0) { *o++ = '-'; v = (u32)(-(int)v); }
			u32 base = (*f == 'x') ? 16 : 10;
			do { u32 d = v % base; b[n++] = (char)(d < 10 ? '0' + d : 'a' + d - 10); v /= base; } while (v);
			while (n) *o++ = b[--n];
		}
		f++;
	}
	*o = 0;
	va_end(ap);
}

u64 strtou64(const char *p)
{
	u64 v = 0;
	if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
		for (p += 2; *p; p++) {
			int d = (*p >= '0' && *p <= '9') ? *p - '0' : (*p >= 'a' && *p <= 'f') ? *p - 'a' + 10 :
				(*p >= 'A' && *p <= 'F') ? *p - 'A' + 10 : -1;
			if (d < 0) break;
			v = (v << 4) | (u64)d;
		}
	} else {
		for (; *p >= '0' && *p <= '9'; p++) v = v * 10 + (u64)(*p - '0');
	}
	return v;
}

int parse_ip(const char *p, u32 *ip)
{
	u32 v = 0;
	for (int k = 0; k < 4; k++) {
		u32 o = 0;
		int nd = 0;
		while (*p >= '0' && *p <= '9') { o = o * 10 + (u32)(*p++ - '0'); nd++; }
		if (!nd || o > 255) return -1;
		v = (v << 8) | o;
		if (k < 3) { if (*p != '.') return -1; p++; }
	}
	*ip = v;
	return 0;
}

int parse_mac(const char *p, u8 *m)
{
	int n = 0;
	u32 acc = 0;
	for (; *p && n < 12; p++) {
		if (*p == ':' || *p == '-') continue;
		int d = (*p >= '0' && *p <= '9') ? *p - '0' : (*p >= 'a' && *p <= 'f') ? *p - 'a' + 10 :
			(*p >= 'A' && *p <= 'F') ? *p - 'A' + 10 : -1;
		if (d < 0) return -1;
		acc = (acc << 4) | (u32)d;
		if (n & 1) { m[n / 2] = (u8)acc; acc = 0; }
		n++;
	}
	return n == 12 ? 0 : -1;
}

const char *kv(char **argv, int argc, int from, const char *key)
{
	int kl = (int)strlen(key);
	for (int i = from; i < argc; i++)
		if (!strncmp(argv[i], key, kl) && argv[i][kl] == '=') return argv[i] + kl + 1;
	return NULL;
}

u32 arg_u(char **argv, int argc, int i, u32 dflt)
{
	if (i >= argc) return dflt;
	return (u32)strtou64(argv[i]);
}

int log2u(u32 v) { int n = 0; while (v > 1) { v >>= 1; n++; } return n; }

int getline_uart(char *buf, int max)
{
	int n = 0;
	for (;;) {
		while (!plat_rx_ready())
			;
		char c = plat_rx_byte();
		if (c == '\r' || c == '\n') {
			xil_printf("\r\n");
			buf[n] = 0;
			return n;
		}
		if ((c == 8 || c == 127) && n > 0) { n--; xil_printf("\b \b"); continue; }
		if (n < max - 1 && c >= 32) { buf[n++] = c; xil_printf("%c", c); }
	}
}

/* non-blocking variant for the console loop (HSB mode polls the network between characters):
 * takes the characters that have arrived; 1 = a line is complete in buf */
int getline_poll(char *buf, int max)
{
	static int n;
	while (plat_rx_ready()) {
		char c = plat_rx_byte();
		if (c == '\r' || c == '\n') {
			xil_printf("\r\n");
			buf[n] = 0;
			n = 0;
			return 1;
		}
		if ((c == 8 || c == 127) && n > 0) { n--; xil_printf("\b \b"); continue; }
		if (n < max - 1 && c >= 32) { buf[n++] = c; xil_printf("%c", c); }
	}
	return 0;
}

void delay_us(u32 us) { usleep(us); }

u64 bc(int i)
{
	u32 lo = sys_rd(RSYS_BC(i));        /* latches hi */
	u32 hi = sys_rd(RSYS_BC(i) + 4);
	return ((u64)hi << 32) | lo;
}

u64 eng_rd64(u32 off_lo)
{
	u32 lo = eng_rd(off_lo);            /* latches hi */
	u32 hi = eng_rd(off_lo + 4);
	return ((u64)hi << 32) | lo;
}
