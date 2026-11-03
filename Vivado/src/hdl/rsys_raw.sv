// SPDX-License-Identifier: MIT
//
// rsys_raw - raw frame access for the firmware (firmware frame path):
//  * TX: a 2 KB frame buffer (32 beats) the firmware fills through the register
//    window, sent on request as one frame to the TX arbiter (e.g. an RDMA READ
//    request towards the engine's READ responder, with the ICRC computed in
//    software, or a deliberately bad frame);
//  * capture: the next frame that matches a filter (any / opcode / destination
//    QPN / both) is stored, up to 8 KB (128 beats), for the firmware to read and
//    verify; source = the received stream after the classifier stage, or (mode
//    bit 3) the transmitted stream at the CMAC TX interface. Per beat it also
//    records tkeep, tlast and the idle clocks before the beat (TX: clocks with
//    tvalid low inside the frame = CMAC underrun risk) in an aux window.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_raw (
    input  wire logic          clk,
    input  wire logic          rst,

    // TX buffer
    input  wire logic          wr_en,
    input  wire logic [8:0]    wr_addr,     // 32-bit word index
    input  wire logic [31:0]   wr_data,
    input  wire logic          send,
    input  wire logic [11:0]   send_len,    // bytes, <= 2048
    output wire logic [511:0]  m_axis_tdata,
    output wire logic [63:0]   m_axis_tkeep,
    output wire logic          m_axis_tvalid,
    input  wire logic          m_axis_tready,
    output wire logic          m_axis_tlast,
    output logic               ev_sent,
    output wire logic          busy,        // a frame is being sent (do not rewrite the buffer)

    // capture
    input  wire logic          cap_arm,
    input  wire logic [1:0]    cap_mode,
    input  wire logic          cap_tx,      // 1: capture the TX stream
    input  wire logic          ttap_valid,  // TX tap: accepted beat at the CMAC
    input  wire logic          ttap_first,
    input  wire logic [511:0]  ttap_data,
    input  wire logic [63:0]   ttap_keep,
    input  wire logic          ttap_last,
    input  wire logic [15:0]   ttap_idle,   // clocks since the previous accepted beat (minus one)
    input  wire logic [31:0]   cap_match,   // [7:0] opcode [31:8] dest QPN
    input  wire logic          tap_valid,
    input  wire logic          tap_first,
    input  wire logic [511:0]  tap_data,
    input  wire logic [63:0]   tap_keep,
    input  wire logic          tap_last,
    input  wire logic [11:0]   cap_raddr,   // 32-bit word index; [11] = aux window
    output logic [31:0]        cap_rdata,   // 2 clocks after cap_raddr
    output logic [31:0]        cap_status,  // [0] done [16:4] length
    output logic               ev_cap
);

// ---------------- TX ----------------
// one 32 x 32-bit LUTRAM per 32-bit lane of the beat
logic        t_act = 1'b0;
logic [5:0]  t_k, t_n;
logic [31:0] tx_rd [16];
for (genvar w = 0; w < 16; w++) begin : g_lane
    (* ram_style = "distributed" *) logic [31:0] m [32];
    always_ff @(posedge clk) if (wr_en && wr_addr[3:0] == 4'(w)) m[wr_addr[8:4]] <= wr_data;
    assign tx_rd[w] = m[t_k[4:0]];
end

logic [5:0]  t_last_bytes;
logic [511:0] o_d;
logic [63:0]  o_k;
logic         o_v = 1'b0, o_l;
wire  logic   o_slot = !o_v || m_axis_tready;

function automatic logic [63:0] therm(input logic [6:0] n);
    for (int i = 0; i < 64; i++) therm[i] = (i < n);
endfunction

always_ff @(posedge clk) begin
    ev_sent <= 1'b0;
    if (m_axis_tready) o_v <= 1'b0;
    if (send && !t_act && send_len != 0) begin
        t_act        <= 1'b1;
        t_k          <= '0;
        t_n          <= 6'((send_len - 12'd1) >> 6);      // index of the last beat
        t_last_bytes <= send_len[5:0];
    end else if (t_act && o_slot) begin
        o_v <= 1'b1;
        for (int w = 0; w < 16; w++) o_d[w*32 +: 32] <= tx_rd[w];
        o_l <= (t_k == t_n);
        o_k <= (t_k == t_n) ? ((t_last_bytes == 0) ? '1 : therm({1'b0, t_last_bytes})) : '1;
        t_k <= t_k + 6'd1;
        if (t_k == t_n) begin
            t_act   <= 1'b0;
            ev_sent <= 1'b1;
        end
    end
    if (rst) begin
        t_act <= 1'b0;
        o_v   <= 1'b0;
    end
end
assign busy          = t_act || o_v;
assign m_axis_tdata  = o_d;
assign m_axis_tkeep  = o_k;
assign m_axis_tvalid = o_v;
assign m_axis_tlast  = o_l;

