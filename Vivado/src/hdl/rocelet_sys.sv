// SPDX-License-Identifier: MIT
//
// rocelet_sys - the rocelet RoCE v2 engine in the KCU116 + OP120 reference design:
// everything between the CMAC's 512-bit AXI-Streams and the MicroBlaze's
// AXI-Lite port, in the CMAC user clock (322.265625 MHz).
//
//   CMAC RX -> [u_rinj] -> u_rl (rocelet_top: MAC glue, ARP/ICMP, engine) -> [u_inj, skid] -> CMAC TX
//   u_rl memory master (AXI4, 512 bit) -> u_mem: on-chip memory window (URAM),
//       also mapped into the MicroBlaze address space
//   work requests: u_wrq (firmware WR queue, payload read from u_mem, completion
//       queues) and, with SELFTEST, u_wg (line-rate WR generator, pattern payload)
//   u_raw: firmware frames to the engine's other-traffic port, and a capture
//       buffer at the CMAC interfaces (or on the other-traffic output)
//   CMAC: static control (ctl_*) from system registers, link status and a few
//       fabric counters (the CMAC IP's AXI-Lite statistics block is not built)
//   u_split: AXI-Lite decoder: engine registers (+0x00000), system registers
//       u_regs (+0x10000), memory window (+0x40000)
//   Holoscan Sensor Bridge (HSB) device side (docs/source/hsb.md):
//     u_crx: control-plane receive FIFO on the engine's other-traffic port (HSB
//       register protocol UDP 8192 and BOOTP replies UDP 12268 for the firmware)
//     u_hp: HSB frame producer, a third work-request source (UC-HSB QP), fed by
//       u_iqs (the IQ16 test-signal generator iq16_gen in the 200 MHz generator
//       clock gen_clk, async FIFO into clk), u_bms (the 8 x 8 phased-array
//       generator of the beamforming demo, same clocking, docs/source/beam_contract.md)
//       or a counter pattern
//     u_ptime: free-running seconds / nanoseconds for the frame metadata (PTP stub)
//     u_dna: device DNA (the firmware's HSB serial number), read in gen_clk
// Self-test logic (SELFTEST = 1), none of it part of the engine: u_wg, the
// pattern region of u_mem, the data checkers u_wchk (memory writes) / u_schk
// (SEND payload), the TX / RX fault injectors u_inj / u_rinj and the latency
// probe u_lat. It is what the console's self-test and the loopback benchmarks
// use; a product built from this design sets SELFTEST = 0.
// Hierarchy names are used by the utilisation split (Vivado/scripts/util_split.py).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_sys
    import rsys_pkg::*;
#(
    // engine (rocelet_top parameters)
    parameter int          NUM_QP       = 16,
    parameter int          NUM_MR       = 16,
    parameter int          READ_DEPTH   = 16,
    parameter int          RTX_MODE     = 0,       // 0 RING, 1 REREAD, 2 LOSSY
    parameter int          RING_BYTES   = 262144,
    parameter int          MAX_WR       = 128,
    parameter bit          RX_ICRC_EN   = 1'b1,
    parameter bit          ICRC_SHARE   = 1'b1,
    parameter bit          HSB_EN       = 1'b1,
    // system
    parameter bit          SELFTEST     = 1'b1,
    parameter bit          RSFEC        = 1'b1,    // RS-FEC on after reset
    parameter int          MEM_BYTES    = 262144,
    parameter int          PAT_BIT      = 40
) (
    input  wire logic          clk,
    input  wire logic          gen_clk,        // 200 MHz: IQ16 / beam generators, device DNA (asynchronous to clk)
    input  wire logic          sys_rst,        // system reset (any clock; synchronised here)
    input  wire logic          mac_tx_rst,     // CMAC usr_tx_reset
    input  wire logic          mac_rx_rst,     // CMAC usr_rx_reset
    output wire logic          irq,            // engine: a QP error is latched

    input  wire logic [18:0]   s_axil_awaddr,
    input  wire logic          s_axil_awvalid,
    output wire logic          s_axil_awready,
    input  wire logic [31:0]   s_axil_wdata,
    input  wire logic [3:0]    s_axil_wstrb,
    input  wire logic          s_axil_wvalid,
    output wire logic          s_axil_wready,
    output wire logic [1:0]    s_axil_bresp,
    output wire logic          s_axil_bvalid,
    input  wire logic          s_axil_bready,
    input  wire logic [18:0]   s_axil_araddr,
    input  wire logic          s_axil_arvalid,
    output wire logic          s_axil_arready,
    output wire logic [31:0]   s_axil_rdata,
    output wire logic [1:0]    s_axil_rresp,
    output wire logic          s_axil_rvalid,
    input  wire logic          s_axil_rready,

    input  wire logic [511:0]  rx_tdata,
    input  wire logic [63:0]   rx_tkeep,
    input  wire logic          rx_tvalid,
    input  wire logic          rx_tlast,
    input  wire logic          rx_tuser,

    output wire logic [511:0]  tx_tdata,
    output wire logic [63:0]   tx_tkeep,
    output wire logic          tx_tvalid,
    input  wire logic          tx_tready,
    output wire logic          tx_tlast,
    output wire logic          tx_tuser,

    // CMAC 802.3x flow control
    input  wire logic [8:0]    pause_rx_req,       // stat_rx_pause_req
    input  wire logic [8:0]    pause_rx_valid,     // stat_rx_pause_valid
    input  wire logic [15:0]   pause_rx_quanta8,   // stat_rx_pause_quanta8
    input  wire logic          pause_rx_frame,     // stat_rx_pause
    input  wire logic          pause_tx_frame,     // stat_tx_pause
    output wire logic [8:0]    pause_tx_req,       // ctl_tx_pause_req

    // CMAC static control (C_MAC_CTL / C_MAC_PZ)
    output logic               ctl_rx_enable,
    output logic               ctl_tx_enable,
    output logic               ctl_tx_send_rfi,
    output logic               ctl_tx_send_lfi,
    output logic               ctl_tx_send_idle,
    output logic               ctl_rsfec,          // RS-FEC TX + RX (correction + indication)
    output logic               ctl_rx_pause,       // accept global / priority PAUSE frames (checks on)
    output logic      [8:0]    ctl_rx_pause_vec,   // ctl_rx_pause_enable / ctl_rx_pause_ack: [8] global
    output logic      [8:0]    ctl_tx_pause_vec,   // ctl_tx_pause_enable: [8] global
    output logic      [15:0]   ctl_tx_pause_quanta,
    output logic      [15:0]   ctl_tx_pause_refresh,
    output logic      [11:0]   ctl_gt_loopback,    // gt_loopback_in: 3 bits per lane

    // CMAC status and statistics (CMAC user clock)
    input  wire logic          stat_rx_aligned,
    input  wire logic          stat_rx_status,
    input  wire logic          stat_rx_local_fault,
    input  wire logic          stat_rx_remote_fault,
    input  wire logic          stat_rx_received_local_fault,
    input  wire logic          stat_rx_internal_local_fault,
    input  wire logic          stat_rx_hi_ber,
    input  wire logic          stat_rx_misaligned,
    input  wire logic          stat_rx_rsfec_hi_ser,
    input  wire logic          stat_rx_rsfec_lane_alignment_status,
    input  wire logic [2:0]    stat_rx_total_packets,
    input  wire logic [2:0]    stat_rx_bad_fcs,
    input  wire logic [2:0]    stat_rx_bad_code,
    input  wire logic          stat_rx_rsfec_corrected_cw_inc,
    input  wire logic          stat_rx_rsfec_uncorrected_cw_inc,
    input  wire logic          stat_tx_total_packets,
    input  wire logic          stat_tx_bad_fcs,
    input  wire logic          tx_unfout
);

localparam bit PAY_EN = (RTX_MODE != 1);
localparam     RTX_STR = (RTX_MODE == 1) ? "REREAD" : ((RTX_MODE == 2) ? "LOSSY" : "RING");
localparam int ID_W = 2;

