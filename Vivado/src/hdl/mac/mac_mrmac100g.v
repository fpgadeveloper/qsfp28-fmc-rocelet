// SPDX-License-Identifier: MIT
//
// mac_mrmac100g - the Versal hard MRMAC (1x100GE CAUI-4, "independent" non-segmented 384-bit
// AXI4-Stream client, ctl_axis_cfg 3'b101) behind rocelet_sys's generic MAC boundary (VCK190
// target). The MRMAC and the gt_quad_base are block-design cells (bd_versal.tcl); this module
// is the glue between them and rocelet_sys, and it owns every clock crossing:
//
//   clk       engine clock (rocelet_sys clk, free-running MMCM, 300 MHz by default):
//             S_AXIS_TX / M_AXIS_RX (512 bits), mac_ctl / mac_pz / mac_addr in, mac_stat /
//             mac_ev / mac_pause / mac_lane / mac_lev out (all in clk)
//   axis_clk  the MRMAC client clock (tx_axi_clk = rx_axi_clk, free-running MMCM,
//             >= 390.625 MHz): the six-lane client ports, the PAUSE / FEC-counter ports
//   ctl_clk   the MRMAC s_axi_aclk (pl0, 100 MHz): PG314 puts most stat_* levels and the
//             frame-error pulses in this clock
//
//   RX  MRMAC 6 x 64 bit (48 B/beat, no tready) -> mrmac_rx_packer (48 -> 64 B, takes every
//       beat, MRMAC Err -> tuser) -> frame-safe write gate -> async FIFO (RX_FIFO_DEPTH x 512 b)
//       -> M_AXIS_RX (no tready; tvalid gaps). The RX can never back-pressure the MRMAC: a frame
//       that does not fit is dropped WHOLE (its first beat finds < 2 free entries) or, if it
//       already started, cut and terminated with tuser = 1 (bad, the engine drops it) in the
//       entry kept free for that; the rest of the frame is discarded. Either way mac_lev[5]
//       pulses once per frame lost (always-on RX_OVF counter). With clk >= 300 MHz it cannot
//       happen (read 300 M beats/s > the packer's worst case 281 M beats/s at 100G).
//   TX  S_AXIS_TX -> reset gate (frames are swallowed whole while the MRMAC TX is in reset)
//       -> packet-mode async FIFO (TX_FIFO_DEPTH x 512 b, store-and-forward: a frame is only
//       read once it is complete, so the MRMAC never sees a gap inside a frame) -> 64 -> 48 B
//       downsizer -> skid -> MRMAC 6 x 64 bit (tready). Frames shorter than PAD_MIN bytes are
//       zero-padded to PAD_MIN (rocelet expects the MAC to pad; whether the MRMAC pads itself
//       is not documented). tx_tuser on the last beat = tkeep_user[8] (Err: the MRMAC aborts
//       the frame per CTL_TX_CORRUPT_FCS_ON_ERR).
//   mac_ctl [2] send RFI [3] send LFI [4] send idle -> ctl_tx_send_*_in_0 (async ports,
//       re-registered in axis_clk); [6] receive PAUSE -> ctl_rx_pause_enable_0[8] and
//       ctl_rx_pause_ack_0[8] (as mac_cmac_adapt); [7] send PAUSE -> ctl_tx_pause_enable_0[8];
//       [16] engine PAUSE request (level) -> ctl_tx_pause_req_0[8]; [10:8] GT loopback ->
//       ch0..3_loopback of gt_quad_base (0 off, 1 near-end PCS, 2 near-end PMA; the firmware's
//       reset pulse after a change re-initialises the GT with it). [0] / [1] RX / TX enable and
//       [5] FEC are MRMAC REGISTERS (CONFIGURATION_RX/TX_REG1, FEC_CONFIGURATION_REG1), written
//       by the firmware; so are mac_pz (CTL_TX_PAUSE_QUANTA8 / CTL_TX_PAUSE_REFRESH_TIMER8) and
//       mac_addr (CTL_TX_SA_GPP, the PAUSE source address). mac_pz / mac_addr are unused here.
//   mac_stat / mac_ev / mac_pause: the rocelet_sys.sv header semantics (mac_cmac_adapt map);
//       levels via 2-FF synchronisers, events via gray-coded counters (lossless), the received
//       PAUSE quanta via a handshake (the latest PAUSE wins while one is in flight).
//   mac_lane (levels, for the always-on LANE_STAT): [3:0] stat_rx_fec_lane_lock_0 per physical
//       lane [5:4] stat_rx_fec_mapping_0 [6] stat_rx_fec_aligned_0 [27:8] stat_rx_block_lock_0
//       (PCS lanes 0-19) [31] 1 = four-lane MAC. mac_lev: [5] RX frame lost in the adapter FIFO.
//   Resets: gt_reset (always-on block) -> gt_reset_all_in[3:0] of the MRMAC (its GT reset
//       controller, MRMAC_IS_GT_WIZ_OLD = 1); MRMAC tx/rx core + serdes resets = mac_reset or the
//       lane's GT reset not done (the precedents' scheme plus the always-on mac_reset); the
//       adapter datapaths are held in reset with them (mac_stat[10] / [11] tell the engine).
//       gt_powergood / gt_tx_ready / gt_rx_ready (all four lanes) go to the always-on block.
//
// The MRMAC-side ports carry the MRMAC pin names (direction reversed), so the block design
// connects them name for name. Dev note with the port list: mac_mrmac100g.md.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps

