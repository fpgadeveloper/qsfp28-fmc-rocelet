// SPDX-License-Identifier: MIT
//
// rsys_axi_ilv - address interleave of the PS DDR window over two ports per direction
// (DDR_PORTS = 2 builds of rocelet_sys). Between rsys_axi_dec's PS DDR masters (one write-only,
// one read-only, 512 bits, 64-byte INCR beats, bursts within 4 KB) and two write-only + two
// read-only masters, each to its own S_AXI_HP port of the PS:
//   * granule G = 2^ILV_BIT bytes of physical address (512 B by default): port = address bit
//     ILV_BIT, so consecutive granules alternate between the two ports and each port carries
//     half of any sequential transfer. A burst that crosses a granule boundary is cut there
//     into sub-bursts (a 4 KB burst = 8 sub-bursts of 8 beats, 4 per port); the first keeps
//     the burst's own start address (it may be unaligned inside the first beat), the others
//     start at granule boundaries.
//   * one AXI ID (0) on every port: a port answers in order, so the response order is known
//     without ID bookkeeping in the PS; the original ID is restored here.
//   * the responses are put back into the order of the requests: write responses (one B per
//     original burst, the worst BRESP of its sub-bursts) and read data (the sub-bursts' beats in
//     request order, RLAST on the original burst's last beat, its ID) follow small order FIFOs
//     of (port, last sub-burst, ID).
//   * a FIFO of FIFO_DEPTH beats per port for W (between the router and the port) and R (between
//     the port and the merge): the W stream of the engine is in order, so while it feeds one port
//     the other drains its FIFO, and the read merge drains one port while the other fills its
//     FIFO - two ports per direction at about twice one port's bandwidth with granule <= FIFO.
//   * at most ORD_DEPTH sub-bursts outstanding per direction (the order FIFOs); a full order
//     FIFO stalls the request channel.
// Same address -> same port, so two writes to one address stay in order (one port, one ID).
// W beats follow the sub-burst routes in AW order (a beat waits for its sub-burst's AW to be
// issued to its port, AXI A3.3.1 slaves may wait for AWVALID before WREADY).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_axi_ilv #(
    parameter int ID_W       = 2,
    parameter int AW         = 40,
    parameter int ILV_BIT    = 9,      // granule 2^ILV_BIT bytes, 6 < ILV_BIT <= 12
    parameter int FIFO_DEPTH = 32,     // W / R beats buffered per port (power of two)
    parameter int ORD_DEPTH  = 64      // sub-bursts outstanding per direction (power of two)
) (
    input  wire logic              clk,
    input  wire logic              rst,

    // from rsys_axi_dec: write-only master
    input  wire logic [ID_W-1:0]   s_awid,
    input  wire logic [AW-1:0]     s_awaddr,
    input  wire logic [7:0]        s_awlen,
    input  wire logic              s_awvalid,
    output wire logic              s_awready,
    input  wire logic [511:0]      s_wdata,
    input  wire logic [63:0]       s_wstrb,
    input  wire logic              s_wlast,      // not used: the sub-burst routes give the last beats
    input  wire logic              s_wvalid,
    output wire logic              s_wready,
    output wire logic [ID_W-1:0]   s_bid,
    output wire logic [1:0]        s_bresp,
    output wire logic              s_bvalid,
    input  wire logic              s_bready,
    // from rsys_axi_dec: read-only master
    input  wire logic [ID_W-1:0]   s_arid,
    input  wire logic [AW-1:0]     s_araddr,
    input  wire logic [7:0]        s_arlen,
    input  wire logic              s_arvalid,
    output wire logic              s_arready,
    output wire logic [ID_W-1:0]   s_rid,
    output wire logic [511:0]      s_rdata,
    output wire logic [1:0]        s_rresp,
    output wire logic              s_rlast,
    output wire logic              s_rvalid,
    input  wire logic              s_rready,

    // to the PS: two write-only masters (index = port)
    output logic      [ID_W-1:0]   m_awid    [2],
    output logic      [AW-1:0]     m_awaddr  [2],
    output logic      [7:0]        m_awlen   [2],
    output logic                   m_awvalid [2],
    input  wire logic              m_awready [2],
    output wire logic [511:0]      m_wdata   [2],
    output wire logic [63:0]       m_wstrb   [2],
    output wire logic              m_wlast   [2],
    output wire logic              m_wvalid  [2],
    input  wire logic              m_wready  [2],
    input  wire logic [ID_W-1:0]   m_bid     [2],
    input  wire logic [1:0]        m_bresp   [2],
    input  wire logic              m_bvalid  [2],
    output wire logic              m_bready  [2],
    // to the PS: two read-only masters
    output logic      [ID_W-1:0]   m_arid    [2],
    output logic      [AW-1:0]     m_araddr  [2],
    output logic      [7:0]        m_arlen   [2],
    output logic                   m_arvalid [2],
    input  wire logic              m_arready [2],
    input  wire logic [ID_W-1:0]   m_rid     [2],
    input  wire logic [511:0]      m_rdata   [2],
    input  wire logic [1:0]        m_rresp   [2],
    input  wire logic              m_rlast   [2],
    input  wire logic              m_rvalid  [2],
    output wire logic              m_rready  [2],

    output logic      [1:0]        ev_wsub,      // a write sub-burst left on port 0 / 1
    output logic      [1:0]        ev_rsub       // a read sub-burst left on port 0 / 1
);

