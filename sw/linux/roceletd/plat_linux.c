/*
 * plat_linux.c - the console's platform layer (Vitis/common/src/plat.h) on Linux, plus the
 * standalone-BSP functions the console sources call (compat/: Xil_In32/Out32, xil_printf,
 * XIic_Send):
 *  - registers: the design's physical addresses 0x8000_0000.. (rsys_aon_0: rocelet_sys behind
 *    the clock guard, always-on block at +0x8_0000) through the generic-UIO device rocelet-regs;
 *    any other address reads 0xFFFFFFFF (the AXI IIC and DMA blocks belong to Linux drivers);
 *  - PS DDR window: the reserved-memory carve-out through the UIO device rocelet-ddr, mapped
 *    uncached by UIO (no cache maintenance; aligned 64-bit accesses);
 *  - I2C: the AXI IIC at a base address = the i2c-xiic adapter of device "<base>.i2c", i2c-dev;
 *  - time: CLOCK_MONOTONIC.
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <linux/i2c-dev.h>

#include "xil_types.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xiic_l.h"
#include "plat.h"
#include "plat_linux.h"

/* ---------------------------------------------------------------- UIO */
static volatile u8 *g_regs;
static u32 g_regs_size;
static int g_regs_fd = -1;
static volatile u8 *g_ddr;
static u64 g_ddr_pa;
static u32 g_ddr_size;
static char g_ddr_name[64] = "rocelet-ddr";

static int read_sysfs(const char *path, char *buf, size_t n)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0) return -1;
	ssize_t r = read(fd, buf, n - 1);
	close(fd);
	if (r < 0) return -1;
	buf[r] = 0;
	while (r > 0 && (buf[r - 1] == '\n' || buf[r - 1] == ' ')) buf[--r] = 0;
	return 0;
}

/* /sys/class/uio/uioN whose name is name (or one of the alternatives, comma separated); -1 if none */
static int uio_find(const char *names)
{
	DIR *d = opendir("/sys/class/uio");
	if (!d) return -1;
	struct dirent *e;
	int found = -1;
	while ((e = readdir(d)) && found < 0) {
		int n;
		char p[PATH_MAX], v[128];
		if (sscanf(e->d_name, "uio%d", &n) != 1) continue;
		snprintf(p, sizeof(p), "/sys/class/uio/%s/name", e->d_name);
		if (read_sysfs(p, v, sizeof(v))) continue;
		const char *s = names;
		while (*s && found < 0) {
			size_t l = strcspn(s, ",");
			if (strlen(v) == l && !strncmp(v, s, l)) found = n;
			s += l;
			if (*s == ',') s++;
		}
	}
	closedir(d);
	return found;
}

static int uio_map(int n, int idx, volatile u8 **va, u64 *pa, u32 *size, int *fdout)
{
	char p[PATH_MAX], v[64];
	snprintf(p, sizeof(p), "/sys/class/uio/uio%d/maps/map%d/addr", n, idx);
	if (read_sysfs(p, v, sizeof(v))) return -1;
	*pa = strtoull(v, NULL, 0);
	snprintf(p, sizeof(p), "/sys/class/uio/uio%d/maps/map%d/size", n, idx);
	if (read_sysfs(p, v, sizeof(v))) return -1;
	*size = (u32)strtoull(v, NULL, 0);
	snprintf(p, sizeof(p), "/dev/uio%d", n);
	int fd = open(p, O_RDWR | O_SYNC | O_CLOEXEC);
	if (fd < 0) return -1;
	void *m = mmap(NULL, *size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)idx * getpagesize());
	if (m == MAP_FAILED) { close(fd); return -1; }
	*va = m;
	if (fdout) *fdout = fd;
	return 0;
}

int plat_linux_open(const char *regs_name, const char *ddr_name, int wait_s)
{
	int n = -1;
	if (ddr_name) snprintf(g_ddr_name, sizeof(g_ddr_name), "%s", ddr_name);
	for (int t = 0; t <= wait_s * 10; t++) {
		if ((n = uio_find(regs_name)) >= 0) break;
		usleep(100000);
	}
	if (n < 0) { dlog("roceletd: no UIO device named %s (device tree, uio_pdrv_genirq.of_id=generic-uio)", regs_name); return -1; }
	u64 pa;
	if (uio_map(n, 0, &g_regs, &pa, &g_regs_size, &g_regs_fd)) {
		dlog("roceletd: cannot map /dev/uio%d: %s", n, strerror(errno));
		return -1;
	}
	if (pa != REGS_PA) dlog("roceletd: WARNING: register window at 0x%llx, expected 0x%x", (unsigned long long)pa, REGS_PA);
	dlog("roceletd: register window /dev/uio%d (%s) PA 0x%llx, %u KB", n, regs_name, (unsigned long long)pa,
	     g_regs_size >> 10);
	return 0;
}

