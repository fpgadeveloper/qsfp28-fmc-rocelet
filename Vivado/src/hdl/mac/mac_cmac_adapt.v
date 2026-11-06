// SPDX-License-Identifier: MIT
//
// mac_cmac_adapt - the UltraScale+ 100G CMAC (cmac_usplus, AXIS user interface, no AXI-Lite
// block) behind rocelet_sys's generic MAC boundary (KCU116 target). Combinational: the
// control bundle is registered in rocelet_sys (as the CMAC ctl_* ports were before 0.5), the
// status bundle is registered there too. The AXI-Streams connect the CMAC to rocelet_sys
// directly (512 bits, rx_clk = gt_txusrclk2 = the rocelet_sys clock).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps

module mac_cmac_adapt (
    // rocelet_sys side
    input  wire [31:0]  mac_ctl,
    input  wire [31:0]  mac_pz,
    output wire [15:0]  mac_stat,
    output wire [15:0]  mac_ev,
    output wire [17:0]  mac_pause,

    // CMAC static control
    output wire         ctl_rx_enable,
    output wire         ctl_tx_enable,
    output wire         ctl_tx_send_rfi,
    output wire         ctl_tx_send_lfi,
    output wire         ctl_tx_send_idle,
    output wire         ctl_rsfec,           // RS-FEC TX + RX (correction + indication)
    output wire         ctl_rx_pause,        // accept global PAUSE frames (checks on)
    output wire [8:0]   ctl_rx_pause_vec,    // ctl_rx_pause_enable / ctl_rx_pause_ack: [8] global
    output wire [8:0]   ctl_tx_pause_vec,    // ctl_tx_pause_enable: [8] global
    output wire [15:0]  ctl_tx_pause_quanta,
    output wire [15:0]  ctl_tx_pause_refresh,
    output wire [8:0]   ctl_tx_pause_req,
    output wire [11:0]  ctl_gt_loopback,     // gt_loopback_in: 3 bits per lane

    // CMAC status and statistics
    input  wire         usr_rx_reset,
    input  wire         usr_tx_reset,
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
    input  wire         tx_unfout,
    input  wire [8:0]   stat_rx_pause_req,
    input  wire [8:0]   stat_rx_pause_valid,
    input  wire [15:0]  stat_rx_pause_quanta8,
    input  wire         stat_rx_pause,
    input  wire         stat_tx_pause
);

assign ctl_rx_enable        = mac_ctl[0];
assign ctl_tx_enable        = mac_ctl[1];
assign ctl_tx_send_rfi      = mac_ctl[2];
assign ctl_tx_send_lfi      = mac_ctl[3];
assign ctl_tx_send_idle     = mac_ctl[4];
assign ctl_rsfec            = mac_ctl[5];
assign ctl_rx_pause         = mac_ctl[6];
assign ctl_rx_pause_vec     = {mac_ctl[6], 8'd0};
assign ctl_tx_pause_vec     = {mac_ctl[7], 8'd0};
assign ctl_tx_pause_quanta  = mac_pz[15:0];
assign ctl_tx_pause_refresh = mac_pz[31:16];
assign ctl_tx_pause_req     = {mac_ctl[16], 8'd0};
assign ctl_gt_loopback      = {4{mac_ctl[10:8]}};

assign mac_stat = {2'b00,
                   stat_rx_aligned & ~stat_rx_local_fault & ~stat_rx_remote_fault,   // [12] link up
                   usr_tx_reset, usr_rx_reset, stat_rx_rsfec_lane_alignment_status, stat_rx_rsfec_hi_ser,
                   stat_rx_misaligned, stat_rx_hi_ber, stat_rx_internal_local_fault,
                   stat_rx_received_local_fault, stat_rx_remote_fault, stat_rx_local_fault,
                   stat_rx_status, stat_rx_aligned};
assign mac_ev   = {stat_tx_pause, stat_rx_pause, stat_rx_rsfec_uncorrected_cw_inc, stat_rx_rsfec_corrected_cw_inc,
                   tx_unfout, stat_tx_bad_fcs, stat_tx_total_packets,
                   stat_rx_bad_code, stat_rx_bad_fcs, stat_rx_total_packets};
assign mac_pause = {stat_rx_pause_req[8], stat_rx_pause_valid[8], stat_rx_pause_quanta8};

endmodule
