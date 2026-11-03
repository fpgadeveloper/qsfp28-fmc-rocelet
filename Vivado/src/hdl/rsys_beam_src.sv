// SPDX-License-Identifier: MIT
//
// rsys_beam_src - the 8 x 8 phased-array generator of the beamforming demo (Opsero SOURCE = 2):
// the complex baseband samples of 64 antenna elements receiving up to four sources (CW tone,
// LFM radar pulse, QPSK, pulsed tone) from directions (u, v), with per-element complex gains,
// an element enable mask and element noise, bit-exact with the integer model
// sw/beam/beam_model.py. The specification is docs/source/beam_contract.md (version 1):
// packing (section 2), registers and APPLY semantics (section 4), the source model (section 5).
//
// Same frame interface as rsys_iq_src: the generator runs in the 200 MHz gen_clk, 16 complex
// int16 samples per 64-byte beat, one beat per gen_clk at most (102 Gb/s), an asynchronous FIFO
// into the CMAC user clock (clk), 2-bit run epochs on every beat. Beat b carries time sample
// n = b / 4, lane L = element k = 16 (b mod 4) + L. Each beat carries, as side-band, the
// SCENE_ID and the activation frame of the scene that generated it (the producer writes them
// into the frame's metadata record, contract section 3).
//
// Structure (gen_clk)
//   scene engine  APPLY (clk) snapshots the shadow words into the qsb_* registers (clk domain,
//                 one edge: words written after APPLY belong to the next scene) and sends a
//                 pulse to gen_clk. The engine then computes the per-scene steering table
//                 G[k][s] = EN_k ? rnd(E(phi_ks) g_k, 14) : 0 (one shared E() unit, 256 entries
//                 at one per clock, phi by additions) into the INACTIVE bank of the 16 x 4
//                 per-lane table RAMs (LUTRAM, 2 banks x 4 beat phases x 40 bit), copies the
//                 waveform parameters into the inactive parameter bank, waits SETTLE clocks
//                 and declares the bank ready: 256 + 13 + SETTLE = ~290 gen clocks = 1.45 us
//                 from the pulse (contract bound 10 us). It reads qsb_* directly (false path:
//                 qsb_* change only at an APPLY, whose pulse reaches gen_clk within ~6 clocks
//                 and restarts the engine; SETTLE > that, so a result computed while qsb_*
//                 changed is never declared ready: no torn scene).
//   head          the state of the beat to generate: q (beat phase), the time since the
//                 scene's activation j, per source the tone phase [INC j]_32 and the LFM
//                 accumulator / increment, the noise index (m[31:4] = b[27:0] and the key
//                 multiplier of m[63:32]), the frame position, the active bank. It advances one
//                 beat per clock while it holds a credit (internal FIFO slots not claimed);
//                 time advances once per 4 beats. A ready bank becomes active at the first frame
//                 boundary the head reaches (or at once when idle / at a run start): the head
//                 flips its bank bit, restarts the waveform state (j = 0, phases 0) and keeps the
//                 noise index. Every beat carries its bank bit, so beats of the old scene still
//                 in the pipeline finish with the old table and parameters; the engine does not
//                 write the old bank for GUARD clocks after an activation.
//   pipeline      PIPE_LAT = 28 clocks, free running, a valid bit per stage:
//                 waveforms (all four sources per beat, in parallel): select phase / gate /
//                 QPSK symbol key [3] -> E() [7] (+ lowbias32 [9] for QPSK from stage 2) ->
//                 symbol rotation + amplitude select [1] -> x A [2] = w_s (18 bit);
//                 lanes: 16 x two 8-deep DSP48E2 cascades (SI, SQ: the 4 complex products
//                 w_s G[k,s] of the lane's element, systolic, w on the 18-bit port, G on the
//                 27-bit port) [11]; element noise = the IQ16 noise path (iq16_hash,
//                 Irwin-Hall, x A_n) at index m = 16 b + L [12, aligned]; sum, rnd 17 + noise,
//                 sat16 + clip [2], pack [1].
//   FIFO          64 x 578 bit LUTRAM (iq16_fifo, first word fall through), then the
//                 32-beat asynchronous FIFO into clk.
//
// Status (clk): PENDING (an APPLY not yet active: a 64-clock flag after the APPLY write, then
// the synchronised engine state), APPLIED_ID / APPLIED_FRAME / APPLIES (gen_clk registers at
// each activation and run start, through xpm_cdc_handshake), CLIPPED (a saturated beat of the
// active scene was taken; cleared by the first beat of a scene and at run start).
//
// SEEK_EN (simulation only, 0 in the design): at a run start the noise index starts at
// seek_bl / seek_km instead of 0 (the waveforms start at j = 0 as always), so a testbench can
// check samples near n = 2^26 (m[63:32] = 1) without simulating up to them.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_beam_src
    import rsys_pkg::*;
