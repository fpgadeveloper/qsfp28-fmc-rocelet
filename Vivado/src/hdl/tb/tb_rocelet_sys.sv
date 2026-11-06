// SPDX-License-Identifier: MIT
//
// tb_rocelet_sys - system-level simulation of rocelet_sys (the rocelet engine with
// the design's memory window, work-request queue, raw frames and self-test logic)
// through a model of a QSFP28 loopback: the CMAC TX stream comes back on the CMAC
// RX stream after a fixed latency, TX throttled to ~100 Gb/s (tready duty, or
// random with +rndready), RX without back-pressure. Drives the AXI-Lite port the
// way the firmware does (engine registers +0x00000, system registers +0x10000,
// memory window +0x40000) and checks the counters. Plusargs: +test=<name>
// (default all), +rndready.
//
// Run: Vivado/src/hdl/tb/run_xsim.sh [test] [plusargs]
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module tb_rocelet_sys
    import rsys_pkg::*;
    import rocelet_regs_pkg::*;
#(
    parameter int  NUM_QP   = 16,
    parameter int  RTX_MODE = 0,
    parameter int  LOOP_LAT = 120,     // clocks through the MAC + loopback model
    parameter int  MAC_WIDTH = 512,    // 512 (KCU116 CMAC) or 64 / 256 (ZCU106 omac): MAC_WIDTH=64 run_xsim.sh
    parameter int  ZU = 0,             // 1: the ZynqMP options (PS DDR window, netdev DMA channel): ZU=1 run_xsim.sh
    parameter int  DDR_PORTS = 2       // ZU: PS DDR masters per direction (2 = address-interleaved, the ZCU106): DDRP=1 run_xsim.sh
);
localparam int MB = MAC_WIDTH / 8;

logic clk = 1'b0;
always #1.5515 clk = ~clk;
logic gen_clk = 1'b0;                  // 200 MHz generator clock (IQ16, DNA)
always #2.5 gen_clk = ~gen_clk;
logic sys_rst = 1'b1;

// AXI-Lite
logic [18:0] awaddr, araddr;
logic        awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
logic [31:0] wdata;
wire  logic  awready, wready, bvalid, arready, rvalid;
wire  logic [31:0] rdata;
wire  logic [1:0]  bresp, rresp;

// CMAC model
wire  logic [MAC_WIDTH-1:0] tx_tdata;
wire  logic [MB-1:0]  tx_tkeep;
wire  logic         tx_tvalid, tx_tlast, tx_tuser;
logic               tx_tready = 1'b0;
logic [MAC_WIDTH-1:0] rx_tdata = '0;
logic [MB-1:0]  rx_tkeep = '0;
logic         rx_tvalid = 1'b0, rx_tlast = 1'b0, rx_tuser = 1'b0;
wire  logic [31:0] mac_ctl;
wire  logic       pz_tx_req = mac_ctl[16];
wire  logic       irq;

