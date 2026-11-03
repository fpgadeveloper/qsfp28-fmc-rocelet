// SPDX-License-Identifier: MIT
//
// tb_beam_src - xsim testbench of the beam array generator (rsys_beam_src) against the
// bit-exact reference model (sw/beam/beam_model.py, vectors written by beam_vectors.py into
// the build directory). A consumer in the CMAC clock (322 MHz) pops beats at a random duty
// like the producer and compares every beat with the model and the scene side-band of every
// frame's first beat; the generator runs in its 200 MHz gen_clk.
//   reset scene: APPLIED_ID 0, APPLIES 1 without any write;
//   APPLY while idle (preset 1): active at once, APPLIED_FRAME 0;
//   run 1, 6 frames: preset 1 (frames 0-1); mid frame 1 APPLY preset 3 then, 300 clocks
//   later, APPLY preset 2 (replaces the pending scene 3, which must never appear) followed by
//   writes to the shadow words (they belong to the next scene and must not change scene 2):
//   frames 2-3 = preset 2 with n0 = 2T; mid frame 3 APPLY preset 5: frames 4-5 with n0 = 4T;
//   run 2 (SEEK: noise index from n = 2^26 - 512, across m[63:32] = 0 -> 1): one frame of
//   preset 5, scene_frame 0, APPLIED_FRAME 0; beats of run 1 left in the FIFOs are discarded.
// Run: Vivado/src/hdl/tb/run_xsim_beam.sh [+T=<time samples per frame>] (default 4096 = 1 MiB).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module tb_beam_src
    import rsys_pkg::*;
;

logic clk = 1'b0;
always #1.5515 clk = ~clk;              // 322.27 MHz
logic gen_clk = 1'b0;
always #2.5 gen_clk = ~gen_clk;         // 200 MHz
logic rst = 1'b1, g_rst = 1'b1;

int T = 4096;
int FB;                                 // beats per frame
int errors = 0, checks = 0;

logic [127:0][31:0] shadow;
logic               apply = 1'b0, start = 1'b0, enable = 1'b0;
logic [27:0]        seek_bl = '0;
logic [31:0]        seek_km = '0;
wire  logic         o_valid, ev_clip, st_pending, st_clipped;
wire  logic [511:0] o_data;
wire  logic [31:0]  o_sid, o_sfr, st_aid, st_afr, st_applies;
logic               o_pop;

rsys_beam_src #(.SEEK_EN(1'b1)) dut (
    .gen_clk(gen_clk), .g_rst(g_rst), .clk(clk), .rst(rst),
    .bm_cfg(shadow), .apply(apply), .frame_beats(26'(FB)), .start(start), .enable(enable),
    .o_valid(o_valid), .o_data(o_data), .o_scene_id(o_sid), .o_scene_frame(o_sfr), .o_pop(o_pop),
    .ev_clip(ev_clip), .st_pending(st_pending), .st_clipped(st_clipped), .st_applied_id(st_aid),
    .st_applied_frame(st_afr), .st_applies(st_applies), .seek_bl(seek_bl), .seek_km(seek_km)
);

// ---------------- vectors ----------------
logic [31:0]  regs [0:4*128-1];          // presets 1, 2, 3, 5
logic [511:0] exp1 [0:6*16384-1];
logic [511:0] exp2 [0:16384-1];
string        vdir = "";

task automatic set_preset(input int idx);   // 0..3 = presets 1, 2, 3, 5
    for (int i = 0; i < 128; i++) shadow[i] = regs[idx * 128 + i];
endtask

task automatic do_apply();
    @(posedge clk) apply <= 1'b1;
    @(posedge clk) apply <= 1'b0;
endtask

task automatic expect_eq(input string what, input longint got, input longint want);
    checks++;
    if (got !== want) begin
        $display("FAIL %s: got %0d (0x%0h), want %0d (0x%0h)", what, got, got, want, want);
        errors++;
    end
endtask

