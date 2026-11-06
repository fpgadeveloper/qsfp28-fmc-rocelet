// SPDX-License-Identifier: MIT
//
// rsys_odma - the "netdev" DMA channel of rocelet_sys (ODMA_EN builds): the engine's
// other-traffic frames (everything that is not RoCE and not answered by the built-in
// ARP/ICMP responder, see rocelet docs/interface.md "Other traffic") go to the PS through
// an AXI DMA, and frames from the PS are sent through the engine's other-traffic input.
//   RX: other-traffic beats (clk, no back-pressure) -> admission check at the first beat
//       (rx_en and room for a whole MAX_BEATS frame in the FIFO, else the frame is dropped
//       and counted) -> packet-mode asynchronous FIFO (FIFO_DEPTH 64-byte beats) ->
//       m_axis (dma_clk, 512 bits): one complete frame per packet, tlast on its last beat,
//       tkeep contiguous on the last beat, no FCS, starting with the destination MAC;
//       so the AXI DMA S2MM sees whole frames only and never stalls the engine.
//   TX: s_axis (dma_clk, 512 bits; one frame per packet, no FCS, the MAC pads and adds it)
//       -> packet-mode asynchronous FIFO -> m_tx (clk) whole frames, for the frame-atomic
//       arbiter in rocelet_sys (shared with the firmware's raw TX buffer).
// Both FIFOs are xpm_fifo_axis (PACKET_FIFO: a frame leaves only once its last beat is in).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_odma #(
    parameter int FIFO_DEPTH = 512,      // 64-byte beats per direction (32 KB)
    parameter int MAX_BEATS  = 160       // largest frame accepted (10240 bytes)
) (
    input  wire logic          clk,
    input  wire logic          rst,
    input  wire logic          rx_en,

    // other-traffic RX from the engine (clk)
    input  wire logic          s_valid,
    input  wire logic          s_first,
    input  wire logic [511:0]  s_data,
    input  wire logic [63:0]   s_keep,
    input  wire logic          s_last,

    // frames to the PS (dma_clk)
    input  wire logic          dma_clk,
    output wire logic [511:0]  m_axis_tdata,
    output wire logic [63:0]   m_axis_tkeep,
    output wire logic          m_axis_tvalid,
    input  wire logic          m_axis_tready,
    output wire logic          m_axis_tlast,

    // frames from the PS (dma_clk)
    input  wire logic [511:0]  s_axis_tdata,
    input  wire logic [63:0]   s_axis_tkeep,
    input  wire logic          s_axis_tvalid,
    output wire logic          s_axis_tready,
    input  wire logic          s_axis_tlast,

    // to the TX arbiter (clk)
    output wire logic [511:0]  m_tx_tdata,
    output wire logic [63:0]   m_tx_tkeep,
    output wire logic          m_tx_tvalid,
    input  wire logic          m_tx_tready,
    output wire logic          m_tx_tlast,

    output logic               ev_rx_frame,   // a frame entered the RX FIFO
    output logic               ev_rx_drop,    // a frame was dropped (disabled, FIFO full or too long)
    output logic               ev_tx_frame,   // a frame from the PS went to the engine
    output wire logic          rx_pending     // the RX FIFO holds data (clk)
);

localparam int CW = $clog2(FIFO_DEPTH) + 1;