module mac_mrmac100g #(
    parameter RX_FIFO_DEPTH = 512,       // engine-side RX FIFO entries (512-bit beats)
    parameter TX_FIFO_DEPTH = 512,       // TX packet FIFO entries (>= 2 x the largest frame / 64)
    parameter FIFO_MEM      = "block",   // xpm memory type of both FIFOs
    parameter PAD_MIN       = 60         // TX frames shorter than this (bytes, without FCS) are padded
) (
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

    // ---- rocelet_sys side (clk) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TX TDATA" *)  input  wire [511:0] tx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TX TKEEP" *)  input  wire [63:0]  tx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TX TVALID" *) input  wire         tx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TX TREADY" *) output wire         tx_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TX TLAST" *)  input  wire         tx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TX TUSER" *)  input  wire         tx_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RX TDATA" *)  output reg  [511:0] rx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RX TKEEP" *)  output reg  [63:0]  rx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RX TVALID" *) output reg          rx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RX TLAST" *)  output reg          rx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RX TUSER" *)  output reg          rx_tuser,

    input  wire [31:0]  mac_ctl,
    input  wire [31:0]  mac_pz,
    input  wire [47:0]  mac_addr,
    output wire [15:0]  mac_stat,
    output wire [15:0]  mac_ev,
    output wire [17:0]  mac_pause,
    output wire [31:0]  mac_lane,
    output wire [5:0]   mac_lev,

    // ---- always-on block (levels, synchronised there) ----
    output wire         gt_powergood,
    output wire         gt_tx_ready,
    output wire         gt_rx_ready,

    // ---- gt_quad_base ----
    (* X_INTERFACE_IGNORE = "true" *) input  wire        gtpowergood_in,   // gt_quad_base/gtpowergood
    (* X_INTERFACE_IGNORE = "true" *) output wire [2:0]  ch0_loopback,
    (* X_INTERFACE_IGNORE = "true" *) output wire [2:0]  ch1_loopback,
    (* X_INTERFACE_IGNORE = "true" *) output wire [2:0]  ch2_loopback,
    (* X_INTERFACE_IGNORE = "true" *) output wire [2:0]  ch3_loopback,

    // ---- MRMAC: GT reset controller and core resets ----
    (* X_INTERFACE_IGNORE = "true" *) output wire [3:0]  gt_reset_all_in,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [3:0]  gt_tx_reset_done_out,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [3:0]  gt_rx_reset_done_out,
    (* X_INTERFACE_IGNORE = "true" *) output wire [3:0]  tx_core_reset,
    (* X_INTERFACE_IGNORE = "true" *) output wire [3:0]  rx_core_reset,
    (* X_INTERFACE_IGNORE = "true" *) output wire [3:0]  tx_serdes_reset,
    (* X_INTERFACE_IGNORE = "true" *) output wire [3:0]  rx_serdes_reset,

    // ---- MRMAC port 0 client, independent 384-bit non-segmented (axis_clk) ----
    (* X_INTERFACE_IGNORE = "true" *) input  wire [63:0] rx_axis_tdata0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [63:0] rx_axis_tdata1,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [63:0] rx_axis_tdata2,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [63:0] rx_axis_tdata3,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [63:0] rx_axis_tdata4,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [63:0] rx_axis_tdata5,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [10:0] rx_axis_tkeep_user0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [10:0] rx_axis_tkeep_user1,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [10:0] rx_axis_tkeep_user2,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [10:0] rx_axis_tkeep_user3,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [10:0] rx_axis_tkeep_user4,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [10:0] rx_axis_tkeep_user5,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        rx_axis_tvalid_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        rx_axis_tlast_0,
    (* X_INTERFACE_IGNORE = "true" *) output wire [63:0] tx_axis_tdata0,
    (* X_INTERFACE_IGNORE = "true" *) output wire [63:0] tx_axis_tdata1,
    (* X_INTERFACE_IGNORE = "true" *) output wire [63:0] tx_axis_tdata2,
    (* X_INTERFACE_IGNORE = "true" *) output wire [63:0] tx_axis_tdata3,
    (* X_INTERFACE_IGNORE = "true" *) output wire [63:0] tx_axis_tdata4,
    (* X_INTERFACE_IGNORE = "true" *) output wire [63:0] tx_axis_tdata5,
    (* X_INTERFACE_IGNORE = "true" *) output wire [10:0] tx_axis_tkeep_user0,
    (* X_INTERFACE_IGNORE = "true" *) output wire [10:0] tx_axis_tkeep_user1,
    (* X_INTERFACE_IGNORE = "true" *) output wire [10:0] tx_axis_tkeep_user2,
    (* X_INTERFACE_IGNORE = "true" *) output wire [10:0] tx_axis_tkeep_user3,
    (* X_INTERFACE_IGNORE = "true" *) output wire [10:0] tx_axis_tkeep_user4,
    (* X_INTERFACE_IGNORE = "true" *) output wire [10:0] tx_axis_tkeep_user5,
    (* X_INTERFACE_IGNORE = "true" *) output wire        tx_axis_tvalid_0,
    (* X_INTERFACE_IGNORE = "true" *) output wire        tx_axis_tlast_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        tx_axis_tready_0,

    // ---- MRMAC port 0 flow control and fault injection ----
    (* X_INTERFACE_IGNORE = "true" *) output wire [8:0]  ctl_tx_pause_req_0,      // tx_axi_clk
    (* X_INTERFACE_IGNORE = "true" *) output wire [8:0]  ctl_tx_pause_enable_0,   // tx_axi_clk
    (* X_INTERFACE_IGNORE = "true" *) output wire [8:0]  ctl_rx_pause_enable_0,   // rx_axi_clk
    (* X_INTERFACE_IGNORE = "true" *) output wire [8:0]  ctl_rx_pause_ack_0,      // rx_axi_clk
    (* X_INTERFACE_IGNORE = "true" *) output wire        ctl_tx_resend_pause_0,   // async
    (* X_INTERFACE_IGNORE = "true" *) output wire        ctl_tx_send_rfi_in_0,    // async
    (* X_INTERFACE_IGNORE = "true" *) output wire        ctl_tx_send_lfi_in_0,    // async
    (* X_INTERFACE_IGNORE = "true" *) output wire        ctl_tx_send_idle_in_0,   // async

    // ---- MRMAC port 0 status, s_axi_aclk (PG314 "MRMAC Status Ports") ----
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_aligned_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_status_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_local_fault_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_remote_fault_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_received_local_fault_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_internal_local_fault_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_hi_ber_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_misaligned_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_fec_hi_ser_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_fec_aligned_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [3:0]  stat_rx_fec_lane_lock_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [1:0]  stat_rx_fec_mapping_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [19:0] stat_rx_block_lock_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_bad_fcs_0,       // event
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_bad_code_0,      // event
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_tx_bad_fcs_0,       // event
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_tx_axis_unf_0,      // level: rising edge counted
    // ---- MRMAC port 0 status, rx_axi_clk / tx_axi_clk ----
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_fec_corrected_cw_0_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_fec_corrected_cw_0_1,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_fec_corrected_cw_0_2,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_fec_corrected_cw_0_3,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_fec_uncorrected_cw_0_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_fec_uncorrected_cw_0_1,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_fec_uncorrected_cw_0_2,
    (* X_INTERFACE_IGNORE = "true" *) input  wire        stat_rx_fec_uncorrected_cw_0_3,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [8:0]  stat_rx_pause_req_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [8:0]  stat_rx_pause_valid_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [15:0] stat_rx_pause_quanta8_0,
    (* X_INTERFACE_IGNORE = "true" *) input  wire [8:0]  stat_tx_pause_valid_0
);

