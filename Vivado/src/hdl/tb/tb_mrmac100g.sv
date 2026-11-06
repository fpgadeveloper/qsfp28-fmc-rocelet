// SPDX-License-Identifier: MIT
//
// tb_mrmac100g - self-checking test of mac_mrmac100g (the VCK190 MRMAC adapter) against a
// behavioural model of the MRMAC 100G "independent" 384-bit non-segmented client:
//   RX model (axis_clk 390.625 MHz): six 64-bit lanes, 48 bytes per beat, NO tready; frames
//     paced at the 100G wire rate (L + 24 bytes per frame: FCS, preamble, IPG), back to back,
//     optional idle cycles inside frames, random garbage on idle cycles and in tkeep_user of
//     the non-last beats, MRMAC Err (tkeep_user[8]) on ~5 % of the frames.
//   TX model: tready paced at the 100G wire rate with random extra stalls; checks that tvalid
//     never drops inside a frame (MRMAC underflow), full 48-byte beats except the last,
//     contiguous keep, Err flag, zero padding to 60 bytes.
//   Engine side (clk, 300 MHz unless a phase changes it): rocelet's TX conventions (no gap
//     inside a frame, tkeep all ones except the last beat; garbage above tkeep on the last
//     beat), RX monitor honouring mac_stat[10] (RX in reset: discard the partial frame).
// Every frame is regenerated from (id, byte index), so RX and TX are checked bit-exact, in
// order. Phases: control / status / PAUSE / event pass-through; random mix 60-9000 B both
// ways; RX gaps + heavy TX stalls; mac_reset in the middle of traffic (lossy window: frames
// may vanish whole, never merge or corrupt); RX overflow (engine clock 200 MHz, 65-byte
// frames at line rate: dropped whole; 150 MHz, 60-9000 B: also cut mid-frame + flagged bad;
// accounting = mac_lev[5]);
// 250 MHz engine clock random mix (no loss).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps

module tb_mrmac100g;

// ---------------------------------------------------------------- clocks
realtime eng_half = 1.6667;
logic clk = 0, axis_clk = 0, ctl_clk = 0;
always #(eng_half) clk = ~clk;
always #1.28 axis_clk = ~axis_clk;
always #5.0 ctl_clk = ~ctl_clk;

int errors = 0;
task automatic fail(string s); $display("FAIL %s (t=%0t)", s, $realtime); errors++; endtask

// ---------------------------------------------------------------- DUT signals
logic        gt_reset = 1, mac_reset = 1;
logic [511:0] tx_tdata = '0; logic [63:0] tx_tkeep = '0; logic tx_tvalid = 0, tx_tlast = 0, tx_tuser = 0;
wire         tx_tready;
wire [511:0] rx_tdata; wire [63:0] rx_tkeep; wire rx_tvalid, rx_tlast, rx_tuser;
logic [31:0] mac_ctl = 32'h0000_00C3, mac_pz = 32'h0;
wire  [15:0] mac_stat, mac_ev; wire [17:0] mac_pause; wire [31:0] mac_lane; wire [5:0] mac_lev;
wire         gt_powergood, gt_tx_ready, gt_rx_ready;
logic [3:0]  tx_done = 0, rx_done = 0;
wire  [2:0]  lb0, lb1, lb2, lb3;
wire  [3:0]  gt_reset_all_in, tx_core_reset, rx_core_reset, tx_serdes_reset, rx_serdes_reset;
logic [63:0] rxd [6]; logic [10:0] rxk [6]; logic rx_v = 0, rx_l = 0;
wire  [63:0] txd [6]; wire [10:0] txk [6]; wire tx_v, tx_l; logic tx_rdy = 1;
wire  [8:0]  c_txpreq, c_txpen, c_rxpen, c_rxpack; wire c_resend, c_rfi, c_lfi, c_idle;
logic        s_aligned = 0, s_status = 0, s_lf = 0, s_rf = 0, s_rlf = 0, s_ilf = 0, s_hiber = 0, s_mis = 0;
logic        s_fhiser = 0, s_falign = 0; logic [3:0] s_flock = 0; logic [1:0] s_fmap = 0; logic [19:0] s_block = 0;
logic        s_rxbadfcs = 0, s_rxbadcode = 0, s_txbadfcs = 0, s_txunf = 0;
logic [3:0]  s_fcorr = 0, s_funcorr = 0;
logic [8:0]  s_rxpreq = 0, s_rxpval = 0, s_txpval = 0; logic [15:0] s_rxpq = 0;

