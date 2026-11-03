// SPDX-License-Identifier: MIT
//
// rocelet_sys_bd - block-design module reference for rocelet_sys (the rocelet
// engine, its MAC glue, the memory window and the optional self-test logic).
// Vivado needs a Verilog top for a module reference; the implementation is the
// SystemVerilog rocelet_sys. The engine configuration and the self-test option
// are the parameters (set per target by the block design from config/data.json).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps

module rocelet_sys_bd #(
    parameter integer NUM_QP     = 16,
    parameter integer NUM_MR     = 16,
    parameter integer READ_DEPTH = 16,
    parameter integer RTX_MODE   = 0,       // 0 RING, 1 REREAD, 2 LOSSY
    parameter integer RING_BYTES = 262144,
    parameter integer MAX_WR     = 128,
    parameter integer RX_ICRC_EN = 1,
    parameter integer ICRC_SHARE = 1,
    parameter integer HSB_EN     = 1,
    parameter integer SELFTEST   = 1,
    parameter integer RSFEC      = 1,
    parameter integer MEM_BYTES  = 262144
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIL:S_AXIS_RX:M_AXIS_TX" *)
    input  wire         clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 gen_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 200000000" *)
    input  wire         gen_clk,        // 200 MHz: IQ16 generator, device DNA
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 sys_rst RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    input  wire         sys_rst,
    input  wire         mac_tx_rst,
    input  wire         mac_rx_rst,
    (* X_INTERFACE_IGNORE = "true" *)
    output wire         irq,            // engine: a QP error is latched (polled through the QSFP0 GPIO)

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL AWADDR" *)
    (* X_INTERFACE_PARAMETER = "PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 19" *)
    input  wire [18:0]  s_axil_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL AWVALID" *) input  wire         s_axil_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL AWREADY" *) output wire         s_axil_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WDATA" *)   input  wire [31:0]  s_axil_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WSTRB" *)   input  wire [3:0]   s_axil_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WVALID" *)  input  wire         s_axil_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WREADY" *)  output wire         s_axil_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL BRESP" *)   output wire [1:0]   s_axil_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL BVALID" *)  output wire         s_axil_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL BREADY" *)  input  wire         s_axil_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL ARADDR" *)  input  wire [18:0]  s_axil_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL ARVALID" *) input  wire         s_axil_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL ARREADY" *) output wire         s_axil_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RDATA" *)   output wire [31:0]  s_axil_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RRESP" *)   output wire [1:0]   s_axil_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RVALID" *)  output wire         s_axil_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RREADY" *)  input  wire         s_axil_rready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_RX TDATA" *) input  wire [511:0] rx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_RX TKEEP" *) input  wire [63:0]  rx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_RX TVALID" *) input wire         rx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_RX TLAST" *) input  wire         rx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_RX TUSER" *) input  wire         rx_tuser,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_TX TDATA" *) output wire [511:0] tx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_TX TKEEP" *) output wire [63:0]  tx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_TX TVALID" *) output wire        tx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_TX TREADY" *) input  wire        tx_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_TX TLAST" *) output wire         tx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_TX TUSER" *) output wire         tx_tuser,

    // CMAC 802.3x flow control (stat_rx_pause_req / _valid / _quanta8, stat_rx_pause,
    // stat_tx_pause, ctl_tx_pause_req)
    input  wire [8:0]   pause_rx_req,
    input  wire [8:0]   pause_rx_valid,
    input  wire [15:0]  pause_rx_quanta8,
    input  wire         pause_rx_frame,
    input  wire         pause_tx_frame,
    output wire [8:0]   pause_tx_req,

    // CMAC static control (CMAC user clock)
    output wire         ctl_rx_enable,
    output wire         ctl_tx_enable,
    output wire         ctl_tx_send_rfi,
    output wire         ctl_tx_send_lfi,
    output wire         ctl_tx_send_idle,
    output wire         ctl_rsfec,
    output wire         ctl_rx_pause,
    output wire [8:0]   ctl_rx_pause_vec,
    output wire [8:0]   ctl_tx_pause_vec,
    output wire [15:0]  ctl_tx_pause_quanta,
    output wire [15:0]  ctl_tx_pause_refresh,
    output wire [11:0]  ctl_gt_loopback,

    // CMAC status and statistics (CMAC user clock)
    input  wire         stat_rx_aligned,
    input  wire         stat_rx_status,
    input  wire         stat_rx_local_fault,
    input  wire         stat_rx_remote_fault,
    input  wire         stat_rx_received_local_fault,
    input  wire         stat_rx_internal_local_fault,
    input  wire         stat_rx_hi_ber,
    input  wire         stat_rx_misaligned,
    input  wire         stat_rx_rsfec_hi_ser,
    input  wire         stat_rx_rsfec_lane_alignment_status,
    input  wire [2:0]   stat_rx_total_packets,
    input  wire [2:0]   stat_rx_bad_fcs,
    input  wire [2:0]   stat_rx_bad_code,
    input  wire         stat_rx_rsfec_corrected_cw_inc,
    input  wire         stat_rx_rsfec_uncorrected_cw_inc,
    input  wire         stat_tx_total_packets,
    input  wire         stat_tx_bad_fcs,
    input  wire         tx_unfout
);