// ---------------- consumer ----------------
int          run = 0;                    // 1, 2: the run whose beats are expected
int          nb = 0;                     // beats taken in this run
int          nb_max = 0;
bit          cons = 1'b0;
int          mism = 0, sb_err = 0, scene3 = 0;
logic [31:0] lfsr = 32'hACE1_2468;
int          fr_sid [8], fr_sfr [8];
always @(posedge clk) lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
assign o_pop = cons && o_valid && nb < nb_max && (lfsr[2:0] != 3'd0);     // ~7/8 duty

always @(posedge clk) begin
    if (o_pop) begin
        logic [511:0] e;
        e = (run == 1) ? exp1[nb] : exp2[nb];
        if (o_data !== e) begin
            if (mism < 6) begin
                for (int l = 0; l < 16; l++)
                    if (o_data[32*l +: 32] !== e[32*l +: 32])
                        $display("FAIL run %0d beat %0d (frame %0d, n %0d) lane %0d: got I %0d Q %0d, want I %0d Q %0d",
                                 run, nb, nb / FB, nb / 4, l, $signed(o_data[32*l +: 16]), $signed(o_data[32*l+16 +: 16]),
                                 $signed(e[32*l +: 16]), $signed(e[32*l+16 +: 16]));
            end
            mism++;
        end
        if (nb % FB == 0) begin
            fr_sid[nb / FB] = o_sid;
            fr_sfr[nb / FB] = o_sfr;
        end
        if (o_sid == 3) scene3++;
        nb <= nb + 1;
    end
end

// generator rate: gen_clk cycles while the consumer takes frame 1 (no activation inside)
longint gcyc = 0, g_f1a = 0, g_f1b = 0;
always @(posedge gen_clk) gcyc <= gcyc + 1;
always @(posedge clk) if (o_pop && run == 1) begin
    if (nb == FB) g_f1a = gcyc;
    if (nb == 2 * FB - 1) g_f1b = gcyc;
end

task automatic wait_beats(input int n);
    while (nb < n) @(posedge clk);
endtask

task automatic wait_status(input int ms_clocks);
    repeat (ms_clocks) @(posedge clk);
endtask

// ---------------- sequence ----------------
initial begin
    if (!$value$plusargs("T=%d", T)) T = 4096;
    if (!$value$plusargs("vdir=%s", vdir)) vdir = ".";
    FB = 4 * T;
    $readmemh({vdir, "/beam_regs.hex"}, regs);
    $readmemh({vdir, "/beam_exp.hex"}, exp1);
    $readmemh({vdir, "/beam_seek.hex"}, exp2);
    for (int i = 0; i < 128; i++) shadow[i] = bm_default(128 + i);
    $display("SIM tb_beam_src: T %0d (%0d beats per frame)", T, FB);
    repeat (8) @(posedge gen_clk);
    @(posedge clk) rst <= 1'b0;
    @(posedge gen_clk) g_rst <= 1'b0;

    // reset scene
    wait_status(1000);
    $display("==== reset scene");
    expect_eq("pending after reset", st_pending, 0);
    expect_eq("APPLIED_ID after reset", st_aid, 0);
    expect_eq("APPLIES after reset", st_applies, 1);

    // APPLY while idle
    $display("==== APPLY while idle (preset 1)");
    set_preset(0);
    do_apply();
    @(posedge clk);
    expect_eq("pending right after APPLY", st_pending, 1);
    wait_status(1000);
    expect_eq("pending", st_pending, 0);
    expect_eq("APPLIED_ID", st_aid, 1);
    expect_eq("APPLIED_FRAME", st_afr, 0);
    expect_eq("APPLIES", st_applies, 2);

    // run 1
    $display("==== run 1: presets 1 -> (3 replaced by) 2 -> 5, 6 frames, mid-run APPLYs");
    run = 1; nb = 0; nb_max = 6 * FB; cons = 1'b1;
    @(posedge clk) begin start <= 1'b1; enable <= 1'b1; end
    @(posedge clk) start <= 1'b0;
    wait_beats(FB + FB / 2);
    set_preset(2);                       // preset 3 (id 3) ...
    do_apply();
    repeat (300) @(posedge clk);
    set_preset(1);                       // ... replaced by preset 2 (id 2) before it is active
    do_apply();
    repeat (2) @(posedge clk);           // the next AXI-Lite write lands >= 3 clocks after the APPLY write
    shadow[1] = 32'h00007777;            // words of the next scene: must not change scene 2
    shadow[16 + 6] = 32'h12345678;
    shadow[64 + 5] = 32'h7FFF7FFF;
    shadow[36] = 32'hDEADBEEF;
    wait_status(2000);
    expect_eq("pending until the frame boundary", st_pending, 1);
    expect_eq("APPLIED_ID still 1 before the boundary", st_aid, 1);
    wait_beats(2 * FB + 64);
    repeat (50) @(posedge clk);
    expect_eq("pending after the activation", st_pending, 0);
    expect_eq("APPLIED_ID (2)", st_aid, 2);
    expect_eq("APPLIED_FRAME (2)", st_afr, 2);
    expect_eq("APPLIES (2 + 1: scene 3 never active)", st_applies, 3);
    wait_beats(3 * FB + FB / 2);
    set_preset(3);                       // preset 5 (id 5)
    do_apply();
    wait_beats(6 * FB);
    repeat (50) @(posedge clk);
    expect_eq("APPLIED_ID (5)", st_aid, 5);
    expect_eq("APPLIED_FRAME (5)", st_afr, 4);
    expect_eq("APPLIES", st_applies, 4);
    expect_eq("CLIPPED", st_clipped, 0);
    @(posedge clk) enable <= 1'b0;
    cons = 1'b0;
    expect_eq("run 1 beats", nb, 6 * FB);
    expect_eq("run 1 beat mismatches", mism, 0);
    for (int f = 0; f < 6; f++) begin
        expect_eq($sformatf("frame %0d scene_id", f), fr_sid[f], f < 2 ? 1 : (f < 4 ? 2 : 5));
        expect_eq($sformatf("frame %0d scene_frame", f), fr_sfr[f], f < 2 ? 0 : (f < 4 ? 2 : 4));
    end
    expect_eq("beats of the replaced scene 3", scene3, 0);
    $display("  frame 1: %0d beats in %0d gen_clk cycles (%.4f beats per clock = %.1f Gb/s at 200 MHz)",
             FB, g_f1b - g_f1a, real'(FB - 1) / real'(g_f1b - g_f1a), 102.4 * real'(FB - 1) / real'(g_f1b - g_f1a));
    checks++;
    if ((g_f1b - g_f1a) > FB + FB / 100) begin $display("FAIL generator slower than 0.99 beats per clock"); errors++; end
    repeat (2000) @(posedge clk);         // generator idle, run 1 beats left in the FIFOs

    // run 2: SEEK near n = 2^26 (noise index m[63:32] 0 -> 1 inside the frame)
    $display("==== run 2: preset 5 from n = 2^26 - 512 (noise index), one frame");
    seek_bl = 28'((64'd1 << 28) - 64'd2048);
    seek_km = 32'd0;
    run = 2; nb = 0; nb_max = FB; mism = 0;
    @(posedge clk) begin start <= 1'b1; enable <= 1'b1; end
    @(posedge clk) start <= 1'b0;
    cons = 1'b1;
    wait_beats(FB);
    repeat (50) @(posedge clk);
    @(posedge clk) enable <= 1'b0;
    cons = 1'b0;
    expect_eq("run 2 beats", nb, FB);
    expect_eq("run 2 beat mismatches", mism, 0);
    expect_eq("run 2 frame 0 scene_id", fr_sid[0], 5);
    expect_eq("run 2 frame 0 scene_frame", fr_sfr[0], 0);
    expect_eq("APPLIED_FRAME after the run start", st_afr, 0);
    expect_eq("APPLIES unchanged by the run start", st_applies, 4);

    $display("==== SIM %s: %0d checks, errors=%0d (%0d beats compared bit-exact)", errors ? "FAIL" : "PASS",
             checks, errors, 7 * FB);
    $finish;
end

initial begin
    #50ms;
    $display("TIMEOUT");
    $finish;
end

endmodule
