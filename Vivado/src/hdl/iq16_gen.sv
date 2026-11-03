// SPDX-License-Identifier: MIT
//
// iq16_gen - the IQ16 test-signal generator of the qsfp28-fmc-rocelet Holoscan Sensor Bridge
// producer: 16 complex int16 samples per clock (512 bits = one payload beat),
// x(n) = sat16(4 tones + sawtooth chirp + noise), bit-exact with the integer model
// sw/hsb/rocelet_iq.py (E() = exp_phi, the tone coefficients = plan, the noise = _hash and
// _noise1, the sum and saturation = samples). rsys_iq_src.sv runs it in the 200 MHz generator
// clock; rsys_beam_src.sv reuses its E(), hash and FIFO modules.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-rocelet reference design and is
// licensed under the MIT license (see LICENSE at the repo root).
//
// Clock: one clock (gen_clk, 200 MHz, in rsys_iq_src).
//
// Structure
//   config engine  COMMIT latches the shadow registers (held off for up to 2
//                  clocks while a copy into the active set is in flight) and
//                  computes, in ~80 clocks, the per-configuration lane
//                  constants: C_t,k = rnd(A_t E(k inc_t), 9) (one shared E()
//                  unit, 64 entries, written through a 2-level fan-out tree) and
//                  the chirp lane start values (adders only). Then the set is
//                  "ready" (st_pending = taken, computing or ready). The
//                  copy into the active set (~5k registers, many of them DSP
//                  input registers) is enabled by a replicated register 2
//                  clocks after the head asks for it.
//   head           the phase / index counters of the beat to generate: n (lane 0
//                  sample index), the tone base phases [16 inc_t q]_32, the
//                  chirp lane accumulators acc(m + k) and their 16-sample steps,
//                  the noise key multiplier [n[63:32] 0x9E3779B9]_32 (updated
//                  when n[31:0] wraps). The head is the only logic that stops:
//                  it advances one beat per clock while it holds a credit
//                  (credits = FIFO slots not yet claimed by the FIFO or the
//                  pipeline), so the deep pipeline below runs without a clock
//                  enable.
//   pipeline       PIPE_LAT = 16 clocks, free running, a valid bit per stage:
//                  4 tones   E(base) [7] -> fan-out [1] -> 16 complex multiplies B x C_k [4]
//                  chirp     16 x E(acc[47:16]) [7] -> x A_c, rnd 17 [2]
//                  noise     32 x lowbias32 [9] -> byte sum [1] -> x A_n [2]
//                  sum       pairs [1] -> sum [1] -> sat16 + clip [1] -> pack [1]
//   FIFO           2**FIFO_AW x 546 bit LUTRAM + output register (first word
//                  fall through): {cfg_first, cfg_id, clip, 16 samples}.
//
// Configuration changes (the constants are global, so they change only when
// the pipeline is empty):
//   * idle (enable = 0, head idle): a ready set is applied at once, n0 = 0;
//   * start (the start pulse of an IQ16 run): the pipeline and the FIFO are
//     flushed, the head waits for a set still being computed, applies a ready
//     set and restarts at n = 0, n0 = 0; the first beat carries cfg_first;
//   * running: at the next chunk boundary of the head (chunk_pbeats payload
//     beats per chunk, latched at start) with a ready set, the head stops,
//     the pipeline drains (16 clocks), the set is applied with n0 = the next
//     beat's n, the tone / chirp phases restart, the noise keeps the global
//     n, and that beat carries cfg_first. The head runs at most 2**FIFO_AW
//     beats ahead of the consumer, so this is the chunk the consumer starts
//     next or the one after it; o_cfg_first and o_cfg_id on the beat say
//     which.
//
// Arithmetic: every width, product and rounding as in sw/hsb/rocelet_iq.py. C_t,k are
// 25-bit (24 bits suffice for amplitudes <= 32767, the 16-bit registers allow
// 65535), tones 19-bit, chirp 18-bit, noise 20-bit, the sum 23-bit before
// saturation. Lane k of the beat holds sample n + k at bits 32k +: 32
// (I low, Q high).
//
// E() units: 21 (4 tones, 16 chirp lanes, 1 engine), each a 256 x 17 quarter-wave
// ROM read on two ports + 3 DSPs; ROM_STYLE "block" puts each ROM in one RAMB18
// (21 in all), "distributed" in ~140 LUTs each.
//
// SEEK_EN (simulation only, 0 in the design): at start the head takes its
// state from the seek_* ports instead of n = 0, so a testbench can check
// samples at any n (the golden words near 2**32 and 2**44) without simulating
// up to them.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module iq16_gen #(
    parameter int N_TONES = 4,         // 4 (contract) or 2 (fallback: tones 2, 3 silent)
    parameter int FIFO_AW = 5,         // output FIFO 2**FIFO_AW beats (> PIPE_LAT)
    parameter bit SEEK_EN = 1'b0,
    parameter string ROM_STYLE = "block"  // E() quarter-wave ROMs: "block" (21 RAMB18) or "distributed"
) (
    input  wire logic              clk,
    input  wire logic              rst,

    // shadow configuration (the IQ16 configuration registers) and COMMIT (pulse)
    input  wire logic [31:0]       sh_cfg_id,
    input  wire logic [3:0][31:0]  sh_tone_inc,
    input  wire logic [3:0][15:0]  sh_tone_amp,
    input  wire logic [31:0]       sh_chirp_start,
    input  wire logic [47:0]       sh_chirp_rate,
    input  wire logic [47:0]       sh_chirp_per,
    input  wire logic [15:0]       sh_chirp_amp,
    input  wire logic [15:0]       sh_noise_amp,
    input  wire logic [31:0]       sh_noise_seed,
    input  wire logic              commit,

    // run control
    input  wire logic              start,         // pulse: restart at n = 0
    input  wire logic              enable,        // an IQ16 run is active
    input  wire logic [17:0]       chunk_pbeats,  // payload beats per chunk (>= 1)

    // beats (first word fall through)
    output wire logic              o_valid,
    output wire logic [511:0]      o_data,
    output wire logic              o_clip,        // a sample of this beat saturated
    output wire logic              o_cfg_first,   // first beat of a configuration (n = n0)
    output wire logic [31:0]       o_cfg_id,
    input  wire logic              o_pop,

    // status
    output wire logic              st_pending,    // a commit is not applied yet
    output wire logic [31:0]       st_active_id,
    output wire logic [63:0]       st_active_n0,
    output wire logic [31:0]       st_commits,
    output wire logic              st_apply,      // pulse: a configuration was applied

    // simulation only (SEEK_EN): head state at start
    input  wire logic [63:0]       seek_n,
    input  wire logic [63:0]       seek_n0,
    input  wire logic [31:0]       seek_keymul,
    input  wire logic [3:0][31:0]  seek_bp,
    input  wire logic [47:0]       seek_m,
    input  wire logic [15:0][47:0] seek_acc,
    input  wire logic [15:0][47:0] seek_dl
);

