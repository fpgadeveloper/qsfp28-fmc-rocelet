// SPDX-License-Identifier: MIT
//
// rsys_iq_src - the IQ16 frame source of the Holoscan Sensor Bridge producer: the IQ16
// test-signal generator (iq16_gen.sv, 16 complex int16 samples per beat) in its own 200 MHz
// clock (gen_clk; up to 3.2 GS/s = 102 Gb/s of samples), and a 32-beat asynchronous FIFO into the
// CMAC user clock (clk) where the producer takes the beats. Keeping the generator out of
// the 322 MHz domain keeps its ~16-clock DSP pipeline and wide fan-outs away from the
// engine's critical paths.
//
// Crossings clk -> gen_clk:
//   * start, commit: xpm_cdc_pulse; enable: xpm_cdc_single;
//   * the configuration words: quasi-static, captured every gen_clk by the qsg_* registers
//     (kcu116.xdc: false path to their inputs). The firmware writes them and then COMMIT;
//     the commit pulse reaches gen_clk 4+ clocks later, when they have long settled.
// gen_clk -> clk: the beats (xpm_fifo_async, distributed RAM), st_pending (xpm_cdc_single).
// Each START begins a new epoch (2-bit tag on every beat, counted on both sides): beats of
// an earlier run still in the FIFO are discarded on the clk side, so the first beat the
// producer sees after a start is sample 0 of the new run.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_iq_src #(
    parameter int    N_TONES   = 4,
    parameter string ROM_STYLE = "block"
) (
    input  wire logic              gen_clk,
    input  wire logic              g_rst,          // gen_clk synchronous
    input  wire logic              clk,
    input  wire logic              rst,            // clk synchronous

    // configuration (clk domain, quasi-static)
    input  wire logic [31:0]       cfg_id,
    input  wire logic [3:0][31:0]  tone_inc,
    input  wire logic [3:0][15:0]  tone_amp,
    input  wire logic [31:0]       chirp_start,
    input  wire logic [47:0]       chirp_rate,
    input  wire logic [47:0]       chirp_per,
    input  wire logic [15:0]       chirp_amp,
    input  wire logic [15:0]       noise_amp,
    input  wire logic [31:0]       noise_seed,
    input  wire logic [17:0]       chunk_pbeats,
    input  wire logic              commit,         // clk pulse
    input  wire logic              start,          // clk pulse: restart at sample 0
    input  wire logic              enable,         // clk level

    // beats (clk domain, first word fall through)
    output wire logic              o_valid,
    output wire logic [511:0]      o_data,
    input  wire logic              o_pop,

    output wire logic              st_pending,     // clk domain
    output logic                   ev_clip         // clk: a beat with a saturated sample was taken
);

// ---------------- clk -> gen_clk ----------------
wire logic g_start, g_commit, g_enable;
xpm_cdc_pulse #(.DEST_SYNC_FF(4), .REG_OUTPUT(1), .RST_USED(0)) u_pstart (
    .src_clk(clk), .src_pulse(start), .src_rst(1'b0), .dest_clk(gen_clk), .dest_rst(1'b0), .dest_pulse(g_start)
);
xpm_cdc_pulse #(.DEST_SYNC_FF(4), .REG_OUTPUT(1), .RST_USED(0)) u_pcommit (
    .src_clk(clk), .src_pulse(commit), .src_rst(1'b0), .dest_clk(gen_clk), .dest_rst(1'b0), .dest_pulse(g_commit)
);
xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1)) u_senable (
    .src_clk(clk), .src_in(enable), .dest_clk(gen_clk), .dest_out(g_enable)
);

logic [31:0]       qsg_id = '0;
logic [3:0][31:0]  qsg_inc = '0;
logic [3:0][15:0]  qsg_amp = '0;
logic [31:0]       qsg_cstart = '0, qsg_seed = '0;
logic [47:0]       qsg_rate = '0, qsg_per = '0;
logic [15:0]       qsg_camp = '0, qsg_namp = '0;
logic [17:0]       qsg_chunk = '0;
always_ff @(posedge gen_clk) begin
    qsg_id     <= cfg_id;
    qsg_inc    <= tone_inc;
    qsg_amp    <= tone_amp;
    qsg_cstart <= chirp_start;
    qsg_rate   <= chirp_rate;
    qsg_per    <= chirp_per;
    qsg_camp   <= chirp_amp;
    qsg_namp   <= noise_amp;
    qsg_seed   <= noise_seed;
    qsg_chunk  <= chunk_pbeats;               // plain capture: nothing from clk may reach R/S/CE
