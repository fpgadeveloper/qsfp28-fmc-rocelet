// SPDX-License-Identifier: MIT
//
// mac_omac10g - the swappable MAC block of the ZCU106 target at 10G: omac_10g (10GBASE-R
// MAC + PCS, opsero-ethernet-mac) on one UltraScale+ GTH channel (omac_gt_usp_gth, the free
// gtwizard_ultrascale IP made by gen_gt.tcl), behind rocelet_sys's generic MAC boundary:
//   clk_out                 the MAC user clock (GT TXUSRCLK2, 156.25 MHz): the rocelet_sys clock
//   s_axis_tx / m_axis_rx   64-bit AXI-Streams in clk_out (RX without tready)
//   mac_ctl / mac_pz / mac_addr in, mac_stat / mac_ev / mac_pause out (rocelet_sys.sv header)
//   gt_reset / mac_reset    from the always-on block (any clock): gt_reset = gtwizard
//                           reset_all (hold it until the Si5328 runs at 156.25 MHz),
//                           mac_reset = the omac reset (also held while the GT TX is not ready)
//   gt_powergood / gt_tx_ready / gt_rx_ready  status for the always-on block
// The 40G step (omac_40g, four lanes, 256 bits) replaces this module with one of the same
// boundary (MAC_WIDTH 256 in rocelet_sys); see docs/source/zynqmp_hw.md.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps

module mac_omac10g #(
    parameter BIT_REVERSE = 1,           // omac_gt_usp_gth bit order (1 = AMD gearbox MSB first)
    parameter TX_DIFFCTRL = 5'b11000,
    parameter RX_LPMEN    = 0            // 0 DFE (passive copper), 1 LPM
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 freerun_clk CLK" *)
    input  wire         freerun_clk,     // 100 MHz, runs before the GT (pl_clk0)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 gt_reset RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    input  wire         gt_reset,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 mac_reset RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    input  wire         mac_reset,

    input  wire         gt_refclk_p,     // 156.25 MHz from the FMC Si5328 (GBTCLK0)
    input  wire         gt_refclk_n,
    input  wire         gt_rxp,
    input  wire         gt_rxn,
    output wire         gt_txp,
    output wire         gt_txn,

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_out CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIS_TX:M_AXIS_RX, FREQ_HZ 156250000" *)
    output wire         clk_out,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TX TDATA" *)  input  wire [63:0] tx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TX TKEEP" *)  input  wire [7:0]  tx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TX TVALID" *) input  wire        tx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TX TREADY" *) output wire        tx_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TX TLAST" *)  input  wire        tx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TX TUSER" *)  input  wire        tx_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RX TDATA" *)  output wire [63:0] rx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RX TKEEP" *)  output wire [7:0]  rx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RX TVALID" *) output wire        rx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RX TLAST" *)  output wire        rx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RX TUSER" *)  output wire        rx_tuser,

    input  wire [31:0]  mac_ctl,
    input  wire [31:0]  mac_pz,
    input  wire [47:0]  mac_addr,
    output wire [15:0]  mac_stat,
    output wire [15:0]  mac_ev,
    output wire [17:0]  mac_pause,

    output wire         gt_powergood,
    output wire         gt_tx_ready,
    output wire         gt_rx_ready
);

wire        clk;
wire        rx_clk;
wire [1:0]  tx_hdr, rx_hdr;
wire [63:0] tx_data, rx_data;
wire        rx_valid, rx_slip, rx_reset_req;
wire [2:0]  loopback;

omac_gt_usp_gth #(.BIT_REVERSE(BIT_REVERSE)) u_gt (
    .refclk_p(gt_refclk_p), .refclk_n(gt_refclk_n), .freerun_clk(freerun_clk), .reset_all(gt_reset),
    .gth_rxp(gt_rxp), .gth_rxn(gt_rxn), .gth_txp(gt_txp), .gth_txn(gt_txn),
    .tx_usrclk2(clk), .gt_tx_ready(gt_tx_ready), .gt_tx_hdr(tx_hdr), .gt_tx_data(tx_data),
    .rx_usrclk2(rx_clk), .gt_rx_ready(gt_rx_ready), .gt_rx_valid(rx_valid), .gt_rx_hdr(rx_hdr),
    .gt_rx_data(rx_data), .gt_rx_slip(rx_slip), .gt_rx_reset_req(rx_reset_req), .gt_loopback(loopback),
    .tx_polarity(1'b0), .rx_polarity(1'b0), .tx_diffctrl(TX_DIFFCTRL), .tx_postcursor(5'b00000),
    .tx_precursor(5'b00000), .rx_lpmen(RX_LPMEN[0]),
    .gt_powergood(gt_powergood)
);
assign clk_out = clk;

// omac reset: the always-on block's mac_reset or the GT TX not ready, synchronised to clk
wire rst;
xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .RST_ACTIVE_HIGH(1)) u_rst (
    .src_arst(mac_reset | ~gt_tx_ready), .dest_clk(clk), .dest_arst(rst)
);

