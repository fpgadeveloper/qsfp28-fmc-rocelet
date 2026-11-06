// SPDX-License-Identifier: MIT
//
// rsys_axi_dec - memory-window address decoder of rocelet_sys (DDR_EN builds): splits the
// rocelet engine's 512-bit AXI4 memory master between
//   * the on-chip memory window u_mem (URAM, and the self-test pattern region at address
//     bit PAT_BIT): every address with bit DDR_BIT = 0, or with PAT_BIT = 1;
//   * the PS DDR window: addresses with bit DDR_BIT = 1 (and PAT_BIT = 0). The low DDR_BIT
//     bits are an OFFSET into a region of PS DDR given by run-time registers: physical
//     address = win_base + offset, accepted while offset < win_size (a Linux reserved-memory
//     carve-out, for example; win_size = 0 closes the window, the reset state). Accepted
//     bursts leave on two masters split by direction, m_w* (write channels only, to one
//     S_AXI_HP port) and m_r* (read channels only, to another), DDR_AW address bits.
//   * a null target for DDR-window bursts outside the region: writes are accepted and
//     discarded (OKAY), reads return zeros (OKAY), ev_ddr_oor counts them. So no remote
//     request can reach PS memory outside the region, whatever the memory windows say.
// So a memory window (MR_LADDR) of 0x80_0000_0000 + offset reaches PS DDR physical address
// win_base + offset (DDR_BIT 39), and the KCU116 layout (URAM at local address 0, pattern at
// bit 40) is unchanged. Bursts never cross 4 KB and win_size is a multiple of 4 KB, so the
// check of a burst's first address covers the whole burst.
// Ordering: AXI requires the responses of one ID in order; the two targets would not
// guarantee that between them, so the decoder changes the target of a direction only when
// that direction has nothing outstanding (B responses for writes, last R beats for reads).
// The engine rarely alternates (one memory window per transfer), so the stall is negligible.
// W beats follow their AW: a W beat is passed only while an AW burst is owed its data (the
// slave side may wait for AWVALID before WREADY, AXI A3.3.1).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_axi_dec #(
    parameter int ID_W    = 2,
    parameter int ADDR_W  = 64,
    parameter int DDR_BIT = 39,
    parameter int PAT_BIT = 40,
    parameter int DDR_AW  = 40
) (
    input  wire logic              clk,
    input  wire logic              rst,
    input  wire logic [DDR_AW-1:0] win_base,      // PS DDR region: physical base (4 KB aligned)
    input  wire logic [DDR_AW-1:0] win_size,      // bytes (multiple of 4 KB); 0 = window closed

    // from the engine
    input  wire logic [ID_W-1:0]   s_awid,
    input  wire logic [ADDR_W-1:0] s_awaddr,
    input  wire logic [7:0]        s_awlen,
    input  wire logic              s_awvalid,
    output wire logic              s_awready,
    input  wire logic [511:0]      s_wdata,
    input  wire logic [63:0]       s_wstrb,
    input  wire logic              s_wlast,
    input  wire logic              s_wvalid,
    output wire logic              s_wready,
    output wire logic [ID_W-1:0]   s_bid,
    output wire logic [1:0]        s_bresp,
    output wire logic              s_bvalid,
    input  wire logic              s_bready,
    input  wire logic [ID_W-1:0]   s_arid,
    input  wire logic [ADDR_W-1:0] s_araddr,
    input  wire logic [7:0]        s_arlen,
    input  wire logic              s_arvalid,
    output wire logic              s_arready,
    output wire logic [ID_W-1:0]   s_rid,
    output wire logic [511:0]      s_rdata,
    output wire logic [1:0]        s_rresp,
    output wire logic              s_rlast,
    output wire logic              s_rvalid,
    input  wire logic              s_rready,

    // to the on-chip memory window (same signals)
    output wire logic [ID_W-1:0]   u_awid,
    output wire logic [ADDR_W-1:0] u_awaddr,
    output wire logic [7:0]        u_awlen,
    output wire logic              u_awvalid,
    input  wire logic              u_awready,
    output wire logic [511:0]      u_wdata,
    output wire logic [63:0]       u_wstrb,
    output wire logic              u_wlast,
    output wire logic              u_wvalid,
    input  wire logic              u_wready,
    input  wire logic [ID_W-1:0]   u_bid,
    input  wire logic [1:0]        u_bresp,
    input  wire logic              u_bvalid,
    output wire logic              u_bready,
    output wire logic [ID_W-1:0]   u_arid,
    output wire logic [ADDR_W-1:0] u_araddr,
    output wire logic [7:0]        u_arlen,
    output wire logic              u_arvalid,
    input  wire logic              u_arready,
    input  wire logic [ID_W-1:0]   u_rid,
    input  wire logic [511:0]      u_rdata,
    input  wire logic [1:0]        u_rresp,
    input  wire logic              u_rlast,
    input  wire logic              u_rvalid,
    output wire logic              u_rready,

    // to PS DDR: write-only master
    output wire logic [ID_W-1:0]   m_awid,
    output wire logic [DDR_AW-1:0] m_awaddr,
    output wire logic [7:0]        m_awlen,
    output wire logic              m_awvalid,
    input  wire logic              m_awready,
    output wire logic [511:0]      m_wdata,
    output wire logic [63:0]       m_wstrb,
    output wire logic              m_wlast,
    output wire logic              m_wvalid,
    input  wire logic              m_wready,
    input  wire logic [ID_W-1:0]   m_bid,
    input  wire logic [1:0]        m_bresp,
    input  wire logic              m_bvalid,
    output wire logic              m_bready,
    // to PS DDR: read-only master
    output wire logic [ID_W-1:0]   m_arid,
    output wire logic [DDR_AW-1:0] m_araddr,
    output wire logic [7:0]        m_arlen,
    output wire logic              m_arvalid,
    input  wire logic              m_arready,
    input  wire logic [ID_W-1:0]   m_rid,
    input  wire logic [511:0]      m_rdata,
    input  wire logic [1:0]        m_rresp,
    input  wire logic              m_rlast,
    input  wire logic              m_rvalid,
    output wire logic              m_rready,

    output logic                   ev_ddr_wr,     // a write burst went to PS DDR
    output logic                   ev_ddr_rd,     // a read burst went to PS DDR
    output logic                   ev_ddr_oor     // a DDR-window burst was outside the region (null target)
);