localparam int PIPE_LAT = 16;
localparam int FIFO_W   = 512 + 1 + 32 + 1;
localparam logic [FIFO_AW:0] FIFO_N = (FIFO_AW+1)'(2**FIFO_AW);

if (FIFO_AW < 5)
    $fatal(0, "Error: iq16_gen FIFO_AW must be >= 5 (FIFO deeper than the pipeline) (instance %m)");
if (N_TONES != 4 && N_TONES != 2)
    $fatal(0, "Error: iq16_gen N_TONES must be 4 or 2 (instance %m)");

// ============================================================================
// Configuration engine
// ============================================================================
// COMMIT is taken (the shadow registers latched, the engine started) when no
// copy into the active set is in flight; a COMMIT while one is still being
// computed restarts the engine (the earlier configuration is never applied).
logic              c_pend = 1'b0;       // COMMIT seen, shadow not latched yet
(* max_fanout = 8 *)  logic a_ld1 = 1'b0;   // copy into the active set: request + 1
(* max_fanout = 64 *) logic a_ld2 = 1'b0;   // copy into the active set: request + 2 (the copy)
// latched configuration
logic [31:0]       l_id = '0;
logic [3:0][31:0]  l_inc = '0;
logic [3:0][15:0]  l_amp = '0;
logic [31:0]       l_cstart = '0;
logic [47:0]       l_rate = '0, l_per = '0;
logic [15:0]       l_camp = '0, l_namp = '0;
logic [31:0]       l_seed = '0;
// computed per-lane constants
logic signed [24:0] n_ck_re [4][16] = '{default: '0};
logic signed [24:0] n_ck_im [4][16] = '{default: '0};
logic [47:0]        n_a0 [16] = '{default: '0};
logic [47:0]        n_dl0 [16] = '{default: '0};

logic        e_busy = 1'b0, e_ready = 1'b0, e_run = 1'b0;
logic [5:0]  e_idx = '0;
logic [31:0] e_ph = '0;
logic        c_run = 1'b0;
logic [3:0]  c_k = '0;
logic [47:0] c_g = '0, c_a0 = '0, c_r120 = '0;

// E(k inc_t) [7] -> x A_t [1] -> + rnd [1] -> fan-out tree [2] -> entry (t, k).
// The 64 entries end up next to their DSPs (as DSP input registers), so the
// write data reaches them through two register levels of fan-out 8.
localparam int E_WB = 9;
logic [E_WB:1]      e_dv = '0;
logic [5:0]         e_didx [E_WB+1] = '{default: '0};
logic signed [17:0] e_re, e_im;
logic signed [34:0] e_mre = '0, e_mim = '0, e_pre = '0, e_pim = '0;
(* max_fanout = 8 *) logic signed [24:0] e_w1re = '0, e_w1im = '0;
(* max_fanout = 8 *) logic signed [24:0] e_w2re = '0, e_w2im = '0;
(* max_fanout = 8 *) logic [5:0]         e_w1idx = '0;
logic               e_w1v = 1'b0;
logic [63:0]        e_we = '0;

wire consume = c_pend && !a_ld1 && !a_ld2;
wire apply_req;   // from the head (below)

iq16_exp #(.ROM_STYLE(ROM_STYLE)) e_exp_inst (.clk(clk), .phi(e_ph), .re(e_re), .im(e_im));