// ---------------- resets ----------------
(* ASYNC_REG = "TRUE" *) logic [2:0] rs_sync = '1;
always_ff @(posedge clk or posedge sys_rst) begin
    if (sys_rst) rs_sync <= '1;
    else         rs_sync <= {rs_sync[1:0], 1'b0};
end
logic regs_rst = 1'b1;
always_ff @(posedge clk) regs_rst <= rs_sync[2];
// generator clock domain reset
wire logic g_rst;
xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .RST_ACTIVE_HIGH(1)) u_grst (
    .src_arst(sys_rst), .dest_clk(gen_clk), .dest_arst(g_rst)
);
// the engine keeps its state across CMAC resets (its MAC glue handles them)
logic eng_rst = 1'b1;
always_ff @(posedge clk) eng_rst <= regs_rst;

logic [31:0] cfg [NCFG];
logic [NCFG-1:0] cfg_wr;
logic        stats_clr;
logic        st_rst = 1'b1;     // system / self-test logic
always_ff @(posedge clk) st_rst <= regs_rst || cfg[C_CTRL][0];
logic        chk_rst = 1'b1;
always_ff @(posedge clk) chk_rst <= st_rst || stats_clr;

// ---------------- AXI-Lite decoder ----------------
wire logic [18:0] ma_awaddr, ma_araddr;
wire logic [2:0]  ma_awvalid, ma_awready, ma_wvalid, ma_wready, ma_bvalid, ma_bready;
wire logic [2:0]  ma_arvalid, ma_arready, ma_rvalid, ma_rready;
wire logic [31:0] ma_wdata;
wire logic [3:0]  ma_wstrb;
logic      [1:0]  ma_bresp [3];
logic      [31:0] ma_rdata [3];
logic      [1:0]  ma_rresp [3];

rsys_axil_split #(.AW(19)) u_split (
    .clk(clk), .rst(regs_rst),
    .s_awaddr(s_axil_awaddr), .s_awvalid(s_axil_awvalid), .s_awready(s_axil_awready),
    .s_wdata(s_axil_wdata), .s_wstrb(s_axil_wstrb), .s_wvalid(s_axil_wvalid), .s_wready(s_axil_wready),
    .s_bresp(s_axil_bresp), .s_bvalid(s_axil_bvalid), .s_bready(s_axil_bready),
    .s_araddr(s_axil_araddr), .s_arvalid(s_axil_arvalid), .s_arready(s_axil_arready),
    .s_rdata(s_axil_rdata), .s_rresp(s_axil_rresp), .s_rvalid(s_axil_rvalid), .s_rready(s_axil_rready),
    .m_awaddr(ma_awaddr), .m_awvalid(ma_awvalid), .m_awready(ma_awready),
    .m_wdata(ma_wdata), .m_wstrb(ma_wstrb), .m_wvalid(ma_wvalid), .m_wready(ma_wready),
    .m_bresp(ma_bresp), .m_bvalid(ma_bvalid), .m_bready(ma_bready),
    .m_araddr(ma_araddr), .m_arvalid(ma_arvalid), .m_arready(ma_arready),
    .m_rdata(ma_rdata), .m_rresp(ma_rresp), .m_rvalid(ma_rvalid), .m_rready(ma_rready)
);

// ---------------- system registers ----------------
logic [31:0]     sv [NSV];
logic [NCNT-1:0] ev;
logic [15:0]     bc_add [NBC];
logic            raw_we;
logic [8:0]      raw_waddr;
logic [31:0]     raw_wdata;
logic [11:0]     cap_raddr;
logic [31:0]     cap_rdata;
logic [8:0]      crx_raddr;
logic [31:0]     crx_rdata;

rsys_regs #(.RSFEC(RSFEC)) u_regs (
    .clk(clk), .rst(regs_rst),
    .s_axil_awaddr(ma_awaddr[15:0]), .s_axil_awvalid(ma_awvalid[1]), .s_axil_awready(ma_awready[1]),
    .s_axil_wdata(ma_wdata), .s_axil_wstrb(ma_wstrb), .s_axil_wvalid(ma_wvalid[1]),
    .s_axil_wready(ma_wready[1]), .s_axil_bresp(ma_bresp[1]), .s_axil_bvalid(ma_bvalid[1]),
    .s_axil_bready(ma_bready[1]), .s_axil_araddr(ma_araddr[15:0]), .s_axil_arvalid(ma_arvalid[1]),
    .s_axil_arready(ma_arready[1]), .s_axil_rdata(ma_rdata[1]), .s_axil_rresp(ma_rresp[1]),
    .s_axil_rvalid(ma_rvalid[1]), .s_axil_rready(ma_rready[1]),
    .cfg(cfg), .cfg_wr(cfg_wr), .stats_clr(stats_clr),
    .sv(sv), .ev(ev), .bc_add(bc_add),
    .raw_we(raw_we), .raw_waddr(raw_waddr), .raw_wdata(raw_wdata),
    .cap_raddr(cap_raddr), .cap_rdata(cap_rdata),
    .crx_raddr(crx_raddr), .crx_rdata(crx_rdata)
);

logic [31:0] now = '0;
always_ff @(posedge clk) now <= now + 32'd1;