// ---------------- capture ----------------
// the tap is registered first (the 512-bit RX bus also feeds the engine; the
// capture RAM may sit far away), the byte count of each beat with it
logic         tv_q = 1'b0, tf_q, tl_q;
logic [511:0] td_q;
logic [63:0]  tk_q;
logic [15:0]  ti_q;
logic [6:0]   tn_q;
logic         src_tx = 1'b0;
always_ff @(posedge clk) begin
    tv_q <= src_tx ? ttap_valid : tap_valid;
    tf_q <= src_tx ? ttap_first : tap_first;
    tl_q <= src_tx ? ttap_last  : tap_last;
    td_q <= src_tx ? ttap_data  : tap_data;
    tk_q <= src_tx ? ttap_keep  : tap_keep;
    ti_q <= src_tx ? ttap_idle  : 16'd0;
    tn_q <= 7'($countones(src_tx ? ttap_keep : tap_keep));
    if (cap_arm) src_tx <= cap_tx;
end
(* ram_style = "distributed" *) logic [80:0] aux_mem [128];

(* ram_style = "block" *) logic [511:0] cap_mem [128];
logic        c_armed = 1'b0, c_act = 1'b0, c_done = 1'b0;
logic [7:0]  c_beat;
logic [12:0] c_len;
// filter fields; 4 bytes later in a frame with an 802.1Q tag (TX side with tagging on)
wire  logic        t_tag  = (td_q[12*8 +: 8] == 8'h81) && (td_q[13*8 +: 8] == 8'h00);
wire  logic [7:0]  t_op   = t_tag ? td_q[46*8 +: 8] : td_q[42*8 +: 8];
wire  logic [23:0] t_dqpn = t_tag ? {td_q[51*8 +: 8], td_q[52*8 +: 8], td_q[53*8 +: 8]}
                                  : {td_q[47*8 +: 8], td_q[48*8 +: 8], td_q[49*8 +: 8]};
wire  logic        f_op   = (t_op == cap_match[7:0]);
wire  logic        f_qp   = (t_dqpn == cap_match[31:8]);
wire  logic        hit    = (cap_mode == 2'd0) || (cap_mode == 2'd1 && f_op) ||
                            (cap_mode == 2'd2 && f_qp) || (cap_mode == 2'd3 && f_op && f_qp);
wire  logic        start  = c_armed && !c_act && tv_q && tf_q && hit;
wire  logic        wr     = (start || c_act) && tv_q && (start ? 1'b1 : c_beat < 8'd128);

always_ff @(posedge clk) begin
    if (wr) cap_mem[start ? 7'd0 : c_beat[6:0]] <= td_q;
    if (wr) aux_mem[start ? 7'd0 : c_beat[6:0]] <= {tl_q, ti_q, tk_q};
end

always_ff @(posedge clk) begin
    ev_cap <= 1'b0;
    if (cap_arm) begin
        c_armed <= 1'b1;
        c_act   <= 1'b0;
        c_done  <= 1'b0;
    end else if (start) begin
        c_act   <= !tl_q;
        c_armed <= 1'b0;
        c_beat  <= 8'd1;
        c_len   <= 13'(tn_q);
        if (tl_q) begin c_done <= 1'b1; ev_cap <= 1'b1; end
    end else if (c_act && tv_q) begin
        c_beat <= c_beat + 8'd1;
        c_len  <= c_len + 13'(tn_q);
        if (tl_q) begin
            c_act  <= 1'b0;
            c_done <= 1'b1;
            ev_cap <= 1'b1;
        end
    end
    if (rst) begin
        c_armed <= 1'b0;
        c_act   <= 1'b0;
        c_done  <= 1'b0;
    end
end
assign cap_status = {15'd0, c_len, 3'd0, c_done};

// read: RAM (registered) then the 32-bit lane mux (registered); aux window:
// per beat 4 words {keep[31:0], keep[63:32], {last, 15'b0, idle[15:0]}, 0}
logic [511:0] cap_q;
logic [80:0]  aux_q;
logic [3:0]   lane_q;
logic         sel_aux;
always_ff @(posedge clk) begin
    cap_q     <= cap_mem[cap_raddr[10:4]];
    aux_q     <= aux_mem[cap_raddr[8:2]];
    lane_q    <= cap_raddr[3:0];
    sel_aux   <= cap_raddr[11];
    if (!sel_aux)               cap_rdata <= cap_q[lane_q*32 +: 32];
    else if (lane_q[1:0] == 0)  cap_rdata <= aux_q[31:0];
    else if (lane_q[1:0] == 1)  cap_rdata <= aux_q[63:32];
    else if (lane_q[1:0] == 2)  cap_rdata <= {aux_q[80], 15'd0, aux_q[79:64]};
    else                        cap_rdata <= 32'd0;
end

endmodule

`resetall
