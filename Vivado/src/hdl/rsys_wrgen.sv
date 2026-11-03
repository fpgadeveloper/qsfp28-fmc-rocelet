// SPDX-License-Identifier: MIT
//
// rsys_wrgen - work-request generator of the rocelet self-test logic: the
// line-rate "data source" in front of the requester. Issues RDMA WRITE /
// WRITE-imm / SEND / SEND-imm work requests (rocelet WR descriptors) of a fixed
// length, walking the remote VA through a window (wrapping to its base), round
// robin over NQP QPs, with an optional gap between WRs and an optional WR count,
// and (PAY_EN, the ring / lossy requester) the payload stream: pattern(VA + 64k)
// per beat (rsys_pkg), tlast on the last beat of each WR. The local address of a
// WR is its VA, so a re-read requester reading the memory window's pattern
// region gets the same pattern.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_wrgen
    import rsys_pkg::*;
#(
    parameter int  QPW    = 3,
    parameter bit  PAY_EN = 1'b1
) (
    input  wire logic             clk,
    input  wire logic             rst,

    input  wire logic             start,
    input  wire logic             stop,
    input  wire logic [7:0]       cfg_qp0,
    input  wire logic [7:0]       cfg_nqp,
    input  wire logic [5:0]       cfg_op,       // [3:0] opcode [4] se [5] HSB metadata
    input  wire logic [63:0]      cfg_va,
    input  wire logic [31:0]      cfg_window,
    input  wire logic [31:0]      cfg_len,
    input  wire logic [31:0]      cfg_rkey,
    input  wire logic [31:0]      cfg_count,
    input  wire logic [31:0]      cfg_gap,
    input  wire logic [31:0]      cfg_seed,
    input  wire logic [31:0]      cfg_imm,

    output wire logic             m_wr_valid,
    input  wire logic             m_wr_ready,
    output wire logic [255:0]     m_wr_desc,    // rocelet WR descriptor
    output wire logic [31:0]      m_wr_len,

    output wire logic [511:0]     m_pay_tdata,
    output wire logic             m_pay_tvalid,
    input  wire logic             m_pay_tready,
    output wire logic             m_pay_tlast,

    output wire logic             running,
    output wire logic             pay_busy,     // payload of an accepted WR still to come
    output wire logic             wr_fire,
    output wire logic [31:0]      issued
);

logic        run = 1'b0;
logic [63:0] va;
logic [31:0] n, imm, gap_cnt;
logic [15:0] id;
logic [7:0]  qoff;
logic [5:0]  op;
logic [31:0] len, win, rkey, cnt_lim, gap;
logic [63:0] base;
logic [31:0] seed;
logic [7:0]  qp0, nqp;

// payload jobs (VA, beats)
wire logic        jq_full, jq_v;
wire logic [63:0] jq_va;
wire logic [25:0] jq_nb;
logic             jq_pop;

wire logic wr_ok = run && (gap_cnt == 0) && (!PAY_EN || !jq_full);
assign m_wr_valid = wr_ok;
assign wr_fire    = wr_ok && m_wr_ready;
wire logic [7:0] qp_n = qp0 + qoff;
// [7:0] qp [11:8] opcode [12] se [13] hsb_md [31:16] wr_id [63:32] length
// [127:64] remote VA [159:128] rkey [191:160] imm [255:192] local address
assign m_wr_desc  = {va, imm, rkey, va, len, id, 2'b00, op, qp_n};
assign m_wr_len   = len;
assign running    = run;
assign issued     = n;

wire logic [63:0] va_n   = va + {32'd0, len};
wire logic [32:0] off_n  = {1'b0, va_n[31:0] - base[31:0]} + {1'b0, len};

always_ff @(posedge clk) begin
    if (gap_cnt != 0) gap_cnt <= gap_cnt - 32'd1;
    if (start) begin
        run     <= 1'b1;
        va      <= cfg_va;
        base    <= cfg_va;
        n       <= '0;
        imm     <= cfg_imm;
        id      <= '0;
        qoff    <= '0;
        op      <= cfg_op;
        len     <= cfg_len;
        win     <= cfg_window;
        rkey    <= cfg_rkey;
        cnt_lim <= cfg_count;
        gap     <= cfg_gap;
        gap_cnt <= '0;
        seed    <= cfg_seed;
        qp0     <= cfg_qp0;
        nqp     <= (cfg_nqp == 0) ? 8'd1 : cfg_nqp;
    end else if (wr_fire) begin
        // next VA, wrapping so that a whole WR always fits in the window
        va      <= (off_n > {1'b0, win}) ? base : va_n;
        n       <= n + 32'd1;
        imm     <= imm + 32'd1;
        id      <= id + 16'd1;
        qoff    <= (qoff + 8'd1 == nqp) ? 8'd0 : qoff + 8'd1;
        gap_cnt <= gap;
        if (cnt_lim != 0 && n + 32'd1 == cnt_lim) run <= 1'b0;
    end
    if (stop) run <= 1'b0;
    if (rst) begin
        run     <= 1'b0;
        gap_cnt <= '0;
        n       <= '0;
    end
end

if (PAY_EN) begin : g_pay
    rsys_fifo #(.WIDTH(64 + 26), .DEPTH(16), .RAM_STYLE("distributed")) u_jq (
        .clk(clk), .rst(rst), .din({va, 26'((len + 32'd63) >> 6)}), .wr_en(wr_fire && len != 0),
        .full(jq_full), .dout({jq_va, jq_nb}), .valid(jq_v), .rd_en(jq_pop), .count()
    );

    logic         act = 1'b0;
    logic [63:0]  a;
    logic [25:0]  left;
    logic [511:0] o_d;
    logic         o_v = 1'b0, o_l = 1'b0;
    wire  logic   slot = !o_v || m_pay_tready;
    assign jq_pop = !act && jq_v;

    always_ff @(posedge clk) begin
        if (m_pay_tready) o_v <= 1'b0;
        if (jq_pop) begin
            act  <= 1'b1;
            a    <= jq_va;
            left <= jq_nb;
        end else if (act && slot) begin
            o_v  <= 1'b1;
            o_l  <= (left == 26'd1);
            o_d  <= pat_beat(a, seed);
            a    <= a + 64'd64;
            left <= left - 26'd1;
            if (left == 26'd1) act <= 1'b0;
        end
        if (rst) begin
            act <= 1'b0;
            o_v <= 1'b0;
        end
    end
    assign m_pay_tdata  = o_d;
    assign m_pay_tvalid = o_v;
    assign m_pay_tlast  = o_l;
    assign pay_busy     = jq_v || act || o_v;
end else begin : g_nopay
    assign jq_full = 1'b0;
    assign jq_v = 1'b0; assign jq_va = '0; assign jq_nb = '0;
    assign jq_pop = 1'b0;
    assign m_pay_tdata  = '0;
    assign m_pay_tvalid = 1'b0;
    assign m_pay_tlast  = 1'b0;
    assign pay_busy     = 1'b0;
end

endmodule

`resetall
