// SPDX-License-Identifier: MIT
//
// rsys_hsb_prod - Holoscan Sensor Bridge (HSB) frame producer: turns a stream of 64-byte
// sample beats into HSB frames for the rocelet engine's UC-HSB mode (QP type 2, see
// submodules/rocelet/docs/hsb.md, "Producing frames"):
//   for every frame, on page p of the host's page ring:
//     WRITE WRs for the frame data at page_va(p) + offset, each at most cfg_wrmax bytes
//       (the engine sends every packet as a WRITE Only with its own RETH);
//     one 128-byte WRITE-with-immediate WR with the metadata record at
//       page_va(p) + roundup(frame, 128), imm[11:0] = p, flag hsb_md (the engine writes the
//       packet's PSN into the record and the PSN into imm[31:12]);
//     p = p + 1, wrapping from the last page to the first.
//   page_va(p) = cfg_va0 + (p - first) x cfg_stride (kept as a running sum, no multiplier).
// Metadata record (128 bytes, big-endian, src/hololink/core/frame_metadata_parser.hpp):
//   0 flags 0 | 4 psn (engine) | 8 crc 0 | 12 timestamp_s u64 + 20 timestamp_ns u32 (time of
//   the frame start) | 24 bytes_written u64 = frame bytes | 32 pad | 34 frame_number u16 |
//   36 metadata_s u64 + 44 metadata_ns u32 (time of the metadata WR) | zeros.
// Sources (cfg_src; through the s_axis_src boundary and rsys_src_mux): 0 = the IQ16 beats of rsys_iq_src (16 complex int16 samples per beat,
// in stream order), 1 = a counter pattern that a host can check without a model: 64-bit
// little-endian word w of a frame = {frame_number[15:0], byte offset 8w [47:0]}, 2 = the beam
// array generator rsys_beam_src (docs/source/beam_contract.md), 3 = as 0. For source 2 the
// metadata record carries, big-endian in bytes 48-63, the scene_id and scene_frame side-band of
// the frame's first beat, the 32-bit frame index and the tag 0x424D0001 (contract section 3).
// Pacing: a frame starts at most every cfg_period clocks (0 = back to back); the engine's
// PACE_RATE can smooth the packets further. cfg_count frames per run (0 = until stopped).
// run 1 -> 0 stops at the next frame boundary (a started frame is always completed, so the
// engine never waits for payload). The configuration is latched when run rises, except
// cfg_period: it is registered (period_q) and sampled at every frame start, so a new period
// (the firmware's RATE_MBPS) changes the rate of a running stream from the next frame start on.
// Source, QP, R_Key, VA, stride, pages, frame size, WR size and count stay latched for the run:
// the host's page ring and frame layout must not change under a running receiver.
// One WR at a time: descriptor, then its payload beats (through a skid buffer), then the
// next descriptor; pay_busy tells the WR source arbiter in rocelet_sys that payload of an
// accepted WR is still to come.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_hsb_prod (
    input  wire logic          clk,
    input  wire logic          rst,

    input  wire logic          run,
    input  wire logic [1:0]    cfg_src,       // 0 IQ16, 1 counter pattern, 2 beam array, 3 = 0
    input  wire logic [7:0]    cfg_qp,
    input  wire logic [31:0]   cfg_rkey,
    input  wire logic [63:0]   cfg_va0,       // VA of the first page
    input  wire logic [31:0]   cfg_stride,    // bytes from one page to the next
    input  wire logic [11:0]   cfg_pg_first,
    input  wire logic [11:0]   cfg_pg_last,
    input  wire logic [31:0]   cfg_frame,     // frame bytes (> 0)
    input  wire logic [31:0]   cfg_wrmax,     // bytes per data WR (multiple of 64)
    input  wire logic [31:0]   cfg_period,    // clocks between frame starts
    input  wire logic [31:0]   cfg_count,     // frames per run, 0 = until stopped

    input  wire logic [47:0]   t_s,
    input  wire logic [29:0]   t_ns,

    // sample source boundary (rsys_src_mux selects the source by src_sel): 64-byte beats,
    // show-ahead (tvalid + tdata of the head beat, tready = consume it); tuser = side-band of
    // the beat ({scene_id, scene_frame} of the beam generator), taken from the frame's first
    // beat into the metadata record when src_sel = 2
    input  wire logic          s_axis_src_tvalid,
    input  wire logic [511:0]  s_axis_src_tdata,
    input  wire logic [63:0]   s_axis_src_tuser,
    output wire logic          s_axis_src_tready,
    output wire logic [1:0]    src_sel,       // source of the current run (0 IQ16, 1 counter, 2 beam)
    output wire logic          src_enable,    // a run is active (keep the source running)
    output logic               src_start = 1'b0, // pulse: a run starts (src_sel already valid)

    output wire logic          m_wr_valid,
    input  wire logic          m_wr_ready,
    output logic [255:0]       m_wr_desc,
    output wire logic [511:0]  m_pay_tdata,
    output wire logic          m_pay_tvalid,
    input  wire logic          m_pay_tready,
    output wire logic          m_pay_tlast,
    output wire logic          pay_busy,

    output wire logic          running,       // a run is active (also while finishing a frame)
    output logic [31:0]        frames,        // frames completed in this run
    output logic [11:0]        page,
    output logic [15:0]        fnum,
    output logic               ev_frame,
    output logic [15:0]        bytes_add,
    output logic               ev_stall_iq
);

