// SPDX-License-Identifier: MIT
//
// rsys_ptime - free-running time of the Holoscan Sensor Bridge producer (the "PTP stub"):
// seconds and nanoseconds since the system reset, in the CMAC user clock (322.265625 MHz,
// exactly 322,265,625 clocks per second). A clock counter wraps once per second (an
// equality compare, no wide comparator) and the nanoseconds are cyc x 1e9 / F, computed
// in a pipelined multiply (cyc x round(2^24 x 1e9 / F) >> 24, error < 1 ns), so the outputs
// lag the counter by 3 clocks (irrelevant for frame timestamps). Not synchronised to any
// grandmaster: the metadata timestamps of the producer are only consistent with each other.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_ptime #(
    parameter longint CLK_HZ = 322265625   // clk frequency (the MAC user clock)
) (
    input  wire logic         clk,
    input  wire logic         rst,
    output logic [47:0]       t_s,
    output logic [29:0]       t_ns
);

localparam logic [28:0] CYC_MAX = 29'(CLK_HZ - 1);      // clocks per second - 1
// round(2^24 x 1e9 / CLK_HZ): 52060210 at 322265625 Hz, 107374182 at 156250000 Hz
localparam longint      K24_L   = ((64'd1 << 24) * 64'd1000000000 + CLK_HZ / 2) / CLK_HZ;
localparam logic [27:0] K24     = 28'(K24_L);

logic [28:0] cyc = '0;
logic [47:0] sec = '0;
logic [28:0] c1 = '0;
logic [47:0] s1 = '0, s2 = '0, s3 = '0;
(* use_dsp = "yes" *) logic [56:0] m2 = '0;
logic [56:0] m3 = '0;

always_ff @(posedge clk) begin
    if (cyc == CYC_MAX) begin
        cyc <= '0;
        sec <= sec + 48'd1;
    end else begin
        cyc <= cyc + 29'd1;
    end
    c1 <= cyc;   s1 <= sec;
    m2 <= c1 * K24; s2 <= s1;
    m3 <= m2;    s3 <= s2;
    t_ns <= m3[53:24];
    t_s  <= s3;
    if (rst) begin
        cyc <= '0;
        sec <= '0;
    end
end

endmodule

`resetall
