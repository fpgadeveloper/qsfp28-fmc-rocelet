/*
 * hsb_regs.h - the Opsero registers of the qsfp28-fmc-rocelet HSB device mode, as a host
 * reaches them with the HSB register protocol (UDP 8192, e.g. Hololink.write_uint32 /
 * read_uint32). Big-endian on the wire like every HSB register; 32-bit, word aligned.
 * Reference for host code (sw/hsb/); behaviour in docs/source/hsb.md, "Opsero registers".
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#ifndef HSB_REGS_H_
#define HSB_REGS_H_

#define OPS_BASE                0x7F000000u
#define OPS_ID                  0x7F000000u /* RO  "OPSR" = 0x4F505352 */
#define OPS_SOURCE              0x7F000004u /* RW  0 IQ16 (default), 1 counter, 2 beam array; next data-plane enable */
#define OPS_RATE_MBPS           0x7F000008u /* RW  frame rate limit, Mb/s of frame + 128-B metadata, 0 = none (default 1000); live: a running stream follows from the next frame */
#define OPS_SCENE               0x7F00000Cu /* RW  IQ16 scene 1 survey (default), 2 radar, 3 tones, 4 noise */
#define OPS_FRAMES              0x7F000010u /* RO  frames completed since the producer last started */
#define OPS_STATUS              0x7F000014u /* RO  see OPS_STATUS_* */
#define OPS_STATUS_RUNNING      0x01u       /*     [0] producer running */
#define OPS_STATUS_DP_ON        0x02u       /*     [1] data plane enabled (DP_VP_MASK bit 0 accepted) */
#define OPS_STATUS_LINK_PAUSED  0x04u       /*     [2] producer paused because the link went down */
#define OPS_STATUS_LPAUSE_EN    0x08u       /*     [3] link pause enabled (console 'hsb lpause on|off', default on) */
#define OPS_STATUS_KA_ARMED     0x10u       /*     [4] keepalive watchdog armed (KEEPALIVE_TIMEOUT_MS != 0) */
/* 0x7F000018, 0x7F00001C: reserved, read 0, writes ignored */
#define OPS_KEEPALIVE_TIMEOUT_MS 0x7F000020u /* RW  0 = watchdog off (default). While the data plane is enabled the
                                                  producer stops when no KEEPALIVE write arrived for this many ms.
                                                  A write restarts the timer. Back to 0 at an HSB reset (0x4 bit 3),
                                                  at 'hsb on' and when the watchdog fires (one-shot) */
#define OPS_KEEPALIVE           0x7F000024u /* W: any value restarts the timer. R: ms since the timer last restarted */
#define OPS_WATCHDOG_COUNT      0x7F000028u /* RO  watchdog stops since 'hsb on' (kept across HSB resets) */
#define OPS_LINKPAUSE_COUNT     0x7F00002Cu /* RO  link pauses since 'hsb on' (kept across HSB resets) */
/* beam array generator (docs/source/beam_contract.md section 4): mapped 1:1 to the system registers */
#define OPS_BM_BASE             0x7F000100u /* RW  0x7F000100..0x7F0002FF: sources, array words, SCENE_ID, APPLY, gains */
#define OPS_BM_SRC(s)           (OPS_BM_BASE + 0x20u * (s)) /* + 0x00 CTRL 0x04 AMP 0x08 INC 0x0C RATE_LO 0x10 RATE_HI
                                                          0x14 WIDTH 0x18 U 0x1C V (Q2.30) */
#define OPS_BM_NOISE_AMP        0x7F000180u
#define OPS_BM_NOISE_SEED       0x7F000184u
#define OPS_BM_EN_LO            0x7F000188u
#define OPS_BM_EN_HI            0x7F00018Cu
#define OPS_BM_SCENE_ID         0x7F000190u
#define OPS_BM_APPLY            0x7F000194u /* W: the scene becomes active at the next frame boundary */
#define OPS_BM_GAIN(k)          (0x7F000200u + 4u * (k)) /* [15:0] I [31:16] Q, Q2.14 */
#define OPS_BM_STAT             0x7F000300u /* RO  0x7F000300..0x7F000318 */
#define OPS_BM_STATUS           0x7F000300u /* [0] pending [1] running [2] clipped [15:8] model version */
#define OPS_BM_APPLIED_ID       0x7F000304u
#define OPS_BM_APPLIED_FRAME    0x7F000308u
#define OPS_BM_APPLIES          0x7F00030Cu
#define OPS_BM_CAPS             0x7F000310u /* 0x01440808 */

#endif