// ---------------- RX admission ----------------
wire  logic [CW-1:0] rx_wcnt;
wire  logic          rx_rdy;
logic                keep_fr = 1'b0;          // the frame in progress is being written
logic [8:0]          fr_beats = '0;
wire  logic          room = (32'(rx_wcnt) + MAX_BEATS + 4 <= FIFO_DEPTH);
wire  logic          admit = s_valid && s_first && rx_en && room && rx_rdy;
wire  logic          wr_this = s_valid && (s_first ? admit : keep_fr);
// a frame longer than MAX_BEATS is cut: the beat that exceeds it ends the packet with tlast
wire  logic          too_long = !s_first && keep_fr && (fr_beats == 9'(MAX_BEATS - 1)) && !s_last;

always_ff @(posedge clk) begin
    ev_rx_frame <= 1'b0;
    ev_rx_drop  <= 1'b0;
    if (s_valid) begin
        if (s_first) begin
            keep_fr  <= admit && !s_last;
            fr_beats <= 9'd1;
            if (admit) ev_rx_frame <= 1'b1; else ev_rx_drop <= 1'b1;
        end else if (keep_fr) begin
            fr_beats <= fr_beats + 9'd1;
            if (s_last || too_long) keep_fr <= 1'b0;
        end
    end
    if (rst) keep_fr <= 1'b0;
end

xpm_fifo_axis #(
    .CLOCKING_MODE("independent_clock"), .FIFO_DEPTH(FIFO_DEPTH), .FIFO_MEMORY_TYPE("block"),
    .PACKET_FIFO("true"), .TDATA_WIDTH(512), .TDEST_WIDTH(1), .TID_WIDTH(1), .TUSER_WIDTH(1),
    .USE_ADV_FEATURES("0004"), .WR_DATA_COUNT_WIDTH(CW), .CDC_SYNC_STAGES(3), .ECC_MODE("no_ecc"),
    .RELATED_CLOCKS(0), .SIM_ASSERT_CHK(0)
) u_rxf (
    .s_aresetn(!rst), .s_aclk(clk), .m_aclk(dma_clk),
    .s_axis_tvalid(wr_this), .s_axis_tready(rx_rdy), .s_axis_tdata(s_data), .s_axis_tkeep(s_keep),
    .s_axis_tlast(s_last || too_long), .s_axis_tstrb(s_keep), .s_axis_tdest(1'b0), .s_axis_tid(1'b0),
    .s_axis_tuser(1'b0),
    .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready), .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep), .m_axis_tlast(m_axis_tlast), .m_axis_tstrb(), .m_axis_tdest(),
    .m_axis_tid(), .m_axis_tuser(),
    .prog_full_axis(), .wr_data_count_axis(rx_wcnt), .almost_full_axis(), .prog_empty_axis(),
    .rd_data_count_axis(), .almost_empty_axis(),
    .injectsbiterr_axis(1'b0), .injectdbiterr_axis(1'b0), .sbiterr_axis(), .dbiterr_axis()
);
assign rx_pending = (rx_wcnt != '0);

// ---------------- TX ----------------
// the TX FIFO's write side is in dma_clk: its reset is synchronised there
wire logic d_rst;
xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .RST_ACTIVE_HIGH(1)) u_drst (
    .src_arst(rst), .dest_clk(dma_clk), .dest_arst(d_rst)
);
xpm_fifo_axis #(
    .CLOCKING_MODE("independent_clock"), .FIFO_DEPTH(FIFO_DEPTH), .FIFO_MEMORY_TYPE("block"),
    .PACKET_FIFO("true"), .TDATA_WIDTH(512), .TDEST_WIDTH(1), .TID_WIDTH(1), .TUSER_WIDTH(1),
    .USE_ADV_FEATURES("0000"), .CDC_SYNC_STAGES(3), .ECC_MODE("no_ecc"), .RELATED_CLOCKS(0),
    .SIM_ASSERT_CHK(0)
) u_txf (
    .s_aresetn(!d_rst), .s_aclk(dma_clk), .m_aclk(clk),
    .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready), .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep), .s_axis_tlast(s_axis_tlast), .s_axis_tstrb(s_axis_tkeep),
    .s_axis_tdest(1'b0), .s_axis_tid(1'b0), .s_axis_tuser(1'b0),
    .m_axis_tvalid(m_tx_tvalid), .m_axis_tready(m_tx_tready), .m_axis_tdata(m_tx_tdata),
    .m_axis_tkeep(m_tx_tkeep), .m_axis_tlast(m_tx_tlast), .m_axis_tstrb(), .m_axis_tdest(),
    .m_axis_tid(), .m_axis_tuser(),
    .prog_full_axis(), .wr_data_count_axis(), .almost_full_axis(), .prog_empty_axis(),
    .rd_data_count_axis(), .almost_empty_axis(),
    .injectsbiterr_axis(1'b0), .injectdbiterr_axis(1'b0), .sbiterr_axis(), .dbiterr_axis()
);
always_ff @(posedge clk) ev_tx_frame <= m_tx_tvalid && m_tx_tready && m_tx_tlast;

endmodule

`resetall