rocelet_sys #(
    .NUM_QP(NUM_QP), .NUM_MR(16), .READ_DEPTH(16), .RTX_MODE(RTX_MODE), .RING_BYTES(262144), .MAX_WR(128),
    .SELFTEST(1'b1), .MEM_BYTES(262144), .MAC_WIDTH(MAC_WIDTH), .DDR_EN(ZU != 0), .DDR_PORTS(DDR_PORTS), .ODMA_EN(ZU != 0)
) dut (
    .clk(clk), .gen_clk(gen_clk), .sys_rst(sys_rst), .irq(irq), .evt(),
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(4'hF), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
    .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
    .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
    .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
    .rx_tdata(rx_tdata), .rx_tkeep(rx_tkeep), .rx_tvalid(rx_tvalid), .rx_tlast(rx_tlast), .rx_tuser(rx_tuser),
    .tx_tdata(tx_tdata), .tx_tkeep(tx_tkeep), .tx_tvalid(tx_tvalid), .tx_tready(tx_tready),
    .tx_tlast(tx_tlast), .tx_tuser(tx_tuser),
    .mac_ctl(mac_ctl), .mac_pz(), .mac_addr(),
    .mac_stat(16'h1203), .mac_ev('0), .mac_pause('0),     // aligned, RX status, FEC lanes aligned, link up
    .m_axi_ddrw_awid(d_awid[0]), .m_axi_ddrw_awaddr(d_awaddr[0]), .m_axi_ddrw_awlen(d_awlen[0]), .m_axi_ddrw_awsize(),
    .m_axi_ddrw_awburst(), .m_axi_ddrw_awcache(), .m_axi_ddrw_awprot(), .m_axi_ddrw_awvalid(d_awvalid[0]),
    .m_axi_ddrw_awready(d_awready[0]), .m_axi_ddrw_wdata(d_wdata[0]), .m_axi_ddrw_wstrb(d_wstrb[0]), .m_axi_ddrw_wlast(d_wlast[0]),
    .m_axi_ddrw_wvalid(d_wvalid[0]), .m_axi_ddrw_wready(d_wready[0]), .m_axi_ddrw_bid(d_bid[0]), .m_axi_ddrw_bresp(2'b00),
    .m_axi_ddrw_bvalid(d_bvalid[0]), .m_axi_ddrw_bready(d_bready[0]),
    .m_axi_ddrr_arid(d_arid[0]), .m_axi_ddrr_araddr(d_araddr[0]), .m_axi_ddrr_arlen(d_arlen[0]), .m_axi_ddrr_arsize(),
    .m_axi_ddrr_arburst(), .m_axi_ddrr_arcache(), .m_axi_ddrr_arprot(), .m_axi_ddrr_arvalid(d_arvalid[0]),
    .m_axi_ddrr_arready(d_arready[0]), .m_axi_ddrr_rid(d_rid[0]), .m_axi_ddrr_rdata(d_rdata[0]), .m_axi_ddrr_rresp(2'b00),
    .m_axi_ddrr_rlast(d_rlast[0]), .m_axi_ddrr_rvalid(d_rvalid[0]), .m_axi_ddrr_rready(d_rready[0]),
    .m_axi_ddrw1_awid(d_awid[1]), .m_axi_ddrw1_awaddr(d_awaddr[1]), .m_axi_ddrw1_awlen(d_awlen[1]), .m_axi_ddrw1_awsize(),
    .m_axi_ddrw1_awburst(), .m_axi_ddrw1_awcache(), .m_axi_ddrw1_awprot(), .m_axi_ddrw1_awvalid(d_awvalid[1]),
    .m_axi_ddrw1_awready(d_awready[1]), .m_axi_ddrw1_wdata(d_wdata[1]), .m_axi_ddrw1_wstrb(d_wstrb[1]), .m_axi_ddrw1_wlast(d_wlast[1]),
    .m_axi_ddrw1_wvalid(d_wvalid[1]), .m_axi_ddrw1_wready(d_wready[1]), .m_axi_ddrw1_bid(d_bid[1]), .m_axi_ddrw1_bresp(2'b00),
    .m_axi_ddrw1_bvalid(d_bvalid[1]), .m_axi_ddrw1_bready(d_bready[1]),
    .m_axi_ddrr1_arid(d_arid[1]), .m_axi_ddrr1_araddr(d_araddr[1]), .m_axi_ddrr1_arlen(d_arlen[1]), .m_axi_ddrr1_arsize(),
    .m_axi_ddrr1_arburst(), .m_axi_ddrr1_arcache(), .m_axi_ddrr1_arprot(), .m_axi_ddrr1_arvalid(d_arvalid[1]),
    .m_axi_ddrr1_arready(d_arready[1]), .m_axi_ddrr1_rid(d_rid[1]), .m_axi_ddrr1_rdata(d_rdata[1]), .m_axi_ddrr1_rresp(2'b00),
    .m_axi_ddrr1_rlast(d_rlast[1]), .m_axi_ddrr1_rvalid(d_rvalid[1]), .m_axi_ddrr1_rready(d_rready[1]),
    .dma_clk(dma_clk), .m_axis_orx_tdata(o_tdata), .m_axis_orx_tkeep(o_tkeep), .m_axis_orx_tvalid(o_tvalid),
    .m_axis_orx_tready(1'b1), .m_axis_orx_tlast(o_tlast), .s_axis_otx_tdata(t_tdata), .s_axis_otx_tkeep(t_tkeep),
    .s_axis_otx_tvalid(t_tvalid), .s_axis_otx_tready(t_tready), .s_axis_otx_tlast(t_tlast)
);

// ---------------- PS DDR model (ZU): two ports per direction, 64-byte beats ----------------
// One memory behind both ports (ddrm, by 64-byte beat). Each port answers in order with random
// ready gaps and read latencies (port 1 slower), so the two ports finish out of order and
// rsys_axi_ilv must restore the request order. With DDR_PORTS 2 every burst is checked: ID 0, on
// the port of its address (bit 9), inside one 512-byte granule (ddr_viol); ddr_sub[p] counts them.
logic dma_clk = 1'b0;                  // 250 MHz netdev DMA channel clock
always #2.0 dma_clk = ~dma_clk;
wire  logic [1:0]   d_awid [2], d_arid [2];
wire  logic [39:0]  d_awaddr [2], d_araddr [2];
wire  logic [7:0]   d_awlen [2], d_arlen [2];
wire  logic         d_awvalid [2], d_wlast [2], d_wvalid [2], d_bready [2], d_arvalid [2], d_rready [2];
wire  logic [511:0] d_wdata [2];
wire  logic [63:0]  d_wstrb [2];
logic [1:0]   d_bid [2], d_rid [2];
logic         d_bvalid [2], d_rvalid [2], d_rlast [2], d_awready [2], d_wready [2], d_arready [2];
logic [511:0] d_rdata [2];
logic [511:0] ddrm [longint];
longint       ddr_wbytes = 0;
int           ddr_viol = 0;
int           ddr_sub [2] = '{0, 0};
longint       dcyc = 0;
always @(posedge clk) dcyc <= dcyc + 1;
for (genvar p = 0; p < 2; p++) begin : g_dport
    logic [39:0]  aw_qa [$], ar_qa [$];
    logic [1:0]   aw_qi [$], ar_qi [$], b_qi [$];
    int           aw_ql [$], ar_ql [$];
    longint       ar_qt [$];
    int           dwbeat = 0, drbeat = 0;
    initial begin
        d_bid[p] = '0; d_rid[p] = '0; d_bvalid[p] = 1'b0; d_rvalid[p] = 1'b0; d_rlast[p] = 1'b0; d_rdata[p] = '0;
        d_awready[p] = 1'b1; d_wready[p] = 1'b1; d_arready[p] = 1'b1;
    end
    always @(posedge clk) begin
        if (d_awvalid[p] && d_awready[p]) begin
            aw_qa.push_back(d_awaddr[p]); aw_qi.push_back(d_awid[p]); aw_ql.push_back(int'(d_awlen[p]));
            if (DDR_PORTS == 2) begin
                ddr_sub[p]++;
                if (d_awid[p] != 0 || d_awaddr[p][9] != p || (d_awaddr[p][8:6] + d_awlen[p]) > 7) begin
                    ddr_viol++;
                    if (ddr_viol < 5) $display("FAIL PS DDR port %0d AW id %0d addr %h len %0d", p, d_awid[p], d_awaddr[p], d_awlen[p]);
                end
            end
        end
        if (d_wvalid[p] && d_wready[p]) begin
            automatic longint k = (aw_qa[0] >> 6) + dwbeat;
            automatic logic [511:0] old = ddrm.exists(k) ? ddrm[k] : '0;
            for (int b = 0; b < 64; b++) if (d_wstrb[p][b]) begin old[b*8 +: 8] = d_wdata[p][b*8 +: 8]; ddr_wbytes++; end
            ddrm[k] = old;
            if (d_wlast[p] != (dwbeat == aw_ql[0])) begin
                ddr_viol++;
                if (ddr_viol < 5) $display("FAIL PS DDR port %0d WLAST at beat %0d of %0d", p, dwbeat, aw_ql[0] + 1);
            end
            dwbeat++;
            if (d_wlast[p]) begin dwbeat = 0; void'(aw_qa.pop_front()); void'(aw_ql.pop_front()); b_qi.push_back(aw_qi.pop_front()); end
        end
        if (d_bvalid[p] && d_bready[p]) d_bvalid[p] <= 1'b0;
        if ((!d_bvalid[p] || d_bready[p]) && b_qi.size() > 0 && $urandom_range(0, 3) != 0) begin
            d_bvalid[p] <= 1'b1; d_bid[p] <= b_qi.pop_front();
        end
        if (d_arvalid[p] && d_arready[p]) begin
            ar_qa.push_back(d_araddr[p]); ar_qi.push_back(d_arid[p]); ar_ql.push_back(int'(d_arlen[p]));
            ar_qt.push_back(dcyc + $urandom_range(4, p ? 60 : 20));
            if (DDR_PORTS == 2) begin
                ddr_sub[p]++;
                if (d_arid[p] != 0 || d_araddr[p][9] != p || (d_araddr[p][8:6] + d_arlen[p]) > 7) begin
                    ddr_viol++;
                    if (ddr_viol < 5) $display("FAIL PS DDR port %0d AR id %0d addr %h len %0d", p, d_arid[p], d_araddr[p], d_arlen[p]);
                end
            end
        end
        // random ready gaps (ZU tests only; harmless elsewhere)
        d_awready[p] <= $urandom_range(0, 3) != 0;
        d_wready[p]  <= $urandom_range(0, 4) != 0;
        d_arready[p] <= $urandom_range(0, 3) != 0;
        if (!d_rvalid[p] || d_rready[p]) begin
            d_rvalid[p] <= 1'b0;
            if (ar_qa.size() > 0 && ar_qt[0] <= dcyc && $urandom_range(0, 4) != 0) begin
                automatic longint k = (ar_qa[0] >> 6) + drbeat;
                d_rvalid[p] <= 1'b1; d_rid[p] <= ar_qi[0]; d_rdata[p] <= ddrm.exists(k) ? ddrm[k] : '0;
                d_rlast[p] <= (drbeat == ar_ql[0]);
                if (drbeat == ar_ql[0]) begin
                    drbeat = 0; void'(ar_qa.pop_front()); void'(ar_qi.pop_front()); void'(ar_ql.pop_front()); void'(ar_qt.pop_front());
                end else drbeat++;
            end
        end
    end
end

// ---------------- netdev DMA channel model (ZU): S2MM capture, MM2S source ----------------
wire  logic [511:0] o_tdata;
wire  logic [63:0]  o_tkeep;
wire  logic         o_tvalid, o_tlast, t_tready;
logic [511:0] t_tdata = '0;
logic [63:0]  t_tkeep = '0;
logic         t_tvalid = 1'b0, t_tlast = 1'b0;
logic [7:0]   orx_buf [0:16383];
int           orx_n = 0, orx_frames = 0, orx_len [$];
always @(posedge dma_clk) if (o_tvalid) begin
    for (int b = 0; b < 64; b++) if (o_tkeep[b]) begin orx_buf[orx_n % 16384] = o_tdata[b*8 +: 8]; orx_n++; end
    if (o_tlast) begin orx_frames++; orx_len.push_back(orx_n); end
end

// TX accepts 5 of 8 clocks (0.625 beats/clock ~ 103 Gb/s at 322 MHz), or random
logic [2:0]  duty = '0;
logic [31:0] trng = 32'h1234_5678;
bit rnd_ready = 0;
initial rnd_ready = $test$plusargs("rndready");
always_ff @(posedge clk) begin
    duty <= duty + 3'd1;
    trng <= {trng[30:0], trng[31] ^ trng[21] ^ trng[1] ^ trng[0]};
    tx_tready <= rnd_ready ? (trng[3:0] > 4'd6) : (MAC_WIDTH < 512 || duty < 3'd5);
end
// loopback delay line
typedef struct packed { logic v; logic l; logic [MB-1:0] k; logic [MAC_WIDTH-1:0] d; } beat_t;
beat_t line [LOOP_LAT];
initial for (int i = 0; i < LOOP_LAT; i++) line[i] = '0;
always_ff @(posedge clk) begin
    line[0] <= '{v: tx_tvalid && tx_tready, l: tx_tlast, k: tx_tkeep, d: tx_tdata};
    for (int i = 1; i < LOOP_LAT; i++) line[i] <= line[i-1];
    rx_tvalid <= line[LOOP_LAT-1].v;
    rx_tlast  <= line[LOOP_LAT-1].l;
    rx_tkeep  <= line[LOOP_LAT-1].k;
    rx_tdata  <= line[LOOP_LAT-1].d;
end
// the CMAC TX must never see tvalid drop inside a frame
logic in_tx = 1'b0;
int   underflows = 0;
always_ff @(posedge clk) begin
    if (tx_tvalid && tx_tready) in_tx <= !tx_tlast;
    if (in_tx && !tx_tvalid) underflows <= underflows + 1;
end

// ---------------- AXI-Lite tasks ----------------
task automatic wr32(input logic [18:0] a, input logic [31:0] d);
    @(posedge clk);
    awaddr <= a; awvalid <= 1; wdata <= d; wvalid <= 1;
    fork
        begin do @(posedge clk); while (!awready); awvalid <= 0; end
        begin do @(posedge clk); while (!wready); wvalid <= 0; end
    join
    do @(posedge clk); while (!bvalid);
endtask
task automatic rd32(input logic [18:0] a, output logic [31:0] d);
    @(posedge clk);
    araddr <= a; arvalid <= 1;
    do @(posedge clk); while (!arready);
    arvalid <= 0;
    do @(posedge clk); while (!rvalid);
    d = rdata;
endtask
localparam logic [18:0] SYS = 19'h10000, MEM = 19'h40000;
task automatic ew(input int off, input logic [31:0] d); wr32(19'(off), d); endtask
task automatic er(input int off, output logic [31:0] d); rd32(19'(off), d); endtask
task automatic cfgw(input int i, input logic [31:0] d); wr32(SYS + 19'(4*i), d); endtask
task automatic cfgr(input int i, output logic [31:0] d); rd32(SYS + 19'(4*i), d); endtask
task automatic cnt(input int i, output logic [31:0] d); rd32(SYS + 19'(32'h800 + 4*i), d); endtask
task automatic svr(input int i, output logic [31:0] d); rd32(SYS + 19'(32'h400 + 4*i), d); endtask
task automatic bcr(input int i, output logic [63:0] d);
    logic [31:0] lo, hi;
    rd32(SYS + 19'(32'hC00 + 8*i), lo);
    rd32(SYS + 19'(32'hC04 + 8*i), hi);
    d = {hi, lo};
endtask

int errors = 0;
task automatic expect_eq(input string what, input longint got, input longint want);
    if (got != want) begin
        $display("FAIL %s: got %0d want %0d", what, got, want);
        errors++;
    end else $display("  ok %s = %0d", what, got);
endtask
task automatic expect_ge(input string what, input longint got, input longint want);
    if (got < want) begin
        $display("FAIL %s: got %0d want >= %0d", what, got, want);
        errors++;
    end else $display("  ok %s = %0d (>= %0d)", what, got, want);
endtask

localparam logic [23:0] QB   = 24'h000100;
localparam logic [63:0] PAT  = 64'h0000_0100_0000_0000;   // bit 40: pattern region
localparam logic [31:0] MYIP = 32'hC0A81402;
localparam logic [47:0] MYMAC = 48'h020A35726C01;
localparam logic [47:0] HMAC  = 48'h020000000099;
localparam logic [31:0] HIP   = 32'hC0A81463;
localparam logic [31:0] SEED  = 32'h5EED1234;

// ---------------- configuration (as the firmware's loop_setup) ----------------
task automatic qp(input int q, input logic [23:0] sq, input logic [23:0] rq, input int pmtu, input logic [23:0] dqpn,
                  input logic [47:0] dmac, input logic [31:0] dip);
    ew(R_QP_INDEX, q);
    ew(R_QP_FLAGS, 1);
    ew(R_QP_SQ_PSN, sq);
    ew(R_QP_RQ_PSN, rq);
    ew(R_QP_PMTU, pmtu);
    ew(R_QP_DMAC_LO, dmac[31:0]);
    ew(R_QP_DMAC_HI, dmac[47:32]);
    ew(R_QP_DIP0, dip);
    ew(R_QP_DQPN, dqpn);
    ew(R_QP_UDP, 32'hC000 + q);
    ew(R_QP_COMMIT, 1);
endtask
task automatic mr(input int i, input logic [31:0] key, input logic [63:0] va, input logic [31:0] len,
                  input logic [63:0] la, input logic [2:0] flags);
    ew(R_MR_INDEX, i); ew(R_MR_RKEY, key); ew(R_MR_VA_LO, va[31:0]); ew(R_MR_VA_HI, va[63:32]);
    ew(R_MR_LEN, len); ew(R_MR_LADDR_LO, la[31:0]); ew(R_MR_LADDR_HI, la[63:32]);
    ew(R_MR_FLAGS, flags); ew(R_MR_COMMIT, 1);
endtask
function automatic logic [23:0] psn0(input int q); return 24'(32'h10000 * (q + 1) + 32'h123); endfunction

task automatic setup(input int pmtu);
    cfgw(C_WG_CTRL, 2);
    cfgw(C_INJ_CTRL, 0); cfgw(C_RINJ_CTRL, 0); cfgw(C_CQ_CTRL, 0);
    ew(R_MAC_LO, MYMAC[31:0]); ew(R_MAC_HI, MYMAC[47:32]); ew(R_IP4, MYIP);
    ew(R_IP_HDR, 32'h4000); ew(R_ACK_TIMEOUT, 20);
    for (int q = 0; q < NUM_QP; q++) begin
        if (q == NUM_QP - 1) qp(q, psn0(q), 24'h400000, pmtu, 24'h50, HMAC, HIP);
        else if (q == NUM_QP - 2) qp(q, psn0(q), psn0(q), pmtu, QB + q, MYMAC, MYIP);
        else qp(q, psn0(q), psn0(q ^ 1), pmtu, QB + (q ^ 1), MYMAC, MYIP);
    end
    mr(0, 32'h1000, PAT, 32'h4000_0000, PAT, 3'b111);
    mr(1, 32'h2001, 0, 32'h40000, 0, 3'b111);
    mr(2, 32'h3002, 0, 32'h40000, 0, 3'b101);
    cfgw(C_WG_SEED, SEED); cfgw(C_WC_SEED, SEED);
    cfgw(C_WC_BASE_LO, PAT[31:0]); cfgw(C_WC_BASE_HI, PAT[63:32]);
    ew(R_CMD, 3);
    cfgw(C_CTRL, 2); cfgw(C_CTRL, 0);
endtask

task automatic run_wg(input int qp0, input int op, input logic [63:0] va, input int window, input int len,
                      input logic [31:0] rkey, input int count);
    cfgw(C_WG_QP, qp0 | (1 << 8)); cfgw(C_WG_OP, op);
    cfgw(C_WG_VA_LO, va[31:0]); cfgw(C_WG_VA_HI, va[63:32]); cfgw(C_WG_WINDOW, window);
    cfgw(C_WG_LEN, len); cfgw(C_WG_RKEY, rkey); cfgw(C_WG_COUNT, count); cfgw(C_WG_GAP, 0);
    cfgw(C_WG_IMM, 32'h10000);
    cfgw(C_WG_CTRL, 1);
endtask

task automatic wait_idle(input int max_us);
    logic [31:0] st, out, f0, f1;
    int t = 0;
    f0 = 0;
    forever begin
        repeat (322) @(posedge clk);
        t++;
        svr(S_STATUS, st);
        er(R_WR_OUTSTANDING, out);
        cnt(E_TX_FRAMES, f1);
        if (!st[1] && out == 0 && f1 == f0 && t > 2) break;
        f0 = f1;
        if (t > max_us) begin $display("TIMEOUT waiting for idle"); errors++; break; end
    end
endtask

task automatic report(input string tag);
    logic [31:0] v;
    $display("---- %s @ %0t", tag, $time);
    for (int i = 0; i < rsys_pkg::NCNT; i++) begin cnt(i, v); if (v) $display("  sys cnt[%0d] = %0d", i, v); end
    for (int i = 0; i < 49; i++) begin er(32'h200 + 4*i, v); if (v) $display("  eng cnt[%0d] = %0d", i, v); end
    er(R_LAST_REQ_ERR, v); $display("  last requester error %h", v);
    er(R_LAST_RESP_ERR, v); $display("  last responder error %h", v);
    $display("  CMAC TX underflows %0d", underflows);
endtask

// ---------------- tests ----------------
task automatic t_write(input int pmtu, input int op, input int len, input int n);
    logic [31:0] v;
    logic [63:0] b;
    $display("==== WG op %0d pmtu %0d len %0d x %0d", op, 1 << pmtu, len, n);
    setup(pmtu);
    run_wg(0, op, PAT, 1 << 20, len, 32'h1000, n);
    wait_idle(3000);
    report("write");
    cnt(E_WG_ISSUED, v); expect_eq("issued", v, n);
    cnt(E_WC, v); expect_eq("work completions", v, n);
    cnt(E_WC_ERR, v); expect_eq("completion errors", v, 0);
    if (op < 2) begin
        bcr(B_WC_BYTES, b); expect_eq("write bytes", b, n * len);
        cnt(E_WC_MISM, v); expect_eq("write mismatch", v, 0);
    end else begin
        bcr(B_SC_BYTES, b); expect_eq("send bytes", b, n * len);
        cnt(E_SC_MISM, v); expect_eq("send mismatch", v, 0);
        cnt(E_RC_SEND, v); expect_eq("send completions", v, n);
    end
    if (op == 1 || op == 3) begin
        cnt(E_RC, v); expect_eq("receive completions", v, n);
        cnt(E_RC_IMM_SEQ, v); expect_eq("immediate sequence breaks", v, 0);
    end
    er(R_CNT_RX_ICRC_BAD, v); expect_eq("ICRC bad", v, 0);
    er(R_STATUS, v); expect_eq("engine error latch", v[4], 0);
    expect_eq("underflows", underflows, 0);
endtask

task automatic t_inject(input bit rx, input int action, input int cls, input int skip, input int count);
    logic [31:0] v;
    logic [63:0] b;
    int n = 64;
    $display("==== INJECT %s action %0d class %0h skip %0d count %0d", rx ? "RX" : "TX", action, cls, skip, count);
    setup(12);
    cfgw(rx ? C_RINJ_CLASS : C_INJ_CLASS, cls); cfgw(rx ? C_RINJ_SKIP : C_INJ_SKIP, skip);
    cfgw(rx ? C_RINJ_COUNT : C_INJ_COUNT, count); cfgw(rx ? C_RINJ_BYTE : C_INJ_BYTE, 53);
    cfgw(rx ? C_RINJ_CTRL : C_INJ_CTRL, 32'h100 | action);
    run_wg(0, 0, PAT, 1 << 20, 4096, 32'h1000, n);
    wait_idle(5000);
    report("inject");
    cnt(rx ? E_RINJ_DONE : E_INJ_DONE, v); expect_eq("injected", v, count);
    cnt(E_WC, v); expect_eq("work completions", v, n);
    cnt(E_WC_ERR, v); expect_eq("completion errors", v, 0);
    cnt(E_WC_MISM, v); expect_eq("mismatch", v, 0);
    // at 100G every lost packet is resent exactly once; through a narrow MAC (8x slower link) the
    // go-back-N window is longer and a duplicate WRITE may be re-executed (same data, same address)
    if (MAC_WIDTH == 512) begin bcr(B_WC_BYTES, b); expect_eq("write bytes (zero loss)", b, n * 4096); end
    else begin bcr(B_WC_BYTES, b); expect_ge("write bytes (zero loss, duplicates allowed)", b, n * 4096); end
    if (cls & 1) begin er(R_CNT_REQ_RTX, v); expect_ge("recoveries", v, 1); end
    cfgw(C_INJ_CTRL, 0); cfgw(C_RINJ_CTRL, 0);
endtask

// firmware WR queue: payload from the memory window, completions in the queues
task automatic t_wrq();
    logic [31:0] v, w, s;
    logic [511:0] pb;
    int mm;
    $display("==== firmware WR queue through the memory window");
    setup(12);
    cfgw(C_CQ_CTRL, 3);
    // payload at 0x10000 = pattern(0x20000 + o): 4 KB
    for (int o = 0; o < 4096; o += 4) begin
        if (o % 64 == 0) pb = pat_beat(64'h20000 + o, SEED);
        wr32(MEM + 19'(32'h10000 + o), pb[(o % 64) * 8 +: 32]);
    end
    cfgw(C_WQ_QP, 0); cfgw(C_WQ_OP, 0); cfgw(C_WQ_VA_LO, 32'h20000); cfgw(C_WQ_VA_HI, 0); cfgw(C_WQ_RKEY, 32'h2001);
    cfgw(C_WQ_LEN, 4096); cfgw(C_WQ_IMM, 0); cfgw(C_WQ_LA_LO, 32'h10000); cfgw(C_WQ_LA_HI, 0); cfgw(C_WQ_ID, 32'h77);
    cfgw(C_WQ_POST, 1);
    // WRITE with immediate, 1 KB
    cfgw(C_WQ_OP, 1); cfgw(C_WQ_LEN, 1024); cfgw(C_WQ_IMM, 32'hABCD0001); cfgw(C_WQ_ID, 32'h78);
    cfgw(C_WQ_POST, 1);
    wait_idle(500);
    report("wrq");
    svr(S_WCQ, v); expect_eq("first work completion valid", v[31], 1); expect_eq("first WC id", v[15:0], 16'h77);
    expect_eq("first WC status", v[30:24], 0);
    cfgw(C_CQ_POP, 1);
    svr(S_WCQ, v); expect_eq("second WC id", v[15:0], 16'h78);
    cfgw(C_CQ_POP, 1);
    svr(S_RCQ, v); expect_eq("receive completion valid", v[31], 1); expect_eq("receive completion qp", v[23:16], 1);
    svr(S_RCQ_IMM, w); expect_eq("receive completion imm", w, 32'hABCD0001);
    svr(S_RCQ_LEN, s); expect_eq("receive completion length", s, 1024);
    cfgw(C_CQ_POP, 2);
    mm = 0;
    for (int o = 0; o < 4096; o += 4) begin
        rd32(MEM + 19'(32'h20000 + o), w);
        rd32(MEM + 19'(32'h10000 + o), s);
        if (w != s) mm++;
    end
    expect_eq("memory window copy mismatches", mm, 0);
    cnt(E_WC_MISM, v); expect_eq("write checker mismatch", v, 0);
    cfgw(C_CQ_CTRL, 0);
endtask

// ---------------- raw frames from the firmware's "host" QP ----------------
function automatic logic [31:0] crc32_byte(input logic [31:0] c, input logic [7:0] b);
    c = c ^ {24'd0, b};
    for (int k = 0; k < 8; k++) c = c[0] ? (32'hEDB88320 ^ (c >> 1)) : (c >> 1);
    return c;
endfunction
logic [7:0] rf [0:4199];
logic [7:0] cf [0:4199];
function automatic logic [31:0] icrc_of(input logic [7:0] f [0:4199], input int n);
    logic [31:0] c = 32'hFFFFFFFF;
    for (int i = 0; i < 8; i++) c = crc32_byte(c, 8'hFF);
    for (int i = 14; i < n; i++) begin
        int o = i - 14;
        logic [7:0] b = f[i];
        if (o == 1 || o == 8 || o == 10 || o == 11 || o == 26 || o == 27 || o == 32) b = 8'hFF;
        c = crc32_byte(c, b);
    end
    return ~c;
endfunction
task automatic raw_send(input int n);
    for (int w = 0; w < (n + 3) / 4; w++)
        wr32(SYS + 19'(32'h1000 + 4*w), {rf[4*w+3], rf[4*w+2], rf[4*w+1], rf[4*w]});
    cfgw(C_RAW_LEN, n);
    cfgw(C_RAW_SEND, 1);
endtask

task automatic t_read(input int pmtu, input int len, input logic [31:0] rkey = 32'h2001,
                      input logic [63:0] va = 64'h8000, input bit fill = 1);
    logic [31:0] v, st, w, ic, sum;
    logic [511:0] pb;
    int clen, npk, mm;
    $display("==== READ len %0d pmtu %0d R_Key %h VA %h (host QP raw request)", len, 1 << pmtu, rkey, va);
    setup(pmtu);
    if (fill) begin
        for (int o = 0; o < len; o += 4) begin
            if (o % 64 == 0) pb = pat_beat(64'h8000 + o, SEED);
            wr32(MEM + 19'(32'h8000 + o), pb[(o % 64) * 8 +: 32]);
        end
    end
    npk = (len + (1 << pmtu) - 1) >> pmtu;
    cfgw(C_CAP_MATCH, (32'h50 << 8) | (npk == 1 ? 32'h10 : 32'h0D));
    cfgw(C_CAP_CTRL, 32'h7);
    for (int i = 0; i < 128; i++) rf[i] = 0;
    for (int i = 0; i < 6; i++) begin rf[i] = MYMAC[(5-i)*8 +: 8]; rf[6+i] = HMAC[(5-i)*8 +: 8]; end
    rf[12] = 8'h08; rf[13] = 8'h00;
    rf[14] = 8'h45; {rf[16], rf[17]} = 16'd60; rf[20] = 8'h40; rf[22] = 8'd64; rf[23] = 8'd17;
    {rf[26], rf[27], rf[28], rf[29]} = HIP; {rf[30], rf[31], rf[32], rf[33]} = MYIP;
    sum = 0;
    for (int i = 14; i < 34; i += 2) sum += {rf[i], rf[i+1]};
    sum = (sum & 32'hFFFF) + (sum >> 16); sum = (sum & 32'hFFFF) + (sum >> 16);
    {rf[24], rf[25]} = ~sum[15:0];
    {rf[34], rf[35]} = 16'hC0DE; {rf[36], rf[37]} = 16'd4791; {rf[38], rf[39]} = 16'd40;
    rf[42] = 8'h0C; rf[43] = 8'h40; rf[44] = 8'hFF; rf[45] = 8'hFF; {rf[47], rf[48], rf[49]} = QB + NUM_QP - 1;
    {rf[51], rf[52], rf[53]} = 24'h400000;
    for (int i = 0; i < 8; i++) rf[54 + i] = 8'(va >> ((7-i)*8));
    {rf[62], rf[63], rf[64], rf[65]} = rkey; {rf[66], rf[67], rf[68], rf[69]} = len;
    ic = icrc_of(rf, 70);
    {rf[73], rf[72], rf[71], rf[70]} = ic;
    raw_send(74);
    repeat (322 * 30) @(posedge clk);
    report("read");
    cnt(E_TX_OP_RDRSP, v); expect_eq("READ responses sent", v, npk);
    cnt(E_RX_OP_RDRSP, v); expect_eq("READ responses received (loopback)", v, npk);
    cnt(E_RAW_SENT, v); expect_eq("raw frames sent", v, 1);
    svr(S_CAP_STATUS, st);
    expect_eq("captured", st[0], 1);
    clen = (st >> 4) & 32'h1FFF;
    for (int i = 0; i < (clen + 3) / 4; i++) begin
        rd32(SYS + 19'(32'h2000 + 4*i), w);
        for (int b = 0; b < 4; b++) if (4*i + b < clen) cf[4*i + b] = w[8*b +: 8];
    end
    expect_eq("captured opcode", cf[42], npk == 1 ? 8'h10 : 8'h0D);
    expect_eq("captured PSN", {cf[51], cf[52], cf[53]}, 24'h400000);
    expect_eq("AETH syndrome", cf[54], 8'h1F);
    expect_eq("ICRC of the capture", {cf[clen-1], cf[clen-2], cf[clen-3], cf[clen-4]}, icrc_of(cf, clen - 4));
    mm = 0;
    for (int i = 0; i < ((npk == 1) ? len : (1 << pmtu)); i++) begin
        if (i % 64 == 0) pb = pat_beat(va + i, SEED);
        if (cf[58 + i] != pb[(i % 64) * 8 +: 8]) mm++;
    end
    expect_eq("READ payload vs memory", mm, 0);
endtask


// a RoCE frame from the host QP (0x50) to engine QP n-1: op, PSN, AckReq, optional RETH
// (va, rkey, len) and a payload of plen bytes of pattern(va); returns the frame length
task automatic host_frame(input logic [7:0] op, input logic [23:0] psn, input bit ackreq, input bit with_reth,
                          input logic [63:0] va, input logic [31:0] rkey, input logic [31:0] dlen,
                          input int plen, output int flen);
    logic [31:0] ic, sum;
    logic [511:0] pb;
    int n, l4, pad;
    pad = (4 - (plen % 4)) % 4;
    l4 = 8 + 12 + (with_reth ? 16 : 0) + plen + pad + 4;
    for (int i = 0; i < 4200; i++) rf[i] = 0;
    for (int i = 0; i < 6; i++) begin rf[i] = MYMAC[(5-i)*8 +: 8]; rf[6+i] = HMAC[(5-i)*8 +: 8]; end
    rf[12] = 8'h08; rf[13] = 8'h00;
    rf[14] = 8'h45; {rf[16], rf[17]} = 16'(20 + l4); rf[20] = 8'h40; rf[22] = 8'd64; rf[23] = 8'd17;
    {rf[26], rf[27], rf[28], rf[29]} = HIP; {rf[30], rf[31], rf[32], rf[33]} = MYIP;
    sum = 0;
    for (int i = 14; i < 34; i += 2) sum += {rf[i], rf[i+1]};
    sum = (sum & 32'hFFFF) + (sum >> 16); sum = (sum & 32'hFFFF) + (sum >> 16);
    {rf[24], rf[25]} = ~sum[15:0];
    {rf[34], rf[35]} = 16'hC0DE; {rf[36], rf[37]} = 16'd4791; {rf[38], rf[39]} = 16'(l4);
    rf[42] = op; rf[43] = 8'(8'h40 | (pad << 4)); rf[44] = 8'hFF; rf[45] = 8'hFF;
    {rf[47], rf[48], rf[49]} = QB + NUM_QP - 1;
    rf[50] = ackreq ? 8'h80 : 8'h00; {rf[51], rf[52], rf[53]} = psn;
    n = 54;
    if (with_reth) begin
        for (int i = 0; i < 8; i++) rf[n + i] = 8'(va >> ((7-i)*8));
        {rf[n+8], rf[n+9], rf[n+10], rf[n+11]} = rkey; {rf[n+12], rf[n+13], rf[n+14], rf[n+15]} = dlen;
        n += 16;
    end
    for (int i = 0; i < plen; i++) begin
        if (i % 64 == 0) pb = pat_beat(va + i, SEED);
        rf[n + i] = pb[(i % 64) * 8 +: 8];
    end
    n += plen + pad;
    ic = icrc_of(rf, n);
    {rf[n+3], rf[n+2], rf[n+1], rf[n]} = ic;
    flen = n + 4;
endtask

// WRITE Only from the host QP: good ICRC (ACKed, data in memory), bad ICRC (counted and dropped),
// good again with the same PSN (ACKed)
task automatic t_icrc();
    logic [31:0] v, b0, st, w;
    logic [511:0] pb;
    int flen, mm;
    $display("==== ICRC: host WRITE Only good / bad / good");
    setup(12);
    for (int o = 0; o < 256; o += 4) wr32(MEM + 19'(32'h30000 + o), 0);
    er(R_CNT_RX_ICRC_BAD, b0);
    cfgw(C_CAP_MATCH, (32'h50 << 8) | 32'h11); cfgw(C_CAP_CTRL, 32'h7);
    host_frame(8'h0A, 24'h400000, 1, 1, 64'h30000, 32'h2001, 256, 256, flen);
    raw_send(flen);
    repeat (322 * 5) @(posedge clk);
    svr(S_CAP_STATUS, st); expect_eq("ACK captured", st[0], 1);
    rd32(SYS + 19'(32'h2000 + 52), w);     // bytes 52..55: PSN[15:0], syndrome
    expect_eq("ACK PSN low bytes", {w[7:0], w[15:8]}, 16'h0000);
    expect_eq("ACK syndrome", w[23:16], 8'h1F);
    mm = 0;
    for (int o = 0; o < 256; o += 4) begin
        if (o % 64 == 0) pb = pat_beat(64'h30000 + o, SEED);
        rd32(MEM + 19'(32'h30000 + o), w);
        if (w != pb[(o % 64) * 8 +: 32]) mm++;
    end
    expect_eq("memory after the good WRITE (mismatched words)", mm, 0);
    cfgw(C_CAP_CTRL, 32'h7);
    host_frame(8'h0A, 24'h400001, 1, 1, 64'h30000, 32'h2001, 256, 256, flen);
    rf[flen - 1] = rf[flen - 1] ^ 8'h01;
    raw_send(flen);
    repeat (322 * 5) @(posedge clk);
    er(R_CNT_RX_ICRC_BAD, v); expect_eq("ICRC errors counted", v - b0, 1);
    svr(S_CAP_STATUS, st); expect_eq("no ACK for the bad frame", st[0], 0);
    host_frame(8'h0A, 24'h400001, 1, 1, 64'h30000, 32'h2001, 256, 256, flen);
    raw_send(flen);
    repeat (322 * 5) @(posedge clk);
    svr(S_CAP_STATUS, st); expect_eq("ACK for the retry", st[0], 1);
    rd32(SYS + 19'(32'h2000 + 52), w);
    expect_eq("retry ACK PSN low byte", w[15:8], 8'h01);
    er(R_STATUS, v); expect_eq("engine error latch", v[4], 0);
endtask

// WRITE with the read-only key of the memory window: NAK remote access, both QPs to error
task automatic t_access();
    logic [31:0] v, q, r;
    logic [63:0] b;
    $display("==== access error: WRITE with a read-only R_Key");
    setup(12);
    run_wg(0, 0, 64'h1000, 1 << 16, 4096, 32'h3002, 1);
    wait_idle(500);
    cnt(E_TX_OP_NAK, v); expect_eq("NAK frames sent", v, 1);
    cnt(E_WC_ERR, v); expect_eq("work completions with an error", v, 1);
    bcr(B_WC_BYTES, b); expect_eq("bytes written", b, 0);
    er(R_LAST_RESP_ERR, r); er(R_LAST_REQ_ERR, q);
    $display("  last responder error %h, last requester error %h", r, q);
    expect_eq("responder error valid", r[31], 1); expect_eq("responder error code", r[7:0], 8'h62);
    expect_eq("responder error QP", r[15:8], 1);
    expect_eq("requester error valid", q[31], 1); expect_eq("requester error code", q[7:0], 8'h62);
    expect_eq("requester error QP", q[15:8], 0);
endtask

task automatic t_arp();
    logic [31:0] v;
    $display("==== ARP request (broadcast) for the FPGA's IP");
    setup(12);
    for (int i = 0; i < 64; i++) rf[i] = (i >= 42) ? 8'hA5 : 8'h00;
    for (int i = 0; i < 6; i++) begin rf[i] = 8'hFF; rf[6+i] = HMAC[(5-i)*8 +: 8]; rf[22+i] = HMAC[(5-i)*8 +: 8]; end
    rf[12] = 8'h08; rf[13] = 8'h06;
    {rf[14], rf[15]} = 16'h0001; {rf[16], rf[17]} = 16'h0800; rf[18] = 6; rf[19] = 4; {rf[20], rf[21]} = 16'h0001;
    {rf[28], rf[29], rf[30], rf[31]} = HIP;
    for (int i = 32; i < 38; i++) rf[i] = 0;
    {rf[38], rf[39], rf[40], rf[41]} = MYIP;
    cfgw(C_CAP_MATCH, 0); cfgw(C_CAP_CTRL, 32'h5);       // mode 2: bytes 47..49 == 0 (the reply)
    raw_send(60);
    repeat (322 * 5) @(posedge clk);
    er(R_CNT_TX_ARP_ICMP, v); expect_eq("ARP replies", v, 1);
    svr(S_CAP_STATUS, v); expect_eq("reply captured", v[0], 1);
endtask

// ---------------- HSB: control-plane receive FIFO ----------------
// a UDP frame (IPv4, no options) of total length n: dst MAC, UDP ports, payload bytes p0.. = pseudo
task automatic udp_frame(input logic [47:0] dmac, input logic [31:0] dip, input logic [15:0] sport,
                         input logic [15:0] dport, input int n, input int seed);
    logic [31:0] sum;
    for (int i = 0; i < n; i++) rf[i] = 8'((i * 7 + seed) & 255);
    for (int i = 0; i < 6; i++) begin rf[i] = dmac[(5-i)*8 +: 8]; rf[6+i] = HMAC[(5-i)*8 +: 8]; end
    rf[12] = 8'h08; rf[13] = 8'h00;
    rf[14] = 8'h45; rf[15] = 0; {rf[16], rf[17]} = 16'(n - 14); rf[18] = 0; rf[19] = 0; rf[20] = 8'h40; rf[21] = 0;
    rf[22] = 8'd64; rf[23] = 8'd17; rf[24] = 0; rf[25] = 0;
    {rf[26], rf[27], rf[28], rf[29]} = HIP; {rf[30], rf[31], rf[32], rf[33]} = dip;
    sum = 0;
    for (int i = 14; i < 34; i += 2) sum += {rf[i], rf[i+1]};
    sum = (sum & 32'hFFFF) + (sum >> 16); sum = (sum & 32'hFFFF) + (sum >> 16);
    {rf[24], rf[25]} = ~sum[15:0];
    {rf[34], rf[35]} = sport; {rf[36], rf[37]} = dport; {rf[38], rf[39]} = 16'(n - 34); rf[40] = 0; rf[41] = 0;
endtask

task automatic crx_check_head(input string what, input int n, input int seed, input logic [47:0] dmac,
                              input logic [15:0] dport);
    logic [31:0] st, w;
    int mm;
    logic [7:0] e;
    svr(S_CRX_STATUS, st);
    expect_eq({what, ": head length"}, st[27:16], n);
    mm = 0;
    for (int i = 0; i < (n + 3) / 4; i++) begin
        rd32(SYS + 19'(32'h8000 + 4*i), w);
        for (int b = 0; b < 4; b++) if (4*i + b < n) begin
            int k = 4*i + b;
            if (k < 6) e = dmac[(5-k)*8 +: 8];
            else if (k < 12) e = HMAC[(11-k)*8 +: 8];
            else if (k == 36) e = dport[15:8];
            else if (k == 37) e = dport[7:0];
            else if (k >= 42) e = 8'((k * 7 + seed) & 255);
            else continue;
            if (w[8*b +: 8] != e) mm++;
        end
    end
    expect_eq({what, ": head frame byte mismatches"}, mm, 0);
endtask

task automatic t_crx();
    logic [31:0] v, st, f0, d0;
    $display("==== HSB control-plane receive FIFO: filter, contents, overflow");
    setup(12);
    ew(R_CTRL, 32'h1AAE | 32'h100);                       // OTHER_RX_EN
    cfgw(C_CRX_CTRL, 1);
    cnt(E_CRX_FILT, f0); cnt(E_CRX_DROP, d0);
    // 1: HSB register request (UDP 8192, unicast, 60 B); 2: BOOTP reply (12268, broadcast, 342 B);
    // 3: UDP 5000 (filtered); 4: ARP request (answered by the engine, not queued)
    udp_frame(MYMAC, MYIP, 16'd50000, 16'd8192, 60, 1);  raw_send(60);
    udp_frame(48'hFFFFFFFFFFFF, 32'hC0A81405, 16'd12267, 16'd12268, 342, 2); raw_send(342);
    udp_frame(MYMAC, MYIP, 16'd50000, 16'd5000, 100, 3); raw_send(100);
    repeat (322 * 4) @(posedge clk);
    cnt(E_CRX_FRAMES, v); expect_eq("frames queued", v, 2);
    cnt(E_CRX_FILT, v);   expect_eq("frames filtered out", v - f0, 1);
    svr(S_CRX_STATUS, st); expect_eq("FIFO level", st[7:0], 2);
    crx_check_head("register request", 60, 1, MYMAC, 16'd8192);
    cfgw(C_CRX_POP, 1);
    crx_check_head("BOOTP reply", 342, 2, 48'hFFFFFFFFFFFF, 16'd12268);
    cfgw(C_CRX_POP, 1);
    svr(S_CRX_STATUS, st); expect_eq("FIFO level after two pops", st[7:0], 0);
    // overflow: 18 requests into 16 slots
    for (int k = 0; k < 18; k++) begin udp_frame(MYMAC, MYIP, 16'd50000 + 16'(k), 16'd8192, 128, 10 + k); raw_send(128); end
    repeat (322 * 4) @(posedge clk);
    svr(S_CRX_STATUS, st); expect_eq("FIFO level when full", st[7:0], 16);
    cnt(E_CRX_DROP, v); expect_eq("frames dropped (FIFO full)", v - d0, 2);
    crx_check_head("first of the burst", 128, 10, MYMAC, 16'd8192);
    for (int k = 0; k < 16; k++) cfgw(C_CRX_POP, 1);
    svr(S_CRX_STATUS, st); expect_eq("FIFO level after draining", st[7:0], 0);
    // the engine still answers ARP itself with OTHER_RX_EN set (t_arp clears the counters)
    t_arp();
    cnt(E_CRX_FRAMES, v); expect_eq("ARP not queued", v, 0);
    cfgw(C_CRX_CTRL, 0);
    ew(R_CTRL, 32'h1AAE);
endtask

// ---------------- HSB: frame producer ----------------
// TX monitor: frames from UDP source port 12288 (the producer's QP) are stored
logic [7:0] mbuf [0:(1<<21)-1];
int         mpos = 0, mfs[$], mfl[$];
bit         mon_en = 0;
logic [7:0] cur [0:8191];
int         cur_n = 0;
always @(posedge clk) begin
    if (mon_en && tx_tvalid && tx_tready) begin
        for (int b = 0; b < MB; b++) if (tx_tkeep[b] && cur_n < 8192) begin cur[cur_n] = tx_tdata[8*b +: 8]; cur_n++; end
        if (tx_tlast) begin
            if (cur_n > 70 && {cur[34], cur[35]} == 16'd12288) begin
                mfs.push_back(mpos); mfl.push_back(cur_n);
                for (int i = 0; i < cur_n; i++) mbuf[mpos + i] = cur[i];
                mpos += cur_n;
            end
            cur_n = 0;
        end
    end
end
function automatic logic [63:0] mget(input int at, input int n);
    logic [63:0] v = 0;
    for (int i = 0; i < n; i++) v = {v[55:0], mbuf[at + i]};
    return v;
endfunction

// IQ16 reference: a second generator with the same configuration (survey scene); its beats in order
logic [3:0][31:0] r_inc = {32'h40000000, 32'h11E00000, 32'hE1400000, 32'hB3400000};
logic [3:0][15:0] r_amp = {16'd750, 16'd1500, 16'd3000, 16'd6000};
logic        r_commit = 0, r_start = 0, r_en = 0, r_pop;
wire  logic  r_valid;
wire  logic [511:0] r_data;
iq16_gen #(.N_TONES(4), .FIFO_AW(5)) u_ref (
    .clk(clk), .rst(sys_rst), .sh_cfg_id(32'd1), .sh_tone_inc(r_inc), .sh_tone_amp(r_amp),
    .sh_chirp_start(32'd2362441728), .sh_chirp_rate(48'd105541), .sh_chirp_per(48'd2400000000),
    .sh_chirp_amp(16'd3000), .sh_noise_amp(16'd200), .sh_noise_seed(32'h5EED0001), .commit(r_commit),
    .start(r_start), .enable(r_en), .chunk_pbeats(18'd1024),
    .o_valid(r_valid), .o_data(r_data), .o_clip(), .o_cfg_first(), .o_cfg_id(), .o_pop(r_pop),
    .st_pending(), .st_active_id(), .st_active_n0(), .st_commits(), .st_apply(),
    .seek_n('0), .seek_n0('0), .seek_keymul('0), .seek_bp('0), .seek_m('0), .seek_acc('0), .seek_dl('0)
);
logic [511:0] rbeat [0:1023];
int           rn = 0;
assign r_pop = r_valid && r_en && rn < 1024;
always @(posedge clk) if (r_pop) begin rbeat[rn] = r_data; rn++; end

task automatic iq_cfg_dut();
    cfgw(C_IQ_CFG_ID, 1);
    for (int t = 0; t < 4; t++) cfgw(C_IQ_TONE_INC0 + t, r_inc[t]);
    cfgw(C_IQ_TONE_AMP01, {r_amp[1], r_amp[0]}); cfgw(C_IQ_TONE_AMP23, {r_amp[3], r_amp[2]});
    cfgw(C_IQ_CHIRP_START, 32'd2362441728); cfgw(C_IQ_CHIRP_RATE_LO, 32'd105541); cfgw(C_IQ_CHIRP_RATE_HI, 0);
    cfgw(C_IQ_CHIRP_PER_LO, 32'd2400000000); cfgw(C_IQ_CHIRP_PER_HI, 0);
    cfgw(C_IQ_AMPS, {16'd200, 16'd3000}); cfgw(C_IQ_SEED, 32'h5EED0001);
    cfgw(C_IQ_CTRL, 1);
endtask

// one producer run; checks every packet: headers, PSN, page ring, payload, metadata
// beam array generator reference: the reset scene from n = 0 (beam_vectors.py, beam_reset.hex)
logic [511:0] bbeat [0:383];
string        vdir = ".";
initial begin
    if (!$value$plusargs("vdir=%s", vdir)) vdir = ".";
    $readmemh({vdir, "/beam_reset.hex"}, bbeat);
end

task automatic hsb_run(input int src, input int frame, input int wrmax, input int pmtu, input int npages,
                       input int nframes, input logic [15:0] dport);
    localparam logic [63:0] VA0 = 64'h0000_0001_2000_0000;
    logic [31:0] v, ts0, ts1;
    int stride, mdoff, pk, f, page, off, plen, mm, psn, nexp, ppf, fb, pos;
    logic [63:0] va, exp_va;
    logic [7:0] e;
    mdoff  = (frame + 127) / 128 * 128;
    stride = mdoff + 128;
    $display("==== HSB producer: %s source, frame %0d B, WR max %0d, PMTU %0d, %0d pages, %0d frames, UDP %0d",
             src == 1 ? "counter" : (src == 2 ? "beam array (reset scene)" : "IQ16"), frame, wrmax, 1 << pmtu, npages,
             nframes, dport);
    setup(12);
    // QP 13: UC-HSB towards the "host" (Linux-UDP receiver at dport), first PSN 0
    ew(R_QP_INDEX, 13); ew(R_QP_FLAGS, 32'h5); ew(R_QP_SQ_PSN, 0); ew(R_QP_RQ_PSN, 0); ew(R_QP_PMTU, pmtu);
    ew(R_QP_DMAC_LO, HMAC[31:0]); ew(R_QP_DMAC_HI, HMAC[47:32]); ew(R_QP_DIP0, HIP); ew(R_QP_DQPN, 24'h000ABC);
    ew(R_QP_UDP, {dport, 16'd12288}); ew(R_QP_COMMIT, 1);
    cfgw(C_HP_QP, 13); cfgw(C_HP_RKEY, 32'hBEEF); cfgw(C_HP_VA_LO, VA0[31:0]); cfgw(C_HP_VA_HI, VA0[63:32]);
    cfgw(C_HP_STRIDE, stride); cfgw(C_HP_PAGES, npages - 1); cfgw(C_HP_FRAME, frame); cfgw(C_HP_WRMAX, wrmax);
    cfgw(C_HP_PERIOD, 0); cfgw(C_HP_COUNT, nframes);
    if (src == 0) begin
        iq_cfg_dut();
        // reference stream: commit, then start with enable
        rn = 0;
        @(posedge clk) r_commit <= 1; @(posedge clk) r_commit <= 0;
        repeat (200) @(posedge clk);
        @(posedge clk) begin r_start <= 1; r_en <= 1; end
        @(posedge clk) r_start <= 0;
    end
    mfs.delete(); mfl.delete(); mpos = 0; mon_en = 1;
    svr(S_TIME_NS, ts0);
    cfgw(C_HP_CTRL, (src << 1) | 1);
    begin
        int t = 0;
        do begin repeat (322) @(posedge clk); svr(S_HP_FRAMES, v); t++; end while (v < nframes && t < 3000);
    end
    wait_idle(500);
    repeat (322 * 2 * (512 / MAC_WIDTH)) @(posedge clk);   // the narrow link drains 8x slower
    svr(S_TIME_NS, ts1);
    mon_en = 0;
    cfgw(C_HP_CTRL, 0);
    r_en <= 0;
    svr(S_HP_FRAMES, v); expect_eq("frames completed (S_HP_FRAMES)", v, nframes);
    cnt(E_HP_FRAMES, v); expect_eq("frames counted (E_HP_FRAMES)", v, nframes);
    expect_ge("producer time advanced (ns)", ts1 - ts0, 1000);
    // packets per frame
    ppf = 0;
    for (int o = 0; o < frame; o += wrmax) begin
        int w = (frame - o > wrmax) ? wrmax : frame - o;
        ppf += (w + (1 << pmtu) - 1) >> pmtu;
    end
    nexp = nframes * (ppf + 1);
    expect_eq("packets sent", mfs.size(), nexp);
    if (mfs.size() != nexp) return;
    mm = 0; pk = 0; psn = 0; fb = 0;
    for (f = 0; f < nframes; f++) begin
        page = f % npages;
        off = 0;
        while (off < frame) begin
            pos = mfs[pk]; plen = mfl[pk] - 74;                 // 70 B of headers + 4 B ICRC
            if (mbuf[pos + 42] != 8'h2A) begin $display("FAIL packet %0d opcode %h", pk, mbuf[pos + 42]); errors++; return; end
            if (mget(pos + 47, 3) != 24'hABC) mm++;
            if (mget(pos + 51, 3) != 24'(psn)) begin $display("FAIL packet %0d PSN %0d want %0d", pk, mget(pos + 51, 3), psn); errors++; return; end
            if (mget(pos + 36, 2) != dport) mm++;
            va = mget(pos + 54, 8);
            exp_va = VA0 + 64'(page * stride + off);
            if (va != exp_va) begin $display("FAIL packet %0d VA %h want %h", pk, va, exp_va); errors++; return; end
            if (mget(pos + 62, 4) != 32'hBEEF) mm++;
            if (mget(pos + 66, 4) != 32'(plen)) mm++;
            for (int i = 0; i < plen; i++) begin
                int o = off + i;
                if (src == 1) begin
                    logic [63:0] w = {16'(f), 48'(o & ~7)};
                    e = w[(o % 8) * 8 +: 8];
                end else if (src == 2) begin
                    int g = fb + o;
                    e = (g / 64 < 384) ? bbeat[g / 64][(g % 64) * 8 +: 8] : 8'hXX;
                end else begin
                    // IQ16 stream: byte fb of the run's concatenated frame data
                    int g = fb + o;
                    e = rbeat[g / 64][(g % 64) * 8 +: 8];
                end
                if (mbuf[pos + 70 + i] != e) mm++;
            end
            off += plen; psn++; pk++;
        end
        fb += frame;    // the IQ16 source continues in the next frame
        // metadata packet
        pos = mfs[pk];
        if (mbuf[pos + 42] != 8'h2B) begin $display("FAIL packet %0d opcode %h (want 2B)", pk, mbuf[pos + 42]); errors++; return; end
        if (mfl[pk] != 74 + 4 + 128) mm++;
        if (mget(pos + 51, 3) != 24'(psn)) mm++;
        if (mget(pos + 54, 8) != VA0 + 64'(page * stride + mdoff)) begin $display("FAIL metadata VA"); errors++; end
        if (mget(pos + 70, 4) != {20'(psn), 12'(page)}) mm++;          // immediate {PSN[19:0], page}
        if (mget(pos + 74 + 4, 4) != 32'(psn)) mm++;                  // record PSN = packet PSN
        if (mget(pos + 74 + 24, 8) != 64'(frame)) mm++;               // bytes_written
        if (mget(pos + 74 + 34, 2) != 16'(f)) mm++;                   // frame_number
        if (mget(pos + 74 + 20, 4) >= 1000000000) mm++;               // timestamp_ns in range
        if (src == 2) begin
            // beam fields (contract section 3): scene_id 0 (reset scene), scene_frame 0, frame index, tag
            if (mget(pos + 74 + 48, 4) != 0 || mget(pos + 74 + 52, 4) != 0) begin
                $display("FAIL frame %0d beam scene_id %h scene_frame %h", f, mget(pos + 74 + 48, 4), mget(pos + 74 + 52, 4));
                mm++;
            end
            if (mget(pos + 74 + 56, 4) != 32'(f)) begin $display("FAIL frame %0d beam frame_index %0d", f, mget(pos + 74 + 56, 4)); mm++; end
            if (mget(pos + 74 + 60, 4) != 32'h424D0001) begin $display("FAIL frame %0d beam tag %h", f, mget(pos + 74 + 60, 4)); mm++; end
            for (int i = 64; i < 128; i++) if (mbuf[pos + 74 + i] != 0) mm++;
        end else begin
            for (int i = 48; i < 128; i++) if (mbuf[pos + 74 + i] != 0) mm++;
        end
        psn++; pk++;
    end
    expect_eq("header / payload / metadata mismatches", mm, 0);
    er(R_STATUS, v); expect_eq("engine error latch", v[4], 0);
    expect_eq("underflows", underflows, 0);
endtask

// beam array generator in the system: registers (256-word cfg window, status, CAPS), the
// reset scene through the producer with the beam metadata, APPLY while idle
task automatic t_hsb_beam();
    logic [31:0] v;
    $display("==== beam array generator: registers, reset scene through the producer, APPLY");
    svr(S_BM_CAPS, v);    expect_eq("S_BM_CAPS", v, 32'h01440808);
    // the reset scene is computed after the FPGA reset (~1.5 us): PENDING until then
    for (int t = 0; t < 100; t++) begin svr(S_BM_STATUS, v); if (!v[0]) break; repeat (322) @(posedge clk); end
    svr(S_BM_APPLIES, v); expect_eq("S_BM_APPLIES after reset (the reset scene)", v, 1);
    svr(S_BM_APPLIED_ID, v); expect_eq("S_BM_APPLIED_ID after reset", v, 0);
    svr(S_BM_STATUS, v);  expect_eq("S_BM_STATUS (version 1, idle)", v, 32'h00000100);
    cfgr(C_BM_S0_AMP, v); expect_eq("C_BM_S0_AMP reset value", v, 8000);
    cfgr(C_BM_GAIN0 + 63, v); expect_eq("C_BM_GAIN[63] reset value", v, 32'h4000);
    cfgr(C_BM_EN_HI, v);  expect_eq("C_BM_EN_HI reset value", v, 32'hFFFFFFFF);
    cfgr(C_IQ_CHUNK, v);  expect_eq("C_IQ_CHUNK (low half of the window)", v, 1024);
    cfgw(C_BM_SCENE_ID, 32'h77);                      // shadow only: the reset scene stays staged
    cfgr(C_BM_SCENE_ID, v); expect_eq("C_BM_SCENE_ID readback", v, 32'h77);
    hsb_run(2, 8192, 4096, 12, 4, 3, 16'd50003);      // beam: 3 frames of the reset scene + beam metadata
    svr(S_BM_APPLIED_FRAME, v); expect_eq("S_BM_APPLIED_FRAME after the run start", v, 0);
    cfgw(C_BM_APPLY, 1);                              // while idle: active at once
    repeat (322 * 4) @(posedge clk);
    svr(S_BM_APPLIED_ID, v); expect_eq("S_BM_APPLIED_ID after APPLY", v, 32'h77);
    svr(S_BM_APPLIES, v);    expect_eq("S_BM_APPLIES after APPLY", v, 2);
    svr(S_BM_STATUS, v);     expect_eq("S_BM_STATUS pending / clipped", v[2:0], 0);
endtask

task automatic t_hsb();
    logic [31:0] v, d0, d1, d2;
    $display("==== HSB producer and device identity");
    hsb_run(1, 5000, 2048, 10, 3, 4, 16'd50000);      // counter: 3 data WRs (2048, 2048, 904) per frame
    hsb_run(1, 4096, 16384, 12, 2, 3, 16'd50001);     // counter: one 4 KB packet + metadata
    hsb_run(0, 8192, 4096, 12, 4, 5, 16'd50002);      // IQ16: 2 x 4 KB per frame vs the reference generator
    t_hsb_beam();
    svr(S_HP_STATUS, v); expect_eq("device DNA valid", v[3], 1);
    svr(S_DNA0, d0); svr(S_DNA1, d1); svr(S_DNA2, d2);
    $display("  DNA %h_%h_%h", d2, d1, d0);
    expect_eq("device DNA = simulation value", {d2, d1, d0} == 96'h0123_4567_89AB_CDEF_0F1E_2D3C, 1);
endtask

// ---------------- ZynqMP options: PS DDR window, netdev DMA channel ----------------
task automatic otx_send(input int n);       // rf[0..n-1] as one frame from the PS
    for (int o = 0; o < n; o += 64) begin
        @(posedge dma_clk);
        t_tvalid <= 1'b1; t_tlast <= (o + 64 >= n);
        for (int b = 0; b < 64; b++) begin t_tdata[b*8 +: 8] <= (o + b < n) ? rf[o + b] : 8'h00; t_tkeep[b] <= (o + b < n); end
        do @(posedge dma_clk); while (!t_tready);
        t_tvalid <= 1'b0;
    end
endtask

localparam logic [63:0] DDR_LA = (64'd1 << 39) | 64'h0010_0000;   // DDR window offset 0x10_0000
localparam logic [39:0] DDR_BASE = 40'h00_7000_0000;              // region base: PA = base + offset
task automatic t_ddr();
    logic [31:0] v;
    int mm = 0;
    $display("==== PS DDR window: WRITE into PS DDR (local address bit 39), READ it back");
    setup(12);
    cfgw(C_DDR_BASE_LO, DDR_BASE[31:0]); cfgw(C_DDR_BASE_HI, DDR_BASE[39:32]);
    cfgw(C_DDR_SIZE, 32'h0020_0000);                     // 2 MB region: offsets 0 .. 0x1F_FFFF
    mr(3, 32'h4003, 64'h0010_0000, 32'h0040_0000, DDR_LA, 3'b111);
    ddr_wbytes = 0;
    run_wg(0, 0, 64'h0010_0000, 65536, 4096, 32'h4003, 16);
    wait_idle(5000);
    cnt(E_WC, v); expect_eq("work completions", v, 16);
    cnt(E_WC_ERR, v); expect_eq("completion errors", v, 0);
    cnt(E_DDR_WR_BURSTS, v); expect_ge("DDR write bursts", v, 16);
    cnt(E_MEM_WR_BURSTS, v); expect_eq("URAM write bursts", v, 0);
    expect_eq("bytes written into PS DDR", ddr_wbytes, 65536);
    for (longint a = 64'h10_0000; a < 64'h11_0000; a += 64)
        if (!ddrm.exists((a + DDR_BASE) >> 6) || ddrm[(a + DDR_BASE) >> 6] != pat_beat(a, SEED)) mm++;
    expect_eq("PS DDR beats (at base + offset) != pattern(VA)", mm, 0);
    // outside the region (offset 0x20_0000 and up): null target, nothing reaches PS DDR
    setup(12);
    cfgw(C_DDR_BASE_LO, DDR_BASE[31:0]); cfgw(C_DDR_BASE_HI, DDR_BASE[39:32]); cfgw(C_DDR_SIZE, 32'h0020_0000);
    mr(3, 32'h4003, 64'h0010_0000, 32'h0040_0000, DDR_LA, 3'b111);
    ddr_wbytes = 0;
    run_wg(0, 0, 64'h0030_0000, 65536, 4096, 32'h4003, 4);
    wait_idle(5000);
    cnt(E_WC, v); expect_eq("work completions (outside the region)", v, 4);
    cnt(E_WC_ERR, v); expect_eq("completion errors (outside the region)", v, 0);
    cnt(E_DDR_OOR, v); expect_ge("null-target bursts", v, 4);
    expect_eq("bytes written into PS DDR (outside the region)", ddr_wbytes, 0);
    t_read(12, 4096, 32'h4003, 64'h0010_0000, 0);
    t_read(10, 8192, 32'h4003, 64'h0010_2000, 0);
    cnt(E_DDR_RD_BURSTS, v); expect_ge("DDR read bursts", v, 2);
    // a READ that starts inside a 512-byte granule and crosses several (both ports, re-merged)
    t_read(12, 4096, 32'h4003, 64'h0010_01C0, 0);
    t_read(12, 3000, 32'h4003, 64'h0010_6040, 0);
    if (DDR_PORTS == 2) begin
        $display("  PS DDR sub-bursts on port 0 / 1: %0d / %0d", ddr_sub[0], ddr_sub[1]);
        expect_ge("PS DDR sub-bursts on port 0", ddr_sub[0], 16);
        expect_ge("PS DDR sub-bursts on port 1", ddr_sub[1], 16);
        expect_eq("PS DDR port rule violations (ID, port, granule, WLAST)", ddr_viol, 0);
    end
endtask

task automatic t_odma();
    logic [31:0] v, d0;
    int f0, mm;
    $display("==== netdev DMA channel: other-traffic frames to the PS, frames from the PS, drop");
    setup(12);
    ew(R_CTRL, 32'h1AAE | 32'h100);                       // OTHER_RX_EN
    cfgw(C_ODMA_CTRL, 1);
    cnt(E_ODMA_DROP, d0);
    f0 = orx_frames;
    // a UDP frame (not RoCE) from the raw buffer loops back into the other-traffic port
    udp_frame(MYMAC, MYIP, 16'd50000, 16'd5000, 200, 5); raw_send(200);
    repeat (322 * 6) @(posedge clk);
    expect_eq("frames at the S2MM stream", orx_frames - f0, 1);
    if (orx_frames - f0 == 1) begin
        int st = orx_len[orx_len.size() - 1] - 200;
        mm = 0; for (int i = 0; i < 200; i++) if (orx_buf[(st + i) % 16384] != rf[i]) mm++;
        expect_eq("frame length", orx_len[orx_len.size() - 1] - (orx_len.size() > 1 ? orx_len[orx_len.size() - 2] : 0), 200);
        expect_eq("frame bytes", mm, 0);
    end
    // a 1514-byte frame from the PS (MM2S): engine TX -> loopback -> back to the PS
    udp_frame(MYMAC, MYIP, 16'd50001, 16'd5001, 1514, 9);
    otx_send(1514);
    repeat (322 * 10) @(posedge clk);
    expect_eq("frames at the S2MM stream (looped back)", orx_frames - f0, 2);
    if (orx_frames - f0 == 2) begin
        int st = orx_len[orx_len.size() - 1] - 1514;
        mm = 0; for (int i = 0; i < 1514; i++) if (orx_buf[(st + i) % 16384] != rf[i]) mm++;
        expect_eq("looped frame bytes", mm, 0);
    end
    cnt(E_ODMA_RX, v); expect_eq("E_ODMA_RX", v, 2);
    cnt(E_ODMA_TX, v); expect_eq("E_ODMA_TX", v, 1);
    // disabled: dropped and counted, never stalls the engine
    cfgw(C_ODMA_CTRL, 0);
    udp_frame(MYMAC, MYIP, 16'd50002, 16'd5002, 100, 11); raw_send(100);
    repeat (322 * 4) @(posedge clk);
    cnt(E_ODMA_DROP, v); expect_eq("E_ODMA_DROP (disabled)", v - d0, 1);
    expect_eq("no frame at the S2MM stream while disabled", orx_frames - f0, 2);
    t_arp();                                               // the engine still answers ARP
    ew(R_CTRL, 32'h1AAE);
endtask

// debug probe (+iqdbg)
initial if ($test$plusargs("iqdbg")) forever begin
    #2000;
    $display("%t hs=%0d gen_en=%b g_valid=%b af_full=%b af_wbusy=%b af_valid=%b af_rbusy=%b c_ep=%0d g_ep=%0d head_ep=%0d hp_st=%0d iq_en=%b pend=%b",
             $time, dut.u_iqs.u_gen.hs, dut.u_iqs.g_enable, dut.u_iqs.g_valid, dut.u_iqs.af_full, dut.u_iqs.af_wbusy,
             dut.u_iqs.af_valid, dut.u_iqs.af_rbusy, dut.u_iqs.c_ep, dut.u_iqs.g_ep, dut.u_iqs.af_dout[513:512],
             dut.u_hp.st, dut.iq_enable, dut.u_iqs.g_pending);
end

string test;
initial begin
    if (!$value$plusargs("test=%s", test)) test = "all";
    repeat (10) @(posedge clk);
    sys_rst = 1'b0;
    repeat (40) @(posedge clk);
    begin logic [31:0] id; er(R_ID, id); expect_eq("engine ID", id, 32'h52434C54); svr(S_ID, id); expect_eq("system ID", id, 32'h52535953); end
    if (test == "all" || test == "arp")   t_arp();
    if (test == "all" || test == "wrq")   t_wrq();
    if (test == "all" || test == "write") begin
        t_write(12, 0, 4096, 40);
        t_write(10, 0, 8192, 16);
    end
    if (test == "all" || test == "send") begin
        t_write(12, 3, 2048, 20);     // SEND with immediate
        t_write(10, 1, 1024, 20);     // WRITE with immediate
    end
    if (test == "all" || test == "inject") begin
        t_inject(0, 1, 32'h1, 10, 1);  // drop one data frame
        t_inject(0, 2, 32'h1, 20, 2);  // corrupt two data frames (PSN byte, ICRC)
        t_inject(0, 1, 32'h2, 5, 3);   // drop three ACKs
        t_inject(1, 1, 32'h1, 10, 1);  // RX side: drop one received data frame
    end
    if (test == "all" || test == "vinject") begin
        // the same with the engine tagging its frames (VID 0, PCP 3): the injectors classify
        // tagged frames, the receiver strips the tags
        ew(R_VLAN_TCI, 32'h6000); ew(R_CTRL, 32'h1AAE | 32'h40);
        t_inject(0, 1, 32'h1, 10, 1);
        t_inject(0, 2, 32'h1, 20, 2);
        t_inject(0, 1, 32'h2, 5, 3);
        t_inject(1, 1, 32'h1, 10, 1);
        begin logic [31:0] v; er(R_CNT_TX_VLAN_TAG, v); expect_ge("tagged frames sent", v, 64);
              er(R_CNT_RX_VLAN_STRIP, v); expect_ge("tags stripped", v, 64); end
        ew(R_CTRL, 32'h1AAE);
    end
    if (test == "all" || test == "read") begin
        t_read(12, 4096);
        t_read(10, 8192);
    end
    if (test == "all" || test == "icrc")   t_icrc();
    if (test == "all" || test == "access") t_access();
    if (test == "all" || test == "crx")    t_crx();
    if (test == "all" || test == "hsb")    t_hsb();
    if (ZU != 0 && (test == "all" || test == "ddr"))  t_ddr();
    if (ZU != 0 && (test == "all" || test == "odma")) t_odma();
    if (test == "hsbiq") hsb_run(0, 8192, 4096, 12, 4, 5, 16'd50002);
    if (test == "hsbbm") t_hsb_beam();
    $display("==== DONE errors=%0d", errors);
    if (errors == 0) $display("SIM PASS"); else $display("SIM FAIL");
    $finish;
end

initial begin
    #30ms;
    $display("SIM FAIL: global timeout");
    $finish;
end

endmodule