// =====================================================================================
// resets
// =====================================================================================
wire tx_rst_any = mac_reset | ~(&gt_tx_reset_done_out);
wire rx_rst_any = mac_reset | ~(&gt_rx_reset_done_out);

assign gt_reset_all_in = {4{gt_reset}};
assign tx_core_reset   = ~gt_tx_reset_done_out | {4{mac_reset}};
assign tx_serdes_reset = ~gt_tx_reset_done_out | {4{mac_reset}};
assign rx_core_reset   = ~gt_rx_reset_done_out | {4{mac_reset}};
assign rx_serdes_reset = ~gt_rx_reset_done_out | {4{mac_reset}};

assign gt_powergood = gtpowergood_in;
assign gt_tx_ready  = &gt_tx_reset_done_out;
assign gt_rx_ready  = &gt_rx_reset_done_out;

wire tx_rst_a, rx_rst_a, tx_rst_c, rx_rst_c;
xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .RST_ACTIVE_HIGH(1)) u_txrst_a (.src_arst(tx_rst_any), .dest_clk(axis_clk), .dest_arst(tx_rst_a));
xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .RST_ACTIVE_HIGH(1)) u_rxrst_a (.src_arst(rx_rst_any), .dest_clk(axis_clk), .dest_arst(rx_rst_a));
xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .RST_ACTIVE_HIGH(1)) u_txrst_c (.src_arst(tx_rst_any), .dest_clk(clk),      .dest_arst(tx_rst_c));
xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .RST_ACTIVE_HIGH(1)) u_rxrst_c (.src_arst(rx_rst_any), .dest_clk(clk),      .dest_arst(rx_rst_c));

// =====================================================================================
// RX: MRMAC -> packer (axis_clk) -> frame-safe write gate -> async FIFO -> engine (clk)
// =====================================================================================
wire [511:0] pk_data;
wire [63:0]  pk_keep;
wire [48:0]  pk_user;
wire         pk_last, pk_valid;
wire [1:0]   pk_stat;

