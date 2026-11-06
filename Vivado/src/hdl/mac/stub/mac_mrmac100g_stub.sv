// SPDX-License-Identifier: MIT
//
// mac_mrmac100g (STUB) - stand-in for the Versal MRMAC adapter of the vck190_fmcp1 target, used
// by scripts/build.tcl ONLY while src/hdl/mac/mac_mrmac100g.* does not exist (it then prints a
// CRITICAL WARNING). It is NOT a working MAC adapter: no 48 -> 64 byte RX packing, no frame-
// complete TX FIFO, no 64 -> 48 byte TX downsizing, statistics mostly zero. It exists so that
// the block design (bd_versal.tcl) validates and the rest of the system can be implemented and
// timed with a live datapath (nothing optimised away) before the real adapter lands.
//
// Port contract (what bd_versal.tcl connects; the same names as the real adapter):
//   clk, axis_clk, ctl_clk      engine clock (rocelet_sys clk) / MRMAC AXIS client clock / 100 MHz
//   gt_reset, mac_reset         from the always-on block (active high, any clock); the adapter
//                               drives the MRMAC's gt_reset_all_in and core / serdes resets
//   gt_powergood, gt_tx_ready, gt_rx_ready   GT status for the always-on block
//   S_AXIS_TX / M_AXIS_RX       512-bit engine-side streams (tx_* / rx_*), clk, RX without tready
//   mac_ctl / mac_pz / mac_addr in, mac_stat / mac_ev / mac_pause out, mac_lane / mac_lev out
//                               (rocelet_sys.sv header), clk
//   every other port carries the NAME OF THE MRMAC PORT it connects to (exact name, with the
//   "_0" port suffix where the MRMAC has one); bd_versal.tcl connects those by name
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps

module mac_mrmac100g (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIS_TX:M_AXIS_RX" *)
    input  wire         clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axis_clk CLK" *)
    input  wire         axis_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ctl_clk CLK" *)
    input  wire         ctl_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 gt_reset RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    input  wire         gt_reset,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 mac_reset RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    input  wire         mac_reset,
    output wire         gt_powergood,
    output wire         gt_tx_ready,
    output wire         gt_rx_ready,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        gtpowergood_in,
    (* X_INTERFACE_IGNORE = "true" *) output wire [3:0]  gt_reset_all_in,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [3:0]  gt_tx_reset_done_out,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [3:0]  gt_rx_reset_done_out,
    (* X_INTERFACE_IGNORE = "true" *) output wire [3:0]  tx_core_reset,
    (* X_INTERFACE_IGNORE = "true" *) output wire [3:0]  rx_core_reset,
    (* X_INTERFACE_IGNORE = "true" *) output wire [3:0]  tx_serdes_reset,
    (* X_INTERFACE_IGNORE = "true" *) output wire [3:0]  rx_serdes_reset,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TX TDATA" *)  input  wire [511:0] tx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TX TKEEP" *)  input  wire [63:0]  tx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TX TVALID" *) input  wire         tx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TX TREADY" *) output wire         tx_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TX TLAST" *)  input  wire         tx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TX TUSER" *)  input  wire         tx_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RX TDATA" *)  output wire [511:0] rx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RX TKEEP" *)  output wire [63:0]  rx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RX TVALID" *) output wire         rx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RX TLAST" *)  output wire         rx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RX TUSER" *)  output wire         rx_tuser,

    input  wire [31:0]  mac_ctl,
    input  wire [31:0]  mac_pz,
    input  wire [47:0]  mac_addr,
    output wire [15:0]  mac_stat,
    output wire [15:0]  mac_ev,
    output wire [17:0]  mac_pause,
    output wire [31:0]  mac_lane,
    output wire [5:0]   mac_lev,

    // MRMAC AXIS client, port 0 (axis_clk): six 64-bit lanes, shared valid / last
    input  wire [63:0]  rx_axis_tdata0, rx_axis_tdata1, rx_axis_tdata2,
    input  wire [63:0]  rx_axis_tdata3, rx_axis_tdata4, rx_axis_tdata5,
    input  wire [10:0]  rx_axis_tkeep_user0, rx_axis_tkeep_user1, rx_axis_tkeep_user2,
    input  wire [10:0]  rx_axis_tkeep_user3, rx_axis_tkeep_user4, rx_axis_tkeep_user5,
    input  wire         rx_axis_tvalid_0,
    input  wire         rx_axis_tlast_0,
    output wire [63:0]  tx_axis_tdata0, tx_axis_tdata1, tx_axis_tdata2,
    output wire [63:0]  tx_axis_tdata3, tx_axis_tdata4, tx_axis_tdata5,
    output wire [10:0]  tx_axis_tkeep_user0, tx_axis_tkeep_user1, tx_axis_tkeep_user2,
    output wire [10:0]  tx_axis_tkeep_user3, tx_axis_tkeep_user4, tx_axis_tkeep_user5,
    output wire         tx_axis_tvalid_0,
    output wire         tx_axis_tlast_0,
    input  wire         tx_axis_tready_0,

    // MRMAC control and status, port 0
    output wire         ctl_tx_send_rfi_in_0,
    output wire         ctl_tx_send_lfi_in_0,
    output wire         ctl_tx_send_idle_in_0,
    output wire [8:0]   ctl_tx_pause_req_0,
    output wire [8:0]   ctl_tx_pause_enable_0,
    output wire [8:0]   ctl_rx_pause_enable_0,
    output wire [8:0]   ctl_rx_pause_ack_0,
    input  wire         stat_rx_status_0,
    input  wire         stat_rx_aligned_0,
    input  wire         stat_rx_local_fault_0,
    input  wire         stat_rx_remote_fault_0,
    input  wire         stat_rx_hi_ber_0,
    input  wire         stat_rx_fec_aligned_0,
    input  wire [8:0]   stat_rx_pause_req_0,
    input  wire [8:0]   stat_rx_pause_valid_0,
    input  wire [15:0]  stat_rx_pause_quanta8_0
);