always_ff @(posedge clk) begin
    if (commit) c_pend <= 1'b1;

    // write-back pipeline
    e_dv       <= {e_dv[E_WB-1:1], e_run};
    e_didx[1]  <= e_idx;
    for (int i = 2; i <= E_WB; i++) e_didx[i] <= e_didx[i-1];
    e_mre   <= e_re * $signed({1'b0, l_amp[e_didx[7][5:4]]});
    e_mim   <= e_im * $signed({1'b0, l_amp[e_didx[7][5:4]]});
    e_pre   <= e_mre + 35'sd256;
    e_pim   <= e_mim + 35'sd256;
    e_w1re  <= e_pre[33:9];
    e_w1im  <= e_pim[33:9];
    e_w1idx <= e_didx[E_WB];
    e_w1v   <= e_dv[E_WB];
    e_w2re  <= e_w1re;
    e_w2im  <= e_w1im;
    for (int i = 0; i < 64; i++) e_we[i] <= e_w1v && (e_w1idx == 6'(i));
    for (int i = 0; i < 64; i++)
        if (e_we[i]) begin
            n_ck_re[i/16][i%16] <= e_w2re;
            n_ck_im[i/16][i%16] <= e_w2im;
        end
    if (e_we[63]) begin
        e_busy  <= 1'b0;
        e_ready <= 1'b1;
    end

    // phase k inc_t of entry (t, k) = e_idx
    if (e_run) begin
        e_idx <= e_idx + 6'd1;
        e_ph  <= (e_idx[3:0] == 4'd15) ? 32'd0 : e_ph + l_inc[e_idx[5:4]];
        if (e_idx == 6'd63) e_run <= 1'b0;
    end

    // chirp lane constants: acc(k) = acc(k-1) + inc48(k-1), inc48(k) = inc_s 2^16 + k r;
    // step of lane k per clock: 16 inc48(k) + 120 r
    if (c_run) begin
        n_a0[c_k]  <= c_a0;
        n_dl0[c_k] <= {c_g[43:0], 4'd0} + c_r120;
        c_a0       <= c_a0 + c_g;
        c_g        <= c_g + l_rate;
        c_k        <= c_k + 4'd1;
        if (c_k == 4'd15) c_run <= 1'b0;
    end

    if (apply_req) e_ready <= 1'b0;

    if (consume) begin
        c_pend   <= commit;      // a COMMIT in this very cycle is taken next time
        l_id     <= sh_cfg_id;
        l_inc    <= sh_tone_inc;
        l_amp    <= sh_tone_amp;
        l_cstart <= sh_chirp_start;
        l_rate   <= sh_chirp_rate;
        l_per    <= sh_chirp_per;
        l_camp   <= sh_chirp_amp;
        l_namp   <= sh_noise_amp;
        l_seed   <= sh_noise_seed;
        e_busy   <= 1'b1;
        e_ready  <= 1'b0;
        e_run    <= 1'b1;
        e_idx    <= '0;
        e_ph     <= '0;
        e_dv     <= '0;          // results of an interrupted pass are dropped
        e_w1v    <= 1'b0;
        e_we     <= '0;
        c_run    <= 1'b1;
        c_k      <= '0;
        c_a0     <= '0;
        c_g      <= {sh_chirp_start, 16'd0};
        c_r120   <= {sh_chirp_rate[40:0], 7'd0} - {sh_chirp_rate[44:0], 3'd0};
    end

    if (rst) begin
        c_pend <= 1'b0; e_busy <= 1'b0; e_ready <= 1'b0; e_run <= 1'b0; c_run <= 1'b0;
        e_dv <= '0; e_w1v <= 1'b0; e_we <= '0;
    end
end

assign st_pending = c_pend || e_busy || e_ready;

// ============================================================================
// Active configuration (changes only while the pipeline is empty)
// ============================================================================
// apply_req -> a_ld1 -> a_ld2: the copy (a_ld2 is the clock enable of ~5k
// registers, many of them DSP input registers; two register levels let it fan
// out). The head waits for it (H_APPLY).
logic [31:0]        a_id = '0;
logic [3:0][31:0]   a_inc16 = '0;
logic signed [24:0] a_ck_re [4][16] = '{default: '0};
logic signed [24:0] a_ck_im [4][16] = '{default: '0};
logic [47:0]        a_a0 [16] = '{default: '0};
logic [47:0]        a_dl0 [16] = '{default: '0};
logic [47:0]        a_r256 = '0, a_pm16 = 48'hFFFF_FFFF_FFF0;
logic               a_cen = 1'b0;
logic [15:0]        a_camp = '0, a_namp = '0;
logic [31:0]        a_seed = '0;

always_ff @(posedge clk) begin
    a_ld1 <= apply_req;
    a_ld2 <= a_ld1;
    if (a_ld2) begin
        a_id   <= l_id;
        for (int t = 0; t < 4; t++) a_inc16[t] <= {l_inc[t][27:0], 4'd0};
        a_ck_re <= n_ck_re;
        a_ck_im <= n_ck_im;
        a_a0   <= n_a0;
        a_dl0  <= n_dl0;
        a_r256 <= {l_rate[39:0], 8'd0};
        a_pm16 <= l_per - 48'd16;
        a_cen  <= (l_per != '0);
        a_camp <= l_camp;
        a_namp <= l_namp;
        a_seed <= l_seed;
    end
    if (rst) begin
        a_ld1 <= 1'b0;
        a_ld2 <= 1'b0;
    end
end

// ============================================================================
// Head
// ============================================================================
// The wide head registers (~1.9k: n, tone phases, 16 x 2 chirp accumulators)
// are steered by registered, replicated signals only: h_ld (load the start
// values), h_adv (advance one beat; decided a cycle ahead against the credits
// left after this cycle's advance, pops not counted), h_wrap (m + 16 = P).
typedef enum logic [2:0] {H_IDLE, H_START, H_APPLY, H_INIT, H_RUN, H_DRAIN} hst_t;
hst_t hs = H_IDLE;

logic [63:0]  h_n = '0;
logic [31:0]  h_keymul = '0;
logic [31:0]  h_bp [4] = '{default: '0};
logic [47:0]  h_m = '0;
logic [47:0]  h_acc [16] = '{default: '0};
logic [47:0]  h_dl [16] = '{default: '0};
logic [17:0]  h_ccnt = '0, h_cpbm1 = '0;
(* max_fanout = 64 *) logic h_adv = 1'b0;
(* max_fanout = 64 *) logic h_ld = 1'b0;
(* max_fanout = 64 *) logic h_wrap = 1'b0;
logic         h_ldinit = 1'b0;      // h_ld is a start (n = 0), not a live switch
logic         h_live = 1'b0;        // H_APPLY of a live switch
logic         h_bound = 1'b1;       // h_ccnt == 0: the next beat starts a chunk
logic         h_clast = 1'b0;       // h_ccnt == chunk_pbeats - 1
logic         h_first = 1'b0;
logic [31:0]  r_active_id = '0, r_commits = '0;
logic [63:0]  r_active_n0 = '0;
logic         r_apply = 1'b0;
logic [FIFO_AW:0] credits = FIFO_N;
logic [PIPE_LAT:1] vp = '0, fp = '0;
wire          pop = o_pop && o_valid;
wire          bound_n = h_adv ? h_clast : h_bound;               // after this cycle
wire [FIFO_AW:0] cred_n = credits - (h_adv ? 1'b1 : 1'b0);       // pops not counted
wire          run_n = (hs == H_RUN) && enable && !start && (cred_n != '0) && !(bound_n && e_ready);

assign apply_req = e_ready && !c_pend && !start &&
                   (hs == H_IDLE ||
                    (hs == H_START && !e_busy && !a_ld1 && !a_ld2) ||
                    (hs == H_DRAIN && enable && vp == '0 && !h_adv));

assign st_active_id = r_active_id;
assign st_active_n0 = r_active_n0;
assign st_commits   = r_commits;
assign st_apply     = r_apply;

// control
always_ff @(posedge clk) begin
    r_apply <= apply_req;
    if (apply_req) begin
        r_active_id <= l_id;
        r_commits   <= r_commits + 32'd1;
        r_active_n0 <= (hs == H_DRAIN) ? h_n : 64'd0;
    end
    if (SEEK_EN && h_ld && h_ldinit) r_active_n0 <= seek_n0;

    h_adv   <= run_n;
    vp      <= {vp[PIPE_LAT-1:1], h_adv};
    fp      <= {fp[PIPE_LAT-1:1], h_adv && h_first};
    credits <= credits - (h_adv ? 1'b1 : 1'b0) + (pop ? 1'b1 : 1'b0);
    h_ld    <= 1'b0;

    case (hs)
        H_IDLE: ;
        H_START: begin
            if (!(c_pend || e_busy || a_ld1 || a_ld2)) begin
                if (e_ready) begin                      // apply_req: copy, then load
                    hs     <= H_APPLY;
                    h_live <= 1'b0;
                end else begin
                    hs       <= H_INIT;
                    h_ld     <= 1'b1;
                    h_ldinit <= 1'b1;
                end
            end
        end
        H_APPLY: begin
            if (a_ld2) begin                            // a_* change at this edge
                hs       <= H_INIT;
                h_ld     <= 1'b1;
                h_ldinit <= !h_live;
            end
        end
        H_INIT: hs <= H_RUN;                            // h_ld is set in this cycle
        H_RUN: begin
            if (!enable)                hs <= H_IDLE;
            else if (bound_n && e_ready) hs <= H_DRAIN;  // stop at the chunk boundary
        end
        H_DRAIN: begin
            if (!enable)                hs <= H_IDLE;
            else if (!e_ready)          hs <= H_RUN;     // re-committed: computing again
            else if (apply_req) begin
                hs     <= H_APPLY;
                h_live <= 1'b1;
            end
        end
        default: hs <= H_IDLE;
    endcase

    if (start) begin
        hs      <= H_START;
        h_cpbm1 <= chunk_pbeats - 18'd1;
        h_adv   <= 1'b0;
        h_ld    <= 1'b0;
        vp      <= '0;           // beats in flight belong to the previous run
        fp      <= '0;
        credits <= FIFO_N;
    end
    if (rst) begin
        hs      <= H_IDLE;
        h_adv   <= 1'b0;
        h_ld    <= 1'b0;
        vp      <= '0;
        fp      <= '0;
        credits <= FIFO_N;
    end
end

// head state
always_ff @(posedge clk) begin
    if (h_ld) begin
        // a start (n = 0) or a live switch (n continues): phases from the active set
        for (int t = 0; t < 4; t++) h_bp[t] <= '0;
        h_m    <= '0;
        h_wrap <= (a_pm16 == '0);
        for (int k = 0; k < 16; k++) begin
            h_acc[k] <= a_a0[k];
            h_dl[k]  <= a_dl0[k];
        end
        if (h_ldinit) begin
            h_n      <= '0;
            h_keymul <= '0;
            if (SEEK_EN) begin
                h_n      <= seek_n;
                h_keymul <= seek_keymul;
                for (int t = 0; t < 4; t++) h_bp[t] <= seek_bp[t];
                h_m      <= seek_m;
                h_wrap   <= (seek_m == a_pm16);
                for (int k = 0; k < 16; k++) begin
                    h_acc[k] <= seek_acc[k];
                    h_dl[k]  <= seek_dl[k];
                end
            end
        end
        h_ccnt  <= '0;
        h_bound <= 1'b1;
        h_clast <= (h_cpbm1 == '0);
        h_first <= 1'b1;
    end else if (h_adv) begin
        h_n <= h_n + 64'd16;
        if (&h_n[31:4]) h_keymul <= h_keymul + 32'h9E3779B9;
        for (int t = 0; t < 4; t++) h_bp[t] <= h_bp[t] + a_inc16[t];
        if (h_wrap) begin
            // m + 16 = P: the next beat starts a new sweep at m = 0
            h_m    <= '0;
            h_wrap <= (a_pm16 == '0);
            for (int k = 0; k < 16; k++) begin
                h_acc[k] <= a_a0[k];
                h_dl[k]  <= a_dl0[k];
            end
        end else begin
            h_m    <= h_m + 48'd16;
            h_wrap <= (h_m + 48'd16 == a_pm16);
            for (int k = 0; k < 16; k++) begin
                h_acc[k] <= h_acc[k] + h_dl[k];
                h_dl[k]  <= h_dl[k] + a_r256;
            end
        end
        if (h_clast) begin
            h_ccnt  <= '0;
            h_bound <= 1'b1;
            h_clast <= (h_cpbm1 == '0);
        end else begin
            h_ccnt  <= h_ccnt + 18'd1;
            h_bound <= 1'b0;
            h_clast <= (h_ccnt + 18'd1 == h_cpbm1);
        end
        h_first <= 1'b0;
    end
end

// ============================================================================
// Pipeline: tones
// ============================================================================
wire logic signed [18:0] tone_re [4][16];
wire logic signed [18:0] tone_im [4][16];

for (genvar t = 0; t < 4; t++) begin : g_tone
    if (t < N_TONES) begin : g_on
        // 7 + 1 + 4 = 12: E(base), a fan-out register (B feeds 32 DSPs of 16
        // lanes, spread over the DSP columns: replicated, <= 4 loads each), cmul
        logic signed [17:0] bc, bs;
        (* max_fanout = 4 *) logic signed [17:0] bc_f = '0, bs_f = '0;
        iq16_exp #(.ROM_STYLE(ROM_STYLE)) exp_inst (.clk(clk), .phi(h_bp[t]), .re(bc), .im(bs));
        always_ff @(posedge clk) begin
            bc_f <= bc;
            bs_f <= bs;
        end
        for (genvar k = 0; k < 16; k++) begin : g_lane
            iq16_cmul cmul_inst (
                .clk(clk), .bc(bc_f), .bs(bs_f), .cre(a_ck_re[t][k]), .cim(a_ck_im[t][k]),
                .re(tone_re[t][k]), .im(tone_im[t][k])
            );
        end
    end else begin : g_off
        for (genvar k = 0; k < 16; k++) begin : g_lane
            assign tone_re[t][k] = '0;
            assign tone_im[t][k] = '0;
        end
    end
end

// ============================================================================
// Pipeline: chirp (16 lanes) and noise (16 lanes x I, Q)
// ============================================================================
wire logic signed [17:0] chirp_re [16];
wire logic signed [17:0] chirp_im [16];
wire logic signed [19:0] noise_re [16];
wire logic signed [19:0] noise_im [16];

for (genvar k = 0; k < 16; k++) begin : g_lane
    // chirp: 3 + 7 + 2 = 12
    logic [31:0] cph_d1 = '0, cph_d2 = '0, cph_d3 = '0;
    logic signed [17:0] cc, cs;
    logic signed [34:0] cm_re = '0, cm_im = '0, cp_re = '0, cp_im = '0;
    always_ff @(posedge clk) begin
        cph_d1 <= h_acc[k][47:16];
        cph_d2 <= cph_d1;
        cph_d3 <= cph_d2;
        cm_re  <= cc * $signed({1'b0, a_camp});
        cm_im  <= cs * $signed({1'b0, a_camp});
        cp_re  <= cm_re + 35'sd65536;
        cp_im  <= cm_im + 35'sd65536;
    end
    iq16_exp #(.ROM_STYLE(ROM_STYLE)) exp_inst (.clk(clk), .phi(cph_d3), .re(cc), .im(cs));
    assign chirp_re[k] = cp_re[34:17];
    assign chirp_im[k] = cp_im[34:17];

    // noise: 9 + 1 + 2 = 12
    for (genvar c = 0; c < 2; c++) begin : g_comp
        wire [31:0] nx = {h_n[31:4], 4'(k)} ^ a_seed ^ h_keymul ^ (c ? 32'h68E31DA4 : 32'h0);
        logic [31:0] hh;
        logic signed [10:0] nu = '0;
        logic signed [27:0] nm = '0, np = '0;
        iq16_hash hash_inst (.clk(clk), .x(nx), .h(hh));
        always_ff @(posedge clk) begin
            nu <= $signed({1'b0, 10'({2'b00, hh[7:0]} + {2'b00, hh[15:8]} + {2'b00, hh[23:16]} + {2'b00, hh[31:24]})})
                  - 11'sd510;
            nm <= nu * $signed({1'b0, a_namp});
            np <= nm + 28'sd64;
        end
        if (c == 0) begin : g_i
            assign noise_re[k] = np[26:7];
        end else begin : g_q
            assign noise_im[k] = np[26:7];
        end
    end
end

// ============================================================================
// Sum, saturation, packing
// ============================================================================
wire  [511:0] beat_w;           // stage 15: saturated samples
wire  [31:0]  clip_w;
logic [511:0] beat_data_q = '0; // stage 16
logic         beat_clip = 1'b0;

for (genvar k = 0; k < 16; k++) begin : g_sum
    for (genvar c = 0; c < 2; c++) begin : g_comp
        wire logic signed [19:0] t0 = c ? tone_im[0][k] : tone_re[0][k];
        wire logic signed [19:0] t1 = c ? tone_im[1][k] : tone_re[1][k];
        wire logic signed [19:0] t2 = c ? tone_im[2][k] : tone_re[2][k];
        wire logic signed [19:0] t3 = c ? tone_im[3][k] : tone_re[3][k];
        wire logic signed [19:0] cn = c ? chirp_im[k] : chirp_re[k];
        wire logic signed [19:0] nz = c ? noise_im[k] : noise_re[k];
        logic signed [20:0] sa = '0, sb = '0, sc = '0;
        logic signed [22:0] v = '0;
        logic [15:0] xs = '0;
        logic        cl = 1'b0;
        always_ff @(posedge clk) begin
            // 13
            sa <= t0 + t1;
            sb <= t2 + t3;
            sc <= (a_cen ? cn : 20'sd0) + nz;
            // 14
            v  <= sa + sb + sc;
            // 15: int16 saturation
            if (v > 23'sd32767) begin
                xs <= 16'h7FFF;
                cl <= 1'b1;
            end else if (v < -23'sd32768) begin
                xs <= 16'h8000;
                cl <= 1'b1;
            end else begin
                xs <= v[15:0];
                cl <= 1'b0;
            end
        end
        assign beat_w[32*k + 16*c +: 16] = xs;
        assign clip_w[2*k + c] = cl;
    end
end

always_ff @(posedge clk) begin
    beat_data_q <= beat_w;
    beat_clip   <= |clip_w;
end

// ============================================================================
// Output FIFO
// ============================================================================
iq16_fifo #(.W(FIFO_W), .AW(FIFO_AW)) fifo_inst (
    .clk(clk), .clr(start || rst),
    .wr(vp[PIPE_LAT]), .wdata({fp[PIPE_LAT], a_id, beat_clip, beat_data_q}),
    .pop(pop), .q_valid(o_valid), .q_data({o_cfg_first, o_cfg_id, o_clip, o_data})
);

endmodule

// ============================================================================
// E(phi) (exp_phi in sw/hsb/rocelet_iq.py), latency 7: phi in cycle c -> (re, im) in c + 7
// ============================================================================
module iq16_exp #(
    parameter string ROM_STYLE = "block"
) (
    input  wire logic               clk,
    input  wire logic [31:0]        phi,
    output wire logic signed [17:0] re,
    output wire logic signed [17:0] im
);

// TAB[i] = round(131071 sin(2 pi (i + 0.5) / 1024)) = IQ16_SIN_TAB (SIN_TAB in sw/hsb/rocelet_iq.py)
localparam logic [16:0] TAB [256] = '{
    17'd402, 17'd1206, 17'd2011, 17'd2815, 17'd3619, 17'd4422, 17'd5226, 17'd6030,
    17'd6833, 17'd7636, 17'd8439, 17'd9241, 17'd10043, 17'd10845, 17'd11646, 17'd12447,
    17'd13247, 17'd14047, 17'd14847, 17'd15645, 17'd16444, 17'd17241, 17'd18038, 17'd18834,
    17'd19630, 17'd20425, 17'd21219, 17'd22012, 17'd22804, 17'd23596, 17'd24386, 17'd25176,
    17'd25965, 17'd26753, 17'd27540, 17'd28325, 17'd29110, 17'd29894, 17'd30676, 17'd31457,
    17'd32238, 17'd33016, 17'd33794, 17'd34571, 17'd35346, 17'd36119, 17'd36892, 17'd37663,
    17'd38433, 17'd39201, 17'd39967, 17'd40733, 17'd41496, 17'd42258, 17'd43019, 17'd43778,
    17'd44535, 17'd45290, 17'd46044, 17'd46796, 17'd47547, 17'd48295, 17'd49042, 17'd49787,
    17'd50530, 17'd51271, 17'd52010, 17'd52748, 17'd53483, 17'd54216, 17'd54947, 17'd55676,
    17'd56403, 17'd57128, 17'd57851, 17'd58572, 17'd59290, 17'd60006, 17'd60720, 17'd61432,
    17'd62141, 17'd62848, 17'd63552, 17'd64254, 17'd64954, 17'd65652, 17'd66346, 17'd67039,
    17'd67729, 17'd68416, 17'd69101, 17'd69783, 17'd70462, 17'd71139, 17'd71813, 17'd72484,
    17'd73153, 17'd73819, 17'd74482, 17'd75143, 17'd75800, 17'd76455, 17'd77107, 17'd77756,
    17'd78402, 17'd79045, 17'd79685, 17'd80322, 17'd80956, 17'd81587, 17'd82215, 17'd82839,
    17'd83461, 17'd84080, 17'd84695, 17'd85307, 17'd85916, 17'd86522, 17'd87124, 17'd87724,
    17'd88319, 17'd88912, 17'd89501, 17'd90087, 17'd90670, 17'd91249, 17'd91824, 17'd92396,
    17'd92965, 17'd93530, 17'd94092, 17'd94650, 17'd95205, 17'd95756, 17'd96303, 17'd96847,
    17'd97387, 17'd97923, 17'd98456, 17'd98985, 17'd99510, 17'd100032, 17'd100550, 17'd101064,
    17'd101574, 17'd102080, 17'd102583, 17'd103081, 17'd103576, 17'd104067, 17'd104554, 17'd105037,
    17'd105516, 17'd105991, 17'd106462, 17'd106930, 17'd107393, 17'd107852, 17'd108307, 17'd108758,
    17'd109204, 17'd109647, 17'd110086, 17'd110520, 17'd110950, 17'd111377, 17'd111798, 17'd112216,
    17'd112630, 17'd113039, 17'd113444, 17'd113844, 17'd114241, 17'd114633, 17'd115021, 17'd115404,
    17'd115783, 17'd116158, 17'd116528, 17'd116894, 17'd117256, 17'd117613, 17'd117966, 17'd118314,
    17'd118658, 17'd118998, 17'd119332, 17'd119663, 17'd119989, 17'd120310, 17'd120627, 17'd120939,
    17'd121247, 17'd121550, 17'd121849, 17'd122143, 17'd122432, 17'd122717, 17'd122997, 17'd123273,
    17'd123544, 17'd123810, 17'd124072, 17'd124329, 17'd124581, 17'd124829, 17'd125072, 17'd125310,
    17'd125543, 17'd125772, 17'd125996, 17'd126215, 17'd126430, 17'd126639, 17'd126844, 17'd127045,
    17'd127240, 17'd127431, 17'd127617, 17'd127798, 17'd127974, 17'd128145, 17'd128312, 17'd128473,
    17'd128630, 17'd128782, 17'd128930, 17'd129072, 17'd129209, 17'd129342, 17'd129470, 17'd129593,
    17'd129711, 17'd129824, 17'd129932, 17'd130035, 17'd130134, 17'd130227, 17'd130316, 17'd130400,
    17'd130479, 17'd130553, 17'd130622, 17'd130686, 17'd130745, 17'd130799, 17'd130848, 17'd130893,
    17'd130932, 17'd130967, 17'd130996, 17'd131021, 17'd131041, 17'd131056, 17'd131065, 17'd131070
};

logic [31:0]        phi0 = '0;
logic [16:0]        sb1 = '0, cb1 = '0;

// the ROM (a literal attribute per branch)
if (ROM_STYLE == "distributed") begin : g_rom_lut
    (* rom_style = "distributed" *) logic [16:0] rom [256] = TAB;
    always_ff @(posedge clk) begin
        sb1 <= rom[phi0[29:22]];
        cb1 <= rom[~phi0[29:22]];
    end
end else begin : g_rom_bram
    (* rom_style = "block" *) logic [16:0] rom [256] = TAB;
    always_ff @(posedge clk) begin
        sb1 <= rom[phi0[29:22]];
        cb1 <= rom[~phi0[29:22]];
    end
end
logic [1:0]         q1 = '0;
logic signed [21:0] d1 = '0;
logic signed [17:0] c2 = '0, s2 = '0, c3 = '0, s3 = '0, c4 = '0, s4 = '0, c5 = '0, s5 = '0;
logic signed [41:0] dm2 = '0;
logic signed [22:0] th3 = '0;
logic signed [40:0] ps4 = '0, pc4 = '0;
logic signed [41:0] rs5 = '0, rc5 = '0;

logic signed [17:0] re6 = '0, im6 = '0;
assign re = re6;
assign im = im6;

always_ff @(posedge clk) begin
    // 1
    phi0 <= phi;
    // 2: coarse look-up (below), residual d = phi[21:0] - 2^21
    q1   <= phi0[31:30];
    d1   <= $signed({~phi0[21], phi0[20:0]});
    // 3: quadrant; d x round(2 pi 2^16)
    case (q1)
        2'd0: begin c2 <=  $signed({1'b0, cb1}); s2 <=  $signed({1'b0, sb1}); end
        2'd1: begin c2 <= -$signed({1'b0, sb1}); s2 <=  $signed({1'b0, cb1}); end
        2'd2: begin c2 <= -$signed({1'b0, cb1}); s2 <= -$signed({1'b0, sb1}); end
        default: begin c2 <= $signed({1'b0, sb1}); s2 <= -$signed({1'b0, cb1}); end
    endcase
    dm2  <= d1 * 20'sd411775;
    // 4: th = asr(d x 411775, 18)
    c3 <= c2; s3 <= s2;
    th3 <= dm2[40:18];
    // 5: s th, c th
    c4 <= c3; s4 <= s3;
    ps4 <= s3 * th3;
    pc4 <= c3 * th3;
    // 6: + 2^29 (round)
    c5 <= c4; s5 <= s4;
    rs5 <= ps4 + 42'sd536870912;
    rc5 <= pc4 + 42'sd536870912;
    // 7: c' = c - rnd(s th, 30), s' = s + rnd(c th, 30)
    re6 <= c5 - $signed(rs5[41:30]);
    im6 <= s5 + $signed(rc5[41:30]);
end

endmodule

// ============================================================================
// One tone lane: (rnd(Bc Cre - Bs Cim, 25), rnd(Bc Cim + Bs Cre, 25)), latency 4
// (two cascaded DSP pairs; C changes only while the pipeline is empty)
// ============================================================================
module iq16_cmul (
    input  wire logic               clk,
    input  wire logic signed [17:0] bc,
    input  wire logic signed [17:0] bs,
    input  wire logic signed [24:0] cre,
    input  wire logic signed [24:0] cim,
    output wire logic signed [18:0] re,
    output wire logic signed [18:0] im
);

logic signed [17:0] bc0 = '0, bs0 = '0, bs1 = '0;
logic signed [43:0] m1 = '0, m2 = '0, m3 = '0, m4 = '0;
logic signed [43:0] p1 = '0, p2 = '0, p3 = '0, p4 = '0;

always_ff @(posedge clk) begin
    bc0 <= bc;
    bs0 <= bs;
    bs1 <= bs0;
    m1  <= bc0 * cre;
    m3  <= bc0 * cim;
    p1  <= m1 + 44'sd16777216;
    p3  <= m3 + 44'sd16777216;
    m2  <= bs1 * cim;
    m4  <= bs1 * cre;
    p2  <= p1 - m2;
    p4  <= p3 + m4;
end

assign re = p2[43:25];
assign im = p4[43:25];

endmodule

// ============================================================================
// lowbias32 (x ^= x >> 16; x *= 0x7FEB352D; x ^= x >> 15; x *= 0x846CA68B;
// x ^= x >> 16), latency 9. Each 32 x 32 -> low 32 multiply by a constant is
// three DSP products: lo17 x Klo17 + 2^17 (lo17 x Khi15 + hi15 x Klo17).
// ============================================================================
module iq16_hash (
    input  wire logic        clk,
    input  wire logic [31:0] x,
    output wire logic [31:0] h
);

localparam logic [31:0] K1 = 32'h7FEB352D;
localparam logic [31:0] K2 = 32'h846CA68B;

logic [31:0] a0 = '0, y = '0, b0 = '0, z = '0;
(* use_dsp = "yes" *) logic [33:0] pa1 = '0, pa2 = '0;
(* use_dsp = "yes" *) logic [31:0] pb1 = '0, pc1 = '0, pb2 = '0, pc2 = '0;
logic [31:0] qa1 = '0, qa2 = '0;
logic [14:0] qbc1 = '0, qbc2 = '0;

logic [31:0] h9 = '0;
assign h = h9;

always_ff @(posedge clk) begin
    // 1
    a0  <= x ^ (x >> 16);
    // 2, 3, 4: a0 x K1
    pa1 <= a0[16:0] * K1[16:0];
    pb1 <= a0[16:0] * K1[31:17];
    pc1 <= a0[31:17] * K1[16:0];
    qa1 <= pa1[31:0];
    qbc1 <= pb1[14:0] + pc1[14:0];
    y   <= {qa1[31:17] + qbc1, qa1[16:0]};
    // 5
    b0  <= y ^ (y >> 15);
    // 6, 7, 8: b0 x K2
    pa2 <= b0[16:0] * K2[16:0];
    pb2 <= b0[16:0] * K2[31:17];
    pc2 <= b0[31:17] * K2[16:0];
    qa2 <= pa2[31:0];
    qbc2 <= pb2[14:0] + pc2[14:0];
    z   <= {qa2[31:17] + qbc2, qa2[16:0]};
    // 9
    h9  <= z ^ (z >> 16);
end

endmodule

// ============================================================================
// FIFO: 2**AW words of distributed RAM + an output register (first word fall
// through, q_valid / q_data). Capacity 2**AW + 1; the writer never exceeds
// 2**AW words in flight (credits). clr empties it.
// ============================================================================
module iq16_fifo #(
    parameter int W  = 546,
    parameter int AW = 5
) (
    input  wire logic         clk,
    input  wire logic         clr,
    input  wire logic         wr,
    input  wire logic [W-1:0] wdata,
    input  wire logic         pop,
    output wire logic         q_valid,
    output wire logic [W-1:0] q_data
);

(* ram_style = "distributed" *) logic [W-1:0] mem [2**AW];
logic [AW:0] wp = '0, rp = '0;
logic         qv = 1'b0;
logic [W-1:0] qd = '0;
wire empty = (wp == rp);
wire load  = !empty && (!qv || pop);

assign q_valid = qv;
assign q_data  = qd;

always_ff @(posedge clk) begin
    if (wr) mem[wp[AW-1:0]] <= wdata;
end

always_ff @(posedge clk) begin
    if (wr) wp <= wp + 1'b1;
    if (load) begin
        qd <= mem[rp[AW-1:0]];
        rp <= rp + 1'b1;
        qv <= 1'b1;
    end else if (pop) begin
        qv <= 1'b0;
    end
    if (clr) begin
        wp <= '0;
        rp <= '0;
        qv <= 1'b0;
    end
end

endmodule

`resetall