// ---------------- CMAC static control, status, fabric counters ----------------
always_ff @(posedge clk) begin
    ctl_rx_enable        <= cfg[C_MAC_CTL][0];
    ctl_tx_enable        <= cfg[C_MAC_CTL][1];
    ctl_tx_send_rfi      <= cfg[C_MAC_CTL][2];
    ctl_tx_send_lfi      <= cfg[C_MAC_CTL][3];
    ctl_tx_send_idle     <= cfg[C_MAC_CTL][4];
    ctl_rsfec            <= cfg[C_MAC_CTL][5];
    ctl_rx_pause         <= cfg[C_MAC_CTL][6];
    ctl_rx_pause_vec     <= {cfg[C_MAC_CTL][6], 8'd0};
    ctl_tx_pause_vec     <= {cfg[C_MAC_CTL][7], 8'd0};
    ctl_tx_pause_quanta  <= cfg[C_MAC_PZ][15:0];
    ctl_tx_pause_refresh <= cfg[C_MAC_PZ][31:16];
    ctl_gt_loopback      <= {4{cfg[C_MAC_CTL][10:8]}};
end

logic [11:0] mac_st, mac_st_d;
logic        ev_tx_unf_mac, ev_tx_bad_fcs, ev_align_lost;
logic [2:0]  m_rx_pkts, m_rx_bad_fcs, m_rx_bad_code;
logic        m_tx_pkts;
logic        link_ok = 1'b0;
always_ff @(posedge clk) link_ok <= stat_rx_aligned & ~stat_rx_local_fault & ~stat_rx_remote_fault;

always_ff @(posedge clk) begin
    mac_st <= {mac_tx_rst, mac_rx_rst, stat_rx_rsfec_lane_alignment_status, stat_rx_rsfec_hi_ser,
               stat_rx_misaligned, stat_rx_hi_ber, stat_rx_internal_local_fault,
               stat_rx_received_local_fault, stat_rx_remote_fault, stat_rx_local_fault,
               stat_rx_status, stat_rx_aligned};
    mac_st_d      <= mac_st;
    ev_tx_unf_mac <= tx_unfout;
    ev_tx_bad_fcs <= stat_tx_bad_fcs;
    ev_align_lost <= mac_st_d[0] && !mac_st[0];
    m_rx_pkts     <= stat_rx_total_packets;
    m_rx_bad_fcs  <= stat_rx_bad_fcs;
    m_rx_bad_code <= stat_rx_bad_code;
    m_tx_pkts     <= stat_tx_total_packets;
end

// ---------------- RX: CMAC -> [RX fault injector] -> engine ----------------
wire logic [511:0] ri_tdata;
wire logic [63:0]  ri_tkeep;
wire logic         ri_tvalid, ri_tlast, ri_tuser;
logic              ev_rinj_seen, ev_rinj_done, rinj_armed;
if (SELFTEST) begin : g_rinj
    rsys_inj u_rinj (
        .clk(clk), .rst(st_rst),
        .cfg_action(cfg[C_RINJ_CTRL][1:0]), .cfg_mode(cfg[C_RINJ_CTRL][3:2]), .cfg_class(cfg[C_RINJ_CLASS][4:0]),
        .cfg_skip(cfg[C_RINJ_SKIP]), .cfg_count(cfg[C_RINJ_COUNT]), .cfg_period(cfg[C_RINJ_PERIOD]),
        .cfg_thresh(cfg[C_RINJ_THRESH]), .cfg_byte(cfg[C_RINJ_BYTE][8:0]),
        .arm(cfg_wr[C_RINJ_CTRL] && cfg[C_RINJ_CTRL][8]),
        .s_axis_tdata(rx_tdata), .s_axis_tkeep(rx_tkeep), .s_axis_tvalid(rx_tvalid), .s_axis_tready(),
        .s_axis_tlast(rx_tlast), .s_axis_tuser(rx_tuser),
        .m_axis_tdata(ri_tdata), .m_axis_tkeep(ri_tkeep), .m_axis_tvalid(ri_tvalid), .m_axis_tready(1'b1),
        .m_axis_tlast(ri_tlast), .m_axis_tuser(ri_tuser),
        .ev_seen(ev_rinj_seen), .ev_done(ev_rinj_done), .armed(rinj_armed), .lfsr_o()
    );
end else begin : g_norinj
    assign ri_tdata = rx_tdata; assign ri_tkeep = rx_tkeep; assign ri_tvalid = rx_tvalid;
    assign ri_tlast = rx_tlast; assign ri_tuser = rx_tuser;
    assign ev_rinj_seen = 1'b0; assign ev_rinj_done = 1'b0; assign rinj_armed = 1'b0;
end

// ---------------- the rocelet engine ----------------
wire logic [511:0]  e_tdata;
wire logic [63:0]   e_tkeep;
wire logic          e_tvalid, e_tready, e_tlast;
// other-traffic ports
wire logic [511:0]  oth_rx_tdata, oth_tx_tdata;
wire logic [63:0]   oth_rx_tkeep, oth_tx_tkeep;
wire logic          oth_rx_tvalid, oth_rx_tlast, oth_tx_tvalid, oth_tx_tready, oth_tx_tlast;
// work requests / completions
wire logic          wr_valid, wr_ready;
wire logic [255:0]  wr_desc;
wire logic [511:0]  wpay_tdata;
wire logic          wpay_tvalid, wpay_tready, wpay_tlast;
wire logic          wc_valid;
wire logic [63:0]   wc_data;
// responder
wire logic [511:0]  send_tdata;
wire logic [63:0]   send_tkeep;
wire logic          send_tvalid, send_tlast, send_commit_valid, send_commit_ok;
wire logic [15:0]   send_tuser;
wire logic          rc_valid;
wire logic [127:0]  rc_data;
// memory master
wire logic [ID_W-1:0] axi_awid, axi_bid, axi_arid, axi_rid;
wire logic [63:0]   axi_awaddr, axi_araddr;
wire logic [7:0]    axi_awlen, axi_arlen;
wire logic          axi_awvalid, axi_awready, axi_wlast, axi_wvalid, axi_wready, axi_bvalid, axi_bready;
wire logic          axi_arvalid, axi_arready, axi_rlast, axi_rvalid, axi_rready;
wire logic [511:0]  axi_wdata, axi_rdata;
wire logic [63:0]   axi_wstrb;
wire logic [1:0]    axi_bresp, axi_rresp;

rocelet_top #(
    .NUM_QP(NUM_QP), .NUM_MR(NUM_MR), .READ_DEPTH(READ_DEPTH), .RTX_MODE(RTX_STR),
    .RING_BYTES(RING_BYTES), .RING_RAM("ultra"), .MAX_WR(MAX_WR), .RX_ICRC_EN(RX_ICRC_EN),
    .ICRC_SHARE(ICRC_SHARE), .IPV6_EN(1'b0), .HSB_EN(HSB_EN), .VLAN_EN(1'b1), .PAUSE_EN(1'b1),
    .ARP_EN(1'b1), .OTHER_EN(1'b1), .COUNTERS_EN(1'b1), .M_AXI_ADDR_W(64), .M_AXI_ID_W(ID_W),
    .CLK_MHZ(322)
) u_rl (
    .clk(clk), .rst(eng_rst), .irq(irq),
    .mac_rx_reset(mac_rx_rst), .mac_tx_reset(mac_tx_rst), .mac_rx_aligned(stat_rx_aligned),
    // link state for the requester's ACK-timeout hold (rocelet v0.2): CMAC aligned and neither a
    // local fault (no valid signal received) nor a remote fault (the partner does not receive
    // ours) - the peer cannot answer in either case. Registered in clk: the CMAC's rx_clk is
    // gt_txusrclk2 (= clk) in this design; rocelet synchronises it with two flip-flops anyway.
    // Fault toggles while the link comes up only restart LINK_GRACE.
    .link_up(link_ok),
    .s_axis_rx_tdata(ri_tdata), .s_axis_rx_tkeep(ri_tkeep), .s_axis_rx_tvalid(ri_tvalid),
    .s_axis_rx_tlast(ri_tlast), .s_axis_rx_tuser(ri_tuser),
    .m_axis_tx_tdata(e_tdata), .m_axis_tx_tkeep(e_tkeep), .m_axis_tx_tvalid(e_tvalid),
    .m_axis_tx_tready(e_tready), .m_axis_tx_tlast(e_tlast), .m_axis_tx_tuser(),
    .stat_rx_pause_req(pause_rx_req), .stat_rx_pause_valid(pause_rx_valid),
    .stat_rx_pause_quanta8(pause_rx_quanta8), .stat_rx_pause(pause_rx_frame),
    .stat_tx_pause(pause_tx_frame), .ctl_tx_pause_req(pause_tx_req),
    .stat_rx_rsfec_corrected_cw_inc(stat_rx_rsfec_corrected_cw_inc),
    .stat_rx_rsfec_uncorrected_cw_inc(stat_rx_rsfec_uncorrected_cw_inc),
    .m_axis_other_tdata(oth_rx_tdata), .m_axis_other_tkeep(oth_rx_tkeep), .m_axis_other_tvalid(oth_rx_tvalid),
    .m_axis_other_tready(1'b1), .m_axis_other_tlast(oth_rx_tlast),
    .s_axis_other_tdata(oth_tx_tdata), .s_axis_other_tkeep(oth_tx_tkeep), .s_axis_other_tvalid(oth_tx_tvalid),
    .s_axis_other_tready(oth_tx_tready), .s_axis_other_tlast(oth_tx_tlast),
    .s_axis_wr_tdata(wr_desc), .s_axis_wr_tvalid(wr_valid), .s_axis_wr_tready(wr_ready),
    .s_axis_wr_data_tdata(wpay_tdata), .s_axis_wr_data_tvalid(wpay_tvalid),
    .s_axis_wr_data_tready(wpay_tready), .s_axis_wr_data_tlast(wpay_tlast),
    .m_axis_wc_tdata(wc_data), .m_axis_wc_tvalid(wc_valid), .m_axis_wc_tready(1'b1),
    .m_axis_send_tdata(send_tdata), .m_axis_send_tkeep(send_tkeep), .m_axis_send_tvalid(send_tvalid),
    .m_axis_send_tready(1'b1), .m_axis_send_tlast(send_tlast), .m_axis_send_tuser(send_tuser),
    .send_commit_valid(send_commit_valid), .send_commit_ok(send_commit_ok),
    .send_rnr(cfg[C_SEND_RNR][NUM_QP-1:0]),
    .m_axis_rc_tdata(rc_data), .m_axis_rc_tvalid(rc_valid), .m_axis_rc_tready(1'b1),
    .m_axi_awid(axi_awid), .m_axi_awaddr(axi_awaddr), .m_axi_awlen(axi_awlen), .m_axi_awsize(),
    .m_axi_awburst(), .m_axi_awlock(), .m_axi_awcache(), .m_axi_awprot(),
    .m_axi_awvalid(axi_awvalid), .m_axi_awready(axi_awready),
    .m_axi_wdata(axi_wdata), .m_axi_wstrb(axi_wstrb), .m_axi_wlast(axi_wlast),
    .m_axi_wvalid(axi_wvalid), .m_axi_wready(axi_wready),
    .m_axi_bid(axi_bid), .m_axi_bresp(axi_bresp), .m_axi_bvalid(axi_bvalid), .m_axi_bready(axi_bready),
    .m_axi_arid(axi_arid), .m_axi_araddr(axi_araddr), .m_axi_arlen(axi_arlen), .m_axi_arsize(),
    .m_axi_arburst(), .m_axi_arlock(), .m_axi_arcache(), .m_axi_arprot(),
    .m_axi_arvalid(axi_arvalid), .m_axi_arready(axi_arready),
    .m_axi_rid(axi_rid), .m_axi_rdata(axi_rdata), .m_axi_rresp(axi_rresp), .m_axi_rlast(axi_rlast),
    .m_axi_rvalid(axi_rvalid), .m_axi_rready(axi_rready),
    .s_axil_awaddr(ma_awaddr[15:0]), .s_axil_awvalid(ma_awvalid[0]), .s_axil_awready(ma_awready[0]),
    .s_axil_wdata(ma_wdata), .s_axil_wstrb(ma_wstrb), .s_axil_wvalid(ma_wvalid[0]),
    .s_axil_wready(ma_wready[0]), .s_axil_bresp(ma_bresp[0]), .s_axil_bvalid(ma_bvalid[0]),
    .s_axil_bready(ma_bready[0]), .s_axil_araddr(ma_araddr[15:0]), .s_axil_arvalid(ma_arvalid[0]),
    .s_axil_arready(ma_arready[0]), .s_axil_rdata(ma_rdata[0]), .s_axil_rresp(ma_rresp[0]),
    .s_axil_rvalid(ma_rvalid[0]), .s_axil_rready(ma_rready[0])
);

// ---------------- TX: engine -> [TX fault injector] -> CMAC ----------------
logic        ev_inj_seen, ev_inj_done, inj_armed;
logic [31:0] inj_lfsr;
if (SELFTEST) begin : g_inj
    wire logic [511:0] k_tdata;
    wire logic [63:0]  k_tkeep;
    wire logic         k_tvalid, k_tready, k_tlast;
    rsys_inj u_inj (
        .clk(clk), .rst(st_rst),
        .cfg_action(cfg[C_INJ_CTRL][1:0]), .cfg_mode(cfg[C_INJ_CTRL][3:2]), .cfg_class(cfg[C_INJ_CLASS][4:0]),
        .cfg_skip(cfg[C_INJ_SKIP]), .cfg_count(cfg[C_INJ_COUNT]), .cfg_period(cfg[C_INJ_PERIOD]),
        .cfg_thresh(cfg[C_INJ_THRESH]), .cfg_byte(cfg[C_INJ_BYTE][8:0]),
        .arm(cfg_wr[C_INJ_CTRL] && cfg[C_INJ_CTRL][8]),
        .s_axis_tdata(e_tdata), .s_axis_tkeep(e_tkeep), .s_axis_tvalid(e_tvalid), .s_axis_tready(e_tready),
        .s_axis_tlast(e_tlast), .s_axis_tuser(1'b0),
        .m_axis_tdata(k_tdata), .m_axis_tkeep(k_tkeep), .m_axis_tvalid(k_tvalid), .m_axis_tready(k_tready),
        .m_axis_tlast(k_tlast), .m_axis_tuser(),
        .ev_seen(ev_inj_seen), .ev_done(ev_inj_done), .armed(inj_armed), .lfsr_o(inj_lfsr)
    );
    // the CMAC's tready reaches the injector (and the engine's TX FIFO) only through a register
    rsys_skid u_txskid (
        .clk(clk), .rst(st_rst),
        .s_axis_tdata(k_tdata), .s_axis_tkeep(k_tkeep), .s_axis_tvalid(k_tvalid), .s_axis_tready(k_tready),
        .s_axis_tlast(k_tlast),
        .m_axis_tdata(tx_tdata), .m_axis_tkeep(tx_tkeep), .m_axis_tvalid(tx_tvalid), .m_axis_tready(tx_tready),
        .m_axis_tlast(tx_tlast)
    );
end else begin : g_noinj
    assign tx_tdata = e_tdata; assign tx_tkeep = e_tkeep; assign tx_tvalid = e_tvalid;
    assign e_tready = tx_tready; assign tx_tlast = e_tlast;
    assign ev_inj_seen = 1'b0; assign ev_inj_done = 1'b0; assign inj_armed = 1'b0; assign inj_lfsr = '0;
end
assign tx_tuser = 1'b0;

// ---------------- firmware frames: raw TX, capture ----------------
logic        rx_first = 1'b1, tx_first = 1'b1, oth_first = 1'b1;
logic [15:0] tx_idle = '0;
always_ff @(posedge clk) begin
    if (rx_tvalid) rx_first <= rx_tlast;
    if (oth_rx_tvalid) oth_first <= oth_rx_tlast;
    if (tx_tvalid && tx_tready) tx_first <= tx_tlast;
    if (tx_tvalid && tx_tready) tx_idle <= '0;
    else if (tx_idle != 16'hFFFF) tx_idle <= tx_idle + 16'd1;
end
wire logic cap_oth = cfg[C_CAP_CTRL][4];
logic ev_raw_sent, ev_cap;
wire logic [31:0] cap_status;
wire logic raw_busy;
rsys_raw u_raw (
    .clk(clk), .rst(st_rst),
    .wr_en(raw_we), .wr_addr(raw_waddr), .wr_data(raw_wdata),
    .send(cfg_wr[C_RAW_SEND]), .send_len(cfg[C_RAW_LEN][11:0]),
    .m_axis_tdata(oth_tx_tdata), .m_axis_tkeep(oth_tx_tkeep), .m_axis_tvalid(oth_tx_tvalid),
    .m_axis_tready(oth_tx_tready), .m_axis_tlast(oth_tx_tlast), .ev_sent(ev_raw_sent), .busy(raw_busy),
    .cap_arm(cfg_wr[C_CAP_CTRL] && cfg[C_CAP_CTRL][0]), .cap_mode(cfg[C_CAP_CTRL][2:1]),
    .cap_tx(cfg[C_CAP_CTRL][3]), .ttap_valid(tx_tvalid && tx_tready), .ttap_first(tx_first),
    .ttap_data(tx_tdata), .ttap_keep(tx_tkeep), .ttap_last(tx_tlast), .ttap_idle(tx_idle),
    .cap_match(cfg[C_CAP_MATCH]),
    .tap_valid(cap_oth ? oth_rx_tvalid : rx_tvalid), .tap_first(cap_oth ? oth_first : rx_first),
    .tap_data(cap_oth ? oth_rx_tdata : rx_tdata), .tap_keep(cap_oth ? oth_rx_tkeep : rx_tkeep),
    .tap_last(cap_oth ? oth_rx_tlast : rx_tlast),
    .cap_raddr(cap_raddr), .cap_rdata(cap_rdata), .cap_status(cap_status), .ev_cap(ev_cap)
);

// ---------------- control-plane receive FIFO (HSB register protocol, BOOTP replies) ----------------
wire logic [7:0]  crx_level;
wire logic [11:0] crx_head_len;
logic             ev_crx_frame, ev_crx_drop, ev_crx_long, ev_crx_filt;
rsys_crx #(.SLOTS(16)) u_crx (
    .clk(clk), .rst(regs_rst),
    .en(cfg[C_CRX_CTRL][0]), .all(cfg[C_CRX_CTRL][1]),
    .port_a(cfg[C_CRX_PORTS][15:0]), .port_b(cfg[C_CRX_PORTS][31:16]),
    .s_valid(oth_rx_tvalid), .s_first(oth_first), .s_data(oth_rx_tdata), .s_keep(oth_rx_tkeep),
    .s_last(oth_rx_tlast),
    .pop(cfg_wr[C_CRX_POP]), .raddr(crx_raddr), .rdata(crx_rdata), .level(crx_level), .head_len(crx_head_len),
    .ev_frame(ev_crx_frame), .ev_drop(ev_crx_drop), .ev_long(ev_crx_long), .ev_filt(ev_crx_filt)
);

// ---------------- HSB producer: time, device DNA, IQ16 source, frame producer ----------------
wire logic [47:0] t_s;
wire logic [29:0] t_ns;
rsys_ptime u_ptime (.clk(clk), .rst(regs_rst), .t_s(t_s), .t_ns(t_ns));

wire logic [95:0] dna;
wire logic        dna_valid;
rsys_dna u_dna (.gen_clk(gen_clk), .g_rst(g_rst), .clk(clk), .dna(dna), .valid(dna_valid));

wire logic         iq_valid, iq_pop, iq_pending, iq_enable, iq_start;
wire logic [511:0] iq_data;
logic              ev_iq_clip;
rsys_iq_src u_iqs (
    .gen_clk(gen_clk), .g_rst(g_rst), .clk(clk), .rst(regs_rst),
    .cfg_id(cfg[C_IQ_CFG_ID]),
    .tone_inc({cfg[C_IQ_TONE_INC0 + 3], cfg[C_IQ_TONE_INC0 + 2], cfg[C_IQ_TONE_INC0 + 1], cfg[C_IQ_TONE_INC0]}),
    .tone_amp({cfg[C_IQ_TONE_AMP23][31:16], cfg[C_IQ_TONE_AMP23][15:0], cfg[C_IQ_TONE_AMP01][31:16],
               cfg[C_IQ_TONE_AMP01][15:0]}),
    .chirp_start(cfg[C_IQ_CHIRP_START]),
    .chirp_rate({cfg[C_IQ_CHIRP_RATE_HI][15:0], cfg[C_IQ_CHIRP_RATE_LO]}),
    .chirp_per({cfg[C_IQ_CHIRP_PER_HI][15:0], cfg[C_IQ_CHIRP_PER_LO]}),
    .chirp_amp(cfg[C_IQ_AMPS][15:0]), .noise_amp(cfg[C_IQ_AMPS][31:16]), .noise_seed(cfg[C_IQ_SEED]),
    .chunk_pbeats(cfg[C_IQ_CHUNK][17:0]),
    .commit(cfg_wr[C_IQ_CTRL] && cfg[C_IQ_CTRL][0]), .start(iq_start), .enable(iq_enable),
    .o_valid(iq_valid), .o_data(iq_data), .o_pop(iq_pop), .st_pending(iq_pending), .ev_clip(ev_iq_clip)
);

// beam array generator (SOURCE 2): shadow words cfg[128..255], APPLY, frame size
logic [127:0][31:0] bm_cfg;
always_comb for (int i = 0; i < 128; i++) bm_cfg[i] = cfg[128 + i];
wire logic         bm_valid, bm_pop, bm_enable, bm_start, bm_pending, bm_clipped;
wire logic [511:0] bm_data;
wire logic [31:0]  bm_sid, bm_sframe, bm_aid, bm_aframe, bm_applies;
logic              ev_bm_clip;
rsys_beam_src u_bms (
    .gen_clk(gen_clk), .g_rst(g_rst), .clk(clk), .rst(regs_rst),
    .bm_cfg(bm_cfg), .apply(cfg_wr[C_BM_APPLY]), .frame_beats(cfg[C_HP_FRAME][31:6]),
    .start(bm_start), .enable(bm_enable),
    .o_valid(bm_valid), .o_data(bm_data), .o_scene_id(bm_sid), .o_scene_frame(bm_sframe), .o_pop(bm_pop),
    .ev_clip(ev_bm_clip), .st_pending(bm_pending), .st_clipped(bm_clipped), .st_applied_id(bm_aid),
    .st_applied_frame(bm_aframe), .st_applies(bm_applies), .seek_bl('0), .seek_km('0)
);

wire logic          h_wr_valid, h_wr_ready;
wire logic [255:0]  h_wr_desc;
wire logic [511:0]  h_pay_tdata;
wire logic          h_pay_tvalid, h_pay_tready, h_pay_tlast, h_pay_busy, h_running;
wire logic [31:0]   h_frames;
wire logic [11:0]   h_page;
wire logic [15:0]   h_fnum;
logic               ev_h_frame, ev_h_stall;
logic [15:0]        h_bytes_add;
rsys_hsb_prod u_hp (
    .clk(clk), .rst(st_rst),
    .run(cfg[C_HP_CTRL][0]), .cfg_src(cfg[C_HP_CTRL][2:1]), .cfg_qp(cfg[C_HP_QP][7:0]), .cfg_rkey(cfg[C_HP_RKEY]),
    .cfg_va0({cfg[C_HP_VA_HI], cfg[C_HP_VA_LO]}), .cfg_stride(cfg[C_HP_STRIDE]),
    .cfg_pg_first(cfg[C_HP_PAGES][27:16]), .cfg_pg_last(cfg[C_HP_PAGES][11:0]), .cfg_frame(cfg[C_HP_FRAME]),
    .cfg_wrmax(cfg[C_HP_WRMAX]), .cfg_period(cfg[C_HP_PERIOD]), .cfg_count(cfg[C_HP_COUNT]),
    .t_s(t_s), .t_ns(t_ns),
    .s_iq_valid(iq_valid), .s_iq_data(iq_data), .s_iq_pop(iq_pop), .iq_enable(iq_enable), .iq_start(iq_start),
    .s_bm_valid(bm_valid), .s_bm_data(bm_data), .s_bm_sid(bm_sid), .s_bm_sframe(bm_sframe), .s_bm_pop(bm_pop),
    .bm_enable(bm_enable), .bm_start(bm_start),
    .m_wr_valid(h_wr_valid), .m_wr_ready(h_wr_ready), .m_wr_desc(h_wr_desc),
    .m_pay_tdata(h_pay_tdata), .m_pay_tvalid(h_pay_tvalid), .m_pay_tready(h_pay_tready), .m_pay_tlast(h_pay_tlast),
    .pay_busy(h_pay_busy), .running(h_running), .frames(h_frames), .page(h_page), .fnum(h_fnum),
    .ev_frame(ev_h_frame), .bytes_add(h_bytes_add), .ev_stall_iq(ev_h_stall)
);

// ---------------- work requests: firmware queue (+ self-test generator, HSB producer) ----------------
wire logic          q_wr_valid, q_wr_ready;
wire logic [255:0]  q_wr_desc;
wire logic [511:0]  q_pay_tdata;
wire logic          q_pay_tvalid, q_pay_tready, q_pay_tlast, q_pay_busy;
wire logic          q_rd_valid, q_rd_ready;
wire logic [63:0]   q_rd_addr;
wire logic [12:0]   q_rd_len;
wire logic [511:0]  q_rdd_tdata;
wire logic          q_rdd_tvalid, q_rdd_tready;
wire logic [8:0]    wq_level;
wire logic          wq_full, ev_wq_post, ev_wq_drop, ev_wcq_ovf, ev_rcq_ovf;
wire logic [31:0]   wcq_head, rcq_head, rcq_imm, rcq_len;
wire logic [7:0]    wcq_level, rcq_level;
// the firmware describes a WR in C_WQ_*; this is its rocelet descriptor
wire logic [255:0]  post_desc = {cfg[C_WQ_LA_HI], cfg[C_WQ_LA_LO], cfg[C_WQ_IMM], cfg[C_WQ_RKEY],
                                 cfg[C_WQ_VA_HI], cfg[C_WQ_VA_LO], cfg[C_WQ_LEN], cfg[C_WQ_ID][15:0],
                                 2'b00, cfg[C_WQ_OP][5:0], cfg[C_WQ_QP][7:0]};

rsys_wrq #(.PAY_EN(PAY_EN)) u_wrq (
    .clk(clk), .rst(st_rst),
    .post(cfg_wr[C_WQ_POST]), .post_desc(post_desc),
    .wq_level(wq_level), .wq_full(wq_full), .ev_posted(ev_wq_post), .ev_dropped(ev_wq_drop),
    .m_wr_valid(q_wr_valid), .m_wr_ready(q_wr_ready), .m_wr_desc(q_wr_desc),
    .m_rd_valid(q_rd_valid), .m_rd_ready(q_rd_ready), .m_rd_addr(q_rd_addr), .m_rd_len(q_rd_len),
    .s_rd_tdata(q_rdd_tdata), .s_rd_tvalid(q_rdd_tvalid), .s_rd_tready(q_rdd_tready),
    .m_pay_tdata(q_pay_tdata), .m_pay_tvalid(q_pay_tvalid), .m_pay_tready(q_pay_tready),
    .m_pay_tlast(q_pay_tlast), .pay_busy(q_pay_busy),
    .cq_en(cfg[C_CQ_CTRL][1:0]),
    .wc_valid(wc_valid), .wc_data(wc_data), .rc_valid(rc_valid), .rc_data(rc_data),
    .cq_pop(cfg_wr[C_CQ_POP] ? cfg[C_CQ_POP][1:0] : 2'b00),
    .wcq_head(wcq_head), .rcq_head(rcq_head), .rcq_imm(rcq_imm), .rcq_len(rcq_len),
    .wcq_level(wcq_level), .rcq_level(rcq_level), .ev_wcq_ovf(ev_wcq_ovf), .ev_rcq_ovf(ev_rcq_ovf)
);

// self-test WR generator (pattern payload). It, the HSB producer and the firmware queue
// take turns: a source may start a WR only while the others have no payload outstanding,
// so the payload stream always follows the WR order (priority: generator, producer, queue).
wire logic          g_wr_valid, g_wr_ready;
wire logic [255:0]  g_wr_desc;
wire logic [31:0]   g_wr_len;
wire logic [511:0]  g_pay_tdata;
wire logic          g_pay_tvalid, g_pay_tready, g_pay_tlast, g_pay_busy;
wire logic          wg_running, wg_fire;
wire logic [31:0]   wg_issued;
if (SELFTEST) begin : g_wg
    rsys_wrgen #(.QPW(8), .PAY_EN(PAY_EN)) u_wg (
        .clk(clk), .rst(st_rst),
        .start(cfg_wr[C_WG_CTRL] && cfg[C_WG_CTRL][0]), .stop(cfg_wr[C_WG_CTRL] && cfg[C_WG_CTRL][1]),
        .cfg_qp0(cfg[C_WG_QP][7:0]), .cfg_nqp(cfg[C_WG_QP][15:8]), .cfg_op(cfg[C_WG_OP][5:0]),
        .cfg_va({cfg[C_WG_VA_HI], cfg[C_WG_VA_LO]}), .cfg_window(cfg[C_WG_WINDOW]), .cfg_len(cfg[C_WG_LEN]),
        .cfg_rkey(cfg[C_WG_RKEY]), .cfg_count(cfg[C_WG_COUNT]), .cfg_gap(cfg[C_WG_GAP]),
        .cfg_seed(cfg[C_WG_SEED]), .cfg_imm(cfg[C_WG_IMM]),
        .m_wr_valid(g_wr_valid), .m_wr_ready(g_wr_ready), .m_wr_desc(g_wr_desc), .m_wr_len(g_wr_len),
        .m_pay_tdata(g_pay_tdata), .m_pay_tvalid(g_pay_tvalid), .m_pay_tready(g_pay_tready),
        .m_pay_tlast(g_pay_tlast),
        .running(wg_running), .pay_busy(g_pay_busy), .wr_fire(wg_fire), .issued(wg_issued)
    );
end else begin : g_nowg
    assign g_wr_valid = 1'b0; assign g_wr_desc = '0; assign g_wr_len = '0;
    assign g_pay_tdata = '0; assign g_pay_tvalid = 1'b0; assign g_pay_tlast = 1'b0; assign g_pay_busy = 1'b0;
    assign wg_running = 1'b0; assign wg_fire = 1'b0; assign wg_issued = '0;
end

wire logic use_gen = g_wr_valid && !q_pay_busy && !h_pay_busy;
wire logic use_hsb = !use_gen && h_wr_valid && !g_pay_busy && !q_pay_busy;
wire logic q_ok    = !g_pay_busy && !g_wr_valid && !h_pay_busy && !h_wr_valid;
assign wr_valid     = use_gen || use_hsb || (q_wr_valid && q_ok);
assign wr_desc      = use_gen ? g_wr_desc : (use_hsb ? h_wr_desc : q_wr_desc);
assign g_wr_ready   = wr_ready && use_gen;
assign h_wr_ready   = wr_ready && use_hsb;
assign q_wr_ready   = wr_ready && !use_gen && !use_hsb && q_ok;
// payload: from whichever source has payload outstanding
assign wpay_tdata   = g_pay_busy ? g_pay_tdata  : (h_pay_busy ? h_pay_tdata  : q_pay_tdata);
assign wpay_tvalid  = g_pay_busy ? g_pay_tvalid : (h_pay_busy ? h_pay_tvalid : q_pay_tvalid);
assign wpay_tlast   = g_pay_busy ? g_pay_tlast  : (h_pay_busy ? h_pay_tlast  : q_pay_tlast);
assign g_pay_tready = wpay_tready && g_pay_busy;
assign h_pay_tready = wpay_tready && !g_pay_busy && h_pay_busy;
assign q_pay_tready = wpay_tready && !g_pay_busy && !h_pay_busy;

// ---------------- memory window ----------------
wire logic         wtap_valid, wtap_last;
wire logic [63:0]  wtap_addr, wtap_keep;
wire logic [511:0] wtap_data;
logic              ev_mem_wr, ev_mem_rd;
logic [15:0]       rd0_bytes_add;
rsys_axi_mem #(
    .BYTES(MEM_BYTES), .PAT_EN(SELFTEST), .PAT_BIT(PAT_BIT), .ID_W(ID_W), .ADDR_W(64), .FW_AW(18), .RD_LAT(3)
) u_mem (
    .clk(clk), .rst(regs_rst), .seed(cfg[C_WC_SEED]),
    .s_axi_awid(axi_awid), .s_axi_awaddr(axi_awaddr), .s_axi_awlen(axi_awlen),
    .s_axi_awvalid(axi_awvalid), .s_axi_awready(axi_awready),
    .s_axi_wdata(axi_wdata), .s_axi_wstrb(axi_wstrb), .s_axi_wlast(axi_wlast),
    .s_axi_wvalid(axi_wvalid), .s_axi_wready(axi_wready),
    .s_axi_bid(axi_bid), .s_axi_bresp(axi_bresp), .s_axi_bvalid(axi_bvalid), .s_axi_bready(axi_bready),
    .s_axi_arid(axi_arid), .s_axi_araddr(axi_araddr), .s_axi_arlen(axi_arlen),
    .s_axi_arvalid(axi_arvalid), .s_axi_arready(axi_arready),
    .s_axi_rid(axi_rid), .s_axi_rdata(axi_rdata), .s_axi_rresp(axi_rresp), .s_axi_rlast(axi_rlast),
    .s_axi_rvalid(axi_rvalid), .s_axi_rready(axi_rready),
    .s_pcmd_valid(q_rd_valid), .s_pcmd_ready(q_rd_ready), .s_pcmd_addr(q_rd_addr), .s_pcmd_len(q_rd_len),
    .m_pdat_tdata(q_rdd_tdata), .m_pdat_tvalid(q_rdd_tvalid), .m_pdat_tready(q_rdd_tready),
    .s_fw_awaddr(ma_awaddr[17:0]), .s_fw_awvalid(ma_awvalid[2]), .s_fw_awready(ma_awready[2]),
    .s_fw_wdata(ma_wdata), .s_fw_wstrb(ma_wstrb), .s_fw_wvalid(ma_wvalid[2]), .s_fw_wready(ma_wready[2]),
    .s_fw_bresp(ma_bresp[2]), .s_fw_bvalid(ma_bvalid[2]), .s_fw_bready(ma_bready[2]),
    .s_fw_araddr(ma_araddr[17:0]), .s_fw_arvalid(ma_arvalid[2]), .s_fw_arready(ma_arready[2]),
    .s_fw_rdata(ma_rdata[2]), .s_fw_rresp(ma_rresp[2]), .s_fw_rvalid(ma_rvalid[2]), .s_fw_rready(ma_rready[2]),
    .wtap_valid(wtap_valid), .wtap_addr(wtap_addr), .wtap_data(wtap_data), .wtap_keep(wtap_keep),
    .wtap_last(wtap_last),
    .ev_wr_burst(ev_mem_wr), .ev_rd_burst(ev_mem_rd), .rd0_bytes_add(rd0_bytes_add)
);

// ---------------- self-test: data checkers ----------------
logic ev_wc_ok, ev_wc_mism, ev_wc_gap, ev_sc_ok, ev_sc_bad, ev_sc_mism, ev_sc_gap;
logic [15:0] wc_bytes, sc_bytes;
logic [63:0] wc_exp, wc_err, sc_exp, sc_err;
logic ev_imm_seq;
wire  logic [63:0] chk_base = {cfg[C_WC_BASE_HI], cfg[C_WC_BASE_LO]};

if (SELFTEST) begin : g_chk
    // memory writes (RDMA WRITE payload): every beat = pattern(its address)
    rsys_wchk #(.SEND_MODE(1'b0), .ADDR_IN(1'b1)) u_wchk (
        .clk(clk), .rst(chk_rst), .seed(cfg[C_WC_SEED]), .base(chk_base),
        .s_cmd_valid(1'b0), .s_cmd_addr('0), .s_cmd_len('0),
        .s_beat_valid(wtap_valid), .s_beat_addr(wtap_addr), .s_beat_data(wtap_data), .s_beat_keep(wtap_keep),
        .s_beat_last(wtap_last), .s_end_valid(wtap_valid && wtap_last), .s_end_ok(1'b1),
        .ev_ok(ev_wc_ok), .ev_bad(), .ev_mism(ev_wc_mism), .ev_gap(ev_wc_gap),
        .bytes_add(wc_bytes), .exp_addr(wc_exp), .err_addr(wc_err)
    );
    // SEND payload: self-describing pattern, judged on the commit verdict
    rsys_wchk #(.SEND_MODE(1'b1)) u_schk (
        .clk(clk), .rst(chk_rst), .seed(cfg[C_WC_SEED]), .base(chk_base),
        .s_cmd_valid(1'b0), .s_cmd_addr('0), .s_cmd_len('0),
        .s_beat_valid(send_tvalid), .s_beat_addr('0), .s_beat_data(send_tdata), .s_beat_keep(send_tkeep),
        .s_beat_last(send_tlast), .s_end_valid(send_commit_valid), .s_end_ok(send_commit_ok),
        .ev_ok(ev_sc_ok), .ev_bad(ev_sc_bad), .ev_mism(ev_sc_mism), .ev_gap(ev_sc_gap),
        .bytes_add(sc_bytes), .exp_addr(sc_exp), .err_addr(sc_err)
    );

    // receive completions: immediates must count up by one (WRITE/SEND with imm)
    logic [31:0] imm_last;
    logic        imm_have = 1'b0;
    always_ff @(posedge clk) begin
        ev_imm_seq <= 1'b0;
        if (rc_valid && rc_data[73]) begin
            if (imm_have && rc_data[31:0] != imm_last + 32'd1) ev_imm_seq <= 1'b1;
            imm_last <= rc_data[31:0];
            imm_have <= 1'b1;
        end
        if (chk_rst) imm_have <= 1'b0;
    end
end else begin : g_nochk
    always_ff @(posedge clk) begin
        ev_wc_ok   <= wtap_valid && wtap_last;
        ev_sc_ok   <= send_commit_valid && send_commit_ok;
        ev_sc_bad  <= send_commit_valid && !send_commit_ok;
        ev_imm_seq <= 1'b0;
    end
    assign ev_wc_mism = 1'b0; assign ev_wc_gap = 1'b0; assign ev_sc_mism = 1'b0; assign ev_sc_gap = 1'b0;
    assign wc_bytes = '0; assign sc_bytes = '0;
    assign wc_exp = '0; assign wc_err = '0; assign sc_exp = '0; assign sc_err = '0;
end

// ---------------- frame classification at the CMAC interfaces ----------------
// frame fields; a frame with an 802.1Q tag has them 4 bytes later
function automatic logic has_tag(input logic [511:0] d);
    return (d[12*8 +: 8] == 8'h81) && (d[13*8 +: 8] == 8'h00);
endfunction
function automatic logic [7:0] fbyte(input logic [511:0] d, input int i);
    return has_tag(d) ? d[(i+4)*8 +: 8] : d[i*8 +: 8];
endfunction
function automatic logic is_roce(input logic [511:0] d);
    return ({fbyte(d, 12), fbyte(d, 13)} == 16'h0800) && (fbyte(d, 23) == 8'd17) &&
           ({fbyte(d, 36), fbyte(d, 37)} == 16'd4791);
endfunction
function automatic logic [31:0] fr_info(input logic [511:0] d);
    return {fbyte(d, 51), fbyte(d, 52), fbyte(d, 53), fbyte(d, 42)};
endfunction
// [0] request [1] ACK [2] NAK [3] READ response [4] RoCE
function automatic logic [4:0] fr_class(input logic [511:0] d);
    logic [7:0] op, syn;
    logic r;
    op  = fbyte(d, 42);
    syn = fbyte(d, 54);
    r   = is_roce(d);
    return {r,
            r && (op[7:5] == 3'b000) && (op[4:0] >= 5'h0D) && (op[4:0] <= 5'h10),
            r && (op == 8'h11) && (syn[7:5] != 3'b000),
            r && (op == 8'h11) && (syn[7:5] == 3'b000),
            r && (op[7:6] == 2'b00) && (op[4:0] <= 5'h0C)};
endfunction

wire logic tx_sof = tx_tvalid && tx_tready && tx_first;
wire logic rx_sof = rx_tvalid && rx_first;
logic [4:0]  tx_cls = '0, rx_cls = '0;
logic        ev_tx_sof = 1'b0, ev_rx_sof = 1'b0, ev_tx_unf = 1'b0;
logic [15:0] tx_bytes_add, rx_bytes_add;
always_ff @(posedge clk) begin
    ev_tx_sof    <= tx_sof;
    ev_rx_sof    <= rx_sof;
    tx_cls       <= tx_sof ? fr_class(tx_tdata) : 5'd0;
    rx_cls       <= rx_sof ? fr_class(rx_tdata) : 5'd0;
    tx_bytes_add <= (tx_tvalid && tx_tready) ? 16'($countones(tx_tkeep)) : 16'd0;
    rx_bytes_add <= rx_tvalid ? 16'($countones(rx_tkeep)) : 16'd0;
    ev_tx_unf    <= !tx_first && !tx_tvalid;     // inside a frame, nothing offered
end

// ---------------- latency (self-test) ----------------
logic [31:0] lp_t_wr, lp_t_cpl, lat_min, lat_max, lat_cnt;
logic [31:0] lp_tx_t [4], lp_tx_i [4], lp_rx_t [4], lp_rx_i [4];
logic [9:0]  lp_flags;
logic [15:0] lat_add;
logic        ev_lat_ovf, lat_ovf;
if (SELFTEST) begin : g_lat
    rsys_lat #(.TRK_DEPTH(1024)) u_lat (
        .clk(clk), .rst(st_rst), .clr(stats_clr), .now(now),
        .arm(cfg_wr[C_LP_ARM]), .wr_fire(wg_fire), .cpl_fire(wc_valid), .cpl_lost(wc_data[31:24] != 8'd0),
        .tx_sof(tx_sof), .tx_info(fr_info(tx_tdata)), .rx_sof(rx_sof), .rx_info(fr_info(rx_tdata)),
        .t_wr(lp_t_wr), .t_cpl(lp_t_cpl), .tx_t(lp_tx_t), .tx_i(lp_tx_i), .rx_t(lp_rx_t), .rx_i(lp_rx_i),
        .flags(lp_flags), .lat_min(lat_min), .lat_max(lat_max), .lat_cnt(lat_cnt), .lat_add(lat_add),
        .ev_ovf(ev_lat_ovf), .ovf(lat_ovf)
    );
end else begin : g_nolat
    assign lp_t_wr = '0; assign lp_t_cpl = '0; assign lat_min = '0; assign lat_max = '0; assign lat_cnt = '0;
    for (genvar i = 0; i < 4; i++) begin : g_z
        assign lp_tx_t[i] = '0; assign lp_tx_i[i] = '0; assign lp_rx_t[i] = '0; assign lp_rx_i[i] = '0;
    end
    assign lp_flags = '0; assign lat_add = '0; assign ev_lat_ovf = 1'b0; assign lat_ovf = 1'b0;
end

// ---------------- statistics ----------------
logic [31:0] wc_last, rc_imm_last;
logic        ev_wc = 1'b0, ev_wc_err = 1'b0, ev_wc_lost = 1'b0, ev_rc = 1'b0, ev_rc_send = 1'b0;
always_ff @(posedge clk) begin
    ev_wc      <= wc_valid;
    ev_wc_err  <= wc_valid && (wc_data[31:24] != 8'd0);
    ev_wc_lost <= wc_valid && (wc_data[31:24] == 8'd1);
    ev_rc      <= rc_valid;
    ev_rc_send <= rc_valid && rc_data[72];
    if (wc_valid) wc_last <= {1'b0, wc_data[30:0]};
    if (rc_valid && rc_data[73]) rc_imm_last <= rc_data[31:0];
    if (regs_rst) begin
        wc_last     <= '0;
        rc_imm_last <= '0;
    end
end

always_comb begin
    ev = '0;
    ev[E_WG_ISSUED]      = wg_fire;
    ev[E_WC]             = ev_wc;
    ev[E_WC_ERR]         = ev_wc_err;
    ev[E_WC_LOST]        = ev_wc_lost;
    ev[E_RC]             = ev_rc;
    ev[E_RC_SEND]        = ev_rc_send;
    ev[E_RC_IMM_SEQ]     = ev_imm_seq;
    ev[E_WCHK_BURSTS]    = ev_wc_ok;
    ev[E_WC_MISM]        = ev_wc_mism;
    ev[E_WC_GAPS]        = ev_wc_gap;
    ev[E_SC_OK]          = ev_sc_ok;
    ev[E_SC_BAD]         = ev_sc_bad;
    ev[E_SC_MISM]        = ev_sc_mism;
    ev[E_SC_GAPS]        = ev_sc_gap;
    ev[E_INJ_SEEN]       = ev_inj_seen;
    ev[E_INJ_DONE]       = ev_inj_done;
    ev[E_RINJ_SEEN]      = ev_rinj_seen;
    ev[E_RINJ_DONE]      = ev_rinj_done;
    ev[E_RAW_SENT]       = ev_raw_sent;
    ev[E_CAP_DONE]       = ev_cap;
    ev[E_LAT_OVF]        = ev_lat_ovf;
    ev[E_TX_UNDERRUN]    = ev_tx_unf;
    ev[E_MAC_TX_UNF]     = ev_tx_unf_mac;
    ev[E_MAC_TX_BAD_FCS] = ev_tx_bad_fcs;
    ev[E_MAC_ALIGN_LOST] = ev_align_lost;
    ev[E_WCQ_OVF]        = ev_wcq_ovf;
    ev[E_RCQ_OVF]        = ev_rcq_ovf;
    ev[E_WQ_POSTED]      = ev_wq_post;
    ev[E_WQ_DROP]        = ev_wq_drop;
    ev[E_MEM_WR_BURSTS]  = ev_mem_wr;
    ev[E_MEM_RD_BURSTS]  = ev_mem_rd;
    ev[E_TX_FRAMES]      = ev_tx_sof;
    ev[E_RX_FRAMES]      = ev_rx_sof;
    ev[E_TX_OP_REQ]      = tx_cls[0];
    ev[E_TX_OP_ACK]      = tx_cls[1];
    ev[E_TX_OP_NAK]      = tx_cls[2];
    ev[E_TX_OP_RDRSP]    = tx_cls[3];
    ev[E_RX_OP_REQ]      = rx_cls[0];
    ev[E_RX_OP_ACK]      = rx_cls[1];
    ev[E_RX_OP_NAK]      = rx_cls[2];
    ev[E_RX_OP_RDRSP]    = rx_cls[3];
    ev[E_RX_ROCE]        = rx_cls[4];
    ev[E_TX_ROCE]        = tx_cls[4];
    ev[E_CRX_FRAMES]     = ev_crx_frame;
    ev[E_CRX_DROP]       = ev_crx_drop;
    ev[E_CRX_LONG]       = ev_crx_long;
    ev[E_CRX_FILT]       = ev_crx_filt;
    ev[E_HP_FRAMES]      = ev_h_frame;

    for (int i = 0; i < NBC; i++) bc_add[i] = '0;
    bc_add[B_CYCLES]          = 16'd1;
    bc_add[B_WG_BYTES]        = wg_fire ? 16'(g_wr_len) : 16'd0;
    bc_add[B_WC_BYTES]        = wc_bytes;
    bc_add[B_SC_BYTES]        = sc_bytes;
    bc_add[B_RD_BYTES]        = rd0_bytes_add;
    bc_add[B_LAT_SUM]         = lat_add;
    bc_add[B_TX_BYTES]        = tx_bytes_add;
    bc_add[B_RX_BYTES]        = rx_bytes_add;
    bc_add[B_MAC_RX_PKTS]     = 16'(m_rx_pkts);
    bc_add[B_MAC_RX_BAD_FCS]  = 16'(m_rx_bad_fcs);
    bc_add[B_MAC_RX_BAD_CODE] = 16'(m_rx_bad_code);
    bc_add[B_MAC_TX_PKTS]     = 16'(m_tx_pkts);
    bc_add[B_HP_BYTES]        = h_bytes_add;
    bc_add[B_HP_IQ_STALL]     = {15'd0, ev_h_stall};
    bc_add[B_IQ_CLIP]         = {15'd0, ev_iq_clip | ev_bm_clip};

    for (int i = 0; i < NSV; i++) sv[i] = '0;
    sv[S_ID]          = 32'h52535953;   // "RSYS"
    sv[S_SYS_CFG]     = {16'd0, 8'($clog2(MEM_BYTES)), 5'd0, PAY_EN, SELFTEST, SELFTEST};
    sv[S_STATUS]      = {25'd0, irq, rinj_armed, inj_armed, lat_ovf, cap_status[0], wg_running, st_rst};
    sv[S_MAC_STAT]    = {20'd0, mac_st};
    sv[S_WQ_STATUS]   = {14'd0, q_pay_busy, wq_full, 7'd0, wq_level};
    sv[S_WCQ]         = wcq_head;
    sv[S_RCQ]         = rcq_head;
    sv[S_RCQ_IMM]     = rcq_imm;
    sv[S_RCQ_LEN]     = rcq_len;
    sv[S_CQ_LEVEL]    = {8'd0, rcq_level, 8'd0, wcq_level};
    sv[S_WG_ISSUED]   = wg_issued;
    sv[S_INJ_LFSR]    = inj_lfsr;
    sv[S_CAP_STATUS]  = cap_status;
    sv[S_WC_LAST]     = wc_last;
    sv[S_RC_IMM_LAST] = rc_imm_last;
    sv[S_WC_EXP_LO]   = wc_exp[31:0];
    sv[S_WC_EXP_HI]   = wc_exp[63:32];
    sv[S_WC_ERR_LO]   = wc_err[31:0];
    sv[S_WC_ERR_HI]   = wc_err[63:32];
    sv[S_SC_EXP_LO]   = sc_exp[31:0];
    sv[S_SC_EXP_HI]   = sc_exp[63:32];
    sv[S_SC_ERR_LO]   = sc_err[31:0];
    sv[S_SC_ERR_HI]   = sc_err[63:32];
    sv[S_LAT_MIN]     = lat_min;
    sv[S_LAT_MAX]     = lat_max;
    sv[S_LAT_CNT]     = lat_cnt;
    sv[S_LP_FLAGS]    = {22'd0, lp_flags};
    sv[S_LP_T_WR]     = lp_t_wr;
    sv[S_LP_T_CPL]    = lp_t_cpl;
    sv[S_CRX_STATUS]  = {4'd0, crx_head_len, 8'd0, crx_level};
    sv[S_HP_STATUS]   = {28'd0, dna_valid, raw_busy, iq_pending, h_running};
    sv[S_HP_FRAMES]   = h_frames;
    sv[S_HP_PAGE]     = {h_fnum, 4'd0, h_page};
    sv[S_DNA0]        = dna[31:0];
    sv[S_DNA1]        = dna[63:32];
    sv[S_DNA2]        = dna[95:64];
    sv[S_TIME_S]      = t_s[31:0];
    sv[S_TIME_NS]     = {2'd0, t_ns};
    sv[S_BM_STATUS]   = {16'd0, BM_MODEL_VERSION, 5'd0, bm_clipped, bm_enable, bm_pending};
    sv[S_BM_APPLIED_ID]    = bm_aid;
    sv[S_BM_APPLIED_FRAME] = bm_aframe;
    sv[S_BM_APPLIES]  = bm_applies;
    sv[S_BM_CAPS]     = BM_CAPS;
    for (int i = 0; i < 4; i++) begin
        sv[S_LP_TX_T0 + i] = lp_tx_t[i];
        sv[S_LP_TX_I0 + i] = lp_tx_i[i];
        sv[S_LP_RX_T0 + i] = lp_rx_t[i];
        sv[S_LP_RX_I0 + i] = lp_rx_i[i];
    end
end

endmodule

`resetall