typedef enum logic [2:0] {S_IDLE, S_WAIT, S_PREP, S_DESC, S_PAY, S_MDESC, S_MPAY, S_DONE} st_t;
st_t st = S_IDLE;

// latched configuration
logic [1:0]  l_src;
logic [31:0] md_sid, md_sframe;       // beam: scene of the frame (side-band of its first beat)
logic        f_first;                 // the next data beat is the frame's first
logic [7:0]  l_qp;
logic [31:0] l_rkey, l_stride, l_frame, l_wrmax, l_count;
logic [31:0] period_q = '0;           // cfg_period, one register stage (live: sampled at each frame start)
logic [63:0] l_va0;
logic [11:0] l_first, l_last;
logic [31:0] l_mdoff;                 // roundup(frame, 128)

logic        run_q = 1'b0;
logic [63:0] pb;                      // VA of the current page
logic [31:0] off, left, wl;           // frame offset, bytes left, this WR's bytes
logic [25:0] bleft;                   // beats of this WR still to push
logic        b_last;                  // the next beat pushed is the WR's last (bleft == 1)
logic        f_lastwr;                // this WR is the frame's last data WR
logic [47:0] cpos;                    // frame offset of the next beat (counter pattern)
logic [31:0] tmr = '0;                // clocks to the next frame start
logic [47:0] t0_s, tm_s;
logic [29:0] t0_ns, tm_ns;
logic [7:0]  wseq;
logic        mb;                      // metadata beat index

// ---------------- payload: source mux -> skid ----------------
wire logic        sk_rdy;
logic             in_v, in_l;
logic [511:0]     in_d;

function automatic logic [511:0] put_be(input logic [511:0] b, input int at, input int n, input logic [63:0] v);
    for (int i = 0; i < n; i++) b[(at + i) * 8 +: 8] = v[(n - 1 - i) * 8 +: 8];
    return b;
endfunction