wire stat_link_up, stat_block_lock, stat_hi_ber, stat_local_fault, stat_remote_fault;
wire stat_rx_pause_req, stat_tx_pause_active;
wire [15:0] stat_rx_pause_quanta;
wire ev_tx_frame, ev_tx_pause, ev_tx_underflow, ev_tx_abort, ev_rx_frame_good, ev_rx_frame_bad;
wire ev_rx_fcs_error, ev_rx_runt, ev_rx_oversize, ev_rx_pause, ev_rx_bad_block, ev_rx_sequence_error;

omac_10g #(.DATA_WIDTH(64), .SPEED(10), .PAUSE_EN(1'b1)) u_mac (
    .clk(clk), .rst(rst),
    .s_axis_tx_tdata(tx_tdata), .s_axis_tx_tkeep(tx_tkeep), .s_axis_tx_tvalid(tx_tvalid),
    .s_axis_tx_tready(tx_tready), .s_axis_tx_tlast(tx_tlast), .s_axis_tx_tuser(tx_tuser),
    .m_axis_rx_tdata(rx_tdata), .m_axis_rx_tkeep(rx_tkeep), .m_axis_rx_tvalid(rx_tvalid),
    .m_axis_rx_tlast(rx_tlast), .m_axis_rx_tuser(rx_tuser),
    .ctl_tx_enable(mac_ctl[1]), .ctl_rx_enable(mac_ctl[0]), .ctl_loopback(mac_ctl[10:8] != 3'd0),
    .ctl_tx_fault(mac_ctl[3]), .ctl_pause_tx_honour(1'b0), .ctl_tx_pause_send(mac_ctl[16] & mac_ctl[7]),
    .ctl_tx_pause_quanta(mac_pz[15:0]), .ctl_tx_pause_refresh(mac_pz[31:16]), .ctl_mac_addr(mac_addr),
    .stat_link_up(stat_link_up), .stat_block_lock(stat_block_lock), .stat_hi_ber(stat_hi_ber),
    .stat_local_fault(stat_local_fault), .stat_remote_fault(stat_remote_fault),
    .stat_rx_pause_req(stat_rx_pause_req), .stat_rx_pause_quanta(stat_rx_pause_quanta),
    .stat_tx_pause_active(stat_tx_pause_active),
    .ev_tx_frame(ev_tx_frame), .ev_tx_pause(ev_tx_pause), .ev_tx_underflow(ev_tx_underflow),
    .ev_tx_abort(ev_tx_abort), .ev_rx_frame_good(ev_rx_frame_good), .ev_rx_frame_bad(ev_rx_frame_bad),
    .ev_rx_fcs_error(ev_rx_fcs_error), .ev_rx_runt(ev_rx_runt), .ev_rx_oversize(ev_rx_oversize),
    .ev_rx_pause(ev_rx_pause), .ev_rx_bad_block(ev_rx_bad_block), .ev_rx_sequence_error(ev_rx_sequence_error),
    .gt_tx_ready(gt_tx_ready), .gt_tx_hdr(tx_hdr), .gt_tx_data(tx_data), .gt_loopback(loopback),
    .gt_rx_clk(rx_clk), .gt_rx_ready(gt_rx_ready), .gt_rx_valid(rx_valid), .gt_rx_hdr(rx_hdr),
    .gt_rx_data(rx_data), .gt_rx_slip(rx_slip), .gt_rx_reset_req(rx_reset_req)
);

// generic status: [0] block lock [1] link up (as "RX status") [2] local fault [3] remote fault
// [6] hi BER [10]/[11] 0 (omac's reset covers both directions, rocelet needs no reset input)
// [12] link up [13] TX PAUSE active
assign mac_stat = {2'b00, stat_tx_pause_active, stat_link_up, 2'b00, 3'b000, stat_hi_ber, 2'b00,
                   stat_remote_fault, stat_local_fault, stat_link_up, stat_block_lock};
// frames: good + bad; bad code = PCS error blocks; TX "bad FCS" = frames aborted by tuser
assign mac_ev = {ev_tx_pause, ev_rx_pause, 2'b00, ev_tx_underflow, ev_tx_abort, ev_tx_frame,
                 {2'b00, ev_rx_bad_block}, {2'b00, ev_rx_fcs_error},
                 {1'b0, ev_rx_frame_good & ev_rx_frame_bad, ev_rx_frame_good ^ ev_rx_frame_bad}};
// received PAUSE as a level (omac times the quanta); no pulse/quanta interface
assign mac_pause = {stat_rx_pause_req, 1'b0, stat_rx_pause_quanta};

endmodule