rocelet_sys #(
    .NUM_QP(NUM_QP), .NUM_MR(NUM_MR), .READ_DEPTH(READ_DEPTH), .RTX_MODE(RTX_MODE),
    .RING_BYTES(RING_BYTES), .MAX_WR(MAX_WR), .RX_ICRC_EN(RX_ICRC_EN != 0), .ICRC_SHARE(ICRC_SHARE != 0),
    .HSB_EN(HSB_EN != 0), .SELFTEST(SELFTEST != 0), .RSFEC(RSFEC != 0), .MEM_BYTES(MEM_BYTES)
) u_sys (
    .clk(clk), .gen_clk(gen_clk), .sys_rst(sys_rst), .mac_tx_rst(mac_tx_rst), .mac_rx_rst(mac_rx_rst), .irq(irq),
    .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
    .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb), .s_axil_wvalid(s_axil_wvalid),
    .s_axil_wready(s_axil_wready), .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid),
    .s_axil_bready(s_axil_bready), .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid),
    .s_axil_arready(s_axil_arready), .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp),
    .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),
    .rx_tdata(rx_tdata), .rx_tkeep(rx_tkeep), .rx_tvalid(rx_tvalid), .rx_tlast(rx_tlast), .rx_tuser(rx_tuser),
    .tx_tdata(tx_tdata), .tx_tkeep(tx_tkeep), .tx_tvalid(tx_tvalid), .tx_tready(tx_tready),
    .tx_tlast(tx_tlast), .tx_tuser(tx_tuser),
    .pause_rx_req(pause_rx_req), .pause_rx_valid(pause_rx_valid), .pause_rx_quanta8(pause_rx_quanta8),
    .pause_rx_frame(pause_rx_frame), .pause_tx_frame(pause_tx_frame), .pause_tx_req(pause_tx_req),
    .ctl_rx_enable(ctl_rx_enable), .ctl_tx_enable(ctl_tx_enable), .ctl_tx_send_rfi(ctl_tx_send_rfi),
    .ctl_tx_send_lfi(ctl_tx_send_lfi), .ctl_tx_send_idle(ctl_tx_send_idle), .ctl_rsfec(ctl_rsfec),
    .ctl_rx_pause(ctl_rx_pause), .ctl_rx_pause_vec(ctl_rx_pause_vec), .ctl_tx_pause_vec(ctl_tx_pause_vec),
    .ctl_tx_pause_quanta(ctl_tx_pause_quanta), .ctl_tx_pause_refresh(ctl_tx_pause_refresh),
    .ctl_gt_loopback(ctl_gt_loopback),
    .stat_rx_aligned(stat_rx_aligned), .stat_rx_status(stat_rx_status),
    .stat_rx_local_fault(stat_rx_local_fault), .stat_rx_remote_fault(stat_rx_remote_fault),
    .stat_rx_received_local_fault(stat_rx_received_local_fault),
    .stat_rx_internal_local_fault(stat_rx_internal_local_fault), .stat_rx_hi_ber(stat_rx_hi_ber),
    .stat_rx_misaligned(stat_rx_misaligned), .stat_rx_rsfec_hi_ser(stat_rx_rsfec_hi_ser),
    .stat_rx_rsfec_lane_alignment_status(stat_rx_rsfec_lane_alignment_status),
    .stat_rx_total_packets(stat_rx_total_packets), .stat_rx_bad_fcs(stat_rx_bad_fcs),
    .stat_rx_bad_code(stat_rx_bad_code), .stat_rx_rsfec_corrected_cw_inc(stat_rx_rsfec_corrected_cw_inc),
    .stat_rx_rsfec_uncorrected_cw_inc(stat_rx_rsfec_uncorrected_cw_inc),
    .stat_tx_total_packets(stat_tx_total_packets), .stat_tx_bad_fcs(stat_tx_bad_fcs), .tx_unfout(tx_unfout)
);

endmodule
