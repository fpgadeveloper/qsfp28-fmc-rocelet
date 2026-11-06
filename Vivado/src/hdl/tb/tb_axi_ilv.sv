// SPDX-License-Identifier: MIT
//
// tb_axi_ilv - self-checking test of rsys_axi_ilv (PS DDR window over two ports per direction):
//   1. random write bursts (unaligned starts with partial first-beat strobes, 1-64 beats, any
//      granule crossing, random IDs) and random read bursts against two port models with random
//      ready gaps and read latencies: every sub-burst on the right port (address bit ILV_BIT),
//      inside one granule, ID 0 on the port; B / R back in request order with the original IDs,
//      RLAST on the last beat; memory = reference after the writes, read data = reference.
//   2. throughput: sequential 4 KB bursts with each port limited to 0.4 beats per clock (an
//      S_AXI_HP port, 128 bits at 250 MHz, seen from 512 bits at 156.25 MHz): the pair must
//      carry > 0.70 beats per clock (40 Gb/s line rate = 0.5) for writes and for reads.
// Run: run_xsim_ilv.sh. Prints "SIM PASS" / "SIM FAIL".
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps

module tb_axi_ilv;

localparam int ID_W = 2, AW = 40, ILV_BIT = 9, GB = 1 << (ILV_BIT - 6);

logic clk = 1'b0, rst = 1'b1;
always #3.2 clk = ~clk;

// engine side
logic [ID_W-1:0] s_awid = '0, s_arid = '0;
logic [AW-1:0]   s_awaddr = '0, s_araddr = '0;
logic [7:0]      s_awlen = '0, s_arlen = '0;
logic            s_awvalid = 1'b0, s_wvalid = 1'b0, s_wlast = 1'b0, s_arvalid = 1'b0;
logic            s_bready = 1'b1, s_rready = 1'b1;
logic [511:0]    s_wdata = '0;
logic [63:0]     s_wstrb = '0;
wire  logic      s_awready, s_wready, s_bvalid, s_arready, s_rvalid, s_rlast;
wire  logic [ID_W-1:0] s_bid, s_rid;
wire  logic [1:0] s_bresp, s_rresp;
wire  logic [511:0] s_rdata;

// port side
wire  logic [ID_W-1:0] m_awid [2], m_arid [2];
wire  logic [AW-1:0]   m_awaddr [2], m_araddr [2];
wire  logic [7:0]      m_awlen [2], m_arlen [2];
wire  logic            m_awvalid [2], m_wlast [2], m_wvalid [2], m_bready [2], m_arvalid [2], m_rready [2];
wire  logic [511:0]    m_wdata [2];
wire  logic [63:0]     m_wstrb [2];
logic                  m_awready [2], m_wready [2], m_bvalid [2], m_arready [2], m_rvalid [2], m_rlast [2];
logic [ID_W-1:0]       m_bid [2], m_rid [2];
logic [1:0]            m_bresp [2], m_rresp [2];
logic [511:0]          m_rdata [2];
wire  logic [1:0]      ev_wsub, ev_rsub;

rsys_axi_ilv #(.ID_W(ID_W), .AW(AW), .ILV_BIT(ILV_BIT)) dut (
    .clk(clk), .rst(rst),
    .s_awid(s_awid), .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awvalid(s_awvalid), .s_awready(s_awready),
    .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast), .s_wvalid(s_wvalid), .s_wready(s_wready),
    .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
    .s_arid(s_arid), .s_araddr(s_araddr), .s_arlen(s_arlen), .s_arvalid(s_arvalid), .s_arready(s_arready),
    .s_rid(s_rid), .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
    .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awvalid(m_awvalid), .m_awready(m_awready),
    .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready),
    .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
    .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arvalid(m_arvalid), .m_arready(m_arready),
    .m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready),
    .ev_wsub(ev_wsub), .ev_rsub(ev_rsub)
);

