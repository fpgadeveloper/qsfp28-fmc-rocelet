// SPDX-License-Identifier: MIT
//
// tb_hsb_prod - xsim testbench of the HSB frame producer rsys_hsb_prod alone (counter source),
// for the live frame period: cfg_period is sampled at every frame start (one register stage),
// so a period written while the stream runs sets the interval that begins at the next frame
// start; everything else stays latched for the run.
//   t_ns is the clock count, so the metadata timestamp (bytes 12-23) of frame k is the clock
//   edge e_k of its frame start. The bench records cfg_period at every edge (hist) and checks
//   every interval: e_{k+1} - e_k == max(hist[e_k - 1] + 1, D), D = the back-to-back frame time
//   (measured in run 1 with period 0, all intervals equal). With the old latched period every
//   interval after a change would keep the start value and fail.
//   run 1: period 0 (D), then 200, 120, 500, 77, 10 (< D: back to back), 0, 300, each written
//          at a random clock of a frame interval; frame bytes and stride written mid-run must
//          not change the run (frame bytes in the metadata, beats per frame, page VAs);
//   run 2: the new frame bytes / stride (latched at the run start), random m_pay_tready (1/2)
//          and periods 400 / 650 / 450 written mid-stream (still longer than a stalled frame).
// Run: Vivado/src/hdl/tb/run_xsim_prod.sh
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module tb_hsb_prod;

logic clk = 1'b0;
always #1.5515 clk = ~clk;              // 322.27 MHz
logic rst = 1'b1;

int errors = 0, checks = 0;
longint cyc = 0;                        // value before edge n = n
always @(posedge clk) cyc <= cyc + 1;

logic        run = 1'b0;
logic [31:0] cfg_frame = 32'd2048, cfg_stride = 32'h1_0000, cfg_wrmax = 32'd1024, cfg_period = '0;
logic [63:0] VA0 = 64'h0000_7f00_0000_0000;
logic        rnd_ready = 1'b0, pay_ready = 1'b1;
always @(posedge clk) pay_ready <= rnd_ready ? 1'($urandom_range(0, 1)) : 1'b1;

wire logic         m_wr_valid, m_pay_tvalid, m_pay_tlast, pay_busy, running, ev_frame, ev_stall_iq;
wire logic         src_tready, src_enable;
wire logic [1:0]   src_sel;
logic              src_start;
wire logic [255:0] m_wr_desc;
wire logic [511:0] m_pay_tdata;
wire logic [31:0]  frames;
wire logic [11:0]  page;
wire logic [15:0]  fnum, bytes_add;

