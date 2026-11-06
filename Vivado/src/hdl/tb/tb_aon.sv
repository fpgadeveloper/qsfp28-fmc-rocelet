// SPDX-License-Identifier: MIT
//
// tb_aon - xsim testbench of rsys_aon (always-on block + clock guard): forwarded accesses
// to a register-file model in the MAC clock, poison / drop while the MAC clock is stopped,
// a MAC clock that stops in the middle of an access (time-out, orphan, recovery), the
// always-on registers (ID, CTRL reset value, MAC clock meter, interrupt latch / W1C), the 40G
// lane status and lane event counters (gray crossing, accumulation, clear).
// Run: Vivado/src/hdl/tb/run_xsim_aon.sh
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module tb_aon;

logic clk = 0, mclk = 0, rst = 1;
always #5 clk = ~clk;                   // 100 MHz
bit   mrun = 1;
always #3.2 if (mrun) mclk = ~mclk;     // 156.25 MHz, stoppable

logic [19:0] awaddr, araddr;
logic        awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
logic [31:0] wdata;
wire  logic  awready, wready, bvalid, arready, rvalid;
wire  logic [31:0] rdata;
wire  logic [1:0]  bresp, rresp;

wire logic [18:0] m_awaddr, m_araddr;
wire logic        m_awvalid, m_wvalid, m_bready, m_arvalid, m_rready;
wire logic [31:0] m_wdata;
wire logic [3:0]  m_wstrb;
logic             m_awready = 0, m_wready = 0, m_bvalid = 0, m_arready = 0, m_rvalid = 0;
logic [31:0]      m_rdata;
logic [15:0]      mac_stat = 16'h0000;
logic [31:0]      mac_lane = 32'h0;
logic [5:0]       mac_lev = 6'h0;
wire  logic       irq, gt_reset, mac_reset, sys_reset;