#(
    parameter string ROM_STYLE = "block",
    parameter bit    SEEK_EN   = 1'b0
) (
    input  wire logic               gen_clk,
    input  wire logic               g_rst,          // gen_clk synchronous
    input  wire logic               clk,
    input  wire logic               rst,            // clk synchronous

    // clk domain: shadow registers cfg[128..255] (C_BM_*), APPLY, run control
    input  wire logic [127:0][31:0] bm_cfg,
    input  wire logic               apply,          // clk pulse: write to C_BM_APPLY
    input  wire logic [25:0]        frame_beats,    // beats per frame (C_HP_FRAME / 64), quasi-static
    input  wire logic               start,          // clk pulse: a run with source 2 starts
    input  wire logic               enable,         // clk level: the run is active

    // beats (clk domain, first word fall through)
    output wire logic               o_valid,
    output wire logic [511:0]       o_data,
    output wire logic [31:0]        o_scene_id,
    output wire logic [31:0]        o_scene_frame,
    input  wire logic               o_pop,
    output logic                    ev_clip = 1'b0, // clk: a beat with a saturated sample was taken

    // status (clk domain)
    output wire logic               st_pending,
    output logic                    st_clipped = 1'b0,
    output logic [31:0]             st_applied_id = '0,
    output logic [31:0]             st_applied_frame = '0,
    output logic [31:0]             st_applies = '0,

    // simulation only (SEEK_EN)
    input  wire logic [27:0]        seek_bl,
    input  wire logic [31:0]        seek_km
);

localparam int PIPE_LAT = 28;
localparam int FIFO_AW  = 6;
localparam int FIFO_W   = 512 + 64 + 2;               // {sf, clip, scene_frame, scene_id, data}
localparam int GUARD    = PIPE_LAT + 8;
localparam int SETTLE   = 16;
localparam logic [FIFO_AW:0] FIFO_N = (FIFO_AW+1)'(2**FIFO_AW);
localparam logic [31:0] SALT [4] = '{32'hB5297A4D, 32'h1B56C4E9, 32'h7F4A7C15, 32'hD1B54A33};

// bm_cfg word indices (cfg index - 128)
localparam int W_NAMP = C_BM_NOISE_AMP - 128, W_SEED = C_BM_NOISE_SEED - 128;
localparam int W_ENLO = C_BM_EN_LO - 128,     W_ENHI = C_BM_EN_HI - 128;
localparam int W_ID   = C_BM_SCENE_ID - 128,  W_GAIN = C_BM_GAIN0 - 128;

// ============================================================================
// clk domain: APPLY snapshot, pending flag
// ============================================================================
// qsb_*: the staged scene. Loaded in one edge by APPLY; read by the gen_clk engine only
// (kcu116.xdc: false path from qsb_*).
function automatic logic [127:0][31:0] bm_reset_words();
    for (int i = 0; i < 128; i++) bm_reset_words[i] = bm_default(128 + i);
endfunction
// The strobe is registered once more (replicated: it enables ~3k snapshot registers); the next
// register write cannot follow within one clock (AXI-Lite write = 3+ clocks in rsys_regs).
logic [127:0][31:0] qsb = bm_reset_words();
logic [5:0]         c_pflag = '0;
(* max_fanout = 128 *) logic apply_q = 1'b0;
always_ff @(posedge clk) begin
    apply_q <= apply && !rst;
    if (apply_q) qsb <= bm_cfg;
    c_pflag <= apply ? 6'd63 : (c_pflag != '0 ? c_pflag - 6'd1 : 6'd0);
    if (rst) begin
        qsb     <= bm_reset_words();
        c_pflag <= '0;
    end
end

// ============================================================================
// clk -> gen_clk
// ============================================================================
wire logic g_apply, g_start, g_enable;
xpm_cdc_pulse #(.DEST_SYNC_FF(4), .REG_OUTPUT(1), .RST_USED(0)) u_papply (
    .src_clk(clk), .src_pulse(apply_q), .src_rst(1'b0), .dest_clk(gen_clk), .dest_rst(1'b0), .dest_pulse(g_apply)
);
xpm_cdc_pulse #(.DEST_SYNC_FF(4), .REG_OUTPUT(1), .RST_USED(0)) u_pstart (
    .src_clk(clk), .src_pulse(start), .src_rst(1'b0), .dest_clk(gen_clk), .dest_rst(1'b0), .dest_pulse(g_start)
);
xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1)) u_senable (
    .src_clk(clk), .src_in(enable), .dest_clk(gen_clk), .dest_out(g_enable)
);
logic [25:0] qsg_fb = '0;                       // plain capture (false path to qsg_*)
logic [25:0] g_fbm1 = '0;                       // beats per frame - 1
always_ff @(posedge gen_clk) begin
    qsg_fb <= frame_beats;
    g_fbm1 <= (qsg_fb == '0) ? 26'd0 : qsg_fb - 26'd1;
end

// ============================================================================
// Parameter banks (gen_clk): written by the engine into the inactive bank
// ============================================================================
logic [3:0]  bk_on    [2] = '{default: '0};    // TYPE 1..4
logic [3:0]  bk_lfm   [2] = '{default: '0};    // TYPE 2
logic [3:0]  bk_qpsk  [2] = '{default: '0};    // TYPE 3
logic [3:0]  bk_gated [2] = '{default: '0};    // TYPE 2, 4
logic [31:0] bk_pmask [2][4] = '{default: '0}; // 2^p - 1
logic [3:0]  bk_sym   [2][4] = '{default: '0};
logic [16:0] bk_amp   [2][4] = '{default: '0}; // A, or A2 = rnd(A 46341, 16) for QPSK
logic [31:0] bk_inc   [2][4] = '{default: '0};
logic [47:0] bk_rate  [2][4] = '{default: '0};
logic [31:0] bk_w     [2][4] = '{default: '0};
logic [31:0] bk_qkey  [2][4] = '{default: '0}; // NOISE_SEED ^ SALT_s
logic [15:0] bk_namp  [2] = '{default: '0};
logic [31:0] bk_seed  [2] = '{default: '0};
logic [31:0] bk_id    [2] = '{default: '0};
logic [31:0] bk_sframe[2] = '{default: '0};    // written by the head at activation / run start