int plat_regs_fd(void) { return g_regs_fd; }
u32 plat_regs_size(void) { return g_regs_size; }

static int g_bad_addr_msgs;

u32 Xil_In32(UINTPTR a)
{
	UINTPTR off = a - REGS_PA;
	if (g_regs && a >= REGS_PA && off + 4 <= g_regs_size)
		return *(volatile u32 *)(g_regs + off);
	if (g_bad_addr_msgs++ < 8) xil_printf("(address 0x%08lx is outside the register window: reads 0xffffffff)\r\n", (unsigned long)a);
	return 0xFFFFFFFFu;
}

void Xil_Out32(UINTPTR a, u32 v)
{
	UINTPTR off = a - REGS_PA;
	if (g_regs && a >= REGS_PA && off + 4 <= g_regs_size) { *(volatile u32 *)(g_regs + off) = v; return; }
	if (g_bad_addr_msgs++ < 8) xil_printf("(address 0x%08lx is outside the register window: write dropped)\r\n", (unsigned long)a);
}

/* ---------------------------------------------------------------- PS DDR window */
int plat_ddr_init(void)
{
	if (g_ddr) return 0;
	int n = uio_find(g_ddr_name);
	if (n < 0) { dlog("roceletd: no UIO device named %s: PS DDR window not set up", g_ddr_name); return -1; }
	if (uio_map(n, 0, &g_ddr, &g_ddr_pa, &g_ddr_size, NULL)) {
		dlog("roceletd: cannot map the PS DDR window /dev/uio%d: %s", n, strerror(errno));
		g_ddr = NULL;
		g_ddr_size = 0;
		return -1;
	}
	g_ddr_size &= ~0xFFFu;
	dlog("roceletd: PS DDR window /dev/uio%d (%s) PA 0x%llx, %u MB", n, g_ddr_name, (unsigned long long)g_ddr_pa,
	     g_ddr_size >> 20);
	return 0;
}

u64  plat_ddr_pa(void)    { return g_ddr ? g_ddr_pa : 0; }
u32  plat_ddr_bytes(void) { return g_ddr ? g_ddr_size : 0; }
void plat_ddr_for_cpu(u32 off, u32 n) { (void)off; (void)n; }   /* uncached mapping */
void plat_ddr_for_dev(u32 off, u32 n) { (void)off; (void)n; }

/* Device memory: aligned 64-bit accesses only (no memcpy / memset on the mapping) */
void plat_ddr_put64(u32 off, const u8 *src)
{
	volatile u64 *d = (volatile u64 *)(g_ddr + (off & ~63u));
	u64 w[8];
	memcpy(w, src, 64);
	for (int i = 0; i < 8; i++) d[i] = w[i];
}

void plat_ddr_get64(u32 off, u8 *dst)
{
	volatile u64 *s = (volatile u64 *)(g_ddr + (off & ~63u));
	u64 w[8];
	for (int i = 0; i < 8; i++) w[i] = s[i];
	memcpy(dst, w, 64);
}

/* ---------------------------------------------------------------- console, time */
void plat_init(void) { }
int  plat_rx_ready(void) { return 0; }     /* console lines come from the control socket */
char plat_rx_byte(void) { return 0; }
const char *plat_cpu(void) { return "Cortex-A53, Linux"; }

u32 plat_ticks(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (u32)((u64)ts.tv_sec * PLAT_TICKS_S + (u64)ts.tv_nsec / (1000000000u / PLAT_TICKS_S));
}

/* ---------------------------------------------------------------- output */
static int g_out_fd = -1;
#define LOG_LINES 256
static char *g_log[LOG_LINES];
static unsigned g_log_n;

static void log_line(const char *s)
{
	unsigned i = g_log_n++ % LOG_LINES;
	free(g_log[i]);
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	if (asprintf(&g_log[i], "[%6ld.%03ld] %s", (long)ts.tv_sec, ts.tv_nsec / 1000000, s) < 0) g_log[i] = NULL;
}

/* text without CR; lines also go to the ring when they go to the journal */
static void emit(const char *s, size_t n)
{
	static char acc[512];
	static size_t accn;
	char *b = malloc(n + 1);
	size_t m = 0;
	if (!b) return;
	for (size_t i = 0; i < n; i++) if (s[i] != '\r') b[m++] = s[i];
	if (g_out_fd >= 0) {
		size_t o = 0;
		while (o < m) {
			ssize_t w = send(g_out_fd, b + o, m - o, MSG_NOSIGNAL);
			if (w < 0 && errno == EINTR) continue;
			if (w <= 0) { g_out_fd = -2; break; }       /* client gone: drop the rest of this command's output */
			o += (size_t)w;
		}
	} else if (g_out_fd == -1) {
		fwrite(b, 1, m, stdout);
		fflush(stdout);
		for (size_t i = 0; i < m; i++) {
			if (b[i] == '\n' || accn == sizeof(acc) - 1) { acc[accn] = 0; if (accn) log_line(acc); accn = 0; }
			if (b[i] != '\n') acc[accn++] = b[i];
		}
	}
	free(b);
}