rsys_aon #(.PL_CLK_KHZ(100000), .BUILD_ID(32'h1234), .CAPS(32'h0702080A), .GUARD_TMO(4096)) dut (
    .clk(clk), .rst(rst),
    .s_awaddr(awaddr), .s_awvalid(awvalid), .s_awready(awready), .s_wdata(wdata), .s_wstrb(4'hF),
    .s_wvalid(wvalid), .s_wready(wready), .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
    .s_araddr(araddr), .s_arvalid(arvalid), .s_arready(arready), .s_rdata(rdata), .s_rresp(rresp),
    .s_rvalid(rvalid), .s_rready(rready),
    .mac_clk(mclk),
    .m_awaddr(m_awaddr), .m_awvalid(m_awvalid), .m_awready(m_awready), .m_wdata(m_wdata), .m_wstrb(m_wstrb),
    .m_wvalid(m_wvalid), .m_wready(m_wready), .m_bresp(2'b00), .m_bvalid(m_bvalid), .m_bready(m_bready),
    .m_araddr(m_araddr), .m_arvalid(m_arvalid), .m_arready(m_arready), .m_rdata(m_rdata), .m_rresp(2'b00),
    .m_rvalid(m_rvalid), .m_rready(m_rready),
    .gt_reset(gt_reset), .mac_reset(mac_reset), .sys_reset(sys_reset), .qsfp_modsel_l(), .qsfp_reset_l(),
    .qsfp_lpmode(), .led_grn(), .led_red(), .irq(irq),
    .mac_stat(mac_stat), .sys_evt(8'h00), .mac_lane(mac_lane), .mac_lev(mac_lev), .gt_powergood(1'b1), .gt_tx_ready(1'b1), .gt_rx_ready(1'b1),
    .qsfp_modprs_l(1'b0), .qsfp_int_l(1'b1), .clk_los(1'b0)
);

// MAC-side slave model: 16 words; answers after a delay of slow_n clocks
logic [31:0] mem [16];
int slow_n = 2;
always @(posedge mclk) begin
    m_awready <= 0; m_wready <= 0; m_arready <= 0;
    if (m_awvalid && m_wvalid && !m_bvalid && !m_awready) begin
        repeat (slow_n) @(posedge mclk);
        mem[m_awaddr[5:2]] <= m_wdata; m_awready <= 1; m_wready <= 1; m_bvalid <= 1;
    end else if (m_bvalid && m_bready) m_bvalid <= 0;
    if (m_arvalid && !m_rvalid && !m_arready) begin
        repeat (slow_n) @(posedge mclk);
        m_rdata <= mem[m_araddr[5:2]] ^ 32'hA5000000; m_arready <= 1; m_rvalid <= 1;
    end else if (m_rvalid && m_rready) m_rvalid <= 0;
end

int errors = 0;
task automatic check(input string what, input logic [31:0] got, input logic [31:0] want);
    if (got !== want) begin $display("FAIL %s: got 0x%08x want 0x%08x", what, got, want); errors++; end
    else $display("  ok %s = 0x%08x", what, got);
endtask
task automatic wr32(input logic [19:0] a, input logic [31:0] d);
    @(posedge clk); awaddr <= a; awvalid <= 1; wdata <= d; wvalid <= 1;
    do @(posedge clk); while (!(awready && wready));
    awvalid <= 0; wvalid <= 0;
    do @(posedge clk); while (!bvalid);
endtask
task automatic rd32(input logic [19:0] a, output logic [31:0] d);
    @(posedge clk); araddr <= a; arvalid <= 1;
    do @(posedge clk); while (!arready);
    arvalid <= 0;
    do @(posedge clk); while (!rvalid);
    d = rdata;
endtask

logic [31:0] v;
initial begin
    repeat (10) @(posedge clk); rst <= 0; repeat (400) @(posedge clk);
    $display("==== always-on registers");
    rd32(20'h80000, v); check("ID", v, 32'h52414F4E);
    rd32(20'h80008, v); check("BUILD_ID", v, 32'h1234);
    rd32(20'h80010, v); check("CAPS", v, 32'h0702080A);
    rd32(20'h80020, v); check("CTRL reset value", v, 32'h00000203);
    check("gt_reset / mac_reset held", {gt_reset, mac_reset, sys_reset}, 3'b110);
    repeat (250000) @(posedge clk);      // > 2 x 1 ms meter windows
    rd32(20'h80014, v); check("MAC clock kHz (156250 +- 16)", (v >= 156234 && v <= 156266) ? 1 : 0, 1);
    rd32(20'h80024, v); check("STATUS alive", v[0], 1);
    $display("==== forwarded accesses");
    wr32(20'h00010, 32'h00C0FFEE);
    rd32(20'h00010, v); check("forward write/read", v, 32'hA5C0FFEE);
    $display("==== MAC clock stopped: poison, drop");
    mrun = 0; repeat (500) @(posedge clk);
    rd32(20'h80024, v); check("STATUS alive (stopped)", v[0], 0);
    rd32(20'h80014, v); check("MAC clock kHz (stopped)", v, 0);
    rd32(20'h00010, v); check("read while stopped", v, 32'hDEADC10C);
    wr32(20'h00010, 32'h11111111);
    rd32(20'h80040, v); check("poison read count", v, 1);
    rd32(20'h80044, v); check("dropped write count", v, 1);
    mrun = 1; repeat (500) @(posedge clk);
    rd32(20'h00010, v); check("write was dropped", v, 32'hA5C0FFEE);
    $display("==== MAC clock stops during an access: time-out, orphan, recovery");
    slow_n = 200;
    fork
        begin rd32(20'h00014, v); end
        begin repeat (60) @(posedge clk); mrun = 0; end
    join
    check("timed-out read", v, 32'hDEADC10C);
    rd32(20'h80048, v); check("time-out count", v, 1);
    rd32(20'h80024, v); check("orphan pending", v[16], 1);
    mrun = 1; slow_n = 2;
    repeat (2000) @(posedge clk);
    rd32(20'h80024, v); check("orphan cleared", v[16], 0);
    rd32(20'h00010, v); check("forwarding again", v, 32'hA5C0FFEE);
    $display("==== interrupts");
    wr32(20'h80034, 32'h1);              // link change
    mac_stat <= 16'h1001; repeat (20) @(posedge clk);
    check("irq on link up", irq, 1);
    rd32(20'h80028, v); check("link up events", v[15:0], 1);
    wr32(20'h80030, 32'h1); repeat (5) @(posedge clk);
    check("irq cleared (W1C)", irq, 0);
    wr32(20'h80020, 32'h200);            // release GT and MAC
    check("resets released", {gt_reset, mac_reset}, 2'b00);
    $display("==== 40G lane status and counters");
    mac_lane <= 32'h80071BFF; repeat (10) @(posedge clk);
    rd32(20'h80060, v); check("LANE_STAT", v, 32'h80071BFF);
    // lane 0: 70000 events back to back (wraps the 16-bit MAC-side counter), lane 2: 3,
    // skew fail: 1, overflow: every other clock x 50
    @(posedge mclk); mac_lev[0] <= 1'b1; repeat (70000) @(posedge mclk); mac_lev[0] <= 1'b0;
    repeat (3) begin @(posedge mclk) mac_lev[2] <= 1'b1; @(posedge mclk) mac_lev[2] <= 1'b0; repeat (5) @(posedge mclk); end
    @(posedge mclk) mac_lev[4] <= 1'b1; @(posedge mclk) mac_lev[4] <= 1'b0;
    repeat (50) begin @(posedge mclk) mac_lev[5] <= 1'b1; @(posedge mclk) mac_lev[5] <= 1'b0; end
    repeat (50) @(posedge clk);
    rd32(20'h80064, v); check("BIP lane 0 (70000, wrapped)", v, 70000);
    rd32(20'h80068, v); check("BIP lane 1", v, 0);
    rd32(20'h8006C, v); check("BIP lane 2", v, 3);
    rd32(20'h80070, v); check("BIP lane 3", v, 0);
    rd32(20'h80074, v); check("skew fails", v, 1);
    rd32(20'h80078, v); check("RX overflow", v, 50);
    wr32(20'h80060, 32'h0); repeat (5) @(posedge clk);
    rd32(20'h80064, v); check("BIP lane 0 cleared", v, 0);
    @(posedge mclk) mac_lev[3] <= 1'b1; @(posedge mclk) mac_lev[3] <= 1'b0; repeat (50) @(posedge clk);
    rd32(20'h80070, v); check("BIP lane 3 after clear", v, 1);
    rd32(20'h80078, v); check("RX overflow cleared", v, 0);
    $display("==== DONE errors=%0d", errors);
    $display(errors ? "SIM FAIL" : "SIM PASS");
    $finish;
end
initial begin #20ms; $display("TIMEOUT"); $finish; end
endmodule