// ---------------- RX: 6 x 64 bit (axis_clk) -> async FIFO -> 512 bit (clk) ----------------
localparam integer FW = 512 + 64 + 2;
wire [383:0] rx_lanes = {rx_axis_tdata5, rx_axis_tdata4, rx_axis_tdata3, rx_axis_tdata2, rx_axis_tdata1, rx_axis_tdata0};
wire [47:0]  rx_keep  = {rx_axis_tkeep_user5[7:0], rx_axis_tkeep_user4[7:0], rx_axis_tkeep_user3[7:0],
                         rx_axis_tkeep_user2[7:0], rx_axis_tkeep_user1[7:0], rx_axis_tkeep_user0[7:0]};
wire         rx_err   = rx_axis_tkeep_user0[8] | rx_axis_tkeep_user5[8];
wire         rst_axis, rst_eng;
assign gt_powergood    = gtpowergood_in;
assign gt_tx_ready     = &gt_tx_reset_done_out;
assign gt_rx_ready     = &gt_rx_reset_done_out;
assign gt_reset_all_in = {4{gt_reset}};
assign tx_core_reset   = ~gt_tx_reset_done_out;
assign tx_serdes_reset = ~gt_tx_reset_done_out;
assign rx_core_reset   = ~gt_rx_reset_done_out;
assign rx_serdes_reset = ~gt_rx_reset_done_out;
xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .RST_ACTIVE_HIGH(1)) u_rst_axis (
    .src_arst(mac_reset | ~gt_rx_ready | ~gt_tx_ready), .dest_clk(axis_clk), .dest_arst(rst_axis));
xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .RST_ACTIVE_HIGH(1)) u_rst_eng (
    .src_arst(mac_reset), .dest_clk(clk), .dest_arst(rst_eng));

wire [FW-1:0] rxf_dout;
wire          rxf_empty;
xpm_fifo_async #(
    .FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(64), .WRITE_DATA_WIDTH(FW), .READ_DATA_WIDTH(FW),
    .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .CDC_SYNC_STAGES(3), .USE_ADV_FEATURES("0000")
) u_rxf (
    .rst(rst_axis), .wr_clk(axis_clk), .wr_en(rx_axis_tvalid_0 & ~rst_axis),
    .din({rx_err, rx_axis_tlast_0, 16'd0, rx_keep, 128'd0, rx_lanes}),
    .rd_clk(clk), .rd_en(~rxf_empty), .dout(rxf_dout), .empty(rxf_empty),
    .full(), .overflow(), .wr_rst_busy(), .almost_full(), .wr_ack(), .prog_full(), .wr_data_count(),
    .underflow(), .rd_rst_busy(), .almost_empty(), .data_valid(), .prog_empty(), .rd_data_count(),
    .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr()
);
assign rx_tdata  = rxf_dout[511:0];
assign rx_tkeep  = rxf_dout[575:512];
assign rx_tlast  = rxf_dout[576];
assign rx_tuser  = rxf_dout[577];
assign rx_tvalid = ~rxf_empty;

