// SPDX-License-Identifier: MIT
//
// rsys_src_mux - the sample-source boundary of the HSB producer: one show-ahead AXI-Stream
// (s_axis_src: 64-byte beats, tready = consume, tuser = 64-bit side-band of the beat) out of
// N sources, selected by the producer's latched src_sel:
//   0 = IQ16 test-signal generator (rsys_iq_src), 1 = counter pattern (inside the producer,
//   no source here), 2 = beam array generator (rsys_beam_src, side-band {scene_id,
//   scene_frame}), 3 = reserved for a design-specific source (an RFSoC rfdc stream: see
//   docs/source/zynqmp_hw.md "Streaming source boundary"; the producer maps 3 to 0 today).
// The enables and start pulses keep the per-source behaviour of 0.4.0: the IQ16 generator
// runs during any run, the beam generator only during a beam run.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_src_mux (
    input  wire logic [1:0]    src_sel,
    input  wire logic          src_enable,
    input  wire logic          src_start,
    output wire logic          m_axis_src_tvalid,
    output wire logic [511:0]  m_axis_src_tdata,
    output wire logic [63:0]   m_axis_src_tuser,
    input  wire logic          m_axis_src_tready,

    // source 0: IQ16
    input  wire logic          iq_valid,
    input  wire logic [511:0]  iq_data,
    output wire logic          iq_pop,
    output wire logic          iq_enable,
    output wire logic          iq_start,
    // source 2: beam array
    input  wire logic          bm_valid,
    input  wire logic [511:0]  bm_data,
    input  wire logic [31:0]   bm_sid,
    input  wire logic [31:0]   bm_sframe,
    output wire logic          bm_pop,
    output wire logic          bm_enable,
    output wire logic          bm_start
);

wire logic is_bm = (src_sel == 2'd2);
wire logic is_iq = (src_sel == 2'd0);
assign m_axis_src_tvalid = is_bm ? bm_valid : iq_valid;
assign m_axis_src_tdata  = is_bm ? bm_data  : iq_data;
assign m_axis_src_tuser  = is_bm ? {bm_sid, bm_sframe} : 64'd0;
assign iq_pop    = m_axis_src_tready && is_iq;
assign bm_pop    = m_axis_src_tready && is_bm;
assign iq_enable = src_enable;
assign bm_enable = src_enable && is_bm;
assign iq_start  = src_start && is_iq;
assign bm_start  = src_start && is_bm;

endmodule

`resetall
