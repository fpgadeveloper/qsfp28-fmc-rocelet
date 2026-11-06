/*
 * console.h - the console of the qsfp28-fmc-rocelet design as a library (main.c): bring-up and
 * one command line at a time. The standalone BSPs feed it from the UART (main() in main.c), the
 * Linux daemon roceletd from its control socket (sw/linux/roceletd).
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#ifndef CONSOLE_H_
#define CONSOLE_H_

void console_init(void);                   /* banner, Si5328 + MAC bring-up, engine probe, loopback setup */
int  console_exec(char *line);             /* one command line (tokenised in place); non-zero = a test failed */
int  console_is_test(const char *cmd);     /* cmd runs the loopback test suite (re-configures every QP) */
int  console_eng_ok(void);                 /* the engine was found (rocelet_sys accessible once) */

#endif