int errors = 0;
task automatic fail(input string m);
    errors++;
    if (errors < 20) $display("FAIL %s (t=%0t)", m, $time);
endtask

// ---------------- memory (shared by both ports) + reference ----------------
logic [7:0] mem [longint];
logic [7:0] ref_m [longint];
function automatic logic [7:0] memb(input longint a); return mem.exists(a) ? mem[a] : 8'h00; endfunction
function automatic logic [7:0] refb(input longint a); return ref_m.exists(a) ? ref_m[a] : 8'h00; endfunction

// ---------------- port models ----------------
// mode 0: random ready gaps (~50 %), read latency 20-120 clocks
// mode 1: throughput: 0.4 beats per clock per port (2 of every 5 clocks), latency 80 clocks
int  mode = 0;
longint cyc = 0;
always @(posedge clk) cyc <= cyc + 1;
function automatic bit tok(input int p);    // this clock may move a beat on port p (rate model)
    if (mode == 0) return ($urandom_range(0, 99) < 55);
    return ((cyc + p) % 5 == 0) || ((cyc + p) % 5 == 2);
endfunction

int aw_ok [2], w_ok [2], ar_ok [2];          // sub-bursts per port, violations counted in errors
for (genvar p = 0; p < 2; p++) begin : g_port
    // write: AW queue -> W beats into memory -> B after a few clocks
    longint awq_a [$]; int awq_l [$];
    int wbeat = 0;
    longint bq_t [$];
    longint arq_a [$]; int arq_l [$]; longint arq_t [$];
    int rbeat = 0;
    initial begin
        m_awready[p] = 1'b0; m_wready[p] = 1'b0; m_bvalid[p] = 1'b0; m_bid[p] = '0; m_bresp[p] = 2'b00;
        m_arready[p] = 1'b0; m_rvalid[p] = 1'b0; m_rlast[p] = 1'b0; m_rid[p] = '0; m_rresp[p] = 2'b00;
        m_rdata[p] = '0;
    end
    always @(posedge clk) begin
        // AW
        if (m_awvalid[p] && m_awready[p]) begin
            automatic longint a = longint'(m_awaddr[p]);
            if (m_awid[p] != 0) fail($sformatf("port %0d AW ID %0d (not 0)", p, m_awid[p]));
            if (a[ILV_BIT] != p) fail($sformatf("port %0d AW address %h has bit %0d = %0d", p, a, ILV_BIT, a[ILV_BIT]));
            if (((a >> 6) & (GB - 1)) + m_awlen[p] >= GB) fail($sformatf("port %0d AW %h len %0d crosses a granule", p, a, m_awlen[p]));
            awq_a.push_back(a); awq_l.push_back(int'(m_awlen[p]));
            aw_ok[p]++;
        end
        m_awready[p] <= (mode == 0) ? ($urandom_range(0, 99) < 60) : 1'b1;
        // W
        if (m_wvalid[p] && m_wready[p]) begin
            if (awq_a.size() == 0) fail($sformatf("port %0d W beat before its AW", p));
            else begin
                automatic longint base = (awq_a[0] & ~longint'(63)) + 64 * wbeat;
                for (int b = 0; b < 64; b++) if (m_wstrb[p][b]) mem[base + b] = m_wdata[p][b*8 +: 8];
                if (m_wlast[p] != (wbeat == awq_l[0])) fail($sformatf("port %0d WLAST %0d at beat %0d of %0d", p, m_wlast[p], wbeat, awq_l[0] + 1));
                if (wbeat == awq_l[0]) begin
                    wbeat = 0; void'(awq_a.pop_front()); void'(awq_l.pop_front());
                    bq_t.push_back(cyc + $urandom_range(2, 30));
                end else wbeat++;
            end
        end
        m_wready[p] <= tok(p);
        // B (in order)
        if (m_bvalid[p] && m_bready[p]) m_bvalid[p] <= 1'b0;
        else if (!m_bvalid[p] && bq_t.size() > 0 && bq_t[0] <= cyc) begin
            m_bvalid[p] <= 1'b1; m_bresp[p] <= 2'b00; void'(bq_t.pop_front());
        end
        // AR
        if (m_arvalid[p] && m_arready[p]) begin
            automatic longint a = longint'(m_araddr[p]);
            if (m_arid[p] != 0) fail($sformatf("port %0d AR ID %0d (not 0)", p, m_arid[p]));
            if (a[ILV_BIT] != p) fail($sformatf("port %0d AR address %h has bit %0d = %0d", p, a, ILV_BIT, a[ILV_BIT]));
            if (((a >> 6) & (GB - 1)) + m_arlen[p] >= GB) fail($sformatf("port %0d AR %h len %0d crosses a granule", p, a, m_arlen[p]));
            arq_a.push_back(a); arq_l.push_back(int'(m_arlen[p]));
            arq_t.push_back(cyc + ((mode == 0) ? $urandom_range(20, 120) : 80));
            ar_ok[p]++;
        end
        m_arready[p] <= (mode == 0) ? ($urandom_range(0, 99) < 60) : 1'b1;
        // R (in order, after the latency, at the port's rate)
        if (m_rvalid[p] && m_rready[p]) m_rvalid[p] <= 1'b0;
        if ((!m_rvalid[p] || m_rready[p]) && arq_a.size() > 0 && arq_t[0] <= cyc && tok(p)) begin
            automatic longint base = (arq_a[0] & ~longint'(63)) + 64 * rbeat;
            for (int b = 0; b < 64; b++) m_rdata[p][b*8 +: 8] <= memb(base + b);
            m_rvalid[p] <= 1'b1; m_rresp[p] <= 2'b00; m_rlast[p] <= (rbeat == arq_l[0]);
            if (rbeat == arq_l[0]) begin
                rbeat = 0; void'(arq_a.pop_front()); void'(arq_l.pop_front()); void'(arq_t.pop_front());
            end else rbeat++;
        end
    end
end

// ---------------- engine-side drivers ----------------
// write bursts: (addr, len, id) issued on AW; their W beats follow in order; B checked in order
longint wq_a [$]; int wq_l [$]; int wq_i [$];     // for the W driver
int     bq_i [$];                                   // expected B order
int     n_b = 0;
always @(posedge clk) if (s_bvalid && s_bready) begin
    if (bq_i.size() == 0) fail("B without a request");
    else begin
        if (s_bid != bq_i[0]) fail($sformatf("B ID %0d, expected %0d", s_bid, bq_i[0]));
        if (s_bresp != 2'b00) fail("BRESP");
        void'(bq_i.pop_front());
    end
    n_b++;
end
// read bursts: expected R beats in order
longint rq_a [$]; int rq_l [$]; int rq_i [$];
int rb = 0;
longint n_r = 0;
always @(posedge clk) if (s_rvalid && s_rready) begin
    if (rq_a.size() == 0) fail("R beat without a request");
    else begin
        automatic longint base = (rq_a[0] & ~longint'(63)) + 64 * rb;
        automatic int bad = 0;
        for (int b = 0; b < 64; b++) if (s_rdata[b*8 +: 8] !== refb(base + b)) bad++;
        if (bad) fail($sformatf("R data at %h: %0d bytes differ", base, bad));
        if (s_rid != rq_i[0]) fail($sformatf("R ID %0d, expected %0d", s_rid, rq_i[0]));
        if (s_rlast != (rb == rq_l[0])) fail($sformatf("RLAST %0d at beat %0d of %0d", s_rlast, rb, rq_l[0] + 1));
        if (rb == rq_l[0]) begin rb = 0; void'(rq_a.pop_front()); void'(rq_l.pop_front()); void'(rq_i.pop_front()); end
        else rb++;
    end
    n_r++;
end

task automatic aw_send(input longint a, input int len, input int id);
    s_awaddr <= AW'(a); s_awlen <= 8'(len); s_awid <= ID_W'(id); s_awvalid <= 1'b1;
    @(posedge clk);
    while (!s_awready) @(posedge clk);
    s_awvalid <= 1'b0;
    wq_a.push_back(a); wq_l.push_back(len); wq_i.push_back(id); bq_i.push_back(id);
endtask
bit wdrv_stop = 0;
int w_gap = 1;                                       // 1: random gaps in W
initial begin : wdrv
    @(negedge rst);
    forever begin
        @(posedge clk);
        while (wq_a.size() == 0) @(posedge clk);
        for (int k = 0; k <= wq_l[0]; k++) begin
            automatic longint base = (wq_a[0] & ~longint'(63)) + 64 * k;
            automatic int off = (k == 0) ? int'(wq_a[0] & 63) : 0;
            for (int b = 0; b < 64; b++) begin
                automatic logic [7:0] d = 8'($urandom);
                automatic bit st = (b >= off) && ($urandom_range(0, 15) != 0 || w_gap == 0);
                s_wdata[b*8 +: 8] <= d; s_wstrb[b] <= st;
                if (st) ref_m[base + b] = d;
            end
            s_wlast <= (k == wq_l[0]);
            s_wvalid <= 1'b1;
            do @(posedge clk); while (!s_wready);
            s_wvalid <= 1'b0;
            if (w_gap && $urandom_range(0, 3) == 0) @(posedge clk);
        end
        void'(wq_a.pop_front()); void'(wq_l.pop_front()); void'(wq_i.pop_front());
    end
end
task automatic ar_send(input longint a, input int len, input int id);
    s_araddr <= AW'(a); s_arlen <= 8'(len); s_arid <= ID_W'(id); s_arvalid <= 1'b1;
    rq_a.push_back(a); rq_l.push_back(len); rq_i.push_back(id);
    @(posedge clk);
    while (!s_arready) @(posedge clk);
    s_arvalid <= 1'b0;
endtask

// throughput phase: synchronous request generators (sequential 4 KB bursts, back to back)
int  tp_w_n = 0, tp_r_n = 0;                     // bursts still to issue
longint tp_w_a, tp_r_a;
always @(posedge clk) begin
    if (tp_w_n > 0) begin
        if (s_awvalid && s_awready) begin
            wq_a.push_back(longint'(s_awaddr)); wq_l.push_back(63); wq_i.push_back(int'(s_awid)); bq_i.push_back(int'(s_awid));
            tp_w_n = tp_w_n - 1; tp_w_a = tp_w_a + 4096;
        end
        s_awvalid <= (tp_w_n > 0); s_awaddr <= AW'(tp_w_a); s_awlen <= 8'd63; s_awid <= ID_W'(tp_w_a >> 12);
    end
    if (tp_r_n > 0) begin
        if (s_arvalid && s_arready) begin
            rq_a.push_back(longint'(s_araddr)); rq_l.push_back(63); rq_i.push_back(int'(s_arid));
            tp_r_n = tp_r_n - 1; tp_r_a = tp_r_a + 4096;
        end
        s_arvalid <= (tp_r_n > 0); s_araddr <= AW'(tp_r_a); s_arlen <= 8'd63; s_arid <= ID_W'(tp_r_a >> 12);
    end
end

// a random burst inside one 4 KB page: start (unaligned with probability 1/4), 1-64 beats
task automatic rnd_burst(input longint page, output longint a, output int len);
    int b0 = $urandom_range(0, 63);
    int maxl = 64 - b0;
    a = page + 64 * b0 + (($urandom_range(0, 3) == 0) ? $urandom_range(1, 63) : 0);
    len = $urandom_range(0, maxl - 1);
endtask

initial begin
    longint a, t0, t1, nbeats;
    int len;
    real wr_bpc, rd_bpc;
    repeat (10) @(posedge clk);
    rst <= 1'b0;
    repeat (5) @(posedge clk);

    // ---- 1. random writes, then random reads (mode 0) ----
    $display("==== random write bursts (400), unaligned starts, partial strobes, random port gaps");
    for (int i = 0; i < 400; i++) begin
        rnd_burst(64'h7000_0000 + 4096 * i, a, len);
        aw_send(a, len, $urandom_range(0, 3));
        if ($urandom_range(0, 3) == 0) repeat ($urandom_range(1, 8)) @(posedge clk);
    end
    wait (bq_i.size() == 0 && wq_a.size() == 0);
    repeat (50) @(posedge clk);
    begin
        automatic int bad = 0;
        foreach (ref_m[k]) if (memb(k) !== ref_m[k]) bad++;
        foreach (mem[k]) if (!ref_m.exists(k)) bad++;
        if (bad) fail($sformatf("memory != reference in %0d bytes", bad));
        $display("  %0d write bursts, %0d B responses, %0d bytes, sub-bursts port 0 / 1: %0d / %0d, mismatches %0d",
                 400, n_b, ref_m.size(), aw_ok[0], aw_ok[1], bad);
    end
    if (aw_ok[0] < 100 || aw_ok[1] < 100) fail("write sub-bursts not spread over both ports");
    $display("==== random read bursts (400) over the written pages, random latencies 20-120");
    for (int i = 0; i < 400; i++) begin
        rnd_burst(64'h7000_0000 + 4096 * $urandom_range(0, 399), a, len);
        ar_send(a, len, $urandom_range(0, 3));
        if ($urandom_range(0, 3) == 0) repeat ($urandom_range(1, 8)) @(posedge clk);
    end
    wait (rq_a.size() == 0);
    $display("  %0d read beats checked, sub-bursts port 0 / 1: %0d / %0d", n_r, ar_ok[0], ar_ok[1]);
    if (ar_ok[0] < 100 || ar_ok[1] < 100) fail("read sub-bursts not spread over both ports");

    // ---- 2. throughput (mode 1: each port 0.4 beats per clock) ----
    mode = 1; w_gap = 0;
    repeat (200) @(posedge clk);
    $display("==== throughput: 256 x 4 KB sequential writes, each port 0.4 beats/clock");
    nbeats = 0;
    t0 = cyc;
    tp_w_a = 64'h7100_0000; tp_w_n = 256;
    wait (tp_w_n == 0);
    wait (bq_i.size() == 0 && wq_a.size() == 0);
    t1 = cyc;
    wr_bpc = (256.0 * 64.0) / real'(t1 - t0);
    $display("  %0d beats in %0d clocks: %.3f beats/clock = %.1f Gb/s at 156.25 MHz (two ports, 0.4 each)",
             256 * 64, t1 - t0, wr_bpc, wr_bpc * 512.0 * 0.15625);
    if (wr_bpc < 0.70) fail($sformatf("write throughput %.3f beats/clock < 0.70", wr_bpc));
    $display("==== throughput: 256 x 4 KB sequential reads, latency 80, each port 0.4 beats/clock");
    n_r = 0;
    t0 = cyc;
    tp_r_a = 64'h7100_0000; tp_r_n = 256;
    wait (tp_r_n == 0);
    wait (rq_a.size() == 0);
    t1 = cyc;
    rd_bpc = real'(n_r) / real'(t1 - t0);
    $display("  %0d beats in %0d clocks: %.3f beats/clock = %.1f Gb/s at 156.25 MHz", n_r, t1 - t0, rd_bpc,
             rd_bpc * 512.0 * 0.15625);
    if (rd_bpc < 0.70) fail($sformatf("read throughput %.3f beats/clock < 0.70", rd_bpc));
    // reference for the throughput writes (data checked by the reads above)
    if (errors == 0) $display("SIM PASS"); else $display("SIM FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #20ms;
    $display("TIMEOUT");
    $display("SIM FAIL (timeout)");
    $finish;
end

endmodule