// ============================================================================
// Scene engine
// ============================================================================
logic        c_pend = 1'b1;                     // an APPLY to take (after reset: the reset scene)
logic        e_busy = 1'b0, e_ready = 1'b0, e_run = 1'b0, e_cpy = 1'b0;
logic        e_bank = 1'b1;                     // the bank being computed
logic [7:0]  e_idx = '0;                        // {s, k}
logic [31:0] e_phi = '0, e_rowb = '0;
logic [4:0]  e_set = '0;
logic        e_setl = 1'b0;
logic [$clog2(GUARD+1)-1:0] guard = '0;
(* max_fanout = 32 *) logic h_bank = 1'b0;      // active bank (head)
wire  logic  act_ok = e_ready && !c_pend;
logic        do_act;                            // the head activates the ready bank this clock

// E(phi) [7] -> gain products [1] -> sums + rnd [1] -> EN, write data [1] -> fan-out / decode [1] -> RAM
localparam int EW = 11;
logic [EW:1]  e_dv = '0;
logic [7:0]   e_didx [EW+1] = '{default: '0};
logic signed [17:0] e_re, e_im;
logic signed [15:0] e_gi = '0, e_gq = '0;
logic         e_en7 = 1'b0, e_en8 = 1'b0, e_en9 = 1'b0;
logic signed [33:0] e_m1 = '0, e_m2 = '0, e_m3 = '0, e_m4 = '0;
logic signed [35:0] e_sre = '0, e_sim = '0;
(* max_fanout = 16 *) logic [39:0] g_wd1 = '0;
(* max_fanout = 16 *) logic [39:0] g_wd = '0;
(* max_fanout = 16 *) logic [2:0]  g_wa1 = '0;
(* max_fanout = 16 *) logic [2:0]  g_wa = '0;
logic [7:0]   g_wi1 = '0;
logic         g_wv1 = 1'b0;
logic [15:0][3:0] g_we = '0;                    // [lane][source]

wire logic [31:0] e_u [4];
wire logic [31:0] e_v [4];
for (genvar s = 0; s < 4; s++) begin : g_uv
    assign e_u[s] = qsb[8*s + 6];
    assign e_v[s] = qsb[8*s + 7];
end
wire logic [63:0] q_en = {qsb[W_ENHI], qsb[W_ENLO]};
// phi of (s, k = 0) = -7 U_s - 7 V_s
function automatic logic [31:0] phi0(input logic [31:0] u, input logic [31:0] v);
    return u - {u[28:0], 3'd0} + v - {v[28:0], 3'd0};
endfunction

iq16_exp #(.ROM_STYLE(ROM_STYLE)) e_exp_inst (.clk(gen_clk), .phi(e_phi), .re(e_re), .im(e_im));

wire logic consume = c_pend && guard == '0;

// QPSK amplitude A2 = rnd(A 46341, 16): the amplitude is first captured in gen_clk (false path
// from qsb), the product is built in fabric. A DSP here absorbed the clk-domain qsb registers
// as its input register, which hid them from the qsb false path (build of 10c7240).
logic [15:0] e_amp [4] = '{default: '0};
(* use_dsp = "no" *) logic [16:0] e_a2 [4] = '{default: '0};
always_ff @(posedge gen_clk)
    for (int s = 0; s < 4; s++) begin
        e_amp[s] <= qsb[8*s + 1][15:0];
        e_a2[s]  <= 17'((33'(e_amp[s]) * 33'd46341 + 33'd32768) >> 16);
    end