// ---------------- TX: 512 bit (clk) -> async FIFO -> 6 x 64 bit (axis_clk) ----------------
wire [FW-1:0] txf_dout;
wire          txf_empty, txf_full;
xpm_fifo_async #(
    .FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(64), .WRITE_DATA_WIDTH(FW), .READ_DATA_WIDTH(FW),
    .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .CDC_SYNC_STAGES(3), .USE_ADV_FEATURES("0000")
) u_txf (
    .rst(rst_eng), .wr_clk(clk), .wr_en(tx_tvalid & ~txf_full),
    .din({tx_tuser, tx_tlast, tx_tkeep, tx_tdata}),
    .rd_clk(axis_clk), .rd_en(~txf_empty & tx_axis_tready_0), .dout(txf_dout), .empty(txf_empty),
    .full(txf_full), .overflow(), .wr_rst_busy(), .almost_full(), .wr_ack(), .prog_full(), .wr_data_count(),
    .underflow(), .rd_rst_busy(), .almost_empty(), .data_valid(), .prog_empty(), .rd_data_count(),
    .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr()
);
assign tx_tready = ~txf_full;
assign {tx_axis_tdata5, tx_axis_tdata4, tx_axis_tdata3, tx_axis_tdata2, tx_axis_tdata1, tx_axis_tdata0} = txf_dout[383:0];
assign tx_axis_tkeep_user0 = {3'd0, txf_dout[519:512]};
assign tx_axis_tkeep_user1 = {3'd0, txf_dout[527:520]};
assign tx_axis_tkeep_user2 = {3'd0, txf_dout[535:528]};
assign tx_axis_tkeep_user3 = {3'd0, txf_dout[543:536]};
assign tx_axis_tkeep_user4 = {3'd0, txf_dout[551:544]};
assign tx_axis_tkeep_user5 = {3'd0, txf_dout[559:552]};
assign tx_axis_tvalid_0    = ~txf_empty;
assign tx_axis_tlast_0     = txf_dout[576];

// ---------------- control (clk -> axis_clk) and status (-> clk) ----------------
wire [7:0] ctl_a;
xpm_cdc_array_single #(.DEST_SYNC_FF(3), .WIDTH(8), .SRC_INPUT_REG(1)) u_ctl (
    .src_clk(clk), .src_in({mac_ctl[16], mac_ctl[7:2]}), .dest_clk(axis_clk), .dest_out(ctl_a[6:0]));
assign ctl_a[7] = 1'b0;
assign ctl_tx_send_rfi_in_0  = ctl_a[0];
assign ctl_tx_send_lfi_in_0  = ctl_a[1];
assign ctl_tx_send_idle_in_0 = ctl_a[2];
assign ctl_rx_pause_enable_0 = {ctl_a[4], 8'd0};
assign ctl_rx_pause_ack_0    = {ctl_a[4], 8'd0};
assign ctl_tx_pause_enable_0 = {ctl_a[5], 8'd0};
assign ctl_tx_pause_req_0    = {ctl_a[6], 8'd0};

wire [7:0]  st;
xpm_cdc_array_single #(.DEST_SYNC_FF(3), .WIDTH(8), .SRC_INPUT_REG(0)) u_st (
    .src_clk(axis_clk), .src_in({stat_rx_pause_req_0[8], stat_rx_fec_aligned_0, stat_rx_hi_ber_0, stat_rx_remote_fault_0,
                                 stat_rx_local_fault_0, stat_rx_status_0, stat_rx_aligned_0, 1'b0}),
    .dest_clk(clk), .dest_out(st));
reg [15:0] qsp_quanta = 16'd0;     // quasi-static (stub only)
always @(posedge clk) qsp_quanta <= stat_rx_pause_quanta8_0;
assign mac_stat  = {3'b000, st[2] & ~st[3] & ~st[4], 2'b00, st[6], 2'b00, st[5], 2'b00, st[4], st[3], st[2], st[1]};
assign mac_ev    = 16'd0;
assign mac_pause = {st[7], 1'b0, qsp_quanta};
assign mac_lane  = 32'd0;
assign mac_lev   = 6'd0;

endmodule
