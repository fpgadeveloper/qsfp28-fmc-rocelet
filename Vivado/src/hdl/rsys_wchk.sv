// SPDX-License-Identifier: MIT
//
// rsys_wchk - committed-data checker of the rocelet self-test logic.
// Taps the responder's payload as it is written cut-through and judges each
// packet only when its commit verdict arrives (a frame with a bad ICRC is
// written, then discarded and overwritten by the retransmission):
//   SEND_MODE 0 (RDMA WRITE): the packet's local address comes from the write
//     command (or, ADDR_IN, with every beat: the AXI write-beat tap of the
//     memory window, where a "packet" is one AXI burst and every burst counts
//     as committed); every beat must equal pattern(address + 64k) (rsys_pkg).
//   SEND_MODE 1 (SEND): the address is the one embedded in each beat
//     (beat[63:0]); the rest of the beat must match it and the addresses must
//     be consecutive inside the packet.
// Per committed packet: bytes, a mismatch event if any kept byte differs, and a
// gap event if the packet does not start where the previous one ended (lost
// data: lossy resume) unless it starts at the window base (the generator
// wrapped). Discarded packets are only counted.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_wchk
    import rsys_pkg::*;
#(
    parameter bit SEND_MODE = 1'b0,
    parameter bit ADDR_IN   = 1'b0       // WRITE: the address of every beat is given (s_beat_addr)
) (
    input  wire logic          clk,
    input  wire logic          rst,
    input  wire logic [31:0]   seed,
    input  wire logic [63:0]   base,

    input  wire logic          s_cmd_valid,      // WRITE: one per packet, before its data
    input  wire logic [63:0]   s_cmd_addr,
    input  wire logic [12:0]   s_cmd_len,
    input  wire logic          s_beat_valid,     // one accepted payload beat
    input  wire logic [63:0]   s_beat_addr,      // ADDR_IN: its address
    input  wire logic [511:0]  s_beat_data,
    input  wire logic [63:0]   s_beat_keep,
    input  wire logic          s_beat_last,
    input  wire logic          s_end_valid,      // commit verdict, in packet order
    input  wire logic          s_end_ok,

    output logic               ev_ok,
    output logic               ev_bad,
    output logic               ev_mism,
    output logic               ev_gap,
    output logic [15:0]        bytes_add,
    output logic [63:0]        exp_addr,
    output logic [63:0]        err_addr
);

// ---------------- data pipeline ----------------
logic [63:0]  cur;            // WRITE: address of the next beat
logic         first = 1'b1;   // next beat is the first of a packet
logic [63:0]  prev_a;
logic [63:0]  pk_start;
logic [12:0]  pk_len;

// stage 1
logic         v1 = 1'b0, l1, f1, s1;
logic [511:0] d1;
logic [63:0]  k1, a1, st1;
// stage 2
logic         v2 = 1'b0, l2, s2;
logic [511:0] d2, e2;
logic [63:0]  k2, st2;
logic [6:0]   n2;
// stage 3
logic         v3 = 1'b0, l3, m3;
logic [63:0]  st3;
logic [6:0]   n3;
// packet accumulation
logic         pk_mm = 1'b0;
logic [13:0]  pk_bytes = '0;

always_ff @(posedge clk) begin
    if (s_cmd_valid) begin
        cur    <= s_cmd_addr;
        pk_len <= s_cmd_len;
    end
    v1 <= s_beat_valid;
    if (s_beat_valid) begin
        logic [63:0] a;
        a      = SEND_MODE ? s_beat_data[63:0] : (ADDR_IN ? s_beat_addr : cur);
        d1     <= s_beat_data;
        k1     <= s_beat_keep;
        l1     <= s_beat_last;
        a1     <= a;
        f1     <= first;
        // SEND: consecutive embedded addresses inside a packet
        s1     <= SEND_MODE && !first && (a != prev_a + 64'd64);
        st1    <= first ? a : pk_start;
        if (first) pk_start <= a;
        prev_a <= a;
        cur    <= cur + 64'd64;
        first  <= s_beat_last;
    end
    v2 <= v1;
    if (v1) begin
        d2  <= d1;
        e2  <= pat_beat(a1, seed);
        k2  <= k1;
        l2  <= l1;
        s2  <= s1;
        st2 <= st1;
        n2  <= popcnt64(k1);
    end
    v3 <= v2;
    if (v2) begin
        m3  <= beat_mismatch(d2, e2, k2) || s2;
        l3  <= l2;
        st3 <= st2;
        n3  <= n2;
    end
    if (rst) begin
        first <= 1'b1;
        v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0;
    end
end

// per-packet result FIFO {mismatch, start, bytes}
wire logic        rq_v;
wire logic        rq_mm;
wire logic [63:0] rq_start;
wire logic [13:0] rq_bytes;
logic             pop;
rsys_fifo #(.WIDTH(1 + 64 + 14), .DEPTH(16), .RAM_STYLE("distributed")) u_rq (
    .clk(clk), .rst(rst),
    .din({pk_mm || m3, st3, pk_bytes + 14'(n3)}), .wr_en(v3 && l3), .full(),
    .dout({rq_mm, rq_start, rq_bytes}), .valid(rq_v), .rd_en(pop), .count()
);
always_ff @(posedge clk) begin
    if (v3) begin
        pk_mm    <= l3 ? 1'b0 : (pk_mm || m3);
        pk_bytes <= l3 ? '0 : pk_bytes + 14'(n3);
    end
    if (rst) begin
        pk_mm    <= 1'b0;
        pk_bytes <= '0;
    end
end

// verdict FIFO
wire logic vq_v, vq_ok;
rsys_fifo #(.WIDTH(1), .DEPTH(16), .RAM_STYLE("distributed")) u_vq (
    .clk(clk), .rst(rst), .din(s_end_ok), .wr_en(s_end_valid), .full(),
    .dout(vq_ok), .valid(vq_v), .rd_en(pop), .count()
);

assign pop = rq_v && vq_v;
logic have_exp = 1'b0;
always_ff @(posedge clk) begin
    ev_ok     <= 1'b0;
    ev_bad    <= 1'b0;
    ev_mism   <= 1'b0;
    ev_gap    <= 1'b0;
    bytes_add <= '0;
    if (pop) begin
        if (vq_ok) begin
            ev_ok     <= 1'b1;
            bytes_add <= 16'(rq_bytes);
            if (rq_mm) begin
                ev_mism  <= 1'b1;
                err_addr <= rq_start;
            end
            if (have_exp && rq_start != exp_addr && rq_start != base) ev_gap <= 1'b1;
            exp_addr <= rq_start + {50'd0, rq_bytes};
            have_exp <= 1'b1;
        end else begin
            ev_bad <= 1'b1;
        end
    end
    if (rst) begin
        have_exp <= 1'b0;
        exp_addr <= '0;
        err_addr <= '0;
    end
end

endmodule

`resetall
