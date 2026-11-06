/*
 * rl - command-line client of roceletd: the qsfp28-fmc-rocelet console on Linux.
 *
 *   rl <command ...>      run one console command, print its output as it arrives; the exit
 *                         status is 0, or 1 when the command reported a failure (e.g. the
 *                         self-test's "SELFTEST FAIL" line), 2 when the daemon cannot be reached
 *   rl                    interactive: one command per line ("rl> " prompt on a terminal)
 *   rl -s <socket> ...    another control socket (default /run/rocelet/roceletd.sock)
 *
 * Examples: rl st | rl t pma | rl qp 0 | rl RLH qpn=0x... psn=0x... ip=192.168.20.1 mac=... mtu=4096
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "roceletd.h"

static int connect_daemon(const char *path)
{
	int s = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (s < 0) return -1;
	struct sockaddr_un a = { .sun_family = AF_UNIX };
	snprintf(a.sun_path, sizeof(a.sun_path), "%s", path);
	if (connect(s, (struct sockaddr *)&a, sizeof(a)) < 0) {
		fprintf(stderr, "rl: cannot reach roceletd on %s: %s%s\n", path, strerror(errno),
			errno == EACCES ? " (run as root or as a member of the group rocelet)" :
			errno == ENOENT || errno == ECONNREFUSED ? " (systemctl status roceletd)" : "");
		close(s);
		return -1;
	}
	return s;
}

/* send one line, copy the answer to stdout; returns the command's status, -1 on a lost daemon */
static int command(int s, const char *line)
{
	size_t l = strlen(line);
	if (send(s, line, l, MSG_NOSIGNAL) < 0 || send(s, "\n", 1, MSG_NOSIGNAL) < 0) return -1;
	char b[4096];
	int in_status = 0, status = 0;
	for (;;) {
		ssize_t r = recv(s, b, sizeof(b), 0);
		if (r <= 0) return -1;
		for (ssize_t i = 0; i < r; i++) {
			if (in_status) {
				if (b[i] == '\n') { fflush(stdout); return status; }
				if (b[i] >= '0' && b[i] <= '9') status = status * 10 + (b[i] - '0');
			} else if (b[i] == 0) {
				in_status = 1;
			} else {
				putchar(b[i]);
			}
		}
		fflush(stdout);
	}
}

int main(int argc, char **argv)
{
	const char *path = RLD_SOCKET;
	int a = 1;
	if (a + 1 < argc && !strcmp(argv[a], "-s")) { path = argv[a + 1]; a += 2; }
	if (a < argc && (!strcmp(argv[a], "-h") || !strcmp(argv[a], "--help"))) {
		printf("usage: rl [-s socket] [console command ...]   (no command: interactive; 'rl help' lists the commands)\n");
		return 0;
	}
	int s = connect_daemon(path);
	if (s < 0) return 2;
	if (a < argc) {
		char line[1024] = "";
		for (int i = a; i < argc; i++) {
			if (i > a) strncat(line, " ", sizeof(line) - strlen(line) - 1);
			strncat(line, argv[i], sizeof(line) - strlen(line) - 1);
		}
		int rc = command(s, line);
		close(s);
		if (rc < 0) { fprintf(stderr, "rl: connection to roceletd lost\n"); return 2; }
		return rc ? 1 : 0;
	}
	int tty = isatty(0), last = 0;
	char *line = NULL;
	size_t cap = 0;
	for (;;) {
		if (tty) { fputs("rl> ", stdout); fflush(stdout); }
		ssize_t n = getline(&line, &cap, stdin);
		if (n < 0) break;
		while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
		if (!strcmp(line, "quit") || !strcmp(line, "exit")) break;
		last = command(s, line);
		if (last < 0) { fprintf(stderr, "rl: connection to roceletd lost\n"); free(line); return 2; }
	}
	free(line);
	close(s);
	return last ? 1 : 0;
}