rsys_hsb_prod dut (
    .clk(clk), .rst(rst),
    .run(run), .cfg_src(2'd1), .cfg_qp(8'd13), .cfg_rkey(32'hBEEF), .cfg_va0(VA0), .cfg_stride(cfg_stride),
    .cfg_pg_first(12'd0), .cfg_pg_last(12'd3), .cfg_frame(cfg_frame), .cfg_wrmax(cfg_wrmax),
    .cfg_period(cfg_period), .cfg_count(32'd0),
    .t_s(48'd0), .t_ns(cyc[29:0]),
    .s_axis_src_tvalid(1'b0), .s_axis_src_tdata('0), .s_axis_src_tuser('0), .s_axis_src_tready(src_tready),
    .src_sel(src_sel), .src_enable(src_enable), .src_start(src_start),
    .m_wr_valid(m_wr_valid), .m_wr_ready(1'b1), .m_wr_desc(m_wr_desc),
    .m_pay_tdata(m_pay_tdata), .m_pay_tvalid(m_pay_tvalid), .m_pay_tready(pay_ready), .m_pay_tlast(m_pay_tlast),
    .pay_busy(pay_busy), .running(running), .frames(frames), .page(page), .fnum(fnum),
    .ev_frame(ev_frame), .bytes_add(bytes_add), .ev_stall_iq(ev_stall_iq)
);

// ---------------- cfg_period per clock edge ----------------
logic [31:0] hist [longint];
always @(posedge clk) hist[cyc] = cfg_period;

// ---------------- monitor: WRs, payload, metadata ----------------
logic [5:0]  wr_op [$];
logic [63:0] wr_va [$];
logic [5:0]  cur_op;
bit          in_wr = 0, first_beat = 0;
int          beats = 0;                 // data beats of the current frame
longint      t0 [$];                    // frame start edges, in frame order
int          fbytes [$], fbeats [$];
logic [63:0] fva [$];                   // VA of each frame's first data WR

function automatic logic [63:0] be(input logic [511:0] d, input int at, input int n);
    logic [63:0] v = '0;
    for (int i = 0; i < n; i++) v = (v << 8) | 64'(d[(at + i) * 8 +: 8]);
    return v;
endfunction

always @(posedge clk) if (!rst) begin
    if (m_wr_valid) begin                // m_wr_ready = 1
        wr_op.push_back(m_wr_desc[13:8]);
        wr_va.push_back(m_wr_desc[127:64]);
    end
    if (m_pay_tvalid && pay_ready) begin
        if (!in_wr) begin
            cur_op = wr_op.pop_front();
            in_wr = 1; first_beat = 1;
            if (cur_op == 6'h00 && beats == 0) fva.push_back(wr_va[0]);
            void'(wr_va.pop_front());
        end
        if (cur_op == 6'h21) begin
            if (first_beat) begin
                t0.push_back(longint'(be(m_pay_tdata, 20, 4)));
                fbytes.push_back(int'(be(m_pay_tdata, 28, 4)));
                fbeats.push_back(beats);
                beats = 0;
            end
        end else beats++;
        first_beat = 0;
        if (m_pay_tlast) in_wr = 0;
    end
end

task automatic wait_frames(input int n);
    int f0 = t0.size();
    int to = 0;
    while (t0.size() < f0 + n && to < 200000) begin @(posedge clk); to++; end
    if (to >= 200000) begin $display("FAIL timeout waiting for %0d frames", n); errors++; end
endtask

// a new period at a random clock of the current frame interval, then n frames
task automatic set_period(input int p, input int n);
    repeat ($urandom_range(1, 150)) @(posedge clk);
    cfg_period <= 32'(p);
    wait_frames(n);
endtask

task automatic stop_run();
    run <= 1'b0;
    while (running) @(posedge clk);
    repeat (20) @(posedge clk);
endtask

// every interval of frames [k0, k1) against the period sampled at its start
task automatic check_intervals(input string tag, input int k0, input int k1, input int D);
    int changes = 0;
    for (int k = k0; k + 1 < k1; k++) begin
        longint p = longint'(hist[t0[k] - 1]);
        longint want = (p + 1 > D) ? p + 1 : D;
        longint got = t0[k + 1] - t0[k];
        checks++;
        if (got != want) begin
            $display("FAIL %s frame %0d: interval %0d clocks, want %0d (period %0d sampled at the start, D %0d)",
                     tag, k, got, want, p, D);
            errors++;
        end
        if (k > k0 && hist[t0[k] - 1] != hist[t0[k - 1] - 1]) changes++;
    end
    $display("==== %s: %0d intervals checked, %0d period changes mid-stream", tag, k1 - k0 - 1, changes);
    if (changes < 3) begin $display("FAIL %s: only %0d period changes seen", tag, changes); errors++; end
endtask

task automatic check_layout(input string tag, input int k0, input int k1, input int frame, input int stride);
    for (int k = k0; k < k1; k++) begin
        checks++;
        if (fbytes[k] != frame || fbeats[k] != frame / 64) begin
            $display("FAIL %s frame %0d: %0d bytes / %0d beats, want %0d / %0d", tag, k, fbytes[k], fbeats[k], frame, frame / 64);
            errors++;
        end
        if (fva[k] != VA0 + 64'((k - k0) % 4) * 64'(stride)) begin
            $display("FAIL %s frame %0d: VA %h, want %h", tag, k, fva[k], VA0 + 64'((k - k0) % 4) * 64'(stride));
            errors++;
        end
    end
endtask

initial begin
    int D, k1, k2;
    repeat (10) @(posedge clk);
    rst <= 1'b0;
    repeat (10) @(posedge clk);

    // ---- run 1 ----
    run <= 1'b1;
    wait_frames(8);
    D = int'(t0[2] - t0[1]);
    for (int k = 1; k + 1 < 8; k++) if (t0[k + 1] - t0[k] != D) begin
        $display("FAIL back-to-back interval %0d: %0d, want %0d", k, t0[k + 1] - t0[k], D); errors++;
    end
    $display("==== back to back (period 0): D = %0d clocks per 2048-byte frame", D);
    set_period(200, 5);
    cfg_frame <= 32'd4096;              // latched: must not reach this run
    cfg_stride <= 32'h2_0000;
    set_period(120, 5);
    set_period(500, 3);
    set_period(77, 4);
    set_period(10, 4);
    set_period(0, 4);
    set_period(300, 4);
    stop_run();
    k1 = t0.size();                    // incl. the frame finished after run fell
    check_intervals("run 1", 0, k1, D);
    check_layout("run 1", 0, k1, 2048, 32'h1_0000);

    // ---- run 2: new layout from the run start, back-pressure, live periods ----
    rnd_ready <= 1'b1;
    cfg_period <= 32'd450;
    @(posedge clk);
    run <= 1'b1;
    wait_frames(4);
    set_period(400, 4);
    set_period(650, 3);
    set_period(450, 4);
    stop_run();
    k2 = t0.size();                    // incl. the frame finished after run fell
    check_intervals("run 2", k1, k2, D);
    check_layout("run 2", k1, k2, 4096, 32'h2_0000);

    $display("==== %0d checks, %0d errors", checks, errors);
    if (errors == 0) $display("SIM PASS"); else $display("SIM FAIL");
    $finish;
end

initial begin
    #5ms;
    $display("TIMEOUT");
    $display("SIM FAIL: global timeout");
    $finish;
end

endmodule

`default_nettype wire