localparam int GB  = 1 << (ILV_BIT - 6);         // beats per granule
wire  logic wo_pop, bo_pop, ro_pop;              // order FIFO pops (assigned below)
localparam int GBW = ILV_BIT - 6;                // beat index width inside a granule

initial begin
    if (ILV_BIT <= 6 || ILV_BIT > 12) $fatal(1, "rsys_axi_ilv: ILV_BIT must be 7..12");
end

// ---------------------------------------------------------------------------------------------
// Burst splitter (one per direction): the next sub-burst of the request at the input
//   a, left: start address / beats left of the remaining part (the input itself when first)
//   n      : beats of this sub-burst = min(left, beats to the next granule boundary)
// ---------------------------------------------------------------------------------------------
function automatic logic [8:0] room_of(input logic [AW-1:0] a);
    logic [GBW:0] bi;
    bi = {1'b0, a[ILV_BIT-1:6]};
    return 9'(GB) - 9'(bi);
endfunction
function automatic logic [AW-1:0] next_granule(input logic [AW-1:0] a);
    logic [AW-1:0] g;
    g = a;
    g[ILV_BIT-1:0] = '0;
    return g + (AW'(1) << ILV_BIT);
endfunction

// ================================ write direction ================================
logic            ws_first = 1'b1;               // next sub-burst is the first of the input burst
logic [AW-1:0]   ws_addr;
logic [8:0]      ws_left;
wire  logic [AW-1:0] wa  = ws_first ? s_awaddr : ws_addr;
wire  logic [8:0]    wl  = ws_first ? (9'(s_awlen) + 9'd1) : ws_left;
wire  logic [8:0]    wrm = room_of(wa);
wire  logic [8:0]    wn  = (wl < wrm) ? wl : wrm;
wire  logic          wp  = wa[ILV_BIT];
wire  logic          wlast_sub = (wn == wl);

// order FIFOs: W routes (port, beats - 1), B order (port, last sub-burst, ID)
wire  logic          wo_full, wo_valid, bo_full, bo_valid;
wire  logic [8:0]    wo_dout;
wire  logic [ID_W+1:0] bo_dout;
wire  logic          w_slot = !m_awvalid[wp] || m_awready[wp];
wire  logic          w_issue = s_awvalid && w_slot && !wo_full && !bo_full;
assign s_awready = w_issue && wlast_sub;

rsys_fifo #(.WIDTH(9), .DEPTH(ORD_DEPTH)) u_wo (
    .clk(clk), .rst(rst), .din({wp, 8'(wn - 9'd1)}), .wr_en(w_issue), .full(wo_full),
    .dout(wo_dout), .valid(wo_valid), .rd_en(wo_pop), .count()
);
rsys_fifo #(.WIDTH(ID_W + 2), .DEPTH(ORD_DEPTH)) u_bo (
    .clk(clk), .rst(rst), .din({wp, wlast_sub, s_awid}), .wr_en(w_issue), .full(bo_full),
    .dout(bo_dout), .valid(bo_valid), .rd_en(bo_pop), .count()
);

