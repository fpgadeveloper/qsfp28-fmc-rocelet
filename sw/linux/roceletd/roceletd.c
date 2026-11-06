/*
 * roceletd - the qsfp28-fmc-rocelet control plane on Linux (ZCU106, Zynq UltraScale+ PS).
 *
 * One daemon owns the hardware: the register window and the PS DDR window through UIO, the FMC's
 * Si5328 and the QSFP28 module through i2c-dev. It runs the same console sources as the standalone
 * builds (Vitis/common/src: bring-up, engine setup, every console command, the self-test, the HSB
 * device mode) through a Linux platform layer (plat_linux.c), and serves:
 *  - the console on a Unix socket (/run/rocelet/roceletd.sock): the CLI rl, the web UI. Commands
 *    run one at a time, in the daemon, so a dropped SSH session never leaves a test half done;
 *  - the HSB control plane (when 'hsb on') as UDP sockets on rl0 (hsb_net.c);
 *  - the glue to the network interface rl0 (rl_net.ko): Linux owns the port's IP address, so the
 *    engine's MAC / IP follow rl0 (and the console's 'ip' / 'mac' / hololink-set-ip change rl0),
 *    the engine passes ARP / ICMP / all non-RoCE frames to the netdev DMA channel (CTRL.ARP_INT 0,
 *    OTHER_RX_EN 1, C_ODMA_CTRL 1). While a loopback test runs, rl0 is taken down and the engine's
 *    own ARP / ICMP responder is back (the suite tests it); afterwards everything is restored.
 *    Without rl0 (no driver, or the interface down) the engine answers ARP / ICMP itself.
 *
 * Usage: roceletd [-c file]... [-f] [-s socket] [-i iface]
 *   -c  configuration file (key = value; later files override): iface, hsb (on|off at start),
 *       socket, group, regs_uio, ddr_uio
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <net/if.h>
#include <net/if_arp.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "xil_printf.h"
#include "hw.h"
#include "util.h"
#include "plat.h"
#include "mac.h"
#include "eng.h"
#include "sysif.h"
#include "hsb.h"
#include "console.h"
#include "plat_linux.h"
#include "hsb_net.h"
#include "roceletd.h"

/* ---------------------------------------------------------------- configuration */
static struct {
	char iface[IFNAMSIZ];
	char socket[108];
	char group[64];
	char regs_uio[128];
	char ddr_uio[64];
	int  hsb;
} cfg = { "rl0", RLD_SOCKET, "rocelet", "rocelet-regs,rsys_aon_bd", "rocelet-ddr", 0 };

