// SPDX-License-Identifier: MIT
//
// rsys_wrq - firmware access to the rocelet requester and to the completions:
//  * work-request queue: the firmware describes a WR in registers (QP, opcode,
//    remote VA / R_Key, length, immediate, local address, id) and posts it; the
//    WR waits here, as a rocelet WR descriptor, until the engine takes it;
//  * payload reader (PAY_EN: ring / lossy requester): for every WR the engine
//    accepts from this queue, its payload is read from the memory window
//    (rsys_axi_mem payload port) at the WR's local address and streamed to the
//    engine with tlast on its last beat, in read commands of up to 4 KB (a
//    re-read requester reads the payload itself through its AXI master);
//  * completion queues: work completions (m_axis_wc) and receive completions
//    (m_axis_rc), each enabled by the firmware and read one record at a time
//    through status registers.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_wrq #(
    parameter bit PAY_EN   = 1'b1,
    parameter int WQ_DEPTH = 32,
    parameter int CQ_DEPTH = 128
) (
    input  wire logic             clk,
    input  wire logic             rst,

    // post a WR (one clock) with its description
    input  wire logic             post,
    input  wire logic [255:0]     post_desc,    // rocelet WR descriptor
    output wire logic [8:0]       wq_level,
    output wire logic             wq_full,
    output wire logic             ev_posted,
    output wire logic             ev_dropped,

    // WR towards the engine (through the source mux in rocelet_sys)
    output wire logic             m_wr_valid,
    input  wire logic             m_wr_ready,
    output wire logic [255:0]     m_wr_desc,

    // payload: read commands to the memory window, data to the engine
    output wire logic             m_rd_valid,
    input  wire logic             m_rd_ready,
    output wire logic [63:0]      m_rd_addr,
    output wire logic [12:0]      m_rd_len,
    input  wire logic [511:0]     s_rd_tdata,
    input  wire logic             s_rd_tvalid,
    output wire logic             s_rd_tready,
    output wire logic [511:0]     m_pay_tdata,
    output wire logic             m_pay_tvalid,
    input  wire logic             m_pay_tready,
    output wire logic             m_pay_tlast,
    output wire logic             pay_busy,     // payload of an accepted WR still to come

    // completions from the engine
    input  wire logic [1:0]       cq_en,        // [0] work completions [1] receive completions
    input  wire logic             wc_valid,
    input  wire logic [63:0]      wc_data,      // [15:0] wr_id [23:16] qp [31:24] status
    input  wire logic             rc_valid,
    input  wire logic [127:0]     rc_data,      // [31:0] imm [63:32] length [71:64] qp [72] SEND [73] imm present
    input  wire logic [1:0]       cq_pop,       // [0] work completion head [1] receive completion head
    output wire logic [31:0]      wcq_head,     // [31] valid [30:24] status [23:16] qp [15:0] wr_id
    output wire logic [31:0]      rcq_head,     // [31] valid [30] SEND [29] immediate [23:16] qp
    output wire logic [31:0]      rcq_imm,
    output wire logic [31:0]      rcq_len,
    output wire logic [7:0]       wcq_level,
    output wire logic [7:0]       rcq_level,
    output wire logic             ev_wcq_ovf,
    output wire logic             ev_rcq_ovf
);

// ---------------- work-request queue ----------------
wire logic           wq_v;
wire logic [$clog2(WQ_DEPTH):0] wq_cnt;
rsys_fifo #(.WIDTH(256), .DEPTH(WQ_DEPTH), .RAM_STYLE("distributed")) u_wq (
    .clk(clk), .rst(rst), .din(post_desc), .wr_en(post), .full(wq_full),
    .dout(m_wr_desc), .valid(wq_v), .rd_en(m_wr_valid && m_wr_ready), .count(wq_cnt)
);
assign wq_level   = 9'(wq_cnt);
assign ev_posted  = post && !wq_full;
assign ev_dropped = post && wq_full;

wire logic [31:0] d_len   = m_wr_desc[63:32];
wire logic [63:0] d_laddr = m_wr_desc[255:192];

// payload jobs: local address + length of every accepted WR with a payload
wire logic jq_full, jq_v;
wire logic [63:0] jq_a;
wire logic [31:0] jq_len;
logic jq_pop;
assign m_wr_valid = wq_v && (!PAY_EN || !jq_full);

