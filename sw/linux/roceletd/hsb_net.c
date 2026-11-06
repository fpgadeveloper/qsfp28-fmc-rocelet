/*
 * hsb_net.c - HSB control-plane transport on Linux (see hsb_net.h): the protocol itself is
 * Vitis/common/src/hsb.c, unchanged. Enumeration: BOOTP from UDP 12268 to the limited broadcast
 * 255.255.255.255:12267 once a second (SO_BROADCAST, bound to rl0); hololink-set-ip replies
 * arrive on 12268; register protocol: requests on 8192, replies from 8192.
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <net/if_arp.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#include "xil_printf.h"
#include "hsb_net.h"
#include "roceletd.h"

static int s_reg = -1, s_enum = -1;
static u32 n_rx, n_tx, n_txerr;

static int udp_sock(unsigned port, int bcast)
{
	int s = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
	if (s < 0) return -1;
	int one = 1;
	setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	if (bcast) setsockopt(s, SOL_SOCKET, SO_BROADCAST, &one, sizeof(one));
	const char *ifn = rld_iface();
	if (setsockopt(s, SOL_SOCKET, SO_BINDTODEVICE, ifn, (socklen_t)strlen(ifn)) < 0) {
		xil_printf("hsb: SO_BINDTODEVICE %s: %s\r\n", ifn, strerror(errno));
		close(s);
		return -1;
	}
	struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons((u16)port), .sin_addr.s_addr = htonl(INADDR_ANY) };
	if (bind(s, (struct sockaddr *)&a, sizeof(a)) < 0) {
		xil_printf("hsb: bind UDP %u: %s\r\n", port, strerror(errno));
		close(s);
		return -1;
	}
	return s;
}

int hsb_net_open(void)
{
	hsb_net_close();
	s_reg = udp_sock(8192, 0);
	s_enum = udp_sock(12268, 1);
	if (s_reg < 0 || s_enum < 0) { hsb_net_close(); return -1; }
	n_rx = n_tx = n_txerr = 0;
	return 0;
}

void hsb_net_close(void)
{
	if (s_reg >= 0) close(s_reg);
	if (s_enum >= 0) close(s_enum);
	s_reg = s_enum = -1;
}

void hsb_net_send(u32 dip, u32 sport, u32 dport, const u8 *p, int n)
{
	int s = sport == 8192 ? s_reg : s_enum;
	if (s < 0) return;
	struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons((u16)dport), .sin_addr.s_addr = htonl(dip) };
	if (sendto(s, p, (size_t)n, 0, (struct sockaddr *)&a, sizeof(a)) < 0) n_txerr++;
	else n_tx++;
}

/* the neighbour's MAC from the ARP cache of rl0 (zeros if unknown) */
static void arp_lookup(int s, u32 ip, u8 *mac)
{
	struct arpreq r;
	memset(&r, 0, sizeof(r));
	memset(mac, 0, 6);
	struct sockaddr_in *a = (struct sockaddr_in *)&r.arp_pa;
	a->sin_family = AF_INET;
	a->sin_addr.s_addr = htonl(ip);
	snprintf(r.arp_dev, sizeof(r.arp_dev), "%s", rld_iface());
	if (ioctl(s, SIOCGARP, &r) == 0 && (r.arp_flags & ATF_COM)) memcpy(mac, r.arp_ha.sa_data, 6);
}

int hsb_net_recv(u32 *sip, u32 *sport, u32 *dport, u8 *smac, u8 *p, int max)
{
	int socks[2] = { s_reg, s_enum };
	unsigned ports[2] = { 8192, 12268 };
	for (int i = 0; i < 2; i++) {
		if (socks[i] < 0) continue;
		struct sockaddr_in a;
		socklen_t al = sizeof(a);
		ssize_t n = recvfrom(socks[i], p, (size_t)max, MSG_DONTWAIT, (struct sockaddr *)&a, &al);
		if (n < 0) continue;
		*sip = ntohl(a.sin_addr.s_addr);
		*sport = ntohs(a.sin_port);
		*dport = ports[i];
		arp_lookup(socks[i], *sip, smac);
		n_rx++;
		return (int)n;
	}
	return -1;
}

void hsb_net_set_ip(u32 ip) { rld_set_ip(ip); }

void hsb_net_status(void)
{
	xil_printf("control plane: UDP sockets on %s (register protocol 8192, enumeration 12268 -> 12267) %s | datagrams"
		   " received %u sent %u, send errors %u\r\n", rld_iface(), s_reg >= 0 ? "open" : "closed", n_rx, n_tx, n_txerr);
}

int hsb_net_fds(int *fds)
{
	int n = 0;
	if (s_reg >= 0) fds[n++] = s_reg;
	if (s_enum >= 0) fds[n++] = s_enum;
	return n;
}