initial for (int i = 0; i < 6; i++) begin rxd[i] = '0; rxk[i] = '0; end

mac_mrmac100g #(.RX_FIFO_DEPTH(512), .TX_FIFO_DEPTH(512), .FIFO_MEM("block"), .PAD_MIN(60)) dut (
    .clk(clk), .axis_clk(axis_clk), .ctl_clk(ctl_clk), .gt_reset(gt_reset), .mac_reset(mac_reset),
    .tx_tdata(tx_tdata), .tx_tkeep(tx_tkeep), .tx_tvalid(tx_tvalid), .tx_tready(tx_tready),
    .tx_tlast(tx_tlast), .tx_tuser(tx_tuser),
    .rx_tdata(rx_tdata), .rx_tkeep(rx_tkeep), .rx_tvalid(rx_tvalid), .rx_tlast(rx_tlast), .rx_tuser(rx_tuser),
    .mac_ctl(mac_ctl), .mac_pz(mac_pz), .mac_addr(48'h0), .mac_stat(mac_stat), .mac_ev(mac_ev),
    .mac_pause(mac_pause), .mac_lane(mac_lane), .mac_lev(mac_lev),
    .gt_powergood(gt_powergood), .gt_tx_ready(gt_tx_ready), .gt_rx_ready(gt_rx_ready),
    .gtpowergood_in(1'b1), .ch0_loopback(lb0), .ch1_loopback(lb1), .ch2_loopback(lb2), .ch3_loopback(lb3),
    .gt_reset_all_in(gt_reset_all_in), .gt_tx_reset_done_out(tx_done), .gt_rx_reset_done_out(rx_done),
    .tx_core_reset(tx_core_reset), .rx_core_reset(rx_core_reset), .tx_serdes_reset(tx_serdes_reset),
    .rx_serdes_reset(rx_serdes_reset),
    .rx_axis_tdata0(rxd[0]), .rx_axis_tdata1(rxd[1]), .rx_axis_tdata2(rxd[2]), .rx_axis_tdata3(rxd[3]),
    .rx_axis_tdata4(rxd[4]), .rx_axis_tdata5(rxd[5]),
    .rx_axis_tkeep_user0(rxk[0]), .rx_axis_tkeep_user1(rxk[1]), .rx_axis_tkeep_user2(rxk[2]),
    .rx_axis_tkeep_user3(rxk[3]), .rx_axis_tkeep_user4(rxk[4]), .rx_axis_tkeep_user5(rxk[5]),
    .rx_axis_tvalid_0(rx_v), .rx_axis_tlast_0(rx_l),
    .tx_axis_tdata0(txd[0]), .tx_axis_tdata1(txd[1]), .tx_axis_tdata2(txd[2]), .tx_axis_tdata3(txd[3]),
    .tx_axis_tdata4(txd[4]), .tx_axis_tdata5(txd[5]),
    .tx_axis_tkeep_user0(txk[0]), .tx_axis_tkeep_user1(txk[1]), .tx_axis_tkeep_user2(txk[2]),
    .tx_axis_tkeep_user3(txk[3]), .tx_axis_tkeep_user4(txk[4]), .tx_axis_tkeep_user5(txk[5]),
    .tx_axis_tvalid_0(tx_v), .tx_axis_tlast_0(tx_l), .tx_axis_tready_0(tx_rdy),
    .ctl_tx_pause_req_0(c_txpreq), .ctl_tx_pause_enable_0(c_txpen), .ctl_rx_pause_enable_0(c_rxpen),
    .ctl_rx_pause_ack_0(c_rxpack), .ctl_tx_resend_pause_0(c_resend), .ctl_tx_send_rfi_in_0(c_rfi),
    .ctl_tx_send_lfi_in_0(c_lfi), .ctl_tx_send_idle_in_0(c_idle),
    .stat_rx_aligned_0(s_aligned), .stat_rx_status_0(s_status), .stat_rx_local_fault_0(s_lf),
    .stat_rx_remote_fault_0(s_rf), .stat_rx_received_local_fault_0(s_rlf), .stat_rx_internal_local_fault_0(s_ilf),
    .stat_rx_hi_ber_0(s_hiber), .stat_rx_misaligned_0(s_mis), .stat_rx_fec_hi_ser_0(s_fhiser),
    .stat_rx_fec_aligned_0(s_falign), .stat_rx_fec_lane_lock_0(s_flock), .stat_rx_fec_mapping_0(s_fmap),
    .stat_rx_block_lock_0(s_block), .stat_rx_bad_fcs_0(s_rxbadfcs), .stat_rx_bad_code_0(s_rxbadcode),
    .stat_tx_bad_fcs_0(s_txbadfcs), .stat_tx_axis_unf_0(s_txunf),
    .stat_rx_fec_corrected_cw_0_0(s_fcorr[0]), .stat_rx_fec_corrected_cw_0_1(s_fcorr[1]),
    .stat_rx_fec_corrected_cw_0_2(s_fcorr[2]), .stat_rx_fec_corrected_cw_0_3(s_fcorr[3]),
    .stat_rx_fec_uncorrected_cw_0_0(s_funcorr[0]), .stat_rx_fec_uncorrected_cw_0_1(s_funcorr[1]),
    .stat_rx_fec_uncorrected_cw_0_2(s_funcorr[2]), .stat_rx_fec_uncorrected_cw_0_3(s_funcorr[3]),
    .stat_rx_pause_req_0(s_rxpreq), .stat_rx_pause_valid_0(s_rxpval), .stat_rx_pause_quanta8_0(s_rxpq),
    .stat_tx_pause_valid_0(s_txpval)
);

// ---------------------------------------------------------------- frame content
function automatic logic [7:0] fb(int unsigned id, int unsigned i);
    int unsigned h;
    h = id * 32'h9E3779B1 ^ (i * 32'h85EBCA77) ^ 32'h1234567;
    h = h ^ (h >> 15); h = h * 32'h2C1B3C6D; h = h ^ (h >> 12);
    return h[7:0];