if (PAY_EN) begin : g_pay
    rsys_fifo #(.WIDTH(96), .DEPTH(16), .RAM_STYLE("distributed")) u_jq (
        .clk(clk), .rst(rst), .din({d_laddr, d_len}),
        .wr_en(m_wr_valid && m_wr_ready && d_len != 0), .full(jq_full),
        .dout({jq_a, jq_len}), .valid(jq_v), .rd_en(jq_pop), .count()
    );

    // split each job into read commands of up to 4 KB (64 beats); count the
    // job's beats for tlast
    logic        act = 1'b0;
    logic [63:0] a;
    logic [31:0] left;
    logic        c_v = 1'b0;
    logic [63:0] c_a;
    logic [12:0] c_len;
    // jobs whose read commands are issued, waiting for their data: beats per job
    wire  logic        bq_v, bq_full;
    wire  logic [25:0] bq_nb;
    logic              bq_pop;
    logic [25:0]       beat = '0;     // beats delivered of the head job
    logic [31:0]       owed = '0;     // beats requested, not yet delivered
    assign jq_pop = !act && jq_v && !bq_full;
    wire logic [31:0] chunk = (left > 32'd4096) ? 32'd4096 : left;

    rsys_fifo #(.WIDTH(26), .DEPTH(16), .RAM_STYLE("distributed")) u_bq (
        .clk(clk), .rst(rst), .din(26'((jq_len + 32'd63) >> 6)), .wr_en(jq_pop), .full(bq_full),
        .dout(bq_nb), .valid(bq_v), .rd_en(bq_pop), .count()
    );
    wire logic pay_beat = m_pay_tvalid && m_pay_tready;
    assign m_pay_tlast = bq_v && (beat + 26'd1 == bq_nb);
    always_comb bq_pop = pay_beat && m_pay_tlast;

    always_ff @(posedge clk) begin
        if (m_rd_valid && m_rd_ready) c_v <= 1'b0;
        if (jq_pop) begin
            act  <= 1'b1;
            a    <= {jq_a[63:6], 6'd0};
            left <= jq_len;
        end else if (act && (!c_v || m_rd_ready)) begin
            c_v   <= 1'b1;
            c_a   <= a;
            c_len <= 13'(chunk);
            a     <= a + 64'(chunk);
            left  <= left - chunk;
            if (left == chunk) act <= 1'b0;
        end
        if (pay_beat) beat <= m_pay_tlast ? 26'd0 : beat + 26'd1;
        owed <= owed + ((m_rd_valid && m_rd_ready) ? 32'((c_len + 13'd63) >> 6) : 32'd0)
                     - (pay_beat ? 32'd1 : 32'd0);
        if (rst) begin
            act  <= 1'b0;
            c_v  <= 1'b0;
            beat <= '0;
            owed <= '0;
        end
    end
    assign m_rd_valid   = c_v;
    assign m_rd_addr    = c_a;
    assign m_rd_len     = c_len;
    assign m_pay_tdata  = s_rd_tdata;
    assign m_pay_tvalid = s_rd_tvalid;
    assign s_rd_tready  = m_pay_tready;
    assign pay_busy     = jq_v || act || c_v || bq_v || (owed != 0);
end else begin : g_nopay
    assign jq_full = 1'b0;
    assign jq_v = 1'b0; assign jq_a = '0; assign jq_len = '0;
    always_comb jq_pop = 1'b0;
    assign m_rd_valid   = 1'b0;
    assign m_rd_addr    = '0;
    assign m_rd_len     = '0;
    assign m_pay_tdata  = '0;
    assign m_pay_tvalid = 1'b0;
    assign m_pay_tlast  = 1'b0;
    assign s_rd_tready  = 1'b0;
    assign pay_busy     = 1'b0;
end

// ---------------- completion queues ----------------
wire logic        wc_push = cq_en[0] && wc_valid;
wire logic        wc_full, wc_v;
wire logic [31:0] wc_dout;
wire logic [$clog2(CQ_DEPTH):0] wc_cnt;
rsys_fifo #(.WIDTH(32), .DEPTH(CQ_DEPTH), .RAM_STYLE("distributed")) u_wcq (
    .clk(clk), .rst(rst), .din({1'b0, wc_data[30:0]}), .wr_en(wc_push), .full(wc_full),
    .dout(wc_dout), .valid(wc_v), .rd_en(cq_pop[0]), .count(wc_cnt)
);
assign wcq_head   = {wc_v, wc_dout[30:0]};
assign wcq_level  = 8'(wc_cnt);
assign ev_wcq_ovf = wc_push && wc_full;

wire logic        rc_push = cq_en[1] && rc_valid;
wire logic        rc_full, rc_v;
wire logic [95:0] rc_dout;
wire logic [$clog2(CQ_DEPTH):0] rc_cnt;
rsys_fifo #(.WIDTH(96), .DEPTH(CQ_DEPTH), .RAM_STYLE("distributed")) u_rcq (
    .clk(clk), .rst(rst),
    .din({1'b0, rc_data[72], rc_data[73], 5'd0, rc_data[71:64], 16'd0, rc_data[63:32], rc_data[31:0]}),
    .wr_en(rc_push), .full(rc_full),
    .dout(rc_dout), .valid(rc_v), .rd_en(cq_pop[1]), .count(rc_cnt)
);
assign rcq_head   = {rc_v, rc_dout[94:64]};
assign rcq_len    = rc_dout[63:32];
assign rcq_imm    = rc_dout[31:0];
assign rcq_level  = 8'(rc_cnt);
assign ev_rcq_ovf = rc_push && rc_full;

endmodule

`resetall