always_ff @(posedge clk) begin
    ev_wsub <= '0;
    for (int p = 0; p < 2; p++) if (m_awvalid[p] && m_awready[p]) m_awvalid[p] <= 1'b0;
    if (w_issue) begin
        m_awvalid[wp] <= 1'b1;
        m_awid[wp]    <= '0;
        m_awaddr[wp]  <= wa;
        m_awlen[wp]   <= 8'(wn - 9'd1);
        ev_wsub[wp]   <= 1'b1;
        ws_first      <= wlast_sub;
        ws_addr       <= next_granule(wa);
        ws_left       <= wl - wn;
    end
    if (rst) begin
        ws_first  <= 1'b1;
        m_awvalid[0] <= 1'b0; m_awvalid[1] <= 1'b0;
    end
end

// W router: the beats of the route at the head of u_wo go to its port's W FIFO; a beat is
// passed only after its sub-burst's AW has been registered for the port (the route is pushed
// with the AW, so a route at the head always has its AW issued or in the AW register)
logic [7:0]  wr_cnt = '0;
wire  logic  wr_p   = wo_dout[8];
wire  logic  wr_end = (wr_cnt == wo_dout[7:0]);
wire  logic  wf_full [2];
wire  logic  wf_valid [2];
wire  logic [576:0] wf_dout [2];
assign s_wready = wo_valid && !wf_full[wr_p];
wire  logic  w_hs = s_wvalid && s_wready;
assign wo_pop = w_hs && wr_end;
always_ff @(posedge clk) begin
    if (w_hs) wr_cnt <= wr_end ? 8'd0 : wr_cnt + 8'd1;
    if (rst) wr_cnt <= '0;
end

for (genvar p = 0; p < 2; p++) begin : g_wf
    rsys_fifo #(.WIDTH(577), .DEPTH(FIFO_DEPTH)) u_wf (
        .clk(clk), .rst(rst), .din({wr_end, s_wstrb, s_wdata}), .wr_en(w_hs && wr_p == 1'(p)),
        .full(wf_full[p]), .dout(wf_dout[p]), .valid(wf_valid[p]), .rd_en(m_wvalid[p] && m_wready[p]),
        .count()
    );
    assign m_wvalid[p] = wf_valid[p];
    assign m_wdata[p]  = wf_dout[p][511:0];
    assign m_wstrb[p]  = wf_dout[p][575:512];
    assign m_wlast[p]  = wf_dout[p][576];
end

// B merge: the head of u_bo names the port of the next B; the B of a sub-burst that is not
// the last of its burst is taken here (its BRESP kept), the last one goes out with the worst
// BRESP of the burst and the original ID
logic [1:0]  b_acc = 2'b00;
wire  logic  bo_p    = bo_dout[ID_W+1];
wire  logic  bo_last = bo_dout[ID_W];
wire  logic  b_in    = bo_valid && m_bvalid[bo_p];
wire  logic [1:0] b_worst = (m_bresp[bo_p] > b_acc) ? m_bresp[bo_p] : b_acc;
assign s_bvalid = b_in && bo_last;
assign s_bid    = bo_dout[ID_W-1:0];
assign s_bresp  = b_worst;
wire  logic  b_take  = b_in && (!bo_last || s_bready);
assign m_bready[0] = bo_valid && !bo_p && (!bo_last || s_bready);
assign m_bready[1] = bo_valid &&  bo_p && (!bo_last || s_bready);
assign bo_pop = b_take;
always_ff @(posedge clk) begin
    if (b_take) b_acc <= bo_last ? 2'b00 : b_worst;
    if (rst) b_acc <= 2'b00;
