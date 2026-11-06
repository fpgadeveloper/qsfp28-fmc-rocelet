// SPDX-License-Identifier: MIT
//
// rocelet_sys - the rocelet RoCE v2 engine in the qsfp28-fmc-rocelet reference design:
// everything between the MAC's AXI-Streams and the CPU's AXI-Lite port, in the MAC user
// clock (KCU116: 100G CMAC, 512 bits at 322.265625 MHz; ZCU106: omac_10g, 64 bits at
// 156.25 MHz). The MAC connects through a generic boundary (mac_ctl / mac_pz / mac_addr
// out, mac_stat / mac_ev / mac_pause in: docs/source/zynqmp_hw.md "MAC boundary"); a small
// per-MAC adapter in the block design maps it onto the MAC's own ports (Vivado/src/hdl/mac).
// Below 512 bits (MAC_WIDTH 64 / 128 / 256) rocelet's own width converters
// (rocelet_rx_upsize / rocelet_tx_downsize) sit at this module's MAC ports, so the engine
// and every self-test tap, injector and frame classifier here keep working on 64-byte beats.
//
//   MAC RX -> [upsize] -> [u_rinj] -> u_rl (rocelet_top: MAC glue, ARP/ICMP, engine) -> [u_inj, skid] -> [downsize] -> MAC TX
//   u_rl memory master (AXI4, 512 bit) -> [u_dec, DDR_EN] -> u_mem: on-chip memory window
//       (URAM), also mapped into the CPU's address space; with DDR_EN, local addresses with
//       bit 39 set are an offset into a PS DDR region (C_DDR_BASE_* / C_DDR_SIZE) reached
//       on m_axi_ddrw_* / m_axi_ddrr_* (rsys_axi_dec; outside the region: null target);
//       DDR_PORTS = 2: address-interleaved over two masters per direction (rsys_axi_ilv,
//       512-byte granules: port = physical address bit 9; m_axi_ddrw1_* / m_axi_ddrr1_*)
//   work requests: u_wrq (firmware WR queue, payload read from u_mem, completion
//       queues) and, with SELFTEST, u_wg (line-rate WR generator, pattern payload)
//   u_raw: firmware frames to the engine's other-traffic port, and a capture
//       buffer at the MAC interfaces (or on the other-traffic output)
//   u_odma (ODMA_EN): the netdev DMA channel, other-traffic frames to / from the PS through
//       an AXI DMA (dma_clk); its TX shares the other-traffic input with u_raw (frame-atomic)
//   MAC: static control (mac_ctl / mac_pz / mac_addr) from system registers, link status
//       and a few fabric counters
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
    parameter int          PAT_BIT      = 40,
    // MAC and clock
    parameter int          MAC_WIDTH    = 512,     // MAC AXI-Stream width: 64, 128, 256, 512
    parameter int          CLK_MHZ      = 322,     // engine clock (rounded): TICK_DIV reset value
    parameter int          CLK_KHZ      = 322266,  // engine clock in kHz (rocelet CLK_KHZ register)
    parameter int          LINK_GBPS    = 100,     // link speed (PAUSE quantum, CAPS)
    parameter longint      CLK_HZ       = 322265625, // exact clock for the producer time base
    // ZynqMP options
    parameter bit          DDR_EN       = 1'b0,    // PS DDR memory window (m_axi_ddrw / m_axi_ddrr)
    parameter int          DDR_BIT      = 39,      // local address bit that selects PS DDR
    parameter int          DDR_PORTS    = 1,       // PS DDR masters per direction: 1, or 2 (interleaved)
    parameter int          ILV_BIT      = 9,       // DDR_PORTS 2: interleave granule 2^ILV_BIT bytes
    parameter bit          ODMA_EN      = 1'b0     // netdev DMA channel (m_axis_orx / s_axis_otx)
) (
    input  wire logic          clk,
    input  wire logic          gen_clk,        // 200 MHz: IQ16 / beam generators, device DNA (asynchronous to clk)
    input  wire logic          sys_rst,        // system reset (any clock; synchronised here)
    output wire logic          irq,            // engine: a QP error is latched
    output logic      [7:0]    evt,            // event levels for an interrupt controller (always-on block):
                                               // [0] engine irq [1] control-plane RX FIFO not empty
                                               // [2] work completion queued [3] receive completion queued
                                               // [4] DMA channel RX pending [5] raw TX busy

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

    // MAC AXI-Streams (MAC_WIDTH bits, clk); RX has no tready
    input  wire logic [MAC_WIDTH-1:0]   rx_tdata,
    input  wire logic [MAC_WIDTH/8-1:0] rx_tkeep,
    input  wire logic          rx_tvalid,
    input  wire logic          rx_tlast,
    input  wire logic          rx_tuser,

    output wire logic [MAC_WIDTH-1:0]   tx_tdata,
    output wire logic [MAC_WIDTH/8-1:0] tx_tkeep,
    output wire logic          tx_tvalid,
    input  wire logic          tx_tready,
    output wire logic          tx_tlast,
    output wire logic          tx_tuser,

    // generic MAC boundary (clk). mac_ctl: [0] rx enable [1] tx enable [2] send RFI [3] send LFI
    // [4] send idle [5] FEC [6] receive PAUSE [7] send PAUSE [10:8] GT loopback (0 off,
    // 1 near-end PCS, 2 near-end PMA) [16] PAUSE request of the engine (level, unregistered);
    // mac_pz: [15:0] PAUSE quanta sent [31:16] refresh; mac_addr: the station MAC (byte 0 on the
    // wire = [7:0]). mac_stat: [0] RX aligned / block lock [1] RX status [2] local fault
    // [3] remote fault [4] received local fault [5] internal local fault [6] hi BER [7] misaligned
    // [8] FEC hi SER [9] FEC lanes aligned [10] RX in reset [11] TX in reset [12] link up
    // [13] TX PAUSE active. mac_ev (increments per clock): [2:0] RX frames [5:3] RX bad FCS
    // [8:6] RX bad code [9] TX frames [10] TX bad FCS [11] TX underflow [12] FEC corrected
    // [13] FEC uncorrectable [14] PAUSE frame received [15] PAUSE frame sent.
    // mac_pause: [17] received PAUSE in force (level) [16] received PAUSE valid [15:0] its quanta
    output logic      [31:0]   mac_ctl,
    output logic      [31:0]   mac_pz,
    output logic      [47:0]   mac_addr,
    input  wire logic [15:0]   mac_stat,
    input  wire logic [15:0]   mac_ev,
    input  wire logic [17:0]   mac_pause,

    // PS DDR window (DDR_EN): write-only and read-only AXI4 masters, 512 bits, clk
    output wire logic [1:0]    m_axi_ddrw_awid,
    output wire logic [39:0]   m_axi_ddrw_awaddr,
    output wire logic [7:0]    m_axi_ddrw_awlen,
    output wire logic [2:0]    m_axi_ddrw_awsize,
    output wire logic [1:0]    m_axi_ddrw_awburst,
    output wire logic [3:0]    m_axi_ddrw_awcache,
    output wire logic [2:0]    m_axi_ddrw_awprot,
    output wire logic          m_axi_ddrw_awvalid,
    input  wire logic          m_axi_ddrw_awready,
    output wire logic [511:0]  m_axi_ddrw_wdata,
    output wire logic [63:0]   m_axi_ddrw_wstrb,
    output wire logic          m_axi_ddrw_wlast,
    output wire logic          m_axi_ddrw_wvalid,
    input  wire logic          m_axi_ddrw_wready,
    input  wire logic [1:0]    m_axi_ddrw_bid,
    input  wire logic [1:0]    m_axi_ddrw_bresp,
    input  wire logic          m_axi_ddrw_bvalid,
    output wire logic          m_axi_ddrw_bready,
    output wire logic [1:0]    m_axi_ddrr_arid,
    output wire logic [39:0]   m_axi_ddrr_araddr,
    output wire logic [7:0]    m_axi_ddrr_arlen,
    output wire logic [2:0]    m_axi_ddrr_arsize,
    output wire logic [1:0]    m_axi_ddrr_arburst,
    output wire logic [3:0]    m_axi_ddrr_arcache,
    output wire logic [2:0]    m_axi_ddrr_arprot,
    output wire logic          m_axi_ddrr_arvalid,
    input  wire logic          m_axi_ddrr_arready,
    input  wire logic [1:0]    m_axi_ddrr_rid,
    input  wire logic [511:0]  m_axi_ddrr_rdata,
    input  wire logic [1:0]    m_axi_ddrr_rresp,
    input  wire logic          m_axi_ddrr_rlast,
    input  wire logic          m_axi_ddrr_rvalid,
    output wire logic          m_axi_ddrr_rready,

    // PS DDR window, second port per direction (DDR_EN and DDR_PORTS = 2; else idle)
    output wire logic [1:0]    m_axi_ddrw1_awid,
    output wire logic [39:0]   m_axi_ddrw1_awaddr,
    output wire logic [7:0]    m_axi_ddrw1_awlen,
    output wire logic [2:0]    m_axi_ddrw1_awsize,
    output wire logic [1:0]    m_axi_ddrw1_awburst,
    output wire logic [3:0]    m_axi_ddrw1_awcache,
    output wire logic [2:0]    m_axi_ddrw1_awprot,
    output wire logic          m_axi_ddrw1_awvalid,
    input  wire logic          m_axi_ddrw1_awready,
    output wire logic [511:0]  m_axi_ddrw1_wdata,
    output wire logic [63:0]   m_axi_ddrw1_wstrb,
    output wire logic          m_axi_ddrw1_wlast,
    output wire logic          m_axi_ddrw1_wvalid,
    input  wire logic          m_axi_ddrw1_wready,
    input  wire logic [1:0]    m_axi_ddrw1_bid,
    input  wire logic [1:0]    m_axi_ddrw1_bresp,
    input  wire logic          m_axi_ddrw1_bvalid,
    output wire logic          m_axi_ddrw1_bready,
    output wire logic [1:0]    m_axi_ddrr1_arid,
    output wire logic [39:0]   m_axi_ddrr1_araddr,
    output wire logic [7:0]    m_axi_ddrr1_arlen,
    output wire logic [2:0]    m_axi_ddrr1_arsize,
    output wire logic [1:0]    m_axi_ddrr1_arburst,
    output wire logic [3:0]    m_axi_ddrr1_arcache,
    output wire logic [2:0]    m_axi_ddrr1_arprot,
    output wire logic          m_axi_ddrr1_arvalid,
    input  wire logic          m_axi_ddrr1_arready,
    input  wire logic [1:0]    m_axi_ddrr1_rid,
    input  wire logic [511:0]  m_axi_ddrr1_rdata,
    input  wire logic [1:0]    m_axi_ddrr1_rresp,
    input  wire logic          m_axi_ddrr1_rlast,
    input  wire logic          m_axi_ddrr1_rvalid,
    output wire logic          m_axi_ddrr1_rready,

    // netdev DMA channel (ODMA_EN), dma_clk: other-traffic frames to / from the PS
    input  wire logic          dma_clk,
    output wire logic [511:0]  m_axis_orx_tdata,
    output wire logic [63:0]   m_axis_orx_tkeep,
    output wire logic          m_axis_orx_tvalid,
    input  wire logic          m_axis_orx_tready,
    output wire logic          m_axis_orx_tlast,
    input  wire logic [511:0]  s_axis_otx_tdata,
    input  wire logic [63:0]   s_axis_otx_tkeep,
    input  wire logic          s_axis_otx_tvalid,
    output wire logic          s_axis_otx_tready,
    input  wire logic          s_axis_otx_tlast
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

// ---------------- MAC static control, status, fabric counters ----------------
wire logic pz_tx_req;                     // the engine's PAUSE request (level)
always_ff @(posedge clk) begin
    mac_ctl[15:0]  <= {5'd0, cfg[C_MAC_CTL][10:0]};
    mac_pz         <= cfg[C_MAC_PZ];
    mac_addr       <= {cfg[C_MAC_ADDR_HI][15:0], cfg[C_MAC_ADDR_LO]};
end
always_comb mac_ctl[31:16] = {15'd0, pz_tx_req};

wire logic mac_rx_rst = mac_stat[10];
wire logic mac_tx_rst = mac_stat[11];
logic [13:0] mac_st, mac_st_d;
logic        ev_tx_unf_mac, ev_tx_bad_fcs, ev_align_lost;
logic [2:0]  m_rx_pkts, m_rx_bad_fcs, m_rx_bad_code;
logic        m_tx_pkts;
logic        link_ok = 1'b0;
// link state for the requester (rocelet link_up): the adapter's mac_stat[12], e.g. CMAC
// aligned & ~local fault & ~remote fault, omac stat_link_up
always_ff @(posedge clk) link_ok <= mac_stat[12];

always_ff @(posedge clk) begin
    mac_st        <= mac_stat[13:0];
    mac_st_d      <= mac_st;
    ev_tx_unf_mac <= mac_ev[11];
    ev_tx_bad_fcs <= mac_ev[10];
    ev_align_lost <= mac_st_d[0] && !mac_st[0];
    m_rx_pkts     <= mac_ev[2:0];
    m_rx_bad_fcs  <= mac_ev[5:3];
    m_rx_bad_code <= mac_ev[8:6];
    m_tx_pkts     <= mac_ev[9];
end

// ---------------- MAC width conversion (rocelet's converters; none at 512 bits) ----------------
wire logic [511:0] w_rx_tdata, w_tx_tdata;
wire logic [63:0]  w_rx_tkeep, w_tx_tkeep;
wire logic         w_rx_tvalid, w_rx_tlast, w_rx_tuser, w_tx_tvalid, w_tx_tready, w_tx_tlast;
if (MAC_WIDTH == 512) begin : g_w512
    assign w_rx_tdata = rx_tdata; assign w_rx_tkeep = rx_tkeep; assign w_rx_tvalid = rx_tvalid;
    assign w_rx_tlast = rx_tlast; assign w_rx_tuser = rx_tuser;
    assign tx_tdata = w_tx_tdata; assign tx_tkeep = w_tx_tkeep; assign tx_tvalid = w_tx_tvalid;
    assign tx_tlast = w_tx_tlast; assign w_tx_tready = tx_tready;
end else begin : g_wconv
    rocelet_rx_upsize #(.MAC_W(MAC_WIDTH)) u_rx_up (
        .clk(clk), .rst(eng_rst), .abort(mac_rx_rst),
        .s_tdata(rx_tdata), .s_tkeep(rx_tkeep), .s_tvalid(rx_tvalid), .s_tlast(rx_tlast), .s_tuser(rx_tuser),
        .m_tdata(w_rx_tdata), .m_tkeep(w_rx_tkeep), .m_tvalid(w_rx_tvalid), .m_tlast(w_rx_tlast), .m_tuser(w_rx_tuser)
    );
    rocelet_tx_downsize #(.MAC_W(MAC_WIDTH)) u_tx_dn (
        .clk(clk), .rst(eng_rst),
        .s_tdata(w_tx_tdata), .s_tkeep(w_tx_tkeep), .s_tvalid(w_tx_tvalid), .s_tready(w_tx_tready), .s_tlast(w_tx_tlast),
        .m_tdata(tx_tdata), .m_tkeep(tx_tkeep), .m_tvalid(tx_tvalid), .m_tready(tx_tready), .m_tlast(tx_tlast),
        .ev_gap()
    );
end

// ---------------- RX: MAC -> [RX fault injector] -> engine ----------------
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
        .s_axis_tdata(w_rx_tdata), .s_axis_tkeep(w_rx_tkeep), .s_axis_tvalid(w_rx_tvalid), .s_axis_tready(),
        .s_axis_tlast(w_rx_tlast), .s_axis_tuser(w_rx_tuser),
        .m_axis_tdata(ri_tdata), .m_axis_tkeep(ri_tkeep), .m_axis_tvalid(ri_tvalid), .m_axis_tready(1'b1),
        .m_axis_tlast(ri_tlast), .m_axis_tuser(ri_tuser),
        .ev_seen(ev_rinj_seen), .ev_done(ev_rinj_done), .armed(rinj_armed), .lfsr_o()
    );
end else begin : g_norinj
    assign ri_tdata = w_rx_tdata; assign ri_tkeep = w_rx_tkeep; assign ri_tvalid = w_rx_tvalid;
    assign ri_tlast = w_rx_tlast; assign ri_tuser = w_rx_tuser;
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
    .MEM_RD_BUF(DDR_EN ? 512 : 256),
    // the engine is always 512 bits wide here (the converters sit at this module's MAC ports, so
    // the self-test taps see 64-byte beats): its CAPS register reports MAC_WIDTH 512; the MAC's
    // own width is in S_SYS_CFG and in the always-on block's CAPS (ZynqMP)
    .CLK_MHZ(CLK_MHZ), .CLK_KHZ(CLK_KHZ), .LINK_GBPS(LINK_GBPS), .MAC_WIDTH(512)
) u_rl (
    .clk(clk), .rst(eng_rst), .irq(irq),
    .mac_rx_reset(mac_rx_rst), .mac_tx_reset(mac_tx_rst), .mac_rx_status(mac_stat[0]),
    // link state for the requester's ACK-timeout hold (rocelet v0.2): MAC aligned / block-locked
    // and neither a local fault (no valid signal received) nor a remote fault (the partner does
    // not receive ours) - the peer cannot answer in either case (the MAC adapter's mac_stat[12]).
    // Registered in clk; rocelet synchronises it with two flip-flops anyway.
    // Fault toggles while the link comes up only restart LINK_GRACE.
    .link_up(link_ok),
    .s_axis_rx_tdata(ri_tdata), .s_axis_rx_tkeep(ri_tkeep), .s_axis_rx_tvalid(ri_tvalid),
    .s_axis_rx_tlast(ri_tlast), .s_axis_rx_tuser(ri_tuser),
    .m_axis_tx_tdata(e_tdata), .m_axis_tx_tkeep(e_tkeep), .m_axis_tx_tvalid(e_tvalid),
    .m_axis_tx_tready(e_tready), .m_axis_tx_tlast(e_tlast), .m_axis_tx_tuser(),
    .mac_pause_hold(mac_pause[17]), .mac_pause_valid(mac_pause[16]), .mac_pause_quanta(mac_pause[15:0]),
    .mac_pause_req(pz_tx_req), .mac_pause_rx_frame(mac_ev[14]), .mac_pause_tx_frame(mac_ev[15]),
    .mac_fec_corr_inc(mac_ev[12]), .mac_fec_uncorr_inc(mac_ev[13]),
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

// ---------------- TX: engine -> [TX fault injector] -> MAC ----------------
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
        .m_axis_tdata(w_tx_tdata), .m_axis_tkeep(w_tx_tkeep), .m_axis_tvalid(w_tx_tvalid), .m_axis_tready(w_tx_tready),
        .m_axis_tlast(w_tx_tlast)
    );