void xil_printf(const char *fmt, ...)
{
	char sbuf[1024], *p = sbuf;
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(sbuf, sizeof(sbuf), fmt, ap);
	va_end(ap);
	if (n < 0) return;
	if ((size_t)n >= sizeof(sbuf)) {
		p = malloc((size_t)n + 1);
		if (!p) return;
		va_start(ap, fmt);
		vsnprintf(p, (size_t)n + 1, fmt, ap);
		va_end(ap);
	}
	emit(p, (size_t)n);
	if (p != sbuf) free(p);
}

void out_begin(int fd) { g_out_fd = fd; g_bad_addr_msgs = 0; }
void out_end(void) { g_out_fd = -1; }
int  out_client(void) { return g_out_fd; }

void dlog(const char *fmt, ...)
{
	char b[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(b, sizeof(b), fmt, ap);
	va_end(ap);
	fprintf(stderr, "%s\n", b);
	fflush(stderr);
	log_line(b);
}

int dlog_dump(int fd, int max)
{
	unsigned n = g_log_n < LOG_LINES ? g_log_n : LOG_LINES;
	if (max > 0 && (unsigned)max < n) n = (unsigned)max;
	for (unsigned k = g_log_n - n; k != g_log_n; k++) {
		const char *s = g_log[k % LOG_LINES];
		if (!s) continue;
		if (send(fd, s, strlen(s), MSG_NOSIGNAL) < 0 || send(fd, "\n", 1, MSG_NOSIGNAL) < 0) return -1;
	}
	return 0;
}

/* ---------------------------------------------------------------- I2C */
int plat_i2c_bus(UINTPTR base)
{
	char want[32];
	snprintf(want, sizeof(want), "%08lx.i2c", (unsigned long)base);
	DIR *d = opendir("/sys/bus/i2c/devices");
	if (!d) return -1;
	struct dirent *e;
	int bus = -1;
	while ((e = readdir(d)) && bus < 0) {
		int n;
		char p[PATH_MAX], real[PATH_MAX];
		if (sscanf(e->d_name, "i2c-%d", &n) != 1) continue;
		snprintf(p, sizeof(p), "/sys/bus/i2c/devices/%s", e->d_name);
		if (!realpath(p, real)) continue;
		/* .../amba_pl/80100000.i2c/i2c-3 */
		if (strstr(real, want)) bus = n;
	}
	closedir(d);
	return bus;
}

static struct { UINTPTR base; int fd; } g_i2c[4];

static int i2c_fd(UINTPTR base)
{
	for (int i = 0; i < 4; i++) if (g_i2c[i].fd > 0 && g_i2c[i].base == base) return g_i2c[i].fd;
	int bus = plat_i2c_bus(base);
	if (bus < 0) { xil_printf("i2c: no Linux adapter for the AXI IIC at 0x%08lx (i2c-xiic)\r\n", (unsigned long)base); return -1; }
	char p[32];
	snprintf(p, sizeof(p), "/dev/i2c-%d", bus);
	int fd = open(p, O_RDWR | O_CLOEXEC);
	if (fd < 0) { xil_printf("i2c: %s: %s\r\n", p, strerror(errno)); return -1; }
	for (int i = 0; i < 4; i++) if (g_i2c[i].fd <= 0) { g_i2c[i].base = base; g_i2c[i].fd = fd; break; }
	return fd;
}

unsigned XIic_Send(UINTPTR base, u8 addr, u8 *buf, unsigned n, u8 option)
{
	(void)option;
	int fd = i2c_fd(base);
	if (fd < 0) return 0;
	if (ioctl(fd, I2C_SLAVE_FORCE, (long)addr) < 0) return 0;
	ssize_t w = write(fd, buf, n);
	return w < 0 ? 0 : (unsigned)w;
}

unsigned XIic_Recv(UINTPTR base, u8 addr, u8 *buf, unsigned n, u8 option)
{
	(void)option;
	int fd = i2c_fd(base);
	if (fd < 0) return 0;
	if (ioctl(fd, I2C_SLAVE_FORCE, (long)addr) < 0) return 0;
	ssize_t r = read(fd, buf, n);
	return r < 0 ? 0 : (unsigned)r;
}