always_ff @(posedge gen_clk) begin
    if (g_apply) c_pend <= 1'b1;
    if (guard != '0) guard <= guard - 1'b1;
    if (do_act) begin
        e_ready <= 1'b0;
        guard   <= ($clog2(GUARD+1))'(GUARD);
    end

    // steering phases: s outer, k = 8 iy + ix inner;
    // phi = (2 ix - 7) U + (2 iy - 7) V (mod 2^32), by additions
    if (e_run) begin
        e_idx <= e_idx + 8'd1;
        if (e_idx[5:0] == 6'd63) begin
            e_phi  <= phi0(e_u[e_idx[7:6] + 2'd1], e_v[e_idx[7:6] + 2'd1]);
            e_rowb <= phi0(e_u[e_idx[7:6] + 2'd1], e_v[e_idx[7:6] + 2'd1]);
        end else if (e_idx[2:0] == 3'd7) begin
            e_phi  <= e_rowb + {e_v[e_idx[7:6]][30:0], 1'b0};
            e_rowb <= e_rowb + {e_v[e_idx[7:6]][30:0], 1'b0};
        end else begin
            e_phi  <= e_phi + {e_u[e_idx[7:6]][30:0], 1'b0};
        end
        if (e_idx == 8'd255) e_run <= 1'b0;
    end

    // write-back pipeline: entry e_didx[i] is i clocks behind e_phi
    e_dv      <= {e_dv[EW-1:1], e_run};
    e_didx[1] <= e_idx;
    for (int i = 2; i <= EW; i++) e_didx[i] <= e_didx[i-1];
    // 7: the gain and enable of the entry's element (E(phi) arrives at this edge)
    e_gi  <= $signed(qsb[W_GAIN + e_didx[6][5:0]][15:0]);
    e_gq  <= $signed(qsb[W_GAIN + e_didx[6][5:0]][31:16]);
    e_en7 <= q_en[e_didx[6][5:0]];
    // 8: products (18 x 16)
    e_m1  <= e_re * e_gi;
    e_m2  <= e_im * e_gq;
    e_m3  <= e_re * e_gq;
    e_m4  <= e_im * e_gi;
    e_en8 <= e_en7;
    // 9: sums + 2^13
    e_sre <= 36'(e_m1) - 36'(e_m2) + 36'sd8192;
    e_sim <= 36'(e_m3) + 36'(e_m4) + 36'sd8192;
    e_en9 <= e_en8;
    // 10: G = rnd(., 14) (20 bit), zero for a disabled element; table address {bank, q}
    g_wd1 <= e_en9 ? {e_sim[33:14], e_sre[33:14]} : 40'd0;
    g_wa1 <= {e_bank, e_didx[9][5:4]};
    g_wi1 <= e_didx[9];
    g_wv1 <= e_dv[9];
    // 11: write data / address copies next to the RAMs, write enable per (lane, source)
    g_wd  <= g_wd1;
    g_wa  <= g_wa1;
    for (int l = 0; l < 16; l++)
        for (int s = 0; s < 4; s++)
            g_we[l][s] <= g_wv1 && g_wi1[3:0] == 4'(l) && g_wi1[7:6] == 2'(s);

    // after the last entry: copy the waveform parameters, settle, ready
    e_cpy <= e_dv[10] && e_didx[10] == 8'd255;
    if (e_cpy) begin
        for (int s = 0; s < 4; s++) begin
            logic [2:0]  ty;
            ty = qsb[8*s][2:0];
            bk_on[e_bank][s]    <= (ty >= 3'd1 && ty <= 3'd4);
            bk_lfm[e_bank][s]   <= (ty == 3'd2);
            bk_qpsk[e_bank][s]  <= (ty == 3'd3);
            bk_gated[e_bank][s] <= (ty == 3'd2 || ty == 3'd4);
            bk_pmask[e_bank][s] <= ~(32'hFFFFFFFF << qsb[8*s][12:8]);
            bk_sym[e_bank][s]   <= qsb[8*s][19:16];
            bk_amp[e_bank][s]   <= (ty == 3'd3) ? e_a2[s] : {1'b0, e_amp[s]};
            bk_inc[e_bank][s]   <= qsb[8*s + 2];
            bk_rate[e_bank][s]  <= {qsb[8*s + 4][15:0], qsb[8*s + 3]};
            bk_w[e_bank][s]     <= qsb[8*s + 5];
            bk_qkey[e_bank][s]  <= qsb[W_SEED] ^ SALT[s];
        end
        bk_namp[e_bank] <= qsb[W_NAMP][15:0];
        bk_seed[e_bank] <= qsb[W_SEED];
        bk_id[e_bank]   <= qsb[W_ID];
        e_setl <= 1'b1;
        e_set  <= 5'(SETTLE);
    end else if (e_setl) begin
        e_set <= e_set - 5'd1;
        if (e_set == 5'd1) begin
            e_setl  <= 1'b0;
            e_busy  <= 1'b0;
            e_ready <= 1'b1;
        end
    end

    // take an APPLY: (re)start the engine on the inactive bank
    if (consume) begin
        c_pend  <= g_apply;              // an APPLY in this very clock is taken next time
        e_bank  <= !h_bank;
        e_busy  <= 1'b1;
        e_ready <= 1'b0;
        e_run   <= 1'b1;
        e_idx   <= '0;
        e_phi   <= phi0(e_u[0], e_v[0]);
        e_rowb  <= phi0(e_u[0], e_v[0]);
        e_dv    <= '0;                   // results of an interrupted pass are dropped
        g_wv1   <= 1'b0;
        g_we    <= '0;
        e_cpy   <= 1'b0;
        e_setl  <= 1'b0;
    end

    if (g_rst) begin
        c_pend <= 1'b1; e_busy <= 1'b0; e_ready <= 1'b0; e_run <= 1'b0; e_cpy <= 1'b0; e_setl <= 1'b0;
        e_dv <= '0; g_wv1 <= 1'b0; g_we <= '0; guard <= '0;
    end
end

// ============================================================================
// Head
// ============================================================================
typedef enum logic [2:0] {H_IDLE, H_START, H_ACT, H_LD, H_RUN} hst_t;
hst_t hs = H_IDLE;

(* max_fanout = 64 *) logic h_adv = 1'b0;      // emit the beat described by the head
(* max_fanout = 64 *) logic h_tadv = 1'b0;     // ... and it is the 4th beat of its time sample
logic         h_full = 1'b0;                    // H_LD after a start (else: a live activation)
logic [1:0]   h_q = '0;
logic         h_sf = 1'b0;                      // the next beat is the first of its scene
logic [31:0]  h_j = '0;
logic [31:0]  h_th [4] = '{default: '0};
logic [47:0]  h_la [4] = '{default: '0};
logic [47:0]  h_ld [4] = '{default: '0};
logic [3:0]   h_lw = '0;                        // (j mod 2^p) = 2^p - 1: the next sample restarts the LFM sweep
logic [27:0]  h_bl = '0;                        // noise index m[31:4] = b[27:0]
logic [31:0]  h_km = '0;                        // [m[63:32] 0x9E3779B9]_32
logic [25:0]  h_fcnt = '0, h_fbm1 = '0;
logic         h_bound = 1'b1, h_flast = 1'b0;
logic [31:0]  h_f = '0;                         // frame index of the next frame boundary
logic [FIFO_AW:0] credits = FIFO_N;
logic [PIPE_LAT:1] vp = '0;
logic         r_dirty = 1'b0;
logic [31:0]  r_aid = '0, r_aframe = '0, r_applies = '0;
wire  logic   f_pop;                            // internal FIFO pop
logic         hs_send = 1'b0;                   // status handshake (below)
wire  logic   hs_rcv;
wire  logic   hs_take = r_dirty && !hs_send && !hs_rcv;
wire  logic   bound_n = h_adv ? h_flast : h_bound;
wire  logic [FIFO_AW:0] cred_n = credits - (h_adv ? 1'b1 : 1'b0);
wire  logic   run_n = (hs == H_RUN) && g_enable && !g_start && (cred_n != '0) && !(bound_n && act_ok);
wire  logic [1:0] q_n = h_adv ? h_q + 2'd1 : h_q;

always_comb begin
    do_act = 1'b0;
    case (hs)
        H_IDLE:  do_act = act_ok && !g_start;
        H_START: do_act = !c_pend && !e_busy && e_ready && !g_start;
        H_ACT:   do_act = act_ok && !g_start;
        default: do_act = 1'b0;
    endcase
end

always_ff @(posedge gen_clk) begin
    h_adv   <= run_n;
    h_tadv  <= run_n && (q_n == 2'd3);
    vp      <= {vp[PIPE_LAT-1:1], h_adv};
    credits <= credits - (h_adv ? 1'b1 : 1'b0) + (f_pop ? 1'b1 : 1'b0);
    for (int s = 0; s < 4; s++) h_lw[s] <= ((h_j & bk_pmask[h_bank][s]) == bk_pmask[h_bank][s]);

    if (do_act) begin
        h_bank    <= e_bank;
        r_aid     <= bk_id[e_bank];
        r_applies <= r_applies + 32'd1;
        r_aframe  <= (hs == H_ACT) ? h_f : 32'd0;
        bk_sframe[e_bank] <= (hs == H_ACT) ? h_f : 32'd0;
        r_dirty   <= 1'b1;
    end

    case (hs)
        H_IDLE: ;
        H_START: begin
            if (!c_pend && !e_busy) begin
                hs     <= H_LD;
                h_full <= 1'b1;
            end
        end
        H_ACT: begin
            if (act_ok) begin
                hs     <= H_LD;
                h_full <= 1'b0;
            end else begin
                hs <= H_RUN;
            end
        end
        H_LD: begin
            // waveform restart from the active bank (j = 0, n0 = this time sample)
            h_j  <= '0;
            h_sf <= 1'b1;
            for (int s = 0; s < 4; s++) begin
                h_th[s] <= '0;
                h_la[s] <= '0;
                h_ld[s] <= {bk_inc[h_bank][s], 16'd0};
            end
            if (h_full) begin
                // run start: n = 0, frame 0; the active scene's activation frame becomes 0
                h_q     <= '0;
                h_bl    <= SEEK_EN ? seek_bl : 28'd0;
                h_km    <= SEEK_EN ? seek_km : 32'd0;
                h_f     <= '0;
                h_fcnt  <= '0;
                h_bound <= 1'b1;
                h_flast <= (h_fbm1 == '0);
                bk_sframe[h_bank] <= '0;
                r_aframe <= '0;
                r_dirty  <= 1'b1;
            end
            hs <= H_RUN;
        end
        H_RUN: begin
            if (!g_enable)               hs <= H_IDLE;
            else if (bound_n && act_ok)  hs <= H_ACT;    // stop at the frame boundary
        end
        default: hs <= H_IDLE;
    endcase

    if (h_adv) begin
        h_q  <= h_q + 2'd1;
        h_sf <= 1'b0;
        h_bl <= h_bl + 28'd1;
        if (&h_bl) h_km <= h_km + 32'h9E3779B9;
        if (h_flast) begin
            h_fcnt  <= '0;
            h_bound <= 1'b1;
            h_flast <= (h_fbm1 == '0);
            h_f     <= h_f + 32'd1;
        end else begin
            h_fcnt  <= h_fcnt + 26'd1;
            h_bound <= 1'b0;
            h_flast <= (h_fcnt + 26'd1 == h_fbm1);
        end
    end
    if (h_tadv) begin
        h_j <= h_j + 32'd1;
        for (int s = 0; s < 4; s++) begin
            h_th[s] <= h_th[s] + bk_inc[h_bank][s];
            if (h_lw[s]) begin
                h_la[s] <= '0;
                h_ld[s] <= {bk_inc[h_bank][s], 16'd0};
            end else begin
                h_la[s] <= h_la[s] + h_ld[s];
                h_ld[s] <= h_ld[s] + bk_rate[h_bank][s];
            end
        end
    end

    if (g_start) begin
        hs      <= H_START;
        h_fbm1  <= g_fbm1;
        h_adv   <= 1'b0;
        h_tadv  <= 1'b0;
        vp      <= '0;              // beats in flight belong to the previous run
        credits <= FIFO_N;
    end
    if (hs_take) r_dirty <= 1'b0;
    if (g_rst) begin
        hs      <= H_IDLE;
        h_bank  <= 1'b0;
        h_adv   <= 1'b0;
        h_tadv  <= 1'b0;
        vp      <= '0;
        credits <= FIFO_N;
        r_dirty <= 1'b0;
        r_applies <= '0;
    end
end

// ============================================================================
// Pipeline
// ============================================================================
// per-beat control through the stages
(* max_fanout = 32 *) logic d_bank [PIPE_LAT+1] = '{default: '0};
logic [1:0]   d_q    [PIPE_LAT+1] = '{default: '0};
logic         d_sf   [PIPE_LAT+1] = '{default: '0};
logic [27:0]  d_bl   [14] = '{default: '0};
logic [31:0]  d_km   [14] = '{default: '0};
// stage 1: the head
logic [31:0]  s1_j = '0;
logic [31:0]  s1_th [4] = '{default: '0};
logic [31:0]  s1_la [4] = '{default: '0};

always_ff @(posedge gen_clk) begin
    d_bank[1] <= h_bank;
    d_q[1]    <= h_q;
    d_sf[1]   <= h_sf;
    d_bl[1]   <= h_bl;
    d_km[1]   <= h_km;
    for (int i = 2; i <= PIPE_LAT; i++) begin
        d_bank[i] <= d_bank[i-1];
        d_q[i]    <= d_q[i-1];
        d_sf[i]   <= d_sf[i-1];
    end
    for (int i = 2; i <= 13; i++) begin
        d_bl[i] <= d_bl[i-1];
        d_km[i] <= d_km[i-1];
    end
    s1_j <= h_j;
    for (int s = 0; s < 4; s++) begin
        s1_th[s] <= h_th[s];
        s1_la[s] <= h_la[s][47:16];
    end
end

// ---------------- waveforms (four sources in parallel) ----------------
// w[s][0/1] = (wI, wQ) of the beat at stage 14 (18-bit signed)
wire logic signed [17:0] w_re [4];
wire logic signed [17:0] w_im [4];

for (genvar s = 0; s < 4; s++) begin : g_src
    logic [31:0] s2_ph = '0, s2_m = '0, s2_hx = '0, s3_ph = '0, s4_ph = '0;
    logic        gt [3:11] = '{default: 1'b0};
    logic signed [17:0] ec, es;
    logic [31:0] hh;
    logic signed [18:0] s12_pc = '0, s12_ps = '0;
    logic signed [16:0] s12_a = '0;
    logic signed [35:0] s13_mc = '0, s13_ms = '0, s14_pc = '0, s14_ps = '0;
    always_ff @(posedge gen_clk) begin
        // 2: phase (tone [INC j]_32 or LFM acc[47:16]), m = j mod 2^p, QPSK symbol key
        s2_ph <= bk_lfm[d_bank[1]][s] ? s1_la[s] : s1_th[s];
        s2_m  <= s1_j & bk_pmask[d_bank[1]][s];
        s2_hx <= (s1_j >> bk_sym[d_bank[1]][s]) ^ bk_qkey[d_bank[1]][s];
        // 3: pulse gate (m < W)
        gt[3] <= s2_m < bk_w[d_bank[2]][s];
        s3_ph <= s2_ph;
        // 4: into E() (7 clocks: 11)
        s4_ph <= s3_ph;
        for (int i = 4; i <= 11; i++) gt[i] <= gt[i-1];
        // 12: QPSK symbol (a + jb) x E: (a c - b s, a s + b c); amplitude, zero when off / gated off
        if (bk_qpsk[d_bank[11]][s]) begin
            s12_pc <= (hh[0] ? -19'(ec) : 19'(ec)) + (hh[1] ? 19'(es) : -19'(es));
            s12_ps <= (hh[0] ? -19'(es) : 19'(es)) + (hh[1] ? -19'(ec) : 19'(ec));
        end else begin
            s12_pc <= 19'(ec);
            s12_ps <= 19'(es);
        end
        s12_a <= (bk_on[d_bank[11]][s] && (!bk_gated[d_bank[11]][s] || gt[11])) ? $signed(bk_amp[d_bank[11]][s]) : 17'sd0;
        // 13, 14: x A, + 2^16
        s13_mc <= s12_pc * s12_a;
        s13_ms <= s12_ps * s12_a;
        s14_pc <= s13_mc + 36'sd65536;
        s14_ps <= s13_ms + 36'sd65536;
    end
    iq16_exp #(.ROM_STYLE(ROM_STYLE)) exp_inst (.clk(gen_clk), .phi(s4_ph), .re(ec), .im(es));
    iq16_hash hash_inst (.clk(gen_clk), .x(s2_hx), .h(hh));     // h at stage 11
    assign w_re[s] = s14_pc[34:17];
    assign w_im[s] = s14_ps[34:17];
end

// ---------------- w fan-out: chain position i uses x_i = (i even ? wI : wQ) of source i/2,
// delayed i clocks (stage 15 + i); replicated next to the DSP columns ----------------
(* max_fanout = 4 *) logic signed [17:0] xw [8][8] = '{default: '0};   // [position][delay]
always_ff @(posedge gen_clk) begin
    for (int i = 0; i < 8; i++) begin
        xw[i][0] <= (i % 2) ? w_im[i/2] : w_re[i/2];                    // stage 15
        for (int d = 1; d < 8; d++) xw[i][d] <= xw[i][d-1];
    end
end

// ---------------- lanes ----------------
wire  [511:0] beat_w;           // stage 27: saturated samples
wire  [15:0]  clip_w;

for (genvar l = 0; l < 16; l++) begin : g_lane
    // steering table: source s, entry {bank, q} = G[16 q + l][s] = {GQ, GI}
    wire logic [39:0] gr [4];
    wire logic [39:0] gr2 [4];
    for (genvar s = 0; s < 4; s++) begin : g_tab
        (* ram_style = "distributed" *) logic [39:0] tab [8];
        logic [39:0] rd = '0, rd2 = '0;
        always_ff @(posedge gen_clk) begin
            if (g_we[l][s]) tab[g_wa] <= g_wd;
            rd  <= tab[{d_bank[14 + 2*s], d_q[14 + 2*s]}];         // stage 15 + 2s
            rd2 <= rd;                                              // stage 16 + 2s
        end
        assign gr[s]  = rd;
        assign gr2[s] = rd2;
    end

    // SI = sum_s wI GI - wQ GQ ; SQ = sum_s wI GQ + wQ GI: two systolic 8-DSP cascades
    wire logic signed [19:0] yi [8];
    wire logic signed [19:0] yq [8];
    for (genvar i = 0; i < 8; i++) begin : g_y
        if (i % 2 == 0) begin : g_e
            assign yi[i] = $signed(gr[i/2][19:0]);      // GI
            assign yq[i] = $signed(gr[i/2][39:20]);     // GQ
        end else begin : g_o
            assign yi[i] = $signed(gr2[i/2][39:20]);    // GQ (subtracted)
            assign yq[i] = $signed(gr2[i/2][19:0]);     // GI
        end
    end
    logic signed [17:0] ai [8] = '{default: '0}, aq [8] = '{default: '0};
    logic signed [19:0] bi [8] = '{default: '0}, bq [8] = '{default: '0};
    logic signed [37:0] mi [8] = '{default: '0}, mq [8] = '{default: '0};
    logic signed [47:0] pi [8] = '{default: '0}, pq [8] = '{default: '0};
    always_ff @(posedge gen_clk) begin
        for (int i = 0; i < 8; i++) begin
            ai[i] <= xw[i][i];                          // stage 16 + i
            aq[i] <= xw[i][i];
            bi[i] <= yi[i];
            bq[i] <= yq[i];
            mi[i] <= ai[i] * bi[i];                     // stage 17 + i
            mq[i] <= aq[i] * bq[i];
        end
        pi[0] <= 48'(mi[0]) + 48'sd65536;               // stage 18 (+ 2^16: rnd 17)
        pq[0] <= 48'(mq[0]) + 48'sd65536;
        for (int i = 1; i < 8; i++) begin               // stage 18 + i
            pi[i] <= (i % 2) ? pi[i-1] - 48'(mi[i]) : pi[i-1] + 48'(mi[i]);
            pq[i] <= pq[i-1] + 48'(mq[i]);
        end
    end

    // element noise: the IQ16 noise at m = 16 b + l (key from stage 13): 9 + 1 + 2 -> stage 25
    wire logic signed [19:0] nz [2];
    wire logic [1:0]         cl_l;
    for (genvar c = 0; c < 2; c++) begin : g_comp
        wire [31:0] nx = {d_bl[13], 4'(l)} ^ bk_seed[d_bank[13]] ^ d_km[13] ^ (c ? 32'h68E31DA4 : 32'h0);
        logic [31:0] hh;
        logic signed [10:0] nu = '0;
        logic [15:0] na = '0;
        logic signed [27:0] nm = '0, np = '0;
        iq16_hash hash_inst (.clk(gen_clk), .x(nx), .h(hh));    // h at stage 22
        always_ff @(posedge gen_clk) begin
            nu <= $signed({1'b0, 10'({2'b00, hh[7:0]} + {2'b00, hh[15:8]} + {2'b00, hh[23:16]} + {2'b00, hh[31:24]})})
                  - 11'sd510;                                       // 23
            na <= bk_namp[d_bank[22]];
            nm <= nu * $signed({1'b0, na});                         // 24
            np <= nm + 28'sd64;                                     // 25
        end
        assign nz[c] = np[26:7];
    end

    // 26: rnd(S, 17) + noise; 27: sat16
    for (genvar c = 0; c < 2; c++) begin : g_out
        logic signed [31:0] v = '0;
        logic [15:0] xs = '0;
        logic        cl = 1'b0;
        always_ff @(posedge gen_clk) begin
            v <= (c ? 32'($signed(pq[7][47:17])) : 32'($signed(pi[7][47:17]))) + 32'(nz[c]);
            if (v > 32'sd32767) begin
                xs <= 16'h7FFF;
                cl <= 1'b1;
            end else if (v < -32'sd32768) begin
                xs <= 16'h8000;
                cl <= 1'b1;
            end else begin
                xs <= v[15:0];
                cl <= 1'b0;
            end
        end
        assign beat_w[32*l + 16*c +: 16] = xs;
        assign cl_l[c] = cl;
    end
    assign clip_w[l] = |cl_l;
end

// 28: pack with the scene side-band of the beat's bank
logic [511:0] beat_q = '0;
logic         beat_clip = 1'b0, beat_sf = 1'b0;
logic [31:0]  beat_id = '0, beat_sfr = '0;
always_ff @(posedge gen_clk) begin
    beat_q    <= beat_w;
    beat_clip <= |clip_w;
    beat_sf   <= d_sf[27];
    beat_id   <= bk_id[d_bank[27]];
    beat_sfr  <= bk_sframe[d_bank[27]];
end

// ============================================================================
// Internal FIFO (credits) -> asynchronous FIFO -> clk
// ============================================================================
wire logic               q_valid;
wire logic [FIFO_W-1:0]  q_data;
wire logic               af_full, af_wbusy;
assign f_pop = q_valid && !af_full && !af_wbusy;

iq16_fifo #(.W(FIFO_W), .AW(FIFO_AW)) u_fifo (
    .clk(gen_clk), .clr(g_start || g_rst),
    .wr(vp[PIPE_LAT]), .wdata({beat_sf, beat_clip, beat_sfr, beat_id, beat_q}),
    .pop(f_pop), .q_valid(q_valid), .q_data(q_data)
);

logic [1:0] g_ep = '0;
always_ff @(posedge gen_clk) begin
    if (g_start) g_ep <= g_ep + 2'd1;
    if (g_rst)   g_ep <= '0;
end

wire logic [FIFO_W+1:0] af_dout;
wire logic              af_valid, af_rbusy;
logic                   af_rd;
logic [1:0]             c_ep = '0;

xpm_fifo_async #(
    .FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(32), .WRITE_DATA_WIDTH(FIFO_W + 2),
    .READ_DATA_WIDTH(FIFO_W + 2), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .CDC_SYNC_STAGES(3),
    .RELATED_CLOCKS(0), .ECC_MODE("no_ecc"), .USE_ADV_FEATURES("1000"), .DOUT_RESET_VALUE("0"),
    .FULL_RESET_VALUE(0), .PROG_FULL_THRESH(16), .PROG_EMPTY_THRESH(10), .WR_DATA_COUNT_WIDTH(6),
    .RD_DATA_COUNT_WIDTH(6), .WAKEUP_TIME(0), .SIM_ASSERT_CHK(0)
) u_af (
    .rst(g_rst), .wr_clk(gen_clk), .wr_en(f_pop), .din({g_ep, q_data}), .full(af_full),
    .wr_rst_busy(af_wbusy), .rd_clk(clk), .rd_en(af_rd), .dout(af_dout), .data_valid(af_valid),
    .rd_rst_busy(af_rbusy), .empty(), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
    .almost_empty(), .almost_full(), .dbiterr(), .overflow(), .prog_empty(), .prog_full(),
    .rd_data_count(), .sbiterr(), .underflow(), .wr_ack(), .wr_data_count()
);

always_ff @(posedge clk) begin
    if (start) c_ep <= c_ep + 2'd1;
    if (rst)   c_ep <= '0;
end

wire logic head_ok  = af_valid && !af_rbusy && (af_dout[FIFO_W+1:FIFO_W] == c_ep);
wire logic head_old = af_valid && !af_rbusy && (af_dout[FIFO_W+1:FIFO_W] != c_ep);
assign o_valid       = head_ok;
assign o_data        = af_dout[511:0];
assign o_scene_id    = af_dout[543:512];
assign o_scene_frame = af_dout[575:544];
wire logic o_clip    = af_dout[576];
wire logic o_sf      = af_dout[577];
always_comb af_rd = head_old || (head_ok && o_pop);

always_ff @(posedge clk) begin
    ev_clip <= head_ok && o_pop && o_clip;
    if (head_ok && o_pop && o_sf) st_clipped <= 1'b0;
    if (head_ok && o_pop && o_clip) st_clipped <= 1'b1;
    if (start || rst) st_clipped <= 1'b0;
end

// ============================================================================
// Status gen_clk -> clk
// ============================================================================
wire logic g_pending = c_pend || e_busy || e_ready;
wire logic c_gpend;
xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1)) u_spend (
    .src_clk(gen_clk), .src_in(g_pending), .dest_clk(clk), .dest_out(c_gpend)
);
assign st_pending = c_gpend || (c_pflag != '0);

logic [95:0] hs_data = '0;
wire  logic  hs_req;
wire  logic [95:0] hs_out;
always_ff @(posedge gen_clk) begin
    if (hs_take) begin
        hs_data <= {r_applies, r_aframe, r_aid};
        hs_send <= 1'b1;
    end else if (hs_send && hs_rcv) begin
        hs_send <= 1'b0;
    end
    if (g_rst) hs_send <= 1'b0;
end
xpm_cdc_handshake #(.DEST_EXT_HSK(0), .DEST_SYNC_FF(3), .SRC_SYNC_FF(3), .WIDTH(96), .SIM_ASSERT_CHK(0)) u_hs (
    .src_clk(gen_clk), .src_in(hs_data), .src_send(hs_send), .src_rcv(hs_rcv),
    .dest_clk(clk), .dest_req(hs_req), .dest_ack(1'b0), .dest_out(hs_out)
);
always_ff @(posedge clk) begin
    if (hs_req) begin
        st_applied_id    <= hs_out[31:0];
        st_applied_frame <= hs_out[63:32];
        st_applies       <= hs_out[95:64];
    end
end

endmodule

`resetall
