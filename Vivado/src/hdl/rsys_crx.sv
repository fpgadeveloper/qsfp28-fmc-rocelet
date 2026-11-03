// SPDX-License-Identifier: MIT
//
// rsys_crx - control-plane receive FIFO: the frames of the rocelet engine's other-traffic
// port (everything that is not RoCE and not an ARP / ICMP echo request the engine answers
// itself, with CTRL.OTHER_RX_EN = 1) that the firmware wants, queued for the MicroBlaze.
//
// Filter (on the first beat; cfg en = 0 stores nothing): IPv4 without options (EtherType
// 0x0800, byte 14 = 0x45, no 802.1Q tag left after the engine's VID-0 strip), protocol UDP,
// destination port == port_a or port_b (defaults 8192 = HSB register protocol and
// 12268 = HSB BOOTP reply / set-ip); with all = 1 every frame is taken. No MAC / IP check:
// the firmware checks the destination IP (8192) or the BOOTP chaddr (12268).
// Storage: SLOTS frames of up to 2 KB (32 beats; a full 1514-byte frame fits) in one block
// RAM of SLOTS x 32 x 512 bits. A frame that matches while all slots are full is dropped
// (ev_drop), one longer than 2 KB is dropped (ev_long), a frame that does not match is
// counted (ev_filt). The input never stalls (the other-traffic port has tready = 1).
// Read side: the head frame is visible as 32-bit words (raddr = word index, data 2 clocks
// later), head_len its length in bytes, level the number of queued frames; pop frees it.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_crx #(
    parameter int SLOTS = 16              // power of two
) (
    input  wire logic          clk,
    input  wire logic          rst,

    input  wire logic          en,
    input  wire logic          all,
    input  wire logic [15:0]   port_a,
    input  wire logic [15:0]   port_b,

    input  wire logic          s_valid,
    input  wire logic          s_first,
    input  wire logic [511:0]  s_data,
    input  wire logic [63:0]   s_keep,
    input  wire logic          s_last,

    input  wire logic          pop,
    input  wire logic [8:0]    raddr,       // 32-bit word index in the head frame
    output logic [31:0]        rdata,
    output wire logic [7:0]    level,
    output wire logic [11:0]   head_len,

    output logic               ev_frame,
    output logic               ev_drop,
    output logic               ev_long,
    output logic               ev_filt
);

localparam int SW = $clog2(SLOTS);

// input register (the RX bus also feeds the engine and the capture)
logic         v_q = 1'b0, f_q, l_q;
logic [511:0] d_q;
logic [6:0]   n_q;
always_ff @(posedge clk) begin
    v_q <= s_valid;
    f_q <= s_first;
    l_q <= s_last;
    d_q <= s_data;
    n_q <= 7'($countones(s_keep));
end

function automatic logic [7:0] B(input logic [511:0] d, input int i);
    return d[i*8 +: 8];
endfunction
wire logic match = ({B(d_q, 12), B(d_q, 13)} == 16'h0800) && (B(d_q, 14) == 8'h45) && (B(d_q, 23) == 8'd17) &&
                   (({B(d_q, 36), B(d_q, 37)} == port_a) || ({B(d_q, 36), B(d_q, 37)} == port_b));

(* ram_style = "block" *) logic [511:0] mem [SLOTS * 32];
logic [11:0]  len_mem [SLOTS];
logic [SW:0]  ws = '0, rs = '0;          // write / read slot counters (one extra bit)
logic         act = 1'b0;                // storing a frame
logic [5:0]   wb;                        // beat index in the slot
logic [11:0]  wlen;
wire  logic   full  = (ws - rs) == (SW+1)'(SLOTS);
wire  logic   start = v_q && f_q && en;
wire  logic   take  = start && (all || match) && !full;
wire  logic   wr    = (take || (act && v_q)) && (take ? 1'b1 : wb < 6'd32);

always_ff @(posedge clk)
    if (wr) mem[{ws[SW-1:0], take ? 5'd0 : wb[4:0]}] <= d_q;

always_ff @(posedge clk) begin
    ev_frame <= 1'b0;
    ev_drop  <= 1'b0;
    ev_long  <= 1'b0;
    ev_filt  <= 1'b0;
    if (start && !(all || match)) ev_filt <= 1'b1;
    if (start && (all || match) && full) ev_drop <= 1'b1;
    if (take) begin
        wb   <= 6'd1;
        wlen <= 12'(n_q);
        if (l_q) begin
            len_mem[ws[SW-1:0]] <= 12'(n_q);
            ws       <= ws + 1'b1;
            ev_frame <= 1'b1;
        end else begin
            act <= 1'b1;
        end
    end else if (act && v_q) begin
        if (wb != 6'd32) wb <= wb + 6'd1;
        wlen <= wlen + 12'(n_q);
        if (l_q) begin
            act <= 1'b0;
            if (wb == 6'd32) begin
                ev_long <= 1'b1;             // more than 32 beats: dropped, slot reused
            end else begin
                len_mem[ws[SW-1:0]] <= wlen + 12'(n_q);
                ws       <= ws + 1'b1;
                ev_frame <= 1'b1;
            end
        end
    end
    if (pop && ws != rs) rs <= rs + 1'b1;
    if (rst || !en) begin
        act <= 1'b0;
    end
    if (rst) begin
        ws <= '0;
        rs <= '0;
    end
end

assign level    = 8'(ws - rs);
assign head_len = (ws != rs) ? len_mem[rs[SW-1:0]] : 12'd0;

// read: RAM (registered) then the 32-bit lane (registered)
logic [511:0] q;
logic [3:0]   lane;
always_ff @(posedge clk) begin
    q     <= mem[{rs[SW-1:0], raddr[8:4]}];
    lane  <= raddr[3:0];
    rdata <= q[lane*32 +: 32];
end

endmodule

`resetall