end
logic [17:0] g_chunk = 18'd1;
always_ff @(posedge gen_clk) g_chunk <= (qsg_chunk == '0) ? 18'd1 : qsg_chunk;

// ---------------- generator (gen_clk) ----------------
wire logic         g_valid, g_clip, g_pending;
wire logic [511:0] g_data;
wire logic         af_full, af_wbusy;
wire logic         g_pop = g_valid && !af_full && !af_wbusy;
logic [1:0]        g_ep = '0;

iq16_gen #(.N_TONES(N_TONES), .FIFO_AW(5), .SEEK_EN(1'b0), .ROM_STYLE(ROM_STYLE)) u_gen (
    .clk(gen_clk), .rst(g_rst),
    .sh_cfg_id(qsg_id), .sh_tone_inc(qsg_inc), .sh_tone_amp(qsg_amp),
    .sh_chirp_start(qsg_cstart), .sh_chirp_rate(qsg_rate), .sh_chirp_per(qsg_per),
    .sh_chirp_amp(qsg_camp), .sh_noise_amp(qsg_namp), .sh_noise_seed(qsg_seed),
    .commit(g_commit),
    .start(g_start), .enable(g_enable), .chunk_pbeats(g_chunk),
    .o_valid(g_valid), .o_data(g_data), .o_clip(g_clip), .o_cfg_first(), .o_cfg_id(), .o_pop(g_pop),
    .st_pending(g_pending), .st_active_id(), .st_active_n0(), .st_commits(), .st_apply(),
    .seek_n('0), .seek_n0('0), .seek_keymul('0), .seek_bp('0), .seek_m('0),
    .seek_acc('0), .seek_dl('0)
);

always_ff @(posedge gen_clk) begin
    if (g_start) g_ep <= g_ep + 2'd1;
    if (g_rst)   g_ep <= '0;
end

xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1)) u_spend (
    .src_clk(gen_clk), .src_in(g_pending), .dest_clk(clk), .dest_out(st_pending)
);

// ---------------- gen_clk -> clk: beats ----------------
wire logic [514:0] af_dout;
wire logic         af_valid, af_rbusy;
logic              af_rd;
logic [1:0]        c_ep = '0;

xpm_fifo_async #(
    .FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(32), .WRITE_DATA_WIDTH(515), .READ_DATA_WIDTH(515),
    .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .CDC_SYNC_STAGES(3), .RELATED_CLOCKS(0), .ECC_MODE("no_ecc"),
    .USE_ADV_FEATURES("1000"), .DOUT_RESET_VALUE("0"), .FULL_RESET_VALUE(0),
    .PROG_FULL_THRESH(16), .PROG_EMPTY_THRESH(10), .WR_DATA_COUNT_WIDTH(6), .RD_DATA_COUNT_WIDTH(6),
    .WAKEUP_TIME(0), .SIM_ASSERT_CHK(0)
) u_af (
    .rst(g_rst), .wr_clk(gen_clk), .wr_en(g_pop), .din({g_clip, g_ep, g_data}), .full(af_full),
    .wr_rst_busy(af_wbusy), .rd_clk(clk), .rd_en(af_rd), .dout(af_dout), .data_valid(af_valid),
    .rd_rst_busy(af_rbusy), .empty(), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
    .almost_empty(), .almost_full(), .dbiterr(), .overflow(), .prog_empty(), .prog_full(),
    .rd_data_count(), .sbiterr(), .underflow(), .wr_ack(), .wr_data_count()
);

always_ff @(posedge clk) begin
    if (start) c_ep <= c_ep + 2'd1;
    if (rst)   c_ep <= '0;
end

wire logic head_ok = af_valid && !af_rbusy && (af_dout[513:512] == c_ep);
wire logic head_old = af_valid && !af_rbusy && (af_dout[513:512] != c_ep);
assign o_valid = head_ok;
assign o_data  = af_dout[511:0];
always_comb af_rd = head_old || (head_ok && o_pop);

always_ff @(posedge clk) ev_clip <= head_ok && o_pop && af_dout[514];

endmodule

`resetall