// target of an address: 0 URAM / pattern, 1 PS DDR (inside the region), 2 null (outside)
localparam logic [1:0] T_MEM = 2'd0, T_DDR = 2'd1, T_NUL = 2'd2;
function automatic logic [1:0] tgt_of(input logic [ADDR_W-1:0] a);
    logic [DDR_AW-1:0] off;
    off = '0;
    off[DDR_BIT-1:0] = a[DDR_BIT-1:0];
    if (!a[DDR_BIT] || a[PAT_BIT]) return T_MEM;
    return (off < win_size) ? T_DDR : T_NUL;
endfunction
function automatic logic [DDR_AW-1:0] pa(input logic [ADDR_W-1:0] a);
    logic [DDR_AW-1:0] off;
    off = '0;
    off[DDR_BIT-1:0] = a[DDR_BIT-1:0];
    return win_base + off;
endfunction

// ---------------- write direction ----------------
logic [1:0] w_tgt = T_MEM;
logic [7:0] w_out = '0;              // AW bursts without a B response
logic [7:0] w_owe = '0;              // AW bursts still owed W data
wire  logic [1:0] aw_t = tgt_of(s_awaddr);
wire  logic aw_ok  = (w_out == 8'd0 || aw_t == w_tgt) && w_out != 8'hFF && w_owe != 8'hFF;
// null target: AW always accepted, W beats swallowed, one OKAY B per burst (queued by count)
logic [7:0] nb_cnt = '0;             // B responses owed by the null target
logic [1:0] nb_id_q [256];
logic [7:0] nb_wp = '0, nb_rp = '0, nw_q = '0;

assign u_awid = s_awid; assign u_awaddr = s_awaddr; assign u_awlen = s_awlen;
assign m_awid = s_awid; assign m_awaddr = pa(s_awaddr); assign m_awlen = s_awlen;
assign u_awvalid = s_awvalid && aw_ok && aw_t == T_MEM;
assign m_awvalid = s_awvalid && aw_ok && aw_t == T_DDR;
assign s_awready = aw_ok && (aw_t == T_DDR ? m_awready : (aw_t == T_MEM ? u_awready : 1'b1));
wire  logic aw_hs = s_awvalid && s_awready;

wire  logic w_go = (w_owe != 8'd0);
assign u_wdata = s_wdata; assign u_wstrb = s_wstrb; assign u_wlast = s_wlast;
assign m_wdata = s_wdata; assign m_wstrb = s_wstrb; assign m_wlast = s_wlast;
assign u_wvalid = s_wvalid && w_go && w_tgt == T_MEM;
assign m_wvalid = s_wvalid && w_go && w_tgt == T_DDR;
assign s_wready = w_go && (w_tgt == T_DDR ? m_wready : (w_tgt == T_MEM ? u_wready : 1'b1));
wire  logic wl_hs = s_wvalid && s_wready && s_wlast;

wire  logic nb_valid = (nb_cnt != 8'd0);
assign s_bid    = w_tgt == T_DDR ? m_bid    : (w_tgt == T_MEM ? u_bid    : nb_id_q[nb_rp]);
assign s_bresp  = w_tgt == T_DDR ? m_bresp  : (w_tgt == T_MEM ? u_bresp  : 2'b00);
assign s_bvalid = w_tgt == T_DDR ? m_bvalid : (w_tgt == T_MEM ? u_bvalid : nb_valid);
assign u_bready = s_bready && w_tgt == T_MEM;
assign m_bready = s_bready && w_tgt == T_DDR;
wire  logic b_hs = s_bvalid && s_bready;

always_ff @(posedge clk) begin
    ev_ddr_wr <= aw_hs && aw_t == T_DDR;
    if (aw_hs) w_tgt <= aw_t;
    w_out <= w_out + 8'(aw_hs) - 8'(b_hs);
    w_owe <= w_owe + 8'(aw_hs) - 8'(wl_hs);
    // null target bookkeeping: the burst's id at AW, its B once the last W beat is in
    if (aw_hs && aw_t == T_NUL) begin nb_id_q[nb_wp] <= s_awid; nb_wp <= nb_wp + 8'd1; end
    nb_cnt <= nb_cnt + 8'(wl_hs && w_tgt == T_NUL) - 8'(b_hs && w_tgt == T_NUL);
    if (b_hs && w_tgt == T_NUL) nb_rp <= nb_rp + 8'd1;
    if (rst) begin
        w_out <= '0;
        w_owe <= '0;
        w_tgt <= T_MEM;
        nb_cnt <= '0; nb_wp <= '0; nb_rp <= '0;
    end
end

// ---------------- read direction ----------------
logic [1:0] r_tgt = T_MEM;
logic [7:0] r_out = '0;              // AR bursts without their last R beat
wire  logic [1:0] ar_t = tgt_of(s_araddr);
wire  logic ar_ok  = (r_out == 8'd0 || ar_t == r_tgt) && r_out != 8'hFF;
// null target: one AR at a time (r_out == 0 before it is taken), zeros, OKAY
logic       nr_busy = 1'b0;
logic [7:0] nr_left = '0;
logic [ID_W-1:0] nr_id = '0;
wire  logic ar_nul_ok = (ar_t != T_NUL) || !nr_busy;

assign u_arid = s_arid; assign u_araddr = s_araddr; assign u_arlen = s_arlen;
assign m_arid = s_arid; assign m_araddr = pa(s_araddr); assign m_arlen = s_arlen;
assign u_arvalid = s_arvalid && ar_ok && ar_t == T_MEM;
assign m_arvalid = s_arvalid && ar_ok && ar_t == T_DDR;
assign s_arready = ar_ok && ar_nul_ok && (ar_t == T_DDR ? m_arready : (ar_t == T_MEM ? u_arready : 1'b1));
wire  logic ar_hs = s_arvalid && s_arready;

assign s_rid    = r_tgt == T_DDR ? m_rid    : (r_tgt == T_MEM ? u_rid    : nr_id);
assign s_rdata  = r_tgt == T_DDR ? m_rdata  : (r_tgt == T_MEM ? u_rdata  : 512'd0);
assign s_rresp  = r_tgt == T_DDR ? m_rresp  : (r_tgt == T_MEM ? u_rresp  : 2'b00);
assign s_rlast  = r_tgt == T_DDR ? m_rlast  : (r_tgt == T_MEM ? u_rlast  : (nr_left == 8'd0));
assign s_rvalid = r_tgt == T_DDR ? m_rvalid : (r_tgt == T_MEM ? u_rvalid : nr_busy);
assign u_rready = s_rready && r_tgt == T_MEM;
assign m_rready = s_rready && r_tgt == T_DDR;
wire  logic rl_hs = s_rvalid && s_rready && s_rlast;

always_ff @(posedge clk) begin
    ev_ddr_rd  <= ar_hs && ar_t == T_DDR;
    ev_ddr_oor <= (ar_hs && ar_t == T_NUL) || (aw_hs && aw_t == T_NUL);
    if (ar_hs) r_tgt <= ar_t;
    r_out <= r_out + 8'(ar_hs) - 8'(rl_hs);
    if (ar_hs && ar_t == T_NUL) begin nr_busy <= 1'b1; nr_left <= s_arlen; nr_id <= s_arid; end
    else if (nr_busy && r_tgt == T_NUL && s_rready) begin
        if (nr_left == 8'd0) nr_busy <= 1'b0;
        else nr_left <= nr_left - 8'd1;
    end
    if (rst) begin
        r_out <= '0;
        r_tgt <= T_MEM;
        nr_busy <= 1'b0;
    end
end

endmodule

`resetall