mrmac_rx_packer #(.FIFO_DEPTH(16), .RX_TS_BEAT(0)) u_pack (
    .aclk(axis_clk), .aresetn(~rx_rst_a),
    .rx_axis_tdata0(rx_axis_tdata0), .rx_axis_tdata1(rx_axis_tdata1), .rx_axis_tdata2(rx_axis_tdata2),
    .rx_axis_tdata3(rx_axis_tdata3), .rx_axis_tdata4(rx_axis_tdata4), .rx_axis_tdata5(rx_axis_tdata5),
    .rx_axis_tkeep_user0(rx_axis_tkeep_user0), .rx_axis_tkeep_user1(rx_axis_tkeep_user1),
    .rx_axis_tkeep_user2(rx_axis_tkeep_user2), .rx_axis_tkeep_user3(rx_axis_tkeep_user3),
    .rx_axis_tkeep_user4(rx_axis_tkeep_user4), .rx_axis_tkeep_user5(rx_axis_tkeep_user5),
    .rx_axis_tlast(rx_axis_tlast_0), .rx_axis_tvalid(rx_axis_tvalid_0), .rx_ptp_tstamp(55'd0),
    .m_axis_tdata(pk_data), .m_axis_tkeep(pk_keep), .m_axis_tuser(pk_user), .m_axis_tlast(pk_last),
    .m_axis_tvalid(pk_valid), .m_axis_tready(1'b1), .stat(pk_stat)
);

localparam RXW = 512 + 64 + 2;          // {bad, last, keep, data}
wire          rxf_full, rxf_afull, rxf_wbusy, rxf_empty, rxf_rbusy;
wire [RXW-1:0] rxf_dout;
reg           rx_sof = 1'b1;
reg           rx_dropping = 1'b0;
reg           rxf_wr;
reg           rxf_wlast, rxf_wbad;
reg           rx_drop_ev;               // one per frame lost
wire          rx_free1 = ~rxf_full & ~rxf_wbusy;
wire          rx_free2 = ~rxf_full & ~rxf_afull & ~rxf_wbusy;

always @* begin
    rxf_wr     = 1'b0;
    rxf_wlast  = pk_last;
    rxf_wbad   = pk_user[0];
    rx_drop_ev = 1'b0;
    if (pk_valid && !rx_dropping) begin
        if (rx_sof) begin
            // a frame starts only with room for one more entry after it (the terminator)
            if (rx_free2 || (pk_last && rx_free1)) rxf_wr = 1'b1;
            else                                   rx_drop_ev = 1'b1;   // dropped whole
        end else if (pk_last) begin
            rxf_wr = rx_free1;                     // always true: an entry was kept free
            rx_drop_ev = ~rx_free1;
        end else if (rx_free2) begin
            rxf_wr = 1'b1;
        end else begin
            // the last free entry: cut the frame here, flagged bad; drop its remainder
            rxf_wr = rx_free1; rxf_wlast = 1'b1; rxf_wbad = 1'b1; rx_drop_ev = 1'b1;
        end
    end
end

always @(posedge axis_clk) begin
    if (pk_valid) begin
        rx_sof <= pk_last;
        if (rx_dropping)                 rx_dropping <= ~pk_last;
        else if (rx_drop_ev && !pk_last) rx_dropping <= 1'b1;
    end
    if (rx_rst_a) begin
        rx_sof      <= 1'b1;
        rx_dropping <= 1'b0;
    end
end

xpm_fifo_async #(
    .FIFO_MEMORY_TYPE(FIFO_MEM), .FIFO_WRITE_DEPTH(RX_FIFO_DEPTH), .WRITE_DATA_WIDTH(RXW),
    .READ_DATA_WIDTH(RXW), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .USE_ADV_FEATURES("0008"),
    .CDC_SYNC_STAGES(2), .RELATED_CLOCKS(0), .ECC_MODE("no_ecc"), .DOUT_RESET_VALUE("0"),
    .FULL_RESET_VALUE(1), .WR_DATA_COUNT_WIDTH(1), .RD_DATA_COUNT_WIDTH(1), .PROG_FULL_THRESH(10),
    .PROG_EMPTY_THRESH(10), .SIM_ASSERT_CHK(0), .CASCADE_HEIGHT(0), .WAKEUP_TIME(0)
) u_rxf (
    .sleep(1'b0), .rst(rx_rst_a), .wr_clk(axis_clk), .wr_en(rxf_wr),
    .din({rxf_wbad, rxf_wlast, pk_keep, pk_data}),
    .full(rxf_full), .almost_full(rxf_afull), .wr_rst_busy(rxf_wbusy),
    .prog_full(), .wr_data_count(), .overflow(), .wr_ack(),
    .rd_clk(clk), .rd_en(~rxf_empty & ~rxf_rbusy), .dout(rxf_dout), .empty(rxf_empty),
    .rd_rst_busy(rxf_rbusy), .prog_empty(), .rd_data_count(), .underflow(), .almost_empty(),
    .data_valid(), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr()
);

always @(posedge clk) begin
    rx_tvalid <= ~rxf_empty & ~rxf_rbusy;
    rx_tdata  <= rxf_dout[511:0];
    rx_tkeep  <= rxf_dout[575:512];
    rx_tlast  <= rxf_dout[576];
    rx_tuser  <= rxf_dout[577];
end

// =====================================================================================
// TX: engine (clk) -> reset gate -> packet FIFO -> 64 -> 48 B downsizer -> skid -> MRMAC
// =====================================================================================
// popcount of the contiguous tkeep (the byte count of the beat), carried in the FIFO's TUSER
function [6:0] nbytes(input [63:0] k);
    integer i;
    begin
        nbytes = 7'd0;
        for (i = 0; i < 64; i = i + 1) nbytes = nbytes + {6'd0, k[i]};
    end
endfunction

function [511:0] keep_bytes(input [63:0] k);   // tkeep -> byte mask
    integer i;
    begin
        for (i = 0; i < 64; i = i + 1) keep_bytes[8*i +: 8] = {8{k[i]}};
    end
endfunction

reg  tx_sof = 1'b1;
reg  tx_disc = 1'b0;                           // the current frame is being swallowed
wire txf_s_ready;
wire tx_drop  = tx_rst_c | (~tx_sof & tx_disc);
assign tx_tready = tx_drop | txf_s_ready;
wire txf_s_valid = tx_tvalid & ~tx_drop;

wire [6:0] tx_n_raw = tx_tlast ? nbytes(tx_tkeep) : 7'd64;
localparam [6:0] PADN = PAD_MIN;
wire [6:0] tx_n     = (tx_tlast && tx_sof && tx_n_raw < PADN) ? PADN : tx_n_raw;
wire [511:0] tx_d   = tx_tlast ? (tx_tdata & keep_bytes(tx_tkeep)) : tx_tdata;

always @(posedge clk) begin
    if (tx_tvalid && tx_tready) begin
        tx_sof <= tx_tlast;
        if (tx_tlast)    tx_disc <= 1'b0;
        else if (tx_sof) tx_disc <= tx_rst_c;
        else if (tx_rst_c) tx_disc <= 1'b1;
    end else if (tx_rst_c && !tx_sof) begin
        tx_disc <= 1'b1;
    end
end

wire [511:0] txf_data;
wire [7:0]   txf_user;
wire         txf_last, txf_valid, txf_ready;

xpm_fifo_axis #(
    .CLOCKING_MODE("independent_clock"), .FIFO_MEMORY_TYPE(FIFO_MEM), .PACKET_FIFO("true"),
    .FIFO_DEPTH(TX_FIFO_DEPTH), .TDATA_WIDTH(512), .TID_WIDTH(1), .TDEST_WIDTH(1), .TUSER_WIDTH(8),
    .SIM_ASSERT_CHK(0), .CASCADE_HEIGHT(0), .ECC_MODE("no_ecc"), .RELATED_CLOCKS(0),
    .USE_ADV_FEATURES("1000"), .WR_DATA_COUNT_WIDTH(1), .RD_DATA_COUNT_WIDTH(1),
    .PROG_FULL_THRESH(10), .PROG_EMPTY_THRESH(10), .CDC_SYNC_STAGES(2)
) u_txf (
    .s_aresetn(~tx_rst_c), .s_aclk(clk), .m_aclk(axis_clk),
    .s_axis_tvalid(txf_s_valid), .s_axis_tready(txf_s_ready), .s_axis_tdata(tx_d),
    .s_axis_tstrb(64'd0), .s_axis_tkeep(64'd0), .s_axis_tlast(tx_tlast), .s_axis_tid(1'b0),
    .s_axis_tdest(1'b0), .s_axis_tuser({tx_n, tx_tuser & tx_tlast}),
    .m_axis_tvalid(txf_valid), .m_axis_tready(txf_ready), .m_axis_tdata(txf_data),
    .m_axis_tstrb(), .m_axis_tkeep(), .m_axis_tlast(txf_last), .m_axis_tid(), .m_axis_tdest(),
    .m_axis_tuser(txf_user),
    .prog_full_axis(), .wr_data_count_axis(), .almost_full_axis(), .prog_empty_axis(),
    .rd_data_count_axis(), .almost_empty_axis(),
    .injectsbiterr_axis(1'b0), .injectdbiterr_axis(1'b0), .sbiterr_axis(), .dbiterr_axis()
);

// 64 -> 48 B downsizer: a 112-byte buffer holding cnt bytes of ONE frame from byte 0 (bytes
// above cnt are zero). It emits 48 bytes per beat (the MRMAC needs full 48-byte beats except
// the last) and appends a 64-byte input beat at offset cnt, which is a multiple of 16 until
// the frame's last beat is in. Steady state: three inputs per four outputs, no output gap
// inside a frame; the next frame is accepted in the cycle the previous one's last beat leaves.
reg  [895:0] dz_buf = 896'd0;
reg  [6:0]   dz_cnt = 7'd0;
reg          dz_end = 1'b0;                  // the frame's last beat is in the buffer
reg          dz_err = 1'b0;
wire         sk_full;                        // skid register occupied (registered)
wire         dz_adv  = ~sk_full;
wire         dz_last = dz_end & (dz_cnt <= 7'd48);
wire         dz_emit = dz_adv & ((dz_cnt >= 7'd48) | (dz_end & (dz_cnt != 7'd0)));
wire [6:0]   cnt_e   = dz_emit ? (dz_last ? 7'd0 : dz_cnt - 7'd48) : dz_cnt;
wire         end_e   = dz_end & ~(dz_emit & dz_last);
assign       txf_ready = ~tx_rst_a & ~end_e & (cnt_e <= 7'd48);
wire         dz_acc  = txf_valid & txf_ready;
wire [6:0]   dz_n    = txf_last ? txf_user[7:1] : 7'd64;

reg [895:0] dz_ins;
always @* begin
    case (cnt_e[5:4])                        // cnt_e = 0 / 16 / 32 / 48 bytes when accepting
        2'd0:    dz_ins = {384'd0, txf_data};
        2'd1:    dz_ins = {256'd0, txf_data, 128'd0};
        2'd2:    dz_ins = {128'd0, txf_data, 256'd0};
        default: dz_ins = {txf_data, 384'd0};
    endcase
end

function [47:0] keep48(input [6:0] n);      // lowest n (0..48) bits set
    begin
        keep48 = (n >= 7'd48) ? {48{1'b1}} : ~({48{1'b1}} << n);
    end
endfunction

wire [383:0] dz_odata = dz_buf[383:0];
wire [47:0]  dz_okeep = dz_last ? keep48(dz_cnt) : {48{1'b1}};
wire         dz_oerr  = dz_last & dz_err;

always @(posedge axis_clk) begin
    dz_buf <= (dz_emit ? {384'd0, dz_buf[895:384]} : dz_buf) | (dz_acc ? dz_ins : 896'd0);
    dz_cnt <= cnt_e + (dz_acc ? dz_n : 7'd0);
    dz_end <= end_e | (dz_acc & txf_last);
    if (dz_acc & txf_last) dz_err <= txf_user[0];
    if (tx_rst_a) begin
        dz_buf <= 896'd0;
        dz_cnt <= 7'd0;
        dz_end <= 1'b0;
        dz_err <= 1'b0;
    end
end

// skid buffer: the downsizer never sees tx_axis_tready combinationally
localparam OW = 384 + 48 + 2;               // {err, last, keep, data}
reg [OW-1:0] om = {OW{1'b0}}, os = {OW{1'b0}};
reg          om_v = 1'b0, os_v = 1'b0;
assign sk_full = os_v;
always @(posedge axis_clk) begin
    if (!os_v && dz_emit && om_v && !tx_axis_tready_0) begin
        os <= {dz_oerr, dz_last, dz_okeep, dz_odata};
        os_v <= 1'b1;
    end
    if (tx_axis_tready_0 || !om_v) begin
        if (os_v) begin
            om <= os; om_v <= 1'b1; os_v <= 1'b0;
        end else if (dz_emit) begin
            om <= {dz_oerr, dz_last, dz_okeep, dz_odata}; om_v <= 1'b1;
        end else begin
            om_v <= 1'b0;
        end
    end
    if (tx_rst_a) begin
        om_v <= 1'b0;
        os_v <= 1'b0;
    end
end

wire [47:0] o_keep = om[431:384];
wire        o_last = om[432];
wire        o_err  = om[433];
assign tx_axis_tdata0 = om[63:0];
assign tx_axis_tdata1 = om[127:64];
assign tx_axis_tdata2 = om[191:128];
assign tx_axis_tdata3 = om[255:192];
assign tx_axis_tdata4 = om[319:256];
assign tx_axis_tdata5 = om[383:320];
assign tx_axis_tkeep_user0 = {2'b00, o_err & o_last & |o_keep[7:0],   o_keep[7:0]};
assign tx_axis_tkeep_user1 = {2'b00, o_err & o_last & |o_keep[15:8],  o_keep[15:8]};
assign tx_axis_tkeep_user2 = {2'b00, o_err & o_last & |o_keep[23:16], o_keep[23:16]};
assign tx_axis_tkeep_user3 = {2'b00, o_err & o_last & |o_keep[31:24], o_keep[31:24]};
assign tx_axis_tkeep_user4 = {2'b00, o_err & o_last & |o_keep[39:32], o_keep[39:32]};
assign tx_axis_tkeep_user5 = {2'b00, o_err & o_last & |o_keep[47:40], o_keep[47:40]};
assign tx_axis_tvalid_0 = om_v;
assign tx_axis_tlast_0  = o_last;

// =====================================================================================
// control: clk -> axis_clk (levels), GT loopback (static, asynchronous GT pins)
// =====================================================================================
wire [5:0] ctl_a;
xpm_cdc_array_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0), .SRC_INPUT_REG(1), .WIDTH(6)) u_ctl_a (
    .src_clk(clk), .src_in({mac_ctl[16], mac_ctl[7], mac_ctl[6], mac_ctl[4], mac_ctl[3], mac_ctl[2]}),
    .dest_clk(axis_clk), .dest_out(ctl_a));
assign ctl_tx_send_rfi_in_0  = ctl_a[0];
assign ctl_tx_send_lfi_in_0  = ctl_a[1];
assign ctl_tx_send_idle_in_0 = ctl_a[2];
assign ctl_rx_pause_enable_0 = {ctl_a[3], 8'd0};
assign ctl_rx_pause_ack_0    = {ctl_a[3], 8'd0};
assign ctl_tx_pause_enable_0 = {ctl_a[4], 8'd0};
assign ctl_tx_pause_req_0    = {ctl_a[5], 8'd0};
assign ctl_tx_resend_pause_0 = 1'b0;

reg [2:0] loop_r = 3'd0;
always @(posedge clk) loop_r <= mac_ctl[10:8];
assign ch0_loopback = loop_r;
assign ch1_loopback = loop_r;
assign ch2_loopback = loop_r;
assign ch3_loopback = loop_r;

// =====================================================================================
// status: levels into clk
// =====================================================================================
localparam NLV = 10 + 4 + 2 + 20 + 1;
wire [NLV-1:0] lv_c;
xpm_cdc_array_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0), .SRC_INPUT_REG(0), .WIDTH(NLV)) u_lv (
    .src_clk(1'b0),
    .src_in({stat_rx_pause_req_0[8], stat_rx_block_lock_0, stat_rx_fec_mapping_0, stat_rx_fec_lane_lock_0,
             stat_rx_fec_aligned_0, stat_rx_fec_hi_ser_0, stat_rx_misaligned_0, stat_rx_hi_ber_0,
             stat_rx_internal_local_fault_0, stat_rx_received_local_fault_0, stat_rx_remote_fault_0,
             stat_rx_local_fault_0, stat_rx_status_0, stat_rx_aligned_0}),
    .dest_clk(clk), .dest_out(lv_c));
wire        s_aligned = lv_c[0], s_status = lv_c[1], s_lf = lv_c[2], s_rf = lv_c[3];
wire        s_rlf = lv_c[4], s_ilf = lv_c[5], s_hiber = lv_c[6], s_mis = lv_c[7];
wire        s_fhiser = lv_c[8], s_falign = lv_c[9];
wire [3:0]  s_flock = lv_c[13:10];
wire [1:0]  s_fmap  = lv_c[15:14];
wire [19:0] s_block = lv_c[35:16];
wire        s_pzreq = lv_c[36];

reg rx_in_rst = 1'b1, tx_in_rst = 1'b1, txp_act = 1'b0;
always @(posedge clk) begin
    rx_in_rst <= rx_rst_c | rxf_rbusy;
    tx_in_rst <= tx_rst_c;
    txp_act   <= mac_ctl[16] & mac_ctl[7];
end

assign mac_stat = {2'b00, txp_act, s_aligned & ~s_lf & ~s_rf, tx_in_rst, rx_in_rst, s_falign, s_fhiser,
                   s_mis, s_hiber, s_ilf, s_rlf, s_rf, s_lf, s_status, s_aligned};
assign mac_lane = {1'b1, 3'b000, s_block, 1'b0, s_falign, s_fmap, s_flock};

// =====================================================================================
// events into clk (gray-coded counters)
// =====================================================================================
reg       unf_d = 1'b0;
always @(posedge ctl_clk) unf_d <= stat_tx_axis_unf_0;
wire [3:0] ev_k;                             // [0] RX bad FCS [1] RX bad code [2] TX bad FCS [3] TX underflow
mrmac_ev_cdc #(.N(4), .W(1)) u_ev_k (
    .src_clk(ctl_clk), .src_inc({stat_tx_axis_unf_0 & ~unf_d, stat_tx_bad_fcs_0, stat_rx_bad_code_0, stat_rx_bad_fcs_0}),
    .dest_clk(clk), .dest_ev(ev_k));

reg        rxpv_d = 1'b0, txpv_d = 1'b0;
always @(posedge axis_clk) begin
    rxpv_d <= stat_rx_pause_valid_0[8];
    txpv_d <= stat_tx_pause_valid_0[8];
end
wire rxpv_rise = stat_rx_pause_valid_0[8] & ~rxpv_d;
wire [2:0] fec_c = {2'b00, stat_rx_fec_corrected_cw_0_0} + {2'b00, stat_rx_fec_corrected_cw_0_1} +
                   {2'b00, stat_rx_fec_corrected_cw_0_2} + {2'b00, stat_rx_fec_corrected_cw_0_3};
wire [2:0] fec_u = {2'b00, stat_rx_fec_uncorrected_cw_0_0} + {2'b00, stat_rx_fec_uncorrected_cw_0_1} +
                   {2'b00, stat_rx_fec_uncorrected_cw_0_2} + {2'b00, stat_rx_fec_uncorrected_cw_0_3};
wire [4:0] ev_a;                             // [0] FEC corr [1] FEC uncorr [2] PAUSE rx [3] PAUSE tx [4] RX frame lost
mrmac_ev_cdc #(.N(5), .W(3)) u_ev_a (
    .src_clk(axis_clk),
    .src_inc({{2'b00, rx_drop_ev & pk_valid}, {2'b00, stat_tx_pause_valid_0[8] & ~txpv_d}, {2'b00, rxpv_rise}, fec_u, fec_c}),
    .dest_clk(clk), .dest_ev(ev_a));

reg ev_rxf = 1'b0, ev_txf = 1'b0;
always @(posedge clk) begin
    ev_rxf <= rx_tvalid & rx_tlast;
    ev_txf <= txf_s_valid & txf_s_ready & tx_tlast;
end

assign mac_ev = {ev_a[3], ev_a[2], ev_a[1], ev_a[0], ev_k[3], ev_k[2], ev_txf,
                 {2'b00, ev_k[1]}, {2'b00, ev_k[0]}, {2'b00, ev_rxf}};
assign mac_lev = {ev_a[4], 5'd0};

// received PAUSE quanta (axis_clk -> clk): the latest PAUSE is sent once the previous one is in
reg        pz_pend = 1'b0, pz_send = 1'b0;
reg [15:0] pz_pq = 16'd0, pz_sq = 16'd0;
wire       pz_rcv, pz_dreq;
wire [15:0] pz_dq;
always @(posedge axis_clk) begin
    if (rxpv_rise) begin
        pz_pend <= 1'b1;
        pz_pq   <= stat_rx_pause_quanta8_0;
    end else if (pz_pend && !pz_send && !pz_rcv) begin
        pz_pend <= 1'b0;
        pz_send <= 1'b1;
        pz_sq   <= pz_pq;
    end
    if (pz_send && pz_rcv) pz_send <= 1'b0;
end
xpm_cdc_handshake #(.DEST_EXT_HSK(0), .DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0), .SRC_SYNC_FF(3), .WIDTH(16)) u_pz (
    .src_clk(axis_clk), .src_in(pz_sq), .src_send(pz_send), .src_rcv(pz_rcv),
    .dest_clk(clk), .dest_req(pz_dreq), .dest_ack(1'b0), .dest_out(pz_dq));
reg        pz_dreq_d = 1'b0, pz_v = 1'b0;
reg [15:0] pz_q = 16'd0;
always @(posedge clk) begin
    pz_dreq_d <= pz_dreq;
    pz_v      <= pz_dreq & ~pz_dreq_d;
    if (pz_dreq & ~pz_dreq_d) pz_q <= pz_dq;
end
assign mac_pause = {s_pzreq, pz_v, pz_q};

wire unused_ok = &{1'b0, mac_pz, mac_addr, mac_ctl[31:17], mac_ctl[15:11], mac_ctl[5], mac_ctl[1:0],
                   pk_user[48:1], pk_stat, stat_rx_pause_req_0[7:0], stat_rx_pause_valid_0[7:0],
                   stat_tx_pause_valid_0[7:0]};

endmodule

// -------------------------------------------------------------------------------------
// mrmac_ev_cdc - N event channels from src_clk into dest_clk, lossless: each channel adds
// src_inc (0..2^W-1 per src clock) to a pending count that drains one per src clock into a
// gray-coded 6-bit counter (xpm_cdc_gray); dest_clk emits one dest_ev pulse per count step.
// Bursts up to 255 pending events per channel; average rate < 1 per clock of either side.
// -------------------------------------------------------------------------------------
module mrmac_ev_cdc #(
    parameter N = 1,
    parameter W = 1
) (
    input  wire           src_clk,
    input  wire [N*W-1:0] src_inc,
    input  wire           dest_clk,
    output wire [N-1:0]   dest_ev
);
genvar g;
generate for (g = 0; g < N; g = g + 1) begin : g_ch
    reg  [7:0] pend = 8'd0;
    reg  [5:0] cnt  = 6'd0;
    reg  [5:0] seen = 6'd0;
    wire [5:0] now;
    reg        ev = 1'b0;
    assign dest_ev[g] = ev;
    wire       drain = (pend != 8'd0);
    wire [8:0] pend_n = {1'b0, pend} + {{(9-W){1'b0}}, src_inc[g*W +: W]} - {8'd0, drain};
    always @(posedge src_clk) begin
        pend <= pend_n[8] ? 8'hFF : pend_n[7:0];
        if (drain) cnt <= cnt + 6'd1;
    end
    xpm_cdc_gray #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .REG_OUTPUT(1), .SIM_ASSERT_CHK(0),
                   .SIM_LOSSLESS_GRAY_CHK(0), .WIDTH(6)) u_gray (
        .src_clk(src_clk), .src_in_bin(cnt), .dest_clk(dest_clk), .dest_out_bin(now));
    always @(posedge dest_clk) begin
        ev <= (seen != now);
        if (seen != now) seen <= seen + 6'd1;
    end
end endgenerate
endmodule