end

// ================================ read direction ================================
logic            rs_first = 1'b1;
logic [AW-1:0]   rs_addr;
logic [8:0]      rs_left;
wire  logic [AW-1:0] ra  = rs_first ? s_araddr : rs_addr;
wire  logic [8:0]    rl  = rs_first ? (9'(s_arlen) + 9'd1) : rs_left;
wire  logic [8:0]    rrm = room_of(ra);
wire  logic [8:0]    rn  = (rl < rrm) ? rl : rrm;
wire  logic          rp  = ra[ILV_BIT];
wire  logic          rlast_sub = (rn == rl);

wire  logic          ro_full, ro_valid;
wire  logic [ID_W+1:0] ro_dout;
wire  logic          r_slot = !m_arvalid[rp] || m_arready[rp];
wire  logic          r_issue = s_arvalid && r_slot && !ro_full;
assign s_arready = r_issue && rlast_sub;

rsys_fifo #(.WIDTH(ID_W + 2), .DEPTH(ORD_DEPTH)) u_ro (
    .clk(clk), .rst(rst), .din({rp, rlast_sub, s_arid}), .wr_en(r_issue), .full(ro_full),
    .dout(ro_dout), .valid(ro_valid), .rd_en(ro_pop), .count()
);

always_ff @(posedge clk) begin
    ev_rsub <= '0;
    for (int p = 0; p < 2; p++) if (m_arvalid[p] && m_arready[p]) m_arvalid[p] <= 1'b0;
    if (r_issue) begin
        m_arvalid[rp] <= 1'b1;
        m_arid[rp]    <= '0;
        m_araddr[rp]  <= ra;
        m_arlen[rp]   <= 8'(rn - 9'd1);
        ev_rsub[rp]   <= 1'b1;
        rs_first      <= rlast_sub;
        rs_addr       <= next_granule(ra);
        rs_left       <= rl - rn;
    end
    if (rst) begin
        rs_first  <= 1'b1;
        m_arvalid[0] <= 1'b0; m_arvalid[1] <= 1'b0;
    end
end

// R FIFOs per port and the in-order merge
wire  logic  rf_full [2];
wire  logic  rf_valid [2];
wire  logic [514:0] rf_dout [2];      // {rlast, rresp, rdata}
wire  logic  ro_p    = ro_dout[ID_W+1];
wire  logic  ro_last = ro_dout[ID_W];
wire  logic  r_hs    = s_rvalid && s_rready;
assign ro_pop = r_hs && rf_dout[ro_p][514];
for (genvar p = 0; p < 2; p++) begin : g_rf
    rsys_fifo #(.WIDTH(515), .DEPTH(FIFO_DEPTH)) u_rf (
        .clk(clk), .rst(rst), .din({m_rlast[p], m_rresp[p], m_rdata[p]}), .wr_en(m_rvalid[p] && m_rready[p]),
        .full(rf_full[p]), .dout(rf_dout[p]), .valid(rf_valid[p]), .rd_en(r_hs && ro_p == 1'(p)),
        .count()
    );
    assign m_rready[p] = !rf_full[p];
end
assign s_rvalid = ro_valid && rf_valid[ro_p];
assign s_rdata  = rf_dout[ro_p][511:0];
assign s_rresp  = rf_dout[ro_p][513:512];
assign s_rlast  = rf_dout[ro_p][514] && ro_last;
assign s_rid    = ro_dout[ID_W-1:0];

endmodule

`resetall