end else begin : g_noinj
    assign w_tx_tdata = e_tdata; assign w_tx_tkeep = e_tkeep; assign w_tx_tvalid = e_tvalid;
    assign e_tready = w_tx_tready; assign w_tx_tlast = e_tlast;
    assign ev_inj_seen = 1'b0; assign ev_inj_done = 1'b0; assign inj_armed = 1'b0; assign inj_lfsr = '0;
end
assign tx_tuser = 1'b0;

// ---------------- firmware frames: raw TX, capture ----------------
logic        rx_first = 1'b1, tx_first = 1'b1, oth_first = 1'b1;
logic [15:0] tx_idle = '0;
always_ff @(posedge clk) begin
    if (w_rx_tvalid) rx_first <= w_rx_tlast;
    if (oth_rx_tvalid) oth_first <= oth_rx_tlast;
    if (w_tx_tvalid && w_tx_tready) tx_first <= w_tx_tlast;
    if (w_tx_tvalid && w_tx_tready) tx_idle <= '0;
    else if (tx_idle != 16'hFFFF) tx_idle <= tx_idle + 16'd1;
end
wire logic cap_oth = cfg[C_CAP_CTRL][4];
logic ev_raw_sent, ev_cap;
wire logic [511:0] raw_tx_tdata;
wire logic [63:0]  raw_tx_tkeep;
wire logic         raw_tx_tvalid, raw_tx_tready, raw_tx_tlast;
wire logic [31:0] cap_status;
wire logic raw_busy;
rsys_raw u_raw (
    .clk(clk), .rst(st_rst),
    .wr_en(raw_we), .wr_addr(raw_waddr), .wr_data(raw_wdata),
    .send(cfg_wr[C_RAW_SEND]), .send_len(cfg[C_RAW_LEN][11:0]),
    .m_axis_tdata(raw_tx_tdata), .m_axis_tkeep(raw_tx_tkeep), .m_axis_tvalid(raw_tx_tvalid),
    .m_axis_tready(raw_tx_tready), .m_axis_tlast(raw_tx_tlast), .ev_sent(ev_raw_sent), .busy(raw_busy),
    .cap_arm(cfg_wr[C_CAP_CTRL] && cfg[C_CAP_CTRL][0]), .cap_mode(cfg[C_CAP_CTRL][2:1]),
    .cap_tx(cfg[C_CAP_CTRL][3]), .ttap_valid(w_tx_tvalid && w_tx_tready), .ttap_first(tx_first),
    .ttap_data(w_tx_tdata), .ttap_keep(w_tx_tkeep), .ttap_last(w_tx_tlast), .ttap_idle(tx_idle),
    .cap_match(cfg[C_CAP_MATCH]),
    .tap_valid(cap_oth ? oth_rx_tvalid : w_rx_tvalid), .tap_first(cap_oth ? oth_first : rx_first),
    .tap_data(cap_oth ? oth_rx_tdata : w_rx_tdata), .tap_keep(cap_oth ? oth_rx_tkeep : w_rx_tkeep),
    .tap_last(cap_oth ? oth_rx_tlast : w_rx_tlast),
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

// ---------------- netdev DMA channel (ODMA_EN) and the other-traffic TX arbiter ----------------
// Frames to the engine's other-traffic input come from the firmware's raw TX buffer (u_raw) or
// from the PS (u_odma); the arbiter switches only between frames (both sources hold whole
// frames, so a granted frame streams without gaps).
wire logic [511:0] od_tx_tdata;
wire logic [63:0]  od_tx_tkeep;
wire logic         od_tx_tvalid, od_tx_tready, od_tx_tlast;
logic              ev_od_rx, ev_od_drop, ev_od_tx;
wire logic         od_pending;
if (ODMA_EN) begin : g_odma
    rsys_odma u_odma (
        .clk(clk), .rst(st_rst), .rx_en(cfg[C_ODMA_CTRL][0]),
        .s_valid(oth_rx_tvalid), .s_first(oth_first), .s_data(oth_rx_tdata), .s_keep(oth_rx_tkeep),
        .s_last(oth_rx_tlast),
        .dma_clk(dma_clk),
        .m_axis_tdata(m_axis_orx_tdata), .m_axis_tkeep(m_axis_orx_tkeep), .m_axis_tvalid(m_axis_orx_tvalid),
        .m_axis_tready(m_axis_orx_tready), .m_axis_tlast(m_axis_orx_tlast),
        .s_axis_tdata(s_axis_otx_tdata), .s_axis_tkeep(s_axis_otx_tkeep), .s_axis_tvalid(s_axis_otx_tvalid),
        .s_axis_tready(s_axis_otx_tready), .s_axis_tlast(s_axis_otx_tlast),
        .m_tx_tdata(od_tx_tdata), .m_tx_tkeep(od_tx_tkeep), .m_tx_tvalid(od_tx_tvalid),
        .m_tx_tready(od_tx_tready), .m_tx_tlast(od_tx_tlast),
        .ev_rx_frame(ev_od_rx), .ev_rx_drop(ev_od_drop), .ev_tx_frame(ev_od_tx), .rx_pending(od_pending)
    );
end else begin : g_noodma
    assign m_axis_orx_tdata = '0; assign m_axis_orx_tkeep = '0; assign m_axis_orx_tvalid = 1'b0;
    assign m_axis_orx_tlast = 1'b0; assign s_axis_otx_tready = 1'b0;
    assign od_tx_tdata = '0; assign od_tx_tkeep = '0; assign od_tx_tvalid = 1'b0; assign od_tx_tlast = 1'b0;
    assign od_pending = 1'b0;
    always_ff @(posedge clk) begin ev_od_rx <= 1'b0; ev_od_drop <= 1'b0; ev_od_tx <= 1'b0; end
end

logic ta_busy = 1'b0, ta_sel = 1'b0;     // a frame is granted; 0 raw buffer, 1 DMA channel
wire  logic ta_pick = raw_tx_tvalid ? 1'b0 : 1'b1;
wire  logic ta_cur  = ta_busy ? ta_sel : ta_pick;
assign oth_tx_tdata  = ta_cur ? od_tx_tdata  : raw_tx_tdata;
assign oth_tx_tkeep  = ta_cur ? od_tx_tkeep  : raw_tx_tkeep;
assign oth_tx_tvalid = ta_cur ? od_tx_tvalid : raw_tx_tvalid;
assign oth_tx_tlast  = ta_cur ? od_tx_tlast  : raw_tx_tlast;
assign raw_tx_tready = oth_tx_tready && !ta_cur;
assign od_tx_tready  = oth_tx_tready &&  ta_cur;
always_ff @(posedge clk) begin
    if (oth_tx_tvalid && oth_tx_tready) begin
        ta_busy <= !oth_tx_tlast;
        ta_sel  <= ta_cur;
    end
    if (st_rst) ta_busy <= 1'b0;
end

// ---------------- HSB producer: time, device DNA, IQ16 source, frame producer ----------------
wire logic [47:0] t_s;
wire logic [29:0] t_ns;
rsys_ptime #(.CLK_HZ(CLK_HZ)) u_ptime (.clk(clk), .rst(regs_rst), .t_s(t_s), .t_ns(t_ns));

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

// the producer's sample-source boundary (s_axis_src) and the source mux
wire logic          src_tvalid, src_tready, src_enable, src_start;
wire logic [511:0]  src_tdata;
wire logic [63:0]   src_tuser;
wire logic [1:0]    src_sel;
rsys_src_mux u_smux (
    .src_sel(src_sel), .src_enable(src_enable), .src_start(src_start),
    .m_axis_src_tvalid(src_tvalid), .m_axis_src_tdata(src_tdata), .m_axis_src_tuser(src_tuser),
    .m_axis_src_tready(src_tready),
    .iq_valid(iq_valid), .iq_data(iq_data), .iq_pop(iq_pop), .iq_enable(iq_enable), .iq_start(iq_start),
    .bm_valid(bm_valid), .bm_data(bm_data), .bm_sid(bm_sid), .bm_sframe(bm_sframe), .bm_pop(bm_pop),
    .bm_enable(bm_enable), .bm_start(bm_start)
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
    .s_axis_src_tvalid(src_tvalid), .s_axis_src_tdata(src_tdata), .s_axis_src_tuser(src_tuser),
    .s_axis_src_tready(src_tready), .src_sel(src_sel), .src_enable(src_enable), .src_start(src_start),
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

// ---------------- memory window (+ PS DDR window, DDR_EN) ----------------
wire logic [ID_W-1:0] mu_awid, mu_bid, mu_arid, mu_rid;
wire logic [63:0]   mu_awaddr, mu_araddr;
wire logic [7:0]    mu_awlen, mu_arlen;
wire logic          mu_awvalid, mu_awready, mu_wlast, mu_wvalid, mu_wready, mu_bvalid, mu_bready;
wire logic          mu_arvalid, mu_arready, mu_rlast, mu_rvalid, mu_rready;
wire logic [511:0]  mu_wdata, mu_rdata;
wire logic [63:0]   mu_wstrb;
wire logic [1:0]    mu_bresp, mu_rresp;
logic               ev_ddr_wr, ev_ddr_rd, ev_ddr_oor;
if (DDR_EN) begin : g_ddr
    // the decoder's PS DDR masters (one per direction)
    wire logic [ID_W-1:0] dw_awid, dw_bid, dr_arid, dr_rid;
    wire logic [39:0]     dw_awaddr, dr_araddr;
    wire logic [7:0]      dw_awlen, dr_arlen;
    wire logic            dw_awvalid, dw_awready, dw_wlast, dw_wvalid, dw_wready, dw_bvalid, dw_bready;
    wire logic            dr_arvalid, dr_arready, dr_rlast, dr_rvalid, dr_rready;
    wire logic [511:0]    dw_wdata, dr_rdata;
    wire logic [63:0]     dw_wstrb;
    wire logic [1:0]      dw_bresp, dr_rresp;
    rsys_axi_dec #(.ID_W(ID_W), .ADDR_W(64), .DDR_BIT(DDR_BIT), .PAT_BIT(PAT_BIT), .DDR_AW(40)) u_dec (
        .clk(clk), .rst(regs_rst),
        .win_base({cfg[C_DDR_BASE_HI][7:0], cfg[C_DDR_BASE_LO][31:12], 12'd0}),
        .win_size({8'd0, cfg[C_DDR_SIZE][31:12], 12'd0}),
        .s_awid(axi_awid), .s_awaddr(axi_awaddr), .s_awlen(axi_awlen), .s_awvalid(axi_awvalid), .s_awready(axi_awready),
        .s_wdata(axi_wdata), .s_wstrb(axi_wstrb), .s_wlast(axi_wlast), .s_wvalid(axi_wvalid), .s_wready(axi_wready),
        .s_bid(axi_bid), .s_bresp(axi_bresp), .s_bvalid(axi_bvalid), .s_bready(axi_bready),
        .s_arid(axi_arid), .s_araddr(axi_araddr), .s_arlen(axi_arlen), .s_arvalid(axi_arvalid), .s_arready(axi_arready),
        .s_rid(axi_rid), .s_rdata(axi_rdata), .s_rresp(axi_rresp), .s_rlast(axi_rlast), .s_rvalid(axi_rvalid),
        .s_rready(axi_rready),
        .u_awid(mu_awid), .u_awaddr(mu_awaddr), .u_awlen(mu_awlen), .u_awvalid(mu_awvalid), .u_awready(mu_awready),
        .u_wdata(mu_wdata), .u_wstrb(mu_wstrb), .u_wlast(mu_wlast), .u_wvalid(mu_wvalid), .u_wready(mu_wready),
        .u_bid(mu_bid), .u_bresp(mu_bresp), .u_bvalid(mu_bvalid), .u_bready(mu_bready),
        .u_arid(mu_arid), .u_araddr(mu_araddr), .u_arlen(mu_arlen), .u_arvalid(mu_arvalid), .u_arready(mu_arready),
        .u_rid(mu_rid), .u_rdata(mu_rdata), .u_rresp(mu_rresp), .u_rlast(mu_rlast), .u_rvalid(mu_rvalid),
        .u_rready(mu_rready),
        .m_awid(dw_awid), .m_awaddr(dw_awaddr), .m_awlen(dw_awlen), .m_awvalid(dw_awvalid), .m_awready(dw_awready),
        .m_wdata(dw_wdata), .m_wstrb(dw_wstrb), .m_wlast(dw_wlast), .m_wvalid(dw_wvalid), .m_wready(dw_wready),
        .m_bid(dw_bid), .m_bresp(dw_bresp), .m_bvalid(dw_bvalid), .m_bready(dw_bready),
        .m_arid(dr_arid), .m_araddr(dr_araddr), .m_arlen(dr_arlen), .m_arvalid(dr_arvalid), .m_arready(dr_arready),
        .m_rid(dr_rid), .m_rdata(dr_rdata), .m_rresp(dr_rresp), .m_rlast(dr_rlast), .m_rvalid(dr_rvalid),
        .m_rready(dr_rready),
        .ev_ddr_wr(ev_ddr_wr), .ev_ddr_rd(ev_ddr_rd), .ev_ddr_oor(ev_ddr_oor)
    );
    if (DDR_PORTS == 2) begin : g_ilv
        // two ports per direction, address-interleaved (rsys_axi_ilv): port n = physical address
        // bit ILV_BIT; m_axi_ddrw_* / m_axi_ddrr_* = port 0, m_axi_ddrw1_* / m_axi_ddrr1_* = port 1
        wire logic [ID_W-1:0] i_awid [2], i_bid [2], i_arid [2], i_rid [2];
        wire logic [39:0]     i_awaddr [2], i_araddr [2];
        wire logic [7:0]      i_awlen [2], i_arlen [2];
        wire logic            i_awvalid [2], i_awready [2], i_wlast [2], i_wvalid [2], i_wready [2], i_bvalid [2], i_bready [2];
        wire logic            i_arvalid [2], i_arready [2], i_rlast [2], i_rvalid [2], i_rready [2];
        wire logic [511:0]    i_wdata [2], i_rdata [2];
        wire logic [63:0]     i_wstrb [2];
        wire logic [1:0]      i_bresp [2], i_rresp [2];
        rsys_axi_ilv #(.ID_W(ID_W), .AW(40), .ILV_BIT(ILV_BIT)) u_ilv (
            .clk(clk), .rst(regs_rst),
            .s_awid(dw_awid), .s_awaddr(dw_awaddr), .s_awlen(dw_awlen), .s_awvalid(dw_awvalid), .s_awready(dw_awready),
            .s_wdata(dw_wdata), .s_wstrb(dw_wstrb), .s_wlast(dw_wlast), .s_wvalid(dw_wvalid), .s_wready(dw_wready),
            .s_bid(dw_bid), .s_bresp(dw_bresp), .s_bvalid(dw_bvalid), .s_bready(dw_bready),
            .s_arid(dr_arid), .s_araddr(dr_araddr), .s_arlen(dr_arlen), .s_arvalid(dr_arvalid), .s_arready(dr_arready),
            .s_rid(dr_rid), .s_rdata(dr_rdata), .s_rresp(dr_rresp), .s_rlast(dr_rlast), .s_rvalid(dr_rvalid),
            .s_rready(dr_rready),
            .m_awid(i_awid), .m_awaddr(i_awaddr), .m_awlen(i_awlen), .m_awvalid(i_awvalid), .m_awready(i_awready),
            .m_wdata(i_wdata), .m_wstrb(i_wstrb), .m_wlast(i_wlast), .m_wvalid(i_wvalid), .m_wready(i_wready),
            .m_bid(i_bid), .m_bresp(i_bresp), .m_bvalid(i_bvalid), .m_bready(i_bready),
            .m_arid(i_arid), .m_araddr(i_araddr), .m_arlen(i_arlen), .m_arvalid(i_arvalid), .m_arready(i_arready),
            .m_rid(i_rid), .m_rdata(i_rdata), .m_rresp(i_rresp), .m_rlast(i_rlast), .m_rvalid(i_rvalid),
            .m_rready(i_rready),
            .ev_wsub(), .ev_rsub()
        );
        assign m_axi_ddrw_awid = i_awid[0]; assign m_axi_ddrw_awaddr = i_awaddr[0]; assign m_axi_ddrw_awlen = i_awlen[0];
        assign m_axi_ddrw_awvalid = i_awvalid[0]; assign i_awready[0] = m_axi_ddrw_awready;
        assign m_axi_ddrw_wdata = i_wdata[0]; assign m_axi_ddrw_wstrb = i_wstrb[0]; assign m_axi_ddrw_wlast = i_wlast[0];
        assign m_axi_ddrw_wvalid = i_wvalid[0]; assign i_wready[0] = m_axi_ddrw_wready;
        assign i_bid[0] = m_axi_ddrw_bid; assign i_bresp[0] = m_axi_ddrw_bresp; assign i_bvalid[0] = m_axi_ddrw_bvalid;
        assign m_axi_ddrw_bready = i_bready[0];
        assign m_axi_ddrw1_awid = i_awid[1]; assign m_axi_ddrw1_awaddr = i_awaddr[1]; assign m_axi_ddrw1_awlen = i_awlen[1];
        assign m_axi_ddrw1_awvalid = i_awvalid[1]; assign i_awready[1] = m_axi_ddrw1_awready;
        assign m_axi_ddrw1_wdata = i_wdata[1]; assign m_axi_ddrw1_wstrb = i_wstrb[1]; assign m_axi_ddrw1_wlast = i_wlast[1];
        assign m_axi_ddrw1_wvalid = i_wvalid[1]; assign i_wready[1] = m_axi_ddrw1_wready;
        assign i_bid[1] = m_axi_ddrw1_bid; assign i_bresp[1] = m_axi_ddrw1_bresp; assign i_bvalid[1] = m_axi_ddrw1_bvalid;
        assign m_axi_ddrw1_bready = i_bready[1];
        assign m_axi_ddrr_arid = i_arid[0]; assign m_axi_ddrr_araddr = i_araddr[0]; assign m_axi_ddrr_arlen = i_arlen[0];
        assign m_axi_ddrr_arvalid = i_arvalid[0]; assign i_arready[0] = m_axi_ddrr_arready;
        assign i_rid[0] = m_axi_ddrr_rid; assign i_rdata[0] = m_axi_ddrr_rdata; assign i_rresp[0] = m_axi_ddrr_rresp;
        assign i_rlast[0] = m_axi_ddrr_rlast; assign i_rvalid[0] = m_axi_ddrr_rvalid; assign m_axi_ddrr_rready = i_rready[0];
        assign m_axi_ddrr1_arid = i_arid[1]; assign m_axi_ddrr1_araddr = i_araddr[1]; assign m_axi_ddrr1_arlen = i_arlen[1];
        assign m_axi_ddrr1_arvalid = i_arvalid[1]; assign i_arready[1] = m_axi_ddrr1_arready;
        assign i_rid[1] = m_axi_ddrr1_rid; assign i_rdata[1] = m_axi_ddrr1_rdata; assign i_rresp[1] = m_axi_ddrr1_rresp;
        assign i_rlast[1] = m_axi_ddrr1_rlast; assign i_rvalid[1] = m_axi_ddrr1_rvalid; assign m_axi_ddrr1_rready = i_rready[1];
    end else begin : g_one
        assign m_axi_ddrw_awid = dw_awid; assign m_axi_ddrw_awaddr = dw_awaddr; assign m_axi_ddrw_awlen = dw_awlen;
        assign m_axi_ddrw_awvalid = dw_awvalid; assign dw_awready = m_axi_ddrw_awready;
        assign m_axi_ddrw_wdata = dw_wdata; assign m_axi_ddrw_wstrb = dw_wstrb; assign m_axi_ddrw_wlast = dw_wlast;
        assign m_axi_ddrw_wvalid = dw_wvalid; assign dw_wready = m_axi_ddrw_wready;
        assign dw_bid = m_axi_ddrw_bid; assign dw_bresp = m_axi_ddrw_bresp; assign dw_bvalid = m_axi_ddrw_bvalid;
        assign m_axi_ddrw_bready = dw_bready;
        assign m_axi_ddrr_arid = dr_arid; assign m_axi_ddrr_araddr = dr_araddr; assign m_axi_ddrr_arlen = dr_arlen;
        assign m_axi_ddrr_arvalid = dr_arvalid; assign dr_arready = m_axi_ddrr_arready;
        assign dr_rid = m_axi_ddrr_rid; assign dr_rdata = m_axi_ddrr_rdata; assign dr_rresp = m_axi_ddrr_rresp;
        assign dr_rlast = m_axi_ddrr_rlast; assign dr_rvalid = m_axi_ddrr_rvalid; assign m_axi_ddrr_rready = dr_rready;
        assign m_axi_ddrw1_awid = '0; assign m_axi_ddrw1_awaddr = '0; assign m_axi_ddrw1_awlen = '0;
        assign m_axi_ddrw1_awvalid = 1'b0; assign m_axi_ddrw1_wdata = '0; assign m_axi_ddrw1_wstrb = '0;
        assign m_axi_ddrw1_wlast = 1'b0; assign m_axi_ddrw1_wvalid = 1'b0; assign m_axi_ddrw1_bready = 1'b0;
        assign m_axi_ddrr1_arid = '0; assign m_axi_ddrr1_araddr = '0; assign m_axi_ddrr1_arlen = '0;
        assign m_axi_ddrr1_arvalid = 1'b0; assign m_axi_ddrr1_rready = 1'b0;
    end
end else begin : g_noddr
    assign mu_awid = axi_awid; assign mu_awaddr = axi_awaddr; assign mu_awlen = axi_awlen;
    assign mu_awvalid = axi_awvalid; assign axi_awready = mu_awready;
    assign mu_wdata = axi_wdata; assign mu_wstrb = axi_wstrb; assign mu_wlast = axi_wlast;
    assign mu_wvalid = axi_wvalid; assign axi_wready = mu_wready;
    assign axi_bid = mu_bid; assign axi_bresp = mu_bresp; assign axi_bvalid = mu_bvalid; assign mu_bready = axi_bready;
    assign mu_arid = axi_arid; assign mu_araddr = axi_araddr; assign mu_arlen = axi_arlen;
    assign mu_arvalid = axi_arvalid; assign axi_arready = mu_arready;
    assign axi_rid = mu_rid; assign axi_rdata = mu_rdata; assign axi_rresp = mu_rresp; assign axi_rlast = mu_rlast;
    assign axi_rvalid = mu_rvalid; assign mu_rready = axi_rready;
    assign m_axi_ddrw_awid = '0; assign m_axi_ddrw_awaddr = '0; assign m_axi_ddrw_awlen = '0;
    assign m_axi_ddrw_awvalid = 1'b0; assign m_axi_ddrw_wdata = '0; assign m_axi_ddrw_wstrb = '0;
    assign m_axi_ddrw_wlast = 1'b0; assign m_axi_ddrw_wvalid = 1'b0; assign m_axi_ddrw_bready = 1'b0;
    assign m_axi_ddrr_arid = '0; assign m_axi_ddrr_araddr = '0; assign m_axi_ddrr_arlen = '0;
    assign m_axi_ddrr_arvalid = 1'b0; assign m_axi_ddrr_rready = 1'b0;
    assign m_axi_ddrw1_awid = '0; assign m_axi_ddrw1_awaddr = '0; assign m_axi_ddrw1_awlen = '0;
    assign m_axi_ddrw1_awvalid = 1'b0; assign m_axi_ddrw1_wdata = '0; assign m_axi_ddrw1_wstrb = '0;
    assign m_axi_ddrw1_wlast = 1'b0; assign m_axi_ddrw1_wvalid = 1'b0; assign m_axi_ddrw1_bready = 1'b0;
    assign m_axi_ddrr1_arid = '0; assign m_axi_ddrr1_araddr = '0; assign m_axi_ddrr1_arlen = '0;
    assign m_axi_ddrr1_arvalid = 1'b0; assign m_axi_ddrr1_rready = 1'b0;
    always_ff @(posedge clk) begin ev_ddr_wr <= 1'b0; ev_ddr_rd <= 1'b0; ev_ddr_oor <= 1'b0; end
end
// constant AXI4 attributes of the DDR masters: 64-byte INCR beats, non-coherent (the HP ports
// are not coherent: the PS software does the cache maintenance), data access
assign m_axi_ddrw_awsize = 3'd6; assign m_axi_ddrw_awburst = 2'b01; assign m_axi_ddrw_awcache = 4'b0011;
assign m_axi_ddrw_awprot = 3'b000;
assign m_axi_ddrr_arsize = 3'd6; assign m_axi_ddrr_arburst = 2'b01; assign m_axi_ddrr_arcache = 4'b0011;
assign m_axi_ddrr_arprot = 3'b000;
assign m_axi_ddrw1_awsize = 3'd6; assign m_axi_ddrw1_awburst = 2'b01; assign m_axi_ddrw1_awcache = 4'b0011;
assign m_axi_ddrw1_awprot = 3'b000;
assign m_axi_ddrr1_arsize = 3'd6; assign m_axi_ddrr1_arburst = 2'b01; assign m_axi_ddrr1_arcache = 4'b0011;
assign m_axi_ddrr1_arprot = 3'b000;

wire logic         wtap_valid, wtap_last;
wire logic [63:0]  wtap_addr, wtap_keep;
wire logic [511:0] wtap_data;
logic              ev_mem_wr, ev_mem_rd;
logic [15:0]       rd0_bytes_add;
rsys_axi_mem #(
    .BYTES(MEM_BYTES), .PAT_EN(SELFTEST), .PAT_BIT(PAT_BIT), .ID_W(ID_W), .ADDR_W(64), .FW_AW(18), .RD_LAT(3)
) u_mem (
    .clk(clk), .rst(regs_rst), .seed(cfg[C_WC_SEED]),
    .s_axi_awid(mu_awid), .s_axi_awaddr(mu_awaddr), .s_axi_awlen(mu_awlen),
    .s_axi_awvalid(mu_awvalid), .s_axi_awready(mu_awready),
    .s_axi_wdata(mu_wdata), .s_axi_wstrb(mu_wstrb), .s_axi_wlast(mu_wlast),
    .s_axi_wvalid(mu_wvalid), .s_axi_wready(mu_wready),
    .s_axi_bid(mu_bid), .s_axi_bresp(mu_bresp), .s_axi_bvalid(mu_bvalid), .s_axi_bready(mu_bready),
    .s_axi_arid(mu_arid), .s_axi_araddr(mu_araddr), .s_axi_arlen(mu_arlen),
    .s_axi_arvalid(mu_arvalid), .s_axi_arready(mu_arready),
    .s_axi_rid(mu_rid), .s_axi_rdata(mu_rdata), .s_axi_rresp(mu_rresp), .s_axi_rlast(mu_rlast),
    .s_axi_rvalid(mu_rvalid), .s_axi_rready(mu_rready),
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

wire logic tx_sof = w_tx_tvalid && w_tx_tready && tx_first;
wire logic rx_sof = w_rx_tvalid && rx_first;
logic [4:0]  tx_cls = '0, rx_cls = '0;
logic        ev_tx_sof = 1'b0, ev_rx_sof = 1'b0, ev_tx_unf = 1'b0;
logic [15:0] tx_bytes_add, rx_bytes_add;
always_ff @(posedge clk) begin
    ev_tx_sof    <= tx_sof;
    ev_rx_sof    <= rx_sof;
    tx_cls       <= tx_sof ? fr_class(w_tx_tdata) : 5'd0;
    rx_cls       <= rx_sof ? fr_class(w_rx_tdata) : 5'd0;
    tx_bytes_add <= (w_tx_tvalid && w_tx_tready) ? 16'($countones(w_tx_tkeep)) : 16'd0;
    rx_bytes_add <= w_rx_tvalid ? 16'($countones(w_rx_tkeep)) : 16'd0;
    ev_tx_unf    <= !tx_first && !w_tx_tvalid;     // inside a frame, nothing offered
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
        .tx_sof(tx_sof), .tx_info(fr_info(w_tx_tdata)), .rx_sof(rx_sof), .rx_info(fr_info(w_rx_tdata)),
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

// ---------------- event levels for the always-on block's interrupt aggregation ----------------
always_ff @(posedge clk) evt <= {2'd0, raw_busy, od_pending, rcq_level != 8'd0, wcq_level != 8'd0,
                                 crx_level != 8'd0, irq};

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
    ev[E_ODMA_RX]        = ev_od_rx;
    ev[E_ODMA_DROP]      = ev_od_drop;
    ev[E_ODMA_TX]        = ev_od_tx;
    ev[E_DDR_WR_BURSTS]  = ev_ddr_wr;
    ev[E_DDR_RD_BURSTS]  = ev_ddr_rd;
    ev[E_DDR_OOR]        = ev_ddr_oor;

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
    sv[S_SYS_CFG]     = {8'(MAC_WIDTH / 8), 8'(LINK_GBPS), 8'($clog2(MEM_BYTES)), 3'd0, ODMA_EN, DDR_EN, PAY_EN,
                         SELFTEST, SELFTEST};
    sv[S_STATUS]      = {25'd0, irq, rinj_armed, inj_armed, lat_ovf, cap_status[0], wg_running, st_rst};
    sv[S_MAC_STAT]    = {18'd0, mac_st};
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