static void trim(char *s)
{
	char *e = s + strlen(s);
	while (e > s && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\n' || e[-1] == '\r')) *--e = 0;
	char *b = s;
	while (*b == ' ' || *b == '\t') b++;
	if (b != s) memmove(s, b, strlen(b) + 1);
}

static void cfg_load(const char *path)
{
	FILE *f = fopen(path, "r");
	if (!f) { dlog("roceletd: %s: %s", path, strerror(errno)); return; }
	char line[256];
	while (fgets(line, sizeof(line), f)) {
		char *h = strchr(line, '#');
		if (h) *h = 0;
		char *eq = strchr(line, '=');
		if (!eq) continue;
		*eq = 0;
		char *k = line, *v = eq + 1;
		trim(k);
		trim(v);
		if (!strcmp(k, "iface")) snprintf(cfg.iface, sizeof(cfg.iface), "%s", v);
		else if (!strcmp(k, "socket")) snprintf(cfg.socket, sizeof(cfg.socket), "%s", v);
		else if (!strcmp(k, "group")) snprintf(cfg.group, sizeof(cfg.group), "%s", v);
		else if (!strcmp(k, "regs_uio")) snprintf(cfg.regs_uio, sizeof(cfg.regs_uio), "%s", v);
		else if (!strcmp(k, "ddr_uio")) snprintf(cfg.ddr_uio, sizeof(cfg.ddr_uio), "%s", v);
		else if (!strcmp(k, "hsb")) cfg.hsb = !strcmp(v, "on") || !strcmp(v, "1") || !strcmp(v, "yes");
		else if (*k) dlog("roceletd: %s: unknown key '%s'", path, k);
	}
	fclose(f);
}

const char *rld_iface(void) { return cfg.iface; }

/* ---------------------------------------------------------------- rl0 */
static int g_ioc = -1;                     /* AF_INET datagram socket for the interface ioctls */

static int ifr_get(unsigned long req, struct ifreq *r)
{
	memset(r, 0, sizeof(*r));
	snprintf(r->ifr_name, IFNAMSIZ, "%s", cfg.iface);
	return ioctl(g_ioc, req, r);
}

static int net_present(void) { return if_nametoindex(cfg.iface) != 0; }

static int net_flags(void)
{
	struct ifreq r;
	return ifr_get(SIOCGIFFLAGS, &r) < 0 ? 0 : r.ifr_flags;
}

static void net_admin(int up)
{
	struct ifreq r;
	if (ifr_get(SIOCGIFFLAGS, &r) < 0) return;
	r.ifr_flags = up ? (r.ifr_flags | IFF_UP) : (r.ifr_flags & ~IFF_UP);
	if (ioctl(g_ioc, SIOCSIFFLAGS, &r) < 0) dlog("roceletd: %s %s: %s", cfg.iface, up ? "up" : "down", strerror(errno));
}

static int net_mac(u8 *m)
{
	struct ifreq r;
	if (ifr_get(SIOCGIFHWADDR, &r) < 0) return -1;
	memcpy(m, r.ifr_hwaddr.sa_data, 6);
	return 0;
}

static u32 net_ip(void)
{
	struct ifreq r;
	if (ifr_get(SIOCGIFADDR, &r) < 0) return 0;
	return ntohl(((struct sockaddr_in *)&r.ifr_addr)->sin_addr.s_addr);
}

void rld_set_ip(u32 ip)
{
	struct ifreq r;
	memset(&r, 0, sizeof(r));
	snprintf(r.ifr_name, IFNAMSIZ, "%s", cfg.iface);
	struct sockaddr_in *a = (struct sockaddr_in *)&r.ifr_addr;
	a->sin_family = AF_INET;
	a->sin_addr.s_addr = htonl(ip);
	if (ioctl(g_ioc, SIOCSIFADDR, &r) < 0) { dlog("roceletd: %s address: %s", cfg.iface, strerror(errno)); return; }
	a->sin_addr.s_addr = htonl(0xFFFFFF00u);
	if (ioctl(g_ioc, SIOCSIFNETMASK, &r) < 0) dlog("roceletd: %s netmask: %s", cfg.iface, strerror(errno));
}

static void net_set_mac(const u8 *m)
{
	struct ifreq r;
	memset(&r, 0, sizeof(r));
	snprintf(r.ifr_name, IFNAMSIZ, "%s", cfg.iface);
	r.ifr_hwaddr.sa_family = ARPHRD_ETHER;
	memcpy(r.ifr_hwaddr.sa_data, m, 6);
	if (ioctl(g_ioc, SIOCSIFHWADDR, &r) < 0) dlog("roceletd: %s MAC: %s", cfg.iface, strerror(errno));
}

static u64 net_stat(const char *name)
{
	char p[128], v[32];
	snprintf(p, sizeof(p), "/sys/class/net/%s/statistics/%s", cfg.iface, name);
	FILE *f = fopen(p, "r");
	if (!f) return 0;
	u64 x = 0;
	if (fgets(v, sizeof(v), f)) x = strtoull(v, NULL, 10);
	fclose(f);
	return x;
}

/* ---------------------------------------------------------------- engine <-> rl0 */
static int g_paused;                       /* a loopback test runs: rl0 down, engine responder on */
static int g_netdev;                       /* the engine is in netdev mode (last applied) */
static int g_synced;
static u8  g_last_mac[6];
static u32 g_last_ip;

static int eng_ready(void) { return console_eng_ok() && mac_clk_ok(); }

static void eng_addr_write(void)
{
	eng_wr(ROCELET_MAC_LO, ((u32)MY_MAC[2] << 24) | ((u32)MY_MAC[3] << 16) | ((u32)MY_MAC[4] << 8) | MY_MAC[5]);
	eng_wr(ROCELET_MAC_HI, ((u32)MY_MAC[0] << 8) | MY_MAC[1]);
	eng_wr(ROCELET_IP4, MY_IP);
	mac_set_addr(MY_MAC);
}

/* netdev mode on: ARP / ICMP / all non-RoCE frames to the netdev DMA channel (Linux answers);
 * off: the engine's own ARP / ICMP responder, other traffic not delivered */
static void eng_netdev(int on)
{
	g_netdev = on;
	if (!eng_ready()) return;
	if (on) {
		eng_ctrl_set(ROCELET_CTRL_OTHER_RX_EN_MASK, ROCELET_CTRL_ARP_INT_MASK);
		cfg_set(RSYS_C_CRX_CTRL, 0);
		cfg_set(RSYS_C_ODMA_CTRL, 1);
	} else {
		cfg_set(RSYS_C_ODMA_CTRL, 0);
		eng_ctrl_set(ROCELET_CTRL_ARP_INT_MASK, ROCELET_CTRL_OTHER_RX_EN_MASK);
	}
}

/* addresses: the console changed MY_IP / MY_MAC ('ip', 'mac', set-ip) -> rl0 follows; else
 * rl0 changed (ip addr, networkd) -> the engine follows. Then the engine mode for rl0's state. */
static void net_sync(void)
{
	if (!net_present()) {
		if (g_netdev || !g_synced) eng_netdev(0);
		g_synced = 1;
		return;
	}
	u8 m[6];
	u32 ip = net_ip();
	if (net_mac(m) == 0) {
		if (g_synced && memcmp(MY_MAC, g_last_mac, 6)) {
			net_set_mac(MY_MAC);
		} else if (memcmp(m, MY_MAC, 6)) {
			memcpy(MY_MAC, m, 6);
			if (eng_ready()) eng_addr_write();
		}
	}
	if (g_synced && MY_IP != g_last_ip) {
		rld_set_ip(MY_IP);
	} else if (ip && ip != MY_IP) {
		MY_IP = ip;
		if (eng_ready()) eng_addr_write();
	}
	memcpy(g_last_mac, MY_MAC, 6);
	g_last_ip = MY_IP;
	g_synced = 1;
	if (!g_paused) eng_netdev((net_flags() & IFF_UP) != 0);
}

static int g_was_up;

static void net_pause(void)
{
	g_paused = 1;
	g_was_up = net_present() && (net_flags() & IFF_UP);
	if (g_was_up) net_admin(0);
	eng_netdev(0);
}

static void net_resume(void)
{
	g_paused = 0;
	if (g_was_up) net_admin(1);
	if (eng_ready()) eng_addr_write();         /* the tests rewrite the engine's addresses */
}

static void net_status(void)
{
	int fl = net_present() ? net_flags() : 0;
	u8 m[6] = { 0 };
	u32 ip = net_present() ? net_ip() : 0;
	if (net_present()) net_mac(m);
	xil_printf("%s: %s", cfg.iface, !net_present() ? "not present (rl_net.ko not loaded?)" : (fl & IFF_UP) ? "up" : "down");
	if (net_present()) {
		xil_printf(", carrier %s | MAC ", (fl & IFF_RUNNING) ? "on" : "off");
		pr_mac(m);
		xil_printf(" IP ");
		pr_ip(ip);
		xil_printf(" | Linux rx %llu frames tx %llu frames, rx dropped %llu", (unsigned long long)net_stat("rx_packets"),
			   (unsigned long long)net_stat("tx_packets"), (unsigned long long)net_stat("rx_dropped"));
	}
	xil_printf("\r\nengine: MAC ");
	pr_mac(MY_MAC);
	xil_printf(" IP ");
	pr_ip(MY_IP);
	if (!eng_ready()) { xil_printf(" | MAC clock stopped or engine not found\r\n"); return; }
	u32 c = eng_rd(ROCELET_CTRL);
	xil_printf(" | %s (CTRL.ARP_INT %d, OTHER_RX_EN %d, C_ODMA_CTRL %u)%s\r\n",
		   (c & ROCELET_CTRL_ARP_INT_MASK) ? "ARP / ICMP answered by the engine" : "ARP / ICMP / other traffic to Linux",
		   (c & ROCELET_CTRL_ARP_INT_MASK) ? 1 : 0, (c & ROCELET_CTRL_OTHER_RX_EN_MASK) ? 1 : 0, cfg_get(RSYS_C_ODMA_CTRL),
		   g_paused ? " [paused for a test]" : "");
	xil_printf("netdev DMA channel: frames to Linux %u, dropped %u, from Linux %u\r\n", cnt(RSYS_E_ODMA_RX),
		   cnt(RSYS_E_ODMA_DROP), cnt(RSYS_E_ODMA_TX));
}

/* ---------------------------------------------------------------- JSON status (web UI) */
static char *js;
static size_t jn, jcap;

static void jp(const char *fmt, ...)
{
	va_list ap;
	for (;;) {
		va_start(ap, fmt);
		int n = vsnprintf(js ? js + jn : NULL, js ? jcap - jn : 0, fmt, ap);
		va_end(ap);
		if (n < 0) return;
		if (js && jn + (size_t)n < jcap) { jn += (size_t)n; return; }
		size_t nc = (jcap ? jcap * 2 : 8192) + (size_t)n;
		char *b = realloc(js, nc);
		if (!b) return;
		js = b;
		jcap = nc;
	}
}

static void jmac(const char *k, const u8 *m)
{
	jp("\"%s\":\"%02x:%02x:%02x:%02x:%02x:%02x\"", k, m[0], m[1], m[2], m[3], m[4], m[5]);
}

static void jip(const char *k, u32 ip)
{
	jp("\"%s\":\"%u.%u.%u.%u\"", k, ip >> 24, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255);
}

static const char *eng_cnt_name[] = { ROCELET_COUNTER_NAMES };

static void json_status(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	jn = 0;
	jp("{\"daemon\":\"%s\",\"target\":\"%s\",\"mac_name\":\"%s\",\"link_gbps\":%u,\"uptime_s\":%ld,", RLD_VERSION,
	   TARGET_NAME, MAC_NAME, LINK_GBPS, (long)ts.tv_sec);
	u32 st = aon_rd(AON_STATUS), ev = aon_rd(AON_LINK_EV);
	jp("\"aon\":{\"status\":%u,\"mac_khz\":%u,\"link\":%s,\"block_lock\":%s,\"qsfp_present\":%s,\"si5328_los\":%s,"
	   "\"link_up_events\":%u,\"link_down_events\":%u,\"poisoned_reads\":%u,\"ctrl\":%u},", st, aon_rd(AON_MAC_KHZ),
	   (st & AON_ST_LINK) ? "true" : "false", (st & AON_ST_LOCK) ? "true" : "false",
	   (st & AON_ST_MODPRSL) ? "false" : "true", (st & AON_ST_LOS) ? "true" : "false", ev & 0xFFFF, ev >> 16,
	   aon_rd(AON_POISON_RD), aon_rd(AON_CTRL));
	jp("\"mac_clock\":%s,\"engine_found\":%s,\"link_up\":%s,\"loopback\":\"%s\",\"hsb_on\":%s,\"netdev_mode\":%s,"
	   "\"paused\":%s,", mac_clk_ok() ? "true" : "false", console_eng_ok() ? "true" : "false",
	   mac_link_up() ? "true" : "false", loop_name(mac_loop()), hsb_on() ? "true" : "false", g_netdev ? "true" : "false",
	   g_paused ? "true" : "false");
	jmac("fpga_mac", MY_MAC);
	jp(",");
	jip("fpga_ip", MY_IP);
	jp(",");
	{
		u8 m[6] = { 0 };
		int pres = net_present(), fl = pres ? net_flags() : 0;
		if (pres) net_mac(m);
		jp("\"netdev\":{\"name\":\"%s\",\"present\":%s,\"up\":%s,\"carrier\":%s,", cfg.iface, pres ? "true" : "false",
		   (fl & IFF_UP) ? "true" : "false", (fl & IFF_RUNNING) ? "true" : "false");
		jmac("mac", m);
		jp(",");
		jip("ip", pres ? net_ip() : 0);
		jp(",\"rx_packets\":%llu,\"tx_packets\":%llu,\"rx_bytes\":%llu,\"tx_bytes\":%llu,\"rx_dropped\":%llu},",
		   (unsigned long long)net_stat("rx_packets"), (unsigned long long)net_stat("tx_packets"),
		   (unsigned long long)net_stat("rx_bytes"), (unsigned long long)net_stat("tx_bytes"),
		   (unsigned long long)net_stat("rx_dropped"));
	}
	jp("\"ddr\":{\"pa\":%llu,\"bytes\":%u", (unsigned long long)plat_ddr_pa(), plat_ddr_bytes());
	if (eng_ready()) {
		jp(",\"wr_bursts\":%u,\"rd_bursts\":%u,\"outside\":%u},", cnt(RSYS_E_DDR_WR_BURSTS), cnt(RSYS_E_DDR_RD_BURSTS),
		   cnt(RSYS_E_DDR_OOR));
		u64 cyc = eng_rd64(ROCELET_CYCLES_LO);
		jp("\"engine\":{\"version\":%u,\"num_qp\":%d,\"rx_bytes\":%llu,\"tx_bytes\":%llu,\"cycles\":%llu,\"clk_hz\":%u,"
		   "\"err\":%d,\"counters\":{", ENG.version, ENG.num_qp, (unsigned long long)eng_rd64(ROCELET_RX_BYTES_LO),
		   (unsigned long long)eng_rd64(ROCELET_TX_BYTES_LO), (unsigned long long)cyc, F_CLK_HZ, eng_err());
		int first = 1;
		for (int i = 0; i < ROCELET_NUM_COUNTERS; i++) {
			u32 v = eng_rd(ROCELET_CNT_BASE + 4u * (u32)i);
			if (!v) continue;
			jp("%s\"%s\":%u", first ? "" : ",", eng_cnt_name[i], v);
			first = 0;
		}
		jp("}},\"mac_counters\":{\"rx_frames\":%llu,\"rx_bad_fcs\":%llu,\"rx_bad_code\":%llu,\"tx_frames\":%llu,"
		   "\"link_drops\":%u,\"tx_underflow\":%u},", (unsigned long long)bc(RSYS_B_MAC_RX_PKTS),
		   (unsigned long long)bc(RSYS_B_MAC_RX_BAD_FCS), (unsigned long long)bc(RSYS_B_MAC_RX_BAD_CODE),
		   (unsigned long long)bc(RSYS_B_MAC_TX_PKTS), cnt(RSYS_E_MAC_ALIGN_LOST), cnt(RSYS_E_MAC_TX_UNF));
		jp("\"odma\":{\"to_linux\":%u,\"dropped\":%u,\"from_linux\":%u},", cnt(RSYS_E_ODMA_RX), cnt(RSYS_E_ODMA_DROP),
		   cnt(RSYS_E_ODMA_TX));
		jp("\"qp\":[");
		int nq = ENG.num_qp < 64 ? ENG.num_qp : 64;
		for (int q = 0; q < nq; q++) jp("%s%u", q ? "," : "", eng_qp_status(q));
		jp("]}");
	} else {
		jp("}}");
	}
	xil_printf("%s\n", js);
}

/* ---------------------------------------------------------------- commands */
static int run_line(int fd, const char *text)
{
	char line[1024], cmd[32] = "";
	snprintf(line, sizeof(line), "%s", text);
	sscanf(line, "%31s", cmd);
	if (!strcmp(cmd, "json")) { json_status(); return 0; }
	if (!strcmp(cmd, "net")) { net_status(); return 0; }
	if (!strcmp(cmd, "log")) { int n = 0; sscanf(line, "%*s %d", &n); dlog_dump(fd, n ? n : 100); return 0; }
	if (!strcmp(cmd, "version")) { xil_printf("roceletd %s (console sources: Vitis/common/src)\r\n", RLD_VERSION); return 0; }
	int test = console_is_test(cmd);
	if (test) net_pause();
	int rc = console_exec(line);
	if (test) net_resume();
	net_sync();
	if (!strcmp(cmd, "help") || !strcmp(cmd, "?") || !cmd[0])
		xil_printf(" Linux (roceletd): net   rl0 and the engine's netdev mode | log [n]   daemon messages | json | version\r\n");
	return rc;
}

/* ---------------------------------------------------------------- event loop */
#define MAXCLI 8
static struct cli { int fd; size_t n; char buf[2048]; } cli[MAXCLI];
static volatile sig_atomic_t g_stop;

static void on_signal(int s) { (void)s; g_stop = 1; }

static int ctl_listen(void)
{
	char dir[sizeof(cfg.socket)];
	snprintf(dir, sizeof(dir), "%s", cfg.socket);
	char *sl = strrchr(dir, '/');
	if (sl) { *sl = 0; mkdir(dir, 0755); }
	int s = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (s < 0) return -1;
	struct sockaddr_un a = { .sun_family = AF_UNIX };
	snprintf(a.sun_path, sizeof(a.sun_path), "%s", cfg.socket);
	unlink(cfg.socket);
	if (bind(s, (struct sockaddr *)&a, sizeof(a)) < 0 || listen(s, 8) < 0) {
		dlog("roceletd: %s: %s", cfg.socket, strerror(errno));
		close(s);
		return -1;
	}
	struct group *g = getgrnam(cfg.group);
	if (g && chown(cfg.socket, 0, g->gr_gid) < 0) dlog("roceletd: chown %s: %s", cfg.socket, strerror(errno));
	chmod(cfg.socket, g ? 0660 : 0600);
	return s;
}

static void cli_close(struct cli *c)
{
	close(c->fd);
	c->fd = -1;
	c->n = 0;
}

static void cli_serve(struct cli *c)
{
	ssize_t r = recv(c->fd, c->buf + c->n, sizeof(c->buf) - 1 - c->n, 0);
	if (r <= 0) { cli_close(c); return; }
	c->n += (size_t)r;
	for (;;) {
		char *nl = memchr(c->buf, '\n', c->n);
		if (!nl) {
			if (c->n >= sizeof(c->buf) - 1) cli_close(c);      /* no line end in 2 KB */
			return;
		}
		*nl = 0;
		out_begin(c->fd);
		int rc = run_line(c->fd, c->buf);
		int gone = out_client() == -2;
		out_end();
		if (gone) { cli_close(c); return; }
		char t[16];
		int tn = snprintf(t, sizeof(t), "%c%d\n", 0, rc);
		if (send(c->fd, t, (size_t)tn, MSG_NOSIGNAL) < 0) { cli_close(c); return; }
		size_t used = (size_t)(nl + 1 - c->buf);
		memmove(c->buf, nl + 1, c->n - used);
		c->n -= used;
	}
}

/* always-on interrupt: edge sources only (link change, QSFP plug, Si5328 LOS change) */
#define IRQ_SOURCES ((1u << 0) | (1u << 7) | (1u << 8))

static void irq_serve(void)
{
	u32 cnt32;
	if (read(plat_regs_fd(), &cnt32, 4) != 4) return;
	u32 s = aon_rd(AON_IRQ_STATUS);
	aon_wr(AON_IRQ_STATUS, s);
	u32 st = aon_rd(AON_STATUS);
	if (s & 1u) dlog("roceletd: port 0 link %s (always-on status 0x%05x)", (st & AON_ST_LINK) ? "up" : "down", st);
	if (s & (1u << 7)) dlog("roceletd: QSFP28 module %s", (st & AON_ST_MODPRSL) ? "removed" : "inserted");
	if (s & (1u << 8)) dlog("roceletd: Si5328 LOS %s", (st & AON_ST_LOS) ? "set" : "cleared");
	u32 one = 1;
	if (write(plat_regs_fd(), &one, 4) != 4) dlog("roceletd: UIO interrupt re-enable failed");
}

static void usage(void)
{
	fprintf(stderr, "usage: roceletd [-c config]... [-f] [-s socket] [-i iface]\n");
	exit(2);
}

int main(int argc, char **argv)
{
	int opt;
	setvbuf(stdout, NULL, _IOLBF, 0);
	while ((opt = getopt(argc, argv, "c:s:i:fh")) != -1) {
		switch (opt) {
		case 'c': cfg_load(optarg); break;
		case 's': snprintf(cfg.socket, sizeof(cfg.socket), "%s", optarg); break;
		case 'i': snprintf(cfg.iface, sizeof(cfg.iface), "%s", optarg); break;
		case 'f': break;                    /* foreground: always (systemd) */
		default: usage();
		}
	}
	signal(SIGPIPE, SIG_IGN);
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	for (int i = 0; i < MAXCLI; i++) cli[i].fd = -1;

	g_ioc = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	int ls = ctl_listen();                  /* first: clients wait while the hardware comes up */
	if (ls < 0) return 1;
	if (plat_linux_open(cfg.regs_uio, cfg.ddr_uio, 30) != 0) return 1;

	/* the engine takes rl0's addresses from the start (else the bare-metal defaults) */
	for (int t = 0; t < 50 && !net_present(); t++) usleep(100000);
	if (net_present()) {
		u8 m[6];
		u32 ip = net_ip();
		if (net_mac(m) == 0) memcpy(MY_MAC, m, 6);
		if (ip) MY_IP = ip;
	} else {
		dlog("roceletd: no interface %s yet: the engine answers ARP / ICMP itself", cfg.iface);
	}

	console_init();                         /* Si5328, GT, MAC, engine, loopback setup (journal) */
	g_synced = 0;
	net_sync();
	aon_wr(AON_IRQ_STATUS, 0xFFFFFFFFu);
	aon_wr(AON_IRQ_ENABLE, IRQ_SOURCES);
	{
		u32 one = 1;
		if (write(plat_regs_fd(), &one, 4) != 4) dlog("roceletd: UIO interrupt enable failed (no IRQ in the DT?)");
	}
	if (cfg.hsb) {
		char l[] = "hsb on";
		console_exec(l);
	}
	dlog("roceletd %s ready: %s, console on %s", RLD_VERSION, cfg.iface, cfg.socket);

	time_t last = time(NULL);
	while (!g_stop) {
		struct pollfd pf[MAXCLI + 6];
		int n = 0, hfds[2];
		pf[n++] = (struct pollfd){ .fd = ls, .events = POLLIN };
		pf[n++] = (struct pollfd){ .fd = plat_regs_fd(), .events = POLLIN };
		int nh = hsb_net_fds(hfds);
		for (int i = 0; i < nh; i++) pf[n++] = (struct pollfd){ .fd = hfds[i], .events = POLLIN };
		int c0 = n;
		for (int i = 0; i < MAXCLI; i++)
			if (cli[i].fd >= 0) pf[n++] = (struct pollfd){ .fd = cli[i].fd, .events = POLLIN };
		/* HSB on: 10 ms (keepalive watchdog, link pause, BOOTP timer), else 200 ms */
		int r = poll(pf, (nfds_t)n, hsb_on() ? 10 : 200);
		if (r < 0 && errno != EINTR) { dlog("roceletd: poll: %s", strerror(errno)); break; }
		if (r > 0) {
			if (pf[1].revents & POLLIN) irq_serve();
			if (pf[0].revents & POLLIN) {
				int fd = accept4(ls, NULL, NULL, SOCK_CLOEXEC);
				if (fd >= 0) {
					int k = 0;
					while (k < MAXCLI && cli[k].fd >= 0) k++;
					if (k == MAXCLI) close(fd);
					else { cli[k].fd = fd; cli[k].n = 0; }
				}
			}
			for (int j = c0; j < n; j++) {
				if (!(pf[j].revents & (POLLIN | POLLHUP | POLLERR))) continue;
				for (int i = 0; i < MAXCLI; i++)
					if (cli[i].fd == pf[j].fd) { cli_serve(&cli[i]); break; }
			}
		}
		if (hsb_on() && console_eng_ok() && mac_clk_ok()) hsb_poll();
		time_t now = time(NULL);
		if (now != last) { last = now; net_sync(); }
	}
	dlog("roceletd: stopping (hardware left as it is)");
	unlink(cfg.socket);
	return 0;
}
