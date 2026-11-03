// SPDX-License-Identifier: MIT
//
// rsys_skid - 512-bit AXI-Stream skid buffer (registered output, one skid
// register): s_axis_tready is a register, so the downstream tready (the CMAC's)
// does not reach the upstream logic combinationally. Full throughput; a
// contiguous input frame leaves contiguous (no tvalid gap inside a frame).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_skid (
    input  wire logic          clk,
    input  wire logic          rst,

    input  wire logic [511:0]  s_axis_tdata,
    input  wire logic [63:0]   s_axis_tkeep,
    input  wire logic          s_axis_tvalid,
    output logic               s_axis_tready,
    input  wire logic          s_axis_tlast,

    output logic      [511:0]  m_axis_tdata,
    output logic      [63:0]   m_axis_tkeep,
    output logic               m_axis_tvalid,
    input  wire logic          m_axis_tready,
    output logic               m_axis_tlast
);

logic [511:0] sk_d;
logic [63:0]  sk_k;
logic         sk_l, sk_v = 1'b0;
wire  logic   take = s_axis_tvalid && s_axis_tready;
wire  logic   slot = !m_axis_tvalid || m_axis_tready;

always_comb s_axis_tready = !sk_v;

always_ff @(posedge clk) begin
    if (slot) begin
        if (sk_v) begin
            m_axis_tdata  <= sk_d;
            m_axis_tkeep  <= sk_k;
            m_axis_tlast  <= sk_l;
            m_axis_tvalid <= 1'b1;
            sk_v          <= 1'b0;
        end else begin
            m_axis_tdata  <= s_axis_tdata;
            m_axis_tkeep  <= s_axis_tkeep;
            m_axis_tlast  <= s_axis_tlast;
            m_axis_tvalid <= take;
        end
    end else if (take) begin
        sk_d <= s_axis_tdata;
        sk_k <= s_axis_tkeep;
        sk_l <= s_axis_tlast;
        sk_v <= 1'b1;
    end
    if (rst) begin
        m_axis_tvalid <= 1'b0;
        sk_v          <= 1'b0;
    end
end

endmodule

`resetall