logic [511:0] meta0;
always_comb begin
    meta0 = '0;
    meta0 = put_be(meta0, 12, 8, {16'd0, t0_s});
    meta0 = put_be(meta0, 20, 4, {34'd0, t0_ns});
    meta0 = put_be(meta0, 24, 8, {32'd0, l_frame});
    meta0 = put_be(meta0, 34, 2, {48'd0, fnum});
    meta0 = put_be(meta0, 36, 8, {16'd0, tm_s});
    meta0 = put_be(meta0, 44, 4, {34'd0, tm_ns});
    if (l_src == 2'd2) begin
        meta0 = put_be(meta0, 48, 4, {32'd0, md_sid});
        meta0 = put_be(meta0, 52, 4, {32'd0, md_sframe});
        meta0 = put_be(meta0, 56, 4, {32'd0, frames});
        meta0 = put_be(meta0, 60, 4, 64'h424D0001);
    end
end

// counter pattern beat: lane i = {fnum, byte offset}; offsets are 64-byte aligned, so lane
// i's low 6 bits are 8i and no adder is needed
logic [511:0] cnt_beat;
always_comb
    for (int i = 0; i < 8; i++) cnt_beat[i*64 +: 64] = {fnum, cpos[47:6], 3'(i), 3'b000};

always_comb begin
    in_v = 1'b0; in_l = 1'b0; in_d = cnt_beat;
    if (st == S_PAY) begin
        in_v = (l_src == 2'd1) ? 1'b1 : s_axis_src_tvalid;
        in_d = (l_src == 2'd1) ? cnt_beat : s_axis_src_tdata;
        in_l = b_last;
    end else if (st == S_MPAY) begin
        in_v = 1'b1;
        in_d = mb ? 512'd0 : meta0;
        in_l = mb;
    end
end
wire logic push = in_v && sk_rdy;
assign s_axis_src_tready = (st == S_PAY) && l_src != 2'd1 && push;
assign src_sel = l_src;

rsys_skid u_sk (
    .clk(clk), .rst(rst),
    .s_axis_tdata(in_d), .s_axis_tkeep('1), .s_axis_tvalid(in_v), .s_axis_tready(sk_rdy), .s_axis_tlast(in_l),
    .m_axis_tdata(m_pay_tdata), .m_axis_tkeep(), .m_axis_tvalid(m_pay_tvalid), .m_axis_tready(m_pay_tready),
    .m_axis_tlast(m_pay_tlast)
);

assign pay_busy   = (st == S_PAY) || (st == S_MPAY) || m_pay_tvalid;
assign m_wr_valid = (st == S_DESC) || (st == S_MDESC);
assign running    = (st != S_IDLE);
assign src_enable = (st != S_IDLE);

// ---------------- control ----------------
wire logic [31:0] wl_n = (left > l_wrmax) ? l_wrmax : left;

always_ff @(posedge clk) begin
    run_q       <= run;
    period_q    <= cfg_period;
    src_start   <= 1'b0;
    ev_frame    <= 1'b0;
    bytes_add   <= (push && st == S_PAY) ? 16'd64 : 16'd0;
    ev_stall_iq <= (st == S_PAY) && l_src != 2'd1 && !in_v && sk_rdy;
    if (tmr != 0) tmr <= tmr - 32'd1;

    case (st)
        S_IDLE: begin
            if (run && !run_q) begin
                l_src    <= (cfg_src == 2'd3) ? 2'd0 : cfg_src;
                l_qp     <= cfg_qp;
                l_rkey   <= cfg_rkey;
                l_va0    <= cfg_va0;
                l_stride <= cfg_stride;
                l_first  <= cfg_pg_first;
                l_last   <= cfg_pg_last;
                l_frame  <= cfg_frame;
                l_mdoff  <= (cfg_frame + 32'd127) & ~32'd127;
                l_wrmax  <= (cfg_wrmax[31:6] == 0) ? 32'd64 : {cfg_wrmax[31:6], 6'd0};
                l_count  <= cfg_count;
                pb       <= cfg_va0;
                page     <= cfg_pg_first;
                fnum     <= '0;
                frames   <= '0;
                wseq     <= '0;
                tmr      <= '0;
                src_start <= 1'b1;
                st       <= S_WAIT;
            end
        end
        S_WAIT: begin
            if (!run) st <= S_IDLE;
            else if (l_count != 0 && frames == l_count) st <= S_DONE;
            else if (tmr == 0 && l_frame != 0) begin
                tmr   <= period_q;               // live period: a change applies from this frame start
                off   <= '0;
                left  <= l_frame;
                t0_s  <= t_s;
                t0_ns <= t_ns;
                f_first <= 1'b1;
                st    <= S_PREP;
            end
        end
        S_PREP: begin
            // this WR: length, VA, descriptor ([7:0] qp [13:8] op [31:16] id [63:32] length
            // [127:64] VA [159:128] rkey [191:160] imm [255:192] local address)
            wl        <= wl_n;
            bleft     <= 26'((wl_n + 32'd63) >> 6);
            b_last    <= (wl_n <= 32'd64);
            f_lastwr  <= (left <= l_wrmax);
            cpos      <= 48'(off);
            m_wr_desc <= {64'd0, 32'd0, l_rkey, pb + 64'(off), wl_n, fnum[7:0], wseq, 2'b00, 6'h00, l_qp};
            st        <= S_DESC;
        end
        S_DESC: begin
            if (m_wr_ready) begin
                wseq <= wseq + 8'd1;
                st   <= S_PAY;
            end
        end
        S_PAY: begin
            if (push) begin
                f_first <= 1'b0;
                if (f_first) begin
                    md_sid    <= s_axis_src_tuser[63:32];
                    md_sframe <= s_axis_src_tuser[31:0];
                end
                bleft  <= bleft - 26'd1;
                b_last <= (bleft == 26'd2);
                cpos   <= cpos + 48'd64;
                if (in_l) begin
                    off  <= off + wl;
                    left <= left - wl;
                    if (f_lastwr) begin
                        tm_s      <= t_s;
                        tm_ns     <= t_ns;
                        m_wr_desc <= {64'd0, 20'd0, page, l_rkey, pb + 64'(l_mdoff), 32'd128, fnum[7:0], wseq,
                                      2'b00, 6'h21, l_qp};
                        st        <= S_MDESC;
                    end else begin
                        st <= S_PREP;
                    end
                end
            end
        end
        S_MDESC: begin
            if (m_wr_ready) begin
                wseq <= wseq + 8'd1;
                mb   <= 1'b0;
                st   <= S_MPAY;
            end
        end
        S_MPAY: begin
            if (push) begin
                mb <= 1'b1;
                if (mb) begin
                    frames   <= frames + 32'd1;
                    fnum     <= fnum + 16'd1;
                    ev_frame <= 1'b1;
                    if (page == l_last) begin
                        page <= l_first;
                        pb   <= l_va0;
                    end else begin
                        page <= page + 12'd1;
                        pb   <= pb + 64'(l_stride);
                    end
                    st <= S_WAIT;
                end
            end
        end
        S_DONE: if (!run) st <= S_IDLE;
        default: st <= S_IDLE;
    endcase

    if (rst) begin
        st     <= S_IDLE;
        run_q  <= 1'b0;
        tmr    <= '0;
        frames <= '0;
        fnum   <= '0;
        page   <= '0;
    end
end

endmodule

`resetall