endfunction

// mix: 50 % 60-300, 30 % 300-1500, 20 % 1500-9000 (lo = minimum length)
function automatic int rnd_len(int lo);
    int r = $urandom_range(99);
    if (r < 50) return $urandom_range(300, lo);
    if (r < 80) return $urandom_range(1500, 300);
    return $urandom_range(9000, 1500);
endfunction

// ---------------------------------------------------------------- event counters (clk)
int ev_cnt [16];
int lev5 = 0, pz_valid_cnt = 0;
logic [15:0] pz_last_q = 0;
initial foreach (ev_cnt[i]) ev_cnt[i] = 0;
always @(posedge clk) begin
    ev_cnt[0]  += mac_ev[2:0];
    ev_cnt[3]  += mac_ev[5:3];
    ev_cnt[6]  += mac_ev[8:6];
    for (int b = 9; b < 16; b++) ev_cnt[b] += mac_ev[b];
    lev5 += mac_lev[5];
    if (mac_pause[16]) begin pz_valid_cnt++; pz_last_q = mac_pause[15:0]; end
end

// =====================================================================================
// RX: MRMAC model (axis_clk)
// =====================================================================================
int rx_mode = 0;          // 0 idle, 1 random mix, 2 random mix + idle cycles inside frames, 3 flood 65 B
int rx_to_send = 0, rx_sent = 0;
int unsigned rx_next_id = 1;
int rx_len_a [int]; bit rx_err_a [int]; bit rx_md_a [int];   // per id: length, MRMAC Err, may be lost
bit rx_lossy = 0;         // frames generated now may be lost (reset window)
bit rx_cut_ok = 0;        // frames may be dropped / cut by the adapter (overflow phase)
int rx_token = 0;
bit rx_act = 0; int unsigned rx_id; int rx_len, rx_off; bit rx_err;

