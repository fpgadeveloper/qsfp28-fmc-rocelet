// SPDX-License-Identifier: MIT
//
// rsys_lat - latency instrumentation of the rocelet self-test logic.
// 1. First-event probe (armed by the firmware): time of the first WR accepted,
//    the first requester completion, and the first four frames at the CMAC TX
//    and RX interfaces (start-of-frame times with opcode and PSN). With a single
//    WR this splits the self-ACK round trip through the loopback plug into
//    TX pipeline, wire/CMAC/FEC, responder turnaround and ACK return.
// 2. Completion latency under load: the time from a WR being accepted to its
//    requester completion (ACK), for every WR: min / max / sum / count. Works
//    because completions retire in issue order (rl_retx_desc ring).
// Times are in CMAC user clocks (322.265625 MHz, 3.103 ns).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_lat #(
    parameter int TRK_DEPTH = 1024
) (
    input  wire logic          clk,
    input  wire logic          rst,
    input  wire logic          clr,
    input  wire logic [31:0]   now,

    input  wire logic          arm,
    input  wire logic          wr_fire,
    input  wire logic          cpl_fire,
    input  wire logic          cpl_lost,
    input  wire logic          tx_sof,
    input  wire logic [31:0]   tx_info,     // [7:0] opcode [31:8] PSN
    input  wire logic          rx_sof,
    input  wire logic [31:0]   rx_info,

    output logic [31:0]        t_wr,
    output logic [31:0]        t_cpl,
    output logic [31:0]        tx_t [4],
    output logic [31:0]        tx_i [4],
    output logic [31:0]        rx_t [4],
    output logic [31:0]        rx_i [4],
    output logic [9:0]         flags,       // [3:0] tx [7:4] rx [8] wr [9] cpl

    output logic [31:0]        lat_min,
    output logic [31:0]        lat_max,
    output logic [31:0]        lat_cnt,
    output logic [15:0]        lat_add,     // to the 64-bit sum accumulator
    output logic               ev_ovf,
    output logic               ovf
);

// ---------------- first-event probe ----------------
logic [2:0] ntx, nrx;
always_ff @(posedge clk) begin
    if (arm) begin
        flags <= '0;
        ntx   <= '0;
        nrx   <= '0;
    end else begin
        if (wr_fire && !flags[8]) begin flags[8] <= 1'b1; t_wr <= now; end
        if (cpl_fire && !flags[9]) begin flags[9] <= 1'b1; t_cpl <= now; end
        if (tx_sof && ntx < 3'd4) begin
            tx_t[ntx[1:0]] <= now; tx_i[ntx[1:0]] <= tx_info; flags[ntx[1:0]] <= 1'b1; ntx <= ntx + 3'd1;
        end
        if (rx_sof && nrx < 3'd4) begin
            rx_t[nrx[1:0]] <= now; rx_i[nrx[1:0]] <= rx_info; flags[4 + nrx[1:0]] <= 1'b1; nrx <= nrx + 3'd1;
        end
    end
    if (rst) begin
        flags <= '0;
        ntx   <= 3'd4;     // disarmed until the first arm
        nrx   <= 3'd4;
    end
end

// ---------------- completion latency tracker ----------------
wire logic        full, v;
wire logic [31:0] ts;
wire logic        flush = rst || clr;
rsys_fifo #(.WIDTH(32), .DEPTH(TRK_DEPTH), .RAM_STYLE("block")) u_ts (
    .clk(clk), .rst(flush), .din(now), .wr_en(wr_fire && !ovf), .full(full),
    .dout(ts), .valid(v), .rd_en(cpl_fire && !ovf), .count()
);
logic        c_v = 1'b0;
logic [31:0] c_lat;
always_ff @(posedge clk) begin
    ev_ovf  <= 1'b0;
    lat_add <= '0;
    c_v     <= 1'b0;
    if (wr_fire && full && !ovf) begin
        ovf    <= 1'b1;
        ev_ovf <= 1'b1;
    end
    if (cpl_fire && v && !ovf && !cpl_lost) begin
        c_v   <= 1'b1;
        c_lat <= now - ts;
    end
    if (c_v) begin
        lat_cnt <= lat_cnt + 32'd1;
        lat_add <= (c_lat > 32'hFFFF) ? 16'hFFFF : c_lat[15:0];
        if (c_lat < lat_min) lat_min <= c_lat;
        if (c_lat > lat_max) lat_max <= c_lat;
    end
    if (flush) begin
        ovf     <= 1'b0;
        c_v     <= 1'b0;
        lat_cnt <= '0;
        lat_min <= 32'hFFFF_FFFF;
        lat_max <= '0;
    end
end

endmodule

`resetall
