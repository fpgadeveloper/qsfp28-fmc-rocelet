// SPDX-License-Identifier: MIT
//
// rsys_aon_bd - block-design module reference for rsys_aon (the always-on register block and
// the clock guard of the ZynqMP targets). S_AXIL (pl_clk0, 1 MB) is the CPU's register
// window; M_AXIL (MAC clock) goes to rocelet_sys_0/S_AXIL.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps

module rsys_aon_bd #(
    parameter integer PL_CLK_KHZ = 100000,
    parameter integer BUILD_ID   = 0,
    parameter integer TARGET_ID  = 32'h5A313036,
    parameter integer CAPS       = 0
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIL, ASSOCIATED_RESET rst" *)
    input  wire         clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    input  wire         rst,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL AWADDR" *)
    (* X_INTERFACE_PARAMETER = "PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 20" *)
    input  wire [19:0]  s_axil_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL AWVALID" *) input  wire         s_axil_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL AWREADY" *) output wire         s_axil_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WDATA" *)   input  wire [31:0]  s_axil_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WSTRB" *)   input  wire [3:0]   s_axil_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WVALID" *)  input  wire         s_axil_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WREADY" *)  output wire         s_axil_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL BRESP" *)   output wire [1:0]   s_axil_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL BVALID" *)  output wire         s_axil_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL BREADY" *)  input  wire         s_axil_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL ARADDR" *)  input  wire [19:0]  s_axil_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL ARVALID" *) input  wire         s_axil_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL ARREADY" *) output wire         s_axil_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RDATA" *)   output wire [31:0]  s_axil_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RRESP" *)   output wire [1:0]   s_axil_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RVALID" *)  output wire         s_axil_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RREADY" *)  input  wire         s_axil_rready,

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 mac_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF M_AXIL" *)
    input  wire         mac_clk,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXIL AWADDR" *)
    (* X_INTERFACE_PARAMETER = "PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 19" *)
    output wire [18:0]  m_axil_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXIL AWVALID" *) output wire         m_axil_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXIL AWREADY" *) input  wire         m_axil_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXIL WDATA" *)   output wire [31:0]  m_axil_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXIL WSTRB" *)   output wire [3:0]   m_axil_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXIL WVALID" *)  output wire         m_axil_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXIL WREADY" *)  input  wire         m_axil_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXIL BRESP" *)   input  wire [1:0]   m_axil_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXIL BVALID" *)  input  wire         m_axil_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXIL BREADY" *)  output wire         m_axil_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXIL ARADDR" *)  output wire [18:0]  m_axil_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXIL ARVALID" *) output wire         m_axil_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXIL ARREADY" *) input  wire         m_axil_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXIL RDATA" *)   input  wire [31:0]  m_axil_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXIL RRESP" *)   input  wire [1:0]   m_axil_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXIL RVALID" *)  input  wire         m_axil_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXIL RREADY" *)  output wire         m_axil_rready,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 gt_reset RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    output wire         gt_reset,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 mac_reset RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    output wire         mac_reset,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 sys_reset RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    output wire         sys_reset,
    output wire         qsfp_modsel_l,
    output wire         qsfp_reset_l,
    output wire         qsfp_lpmode,
    output wire         led_grn,
    output wire         led_red,
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "SENSITIVITY LEVEL_HIGH" *)
    output wire         irq,

    input  wire [15:0]  mac_stat,
    input  wire [7:0]   sys_evt,
    input  wire [31:0]  mac_lane,       // 40G lane status (MAC clock; 0 on 10G)
    input  wire [5:0]   mac_lev,        // 40G lane events (MAC clock; 0 on 10G)
    input  wire         gt_powergood,
    input  wire         gt_tx_ready,
    input  wire         gt_rx_ready,
    input  wire         qsfp_modprs_l,
    input  wire         qsfp_int_l,
    input  wire         clk_los
);

rsys_aon #(.PL_CLK_KHZ(PL_CLK_KHZ), .BUILD_ID(BUILD_ID), .TARGET_ID(TARGET_ID), .CAPS(CAPS)) u_aon (
    .clk(clk), .rst(rst),
    .s_awaddr(s_axil_awaddr), .s_awvalid(s_axil_awvalid), .s_awready(s_axil_awready),
    .s_wdata(s_axil_wdata), .s_wstrb(s_axil_wstrb), .s_wvalid(s_axil_wvalid), .s_wready(s_axil_wready),
    .s_bresp(s_axil_bresp), .s_bvalid(s_axil_bvalid), .s_bready(s_axil_bready),
    .s_araddr(s_axil_araddr), .s_arvalid(s_axil_arvalid), .s_arready(s_axil_arready),
    .s_rdata(s_axil_rdata), .s_rresp(s_axil_rresp), .s_rvalid(s_axil_rvalid), .s_rready(s_axil_rready),
    .mac_clk(mac_clk),
    .m_awaddr(m_axil_awaddr), .m_awvalid(m_axil_awvalid), .m_awready(m_axil_awready),
    .m_wdata(m_axil_wdata), .m_wstrb(m_axil_wstrb), .m_wvalid(m_axil_wvalid), .m_wready(m_axil_wready),
    .m_bresp(m_axil_bresp), .m_bvalid(m_axil_bvalid), .m_bready(m_axil_bready),
    .m_araddr(m_axil_araddr), .m_arvalid(m_axil_arvalid), .m_arready(m_axil_arready),
    .m_rdata(m_axil_rdata), .m_rresp(m_axil_rresp), .m_rvalid(m_axil_rvalid), .m_rready(m_axil_rready),
    .gt_reset(gt_reset), .mac_reset(mac_reset), .sys_reset(sys_reset), .qsfp_modsel_l(qsfp_modsel_l),
    .qsfp_reset_l(qsfp_reset_l), .qsfp_lpmode(qsfp_lpmode), .led_grn(led_grn), .led_red(led_red), .irq(irq),
    .mac_stat(mac_stat), .sys_evt(sys_evt), .mac_lane(mac_lane), .mac_lev(mac_lev), .gt_powergood(gt_powergood), .gt_tx_ready(gt_tx_ready),
    .gt_rx_ready(gt_rx_ready), .qsfp_modprs_l(qsfp_modprs_l), .qsfp_int_l(qsfp_int_l), .clk_los(clk_los)
);

endmodule