always @(posedge axis_clk) begin
    if (rx_token < 32) rx_token += 32;            // 100 Gb/s = 32 bytes per 2.56 ns
    // garbage by default (idle cycle)
    for (int ln = 0; ln < 6; ln++) begin rxd[ln] <= {$urandom, $urandom}; rxk[ln] <= $urandom; end
    rx_v <= 1'b0; rx_l <= $urandom_range(1);
    if (!rx_act && rx_mode != 0 && rx_to_send > 0 && rx_token >= 32) begin
        rx_act = 1; rx_id = rx_next_id++; rx_off = 0;
        rx_len = (rx_mode == 3) ? 65 : rnd_len(60);
        rx_err = ($urandom_range(99) < 5);
        rx_len_a[rx_id] = rx_len; rx_err_a[rx_id] = rx_err; rx_md_a[rx_id] = rx_lossy;
        rx_token -= rx_len + 24;
        rx_to_send--; rx_sent++;
    end
    if (rx_act && !(rx_mode == 2 && $urandom_range(9) == 0)) begin
        int n = rx_len - rx_off; bit last;
        last = (n <= 48);
        if (n > 48) n = 48;
        for (int ln = 0; ln < 6; ln++) begin
            logic [63:0] d; logic [7:0] k;
            for (int b = 0; b < 8; b++) begin
                int j = ln * 8 + b;
                d[8*b +: 8] = (j < n) ? fb(rx_id, rx_off + j) : $urandom;
                k[b] = (j < n);
            end
            rxd[ln] <= d;
            rxk[ln] <= last ? {2'b00, rx_err & (k != 0), k} : $urandom;   // keep/err: last beat only
        end
        rx_v <= 1'b1; rx_l <= last;
        rx_off += n;
        if (last) rx_act = 0;
    end
    if (rx_lossy && rx_act) rx_md_a[rx_id] = 1;
end

// RX monitor (clk): rebuild frames, match in order
int unsigned rx_exp = 1;  // next expected id
int rx_good = 0, rx_errf = 0, rx_cut = 0, rx_skipped = 0, rx_frames = 0;
logic [7:0] rbuf [0:16383];
int rpos = 0;
always @(posedge clk) begin
    if (mac_stat[10]) rpos = 0;                    // RX in reset: discard the partial frame
    else if (rx_tvalid) begin
        for (int b = 0; b < 64; b++) if (rx_tkeep[b]) begin
            if (rpos < 16384) rbuf[rpos] = rx_tdata[8*b +: 8];
            rpos++;
        end
        if (!rx_tlast && rx_tkeep !== {64{1'b1}}) fail("RX: partial tkeep on a non-last beat");
        if (rx_tlast) begin
            bit done = 0;
            rx_frames++;
            while (!done) begin
                bit match, prefix;
                if (!rx_len_a.exists(rx_exp)) begin fail($sformatf("RX: unexpected frame len %0d", rpos)); done = 1; break; end
                match = (rpos == rx_len_a[rx_exp]);
                prefix = (rpos < rx_len_a[rx_exp]);
                for (int i = 0; i < rpos && i < rx_len_a[rx_exp]; i++) if (rbuf[i] !== fb(rx_exp, i)) begin match = 0; prefix = 0; break; end
                if (match && rx_tuser == rx_err_a[rx_exp]) begin
                    if (rx_tuser) rx_errf++; else rx_good++;
                    rx_exp++; done = 1;
                end else if (prefix && rx_tuser && (rx_cut_ok || rx_md_a[rx_exp])) begin
                    rx_cut++; rx_exp++; done = 1;
                end else if (rx_cut_ok || rx_md_a[rx_exp]) begin
                    rx_skipped++; rx_exp++;                // dropped whole: try the next one
                end else begin
                    fail($sformatf("RX: frame %0d mismatch (len %0d got %0d, tuser %0d err %0d)", rx_exp,
                                   rx_len_a[rx_exp], rpos, rx_tuser, rx_err_a[rx_exp]));
                    rx_exp++; done = 1;
                end
            end
            rpos = 0;
        end
    end
end

// =====================================================================================
// TX: engine model (clk) and MRMAC model (axis_clk)
// =====================================================================================
int tx_to_send = 0, tx_sent = 0;
int unsigned tx_next_id = 1000001;
int tx_len_a [int]; bit tx_err_a [int]; bit tx_md_a [int];
bit tx_lossy = 0;
bit tx_act = 0; int unsigned tx_id; int tx_len, tx_off; int tx_gap = 0;
int tx_minlen = 20;

always @(posedge clk) begin
    if (tx_tvalid && tx_tready) begin
        if (tx_lossy) tx_md_a[tx_id] = 1;
        tx_off += 64;
        if (tx_tlast) begin tx_act = 0; tx_tvalid <= 0; tx_gap = $urandom_range(3) == 0 ? $urandom_range(4) : 0; end
    end
    if (!tx_act && tx_to_send > 0 && !(tx_tvalid && !tx_tready)) begin
        if (tx_gap > 0) tx_gap--;
        else begin
            tx_act = 1; tx_id = tx_next_id++; tx_off = 0;
            tx_len = ($urandom_range(9) == 0) ? $urandom_range(59, tx_minlen) : rnd_len(60);
            tx_len_a[tx_id] = tx_len; tx_err_a[tx_id] = ($urandom_range(49) == 0); tx_md_a[tx_id] = tx_lossy;
            tx_to_send--; tx_sent++;
        end
    end
    if (tx_act && !(tx_tvalid && !tx_tready)) begin
        int n = tx_len - tx_off; bit last;
        last = (n <= 64);
        for (int b = 0; b < 64; b++) begin
            tx_tdata[8*b +: 8] <= (b < n) ? fb(tx_id, tx_off + b) : $urandom;
            tx_tkeep[b] <= (b < n);
        end
        tx_tvalid <= 1; tx_tlast <= last; tx_tuser <= last & tx_err_a[tx_id];
    end
end

int tx_stall_pct = 10;    // extra random tready-low cycles
int tx_token = 0;
always @(posedge axis_clk) begin
    if (tx_token < 96) tx_token += 32;
    if (tx_v && tx_rdy) begin
        int nb = 0;
        for (int ln = 0; ln < 6; ln++) for (int b = 0; b < 8; b++) nb += txk[ln][b];
        tx_token -= nb + (tx_l ? 24 : 0);
    end
end
always @(posedge axis_clk) tx_rdy <= (tx_token > 0) && ($urandom_range(99) >= tx_stall_pct);

int unsigned tx_exp = 1000001;
int tx_good = 0, tx_skipped = 0, tx_frames = 0, tx_bytes = 0;
logic [7:0] tbuf [0:16383];
int tpos = 0; bit t_in = 0;
realtime tx_t0 = 0, tx_t1 = 0;
always @(posedge axis_clk) begin
    if (dut.tx_rst_a) begin tpos = 0; t_in = 0; end       // MRMAC TX in reset: output ignored
    else begin
        if (t_in && !tx_v) fail("TX: tvalid dropped inside a frame (MRMAC underflow)");
        if (tx_v && tx_rdy) begin
            logic [47:0] k; bit err = 0;
            for (int ln = 0; ln < 6; ln++) begin
                k[8*ln +: 8] = txk[ln][7:0];
                if (txk[ln][8]) err = 1;
                if (txk[ln][10:9] != 0) fail("TX: preempt/resume bits set");
            end
            if (!tx_l && k !== {48{1'b1}}) fail("TX: non-last beat not full 48 bytes");
            if (tx_l && (k == 0 || (k & (k + 48'd1)) != 0)) fail($sformatf("TX: bad last-beat keep %012x", k));
            for (int j = 0; j < 48; j++) if (k[j]) begin
                if (tpos < 16384) tbuf[tpos] = txd[j / 8][8 * (j % 8) +: 8];
                tpos++;
            end
            t_in = !tx_l;
            if (tx_l) begin
                bit done = 0;
                tx_frames++; tx_bytes += tpos;
                if (tx_t0 == 0) tx_t0 = $realtime;
                tx_t1 = $realtime;
                while (!done) begin
                    bit match; int el;
                    if (!tx_len_a.exists(tx_exp)) begin fail($sformatf("TX: unexpected frame len %0d", tpos)); break; end
                    el = (tx_len_a[tx_exp] < 60) ? 60 : tx_len_a[tx_exp];
                    match = (tpos == el) && (err == tx_err_a[tx_exp]);
                    for (int i = 0; match && i < el; i++)
                        if (tbuf[i] !== ((i < tx_len_a[tx_exp]) ? fb(tx_exp, i) : 8'h00)) match = 0;
                    if (match) begin tx_good++; tx_exp++; done = 1; end
                    else if (tx_md_a[tx_exp]) begin tx_skipped++; tx_exp++; end
                    else begin
                        fail($sformatf("TX: frame %0d mismatch (len %0d -> %0d, got %0d, err %0d/%0d)", tx_exp,
                                       tx_len_a[tx_exp], el, tpos, err, tx_err_a[tx_exp]));
                        tx_exp++; done = 1;
                    end
                end
                tpos = 0;
            end
        end
    end
end

// =====================================================================================
// sequencer
// =====================================================================================
task automatic check(string what, longint got, longint want);
    if (got !== want) fail($sformatf("%s: got 0x%0h want 0x%0h", what, got, want));
    else $display("  ok %s = 0x%0h", what, got);
endtask

task automatic wait_drain(int max_us);
    realtime t0 = $realtime;
    while ((rx_to_send > 0 || rx_act || tx_to_send > 0 || tx_act) && $realtime - t0 < max_us * 1000.0) #100;
    t0 = $realtime;
    while ((rx_exp != rx_next_id || tx_exp != tx_next_id) && $realtime - t0 < 20000.0) #100;
    repeat (200) @(posedge clk);
    if (rx_cut_ok && rx_exp != rx_next_id) begin           // the last frames were dropped whole
        rx_skipped += rx_next_id - rx_exp; rx_exp = rx_next_id;
    end
    if (rx_exp != rx_next_id) fail($sformatf("RX: %0d frames never arrived", rx_next_id - rx_exp));
    if (tx_exp != tx_next_id) fail($sformatf("TX: %0d frames never arrived", tx_next_id - tx_exp));
endtask

task automatic pulse_a(ref logic s);
    @(posedge axis_clk) s <= 1; @(posedge axis_clk) s <= 0; repeat (3) @(posedge axis_clk);
endtask

int base_ev [16]; int b_lev5, b_rxg, b_rxe, b_txg, b_rxc, b_rxs, b_txs;
task automatic snap();
    foreach (ev_cnt[i]) base_ev[i] = ev_cnt[i];
    b_lev5 = lev5; b_rxg = rx_good; b_rxe = rx_errf; b_txg = tx_good; b_rxc = rx_cut; b_rxs = rx_skipped; b_txs = tx_skipped;
endtask

task automatic traffic(string name, int nrx, int ntx, int mode, bit lossless);
    int r0 = rx_next_id, t0 = tx_next_id;
    snap();
    $display("==== %s: %0d RX + %0d TX frames, engine clock %.1f MHz", name, nrx, ntx, 500.0 / eng_half);
    rx_mode = mode; rx_to_send = nrx; tx_to_send = ntx;
    tx_bytes = 0; tx_t0 = 0;
    wait_drain(4000);
    rx_mode = 0;
    $display("  RX: %0d good, %0d with Err, %0d cut, %0d dropped whole; TX: %0d good, %0d dropped",
             rx_good - b_rxg, rx_errf - b_rxe, rx_cut - b_rxc, rx_skipped - b_rxs, tx_good - b_txg, tx_skipped - b_txs);
    if (lossless) begin
        check("RX frames delivered bit-exact", (rx_good - b_rxg) + (rx_errf - b_rxe), nrx);
        check("TX frames delivered bit-exact", tx_good - b_txg, ntx);
        check("RX frames lost (mac_lev[5])", lev5 - b_lev5, 0);
    end
    check("mac_ev RX frames", ev_cnt[0] - base_ev[0], (rx_good - b_rxg) + (rx_errf - b_rxe) + (rx_cut - b_rxc));
    check("mac_ev TX frames (engine side)", ev_cnt[9] - base_ev[9], ntx);
    if (ntx > 0 && tx_t1 > tx_t0)
        $display("  TX at the MRMAC: %0d bytes in %.2f us = %.1f Gb/s of frame data", tx_bytes,
                 (tx_t1 - tx_t0) / 1000.0, tx_bytes * 8.0 / (tx_t1 - tx_t0));
endtask

initial begin
    // ------------------------------------------------ reset release
    #200; tx_done = 4'hF; rx_done = 4'hF; gt_reset = 0;
    #300; mac_reset = 0;
    #2000;
    $display("==== resets and GT status");
    check("gt_tx/rx_ready, powergood", {gt_tx_ready, gt_rx_ready, gt_powergood}, 3'b111);
    check("core/serdes resets released", {tx_core_reset, rx_core_reset, tx_serdes_reset, rx_serdes_reset}, 16'h0);
    check("mac_stat RX/TX in reset", mac_stat[11:10], 2'b00);
    gt_reset = 1; #20; check("gt_reset_all_in", gt_reset_all_in, 4'hF); gt_reset = 0;
    rx_done = 4'h7; #200; check("rx_core_reset follows GT RX reset done", rx_core_reset, 4'h8);
    check("mac_stat[10] RX in reset", mac_stat[10], 1); rx_done = 4'hF; #2000;
    check("mac_stat[10] released", mac_stat[10], 0);

    // ------------------------------------------------ control and status pass-through
    $display("==== control: mac_ctl -> MRMAC ports and GT loopback");
    mac_ctl = 32'h0001_02DC;          // [16] PAUSE req, [10:8] = 2 (PMA), [7] tx pause, [6] rx pause, [4:2] idle/lfi/rfi
    #100;
    check("ctl_tx_pause_req_0", c_txpreq, 9'h100);
    check("ctl_tx_pause_enable_0", c_txpen, 9'h100);
    check("ctl_rx_pause_enable_0", c_rxpen, 9'h100);
    check("ctl_rx_pause_ack_0", c_rxpack, 9'h100);
    check("ctl_tx_send_{idle,lfi,rfi}", {c_idle, c_lfi, c_rfi}, 3'b111);
    check("chN_loopback", {lb3, lb2, lb1, lb0}, 12'h492);
    check("mac_stat[13] TX PAUSE active", mac_stat[13], 1);
    mac_ctl = 32'h0000_00C3; #100;
    check("ctl ports cleared", {c_txpreq, c_idle, c_lfi, c_rfi, lb0}, 0);
    check("ctl_tx_pause_enable_0 (mac_ctl[7])", c_txpen, 9'h100);

    $display("==== status levels");
    s_aligned = 1; s_status = 1; s_falign = 1; s_flock = 4'hF; s_fmap = 2'd2; s_block = 20'hFFFFF; #100;
    check("mac_stat link up", mac_stat[12], 1);
    check("mac_stat[9:0]", mac_stat[9:0], 10'h203);
    check("mac_lane", mac_lane, 32'h8FFF_FF6F);
    s_rf = 1; #100; check("mac_stat link down on remote fault", {mac_stat[12], mac_stat[3]}, 2'b01); s_rf = 0;
    s_hiber = 1; s_fhiser = 1; #100; check("mac_stat hi BER / FEC hi SER", {mac_stat[8], mac_stat[6]}, 2'b11);
    s_hiber = 0; s_fhiser = 0;

    $display("==== events (gray-coded counters) and PAUSE");
    snap();
    repeat (6) begin @(posedge ctl_clk) s_rxbadfcs <= 1; @(posedge ctl_clk) s_rxbadfcs <= 0; end
    repeat (3) begin @(posedge ctl_clk) s_rxbadcode <= 1; @(posedge ctl_clk) s_rxbadcode <= 0; end
    repeat (2) begin @(posedge ctl_clk) s_txbadfcs <= 1; @(posedge ctl_clk) s_txbadfcs <= 0; end
    repeat (2) begin @(posedge ctl_clk) s_txunf <= 1; repeat (3) @(posedge ctl_clk); s_txunf <= 0; @(posedge ctl_clk); end
    repeat (10) begin @(posedge axis_clk) s_fcorr <= 4'hF; end @(posedge axis_clk) s_fcorr <= 0;   // 40 back to back
    repeat (7) begin @(posedge axis_clk) s_funcorr <= 4'h1; @(posedge axis_clk) s_funcorr <= 0; end
    repeat (5) begin @(posedge axis_clk) s_txpval <= 9'h100; @(posedge axis_clk) s_txpval <= 0; repeat (2) @(posedge axis_clk); end
    @(posedge axis_clk) begin s_rxpq <= 16'h1234; s_rxpval <= 9'h100; s_rxpreq <= 9'h100; end
    @(posedge axis_clk) s_rxpval <= 0;
    #500;
    check("mac_pause[17] PAUSE in force", mac_pause[17], 1);
    check("mac_pause valid pulses", pz_valid_cnt, 1);
    check("mac_pause quanta", pz_last_q, 16'h1234);
    // two PAUSE frames 3 client clocks apart: the latest quanta must arrive
    @(posedge axis_clk) begin s_rxpq <= 16'hAAAA; s_rxpval <= 9'h100; end
    @(posedge axis_clk) s_rxpval <= 0;
    @(posedge axis_clk); @(posedge axis_clk) begin s_rxpq <= 16'h0000; s_rxpval <= 9'h100; end   // XON
    @(posedge axis_clk) begin s_rxpval <= 0; s_rxpreq <= 0; end
    #500;
    check("mac_pause latest quanta (XON) delivered", pz_last_q, 16'h0000);
    check("mac_pause[17] released", mac_pause[17], 0);
    check("mac_ev RX bad FCS", ev_cnt[3] - base_ev[3], 6);
    check("mac_ev RX bad code", ev_cnt[6] - base_ev[6], 3);
    check("mac_ev TX bad FCS", ev_cnt[10] - base_ev[10], 2);
    check("mac_ev TX underflow (rising edges)", ev_cnt[11] - base_ev[11], 2);
    check("mac_ev FEC corrected (4 lanes x 10 clocks)", ev_cnt[12] - base_ev[12], 40);
    check("mac_ev FEC uncorrectable", ev_cnt[13] - base_ev[13], 7);
    check("mac_ev PAUSE received", ev_cnt[14] - base_ev[14], 3);
    check("mac_ev PAUSE sent", ev_cnt[15] - base_ev[15], 5);

    // ------------------------------------------------ traffic
    traffic("random mix 60-9000 B, line-rate RX, TX tready 10 % stalls", 2500, 2500, 1, 1);
    tx_stall_pct = 60;
    traffic("RX idle cycles inside frames, TX tready 60 % stalls", 600, 600, 2, 1);
    tx_stall_pct = 10;

    $display("==== mac_reset in the middle of traffic (frames may vanish whole, never merge)");
    snap();
    rx_mode = 1; rx_to_send = 1500; tx_to_send = 1500;
    #20000;
    rx_lossy = 1; tx_lossy = 1;
    #6000;                                         // the TX FIFO holds < 3 us of traffic
    mac_reset = 1; #700; mac_reset = 0;
    #3000; rx_lossy = 0; tx_lossy = 0;
    wait_drain(4000);
    rx_mode = 0;
    $display("  RX: %0d good, %0d with Err, %0d cut, %0d dropped whole; TX: %0d good, %0d dropped",
             rx_good - b_rxg, rx_errf - b_rxe, rx_cut - b_rxc, rx_skipped - b_rxs, tx_good - b_txg, tx_skipped - b_txs);
    if (tx_skipped - b_txs == 0) fail("reset phase: no TX frame was lost (reset not exercised?)");
    traffic("after the reset: random mix", 500, 500, 1, 1);

    eng_half = 2.5;                                // 200 MHz engine clock
    rx_cut_ok = 1;
    traffic("RX overflow: 65-byte frames at line rate into a 200 MHz engine", 3000, 0, 3, 0);
    rx_cut_ok = 0;
    check("frames lost = cut + dropped whole (mac_lev[5])", lev5 - b_lev5, (rx_cut - b_rxc) + (rx_skipped - b_rxs));
    if (lev5 - b_lev5 == 0) fail("overflow phase: no frame was lost (overflow not exercised?)");
    eng_half = 3.3333;                             // 150 MHz: long frames overflow mid-frame (cut + flagged)
    rx_cut_ok = 1;
    traffic("RX overflow: random mix 60-9000 B at line rate into a 150 MHz engine", 1500, 0, 1, 0);
    rx_cut_ok = 0;
    check("frames lost = cut + dropped whole (mac_lev[5])", lev5 - b_lev5, (rx_cut - b_rxc) + (rx_skipped - b_rxs));
    if (rx_cut - b_rxc == 0) fail("overflow phase: no frame was cut (mid-frame overflow not exercised?)");
    eng_half = 2.0;                                // 250 MHz
    traffic("250 MHz engine clock, random mix", 1000, 1000, 1, 1);
    eng_half = 1.6667;
    traffic("back at 300 MHz: 65-byte RX flood (no loss) + random TX", 3000, 1000, 3, 1);

    $display("==== DONE errors=%0d (RX %0d frames, TX %0d frames checked)", errors, rx_frames, tx_frames);
    if (errors != 0) $display("SIM FAIL"); else $display("SIM PASS");
    $finish;
end
initial begin #50ms; $display("TIMEOUT"); $finish; end

endmodule
