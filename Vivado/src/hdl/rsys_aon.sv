// SPDX-License-Identifier: MIT
//
// rsys_aon - always-on register block and clock guard of the ZynqMP targets (in the PS
// AXI-Lite clock pl_clk0, which never stops). One AXI4-Lite slave, 1 MB:
//   0x00000-0x7FFFF  rocelet_sys (engine +0x00000, system registers +0x10000, memory window
//                    +0x40000; the KCU116 layout), FORWARDED into the MAC clock through the
//                    clock guard below
//   0x80000-0x800FF  the always-on registers (this block; docs/source/zynqmp_hw.md); 0x60-0x78 =
//                    the 40G lane status and lane event counters (omac_40g; zero on 10G)
// Clock guard: rocelet_sys runs on the MAC user clock, which stops while the transceiver is
// in reset or has no reference clock. An access into a stopped clock domain would never
// complete (A53 hang); an error response would be an SError (Linux panic). So every access
// is answered OKAY by this block:
//   * forwarded with a toggle handshake to the MAC-clock half (m_*, an AXI4-Lite master in
//     mac_clk) when the MAC clock is alive (heartbeat seen within ALIVE_CLKS clocks), no
//     earlier access is still pending and rocelet_sys is not held in reset;
//   * otherwise, or when the forwarded access takes longer than GUARD_TMO clocks: reads
//     return POISON (0xDEADC10C), writes are dropped, and a counter counts it. A timed-out
//     access stays "orphaned" until the MAC side acknowledges it (then the pair is in step
//     again); accesses meanwhile get the poison at once.
// The MAC-clock half has its own time-out (a reset rocelet_sys that never answers) and no
// reset of its own, so its toggle never loses step with this side.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_aon #(
    parameter int          PL_CLK_KHZ = 100000,
    parameter logic [31:0] BUILD_ID   = 32'd0,
    parameter logic [31:0] TARGET_ID  = 32'h5A313036,   // "Z106"
    parameter logic [31:0] CAPS       = 32'd0,
    parameter int          GUARD_TMO  = 4096,
    parameter int          ALIVE_CLKS = 256
) (
    input  wire logic         clk,          // pl_clk0
    input  wire logic         rst,          // synchronous to clk, active high

    input  wire logic [19:0]  s_awaddr,
    input  wire logic         s_awvalid,
    output wire logic         s_awready,
    input  wire logic [31:0]  s_wdata,
    input  wire logic [3:0]   s_wstrb,
    input  wire logic         s_wvalid,
    output wire logic         s_wready,
    output wire logic [1:0]   s_bresp,
    output wire logic         s_bvalid,
    input  wire logic         s_bready,
    input  wire logic [19:0]  s_araddr,
    input  wire logic         s_arvalid,
    output wire logic         s_arready,
    output logic      [31:0]  s_rdata,
    output wire logic [1:0]   s_rresp,
    output wire logic         s_rvalid,
    input  wire logic         s_rready,

    // MAC-clock half: AXI4-Lite master to rocelet_sys
    input  wire logic         mac_clk,
    output logic      [18:0]  m_awaddr = '0,
    output logic              m_awvalid = 1'b0,
    input  wire logic         m_awready,
    output logic      [31:0]  m_wdata = '0,
    output logic      [3:0]   m_wstrb = '0,
    output logic              m_wvalid = 1'b0,
    input  wire logic         m_wready,
    input  wire logic [1:0]   m_bresp,
    input  wire logic         m_bvalid,
    output logic              m_bready = 1'b0,
    output logic      [18:0]  m_araddr = '0,
    output logic              m_arvalid = 1'b0,
    input  wire logic         m_arready,
    input  wire logic [31:0]  m_rdata,
    input  wire logic [1:0]   m_rresp,
    input  wire logic         m_rvalid,
    output logic              m_rready = 1'b0,

    // control (clk)
    output wire logic         gt_reset,     // transceiver reset (gtwizard reset_all)
    output wire logic         mac_reset,    // MAC reset
    output wire logic         sys_reset,    // rocelet_sys reset (soft)
    output wire logic         qsfp_modsel_l,
    output wire logic         qsfp_reset_l,
    output wire logic         qsfp_lpmode,
    output wire logic         led_grn,
    output wire logic         led_red,
    output wire logic         irq,

    // status (asynchronous, synchronised here)
    input  wire logic [15:0]  mac_stat,     // rocelet_sys generic MAC status bundle (MAC clock)
    input  wire logic [7:0]   sys_evt,      // rocelet_sys event levels (MAC clock)
    input  wire logic [31:0]  mac_lane,     // 40G lane status levels (MAC clock; 0 on 10G)
    input  wire logic [5:0]   mac_lev,      // 40G lane events, one MAC clock each (0 on 10G):
                                            // [3:0] BIP3 error per lane [4] skew fail [5] RX overflow
    input  wire logic         gt_powergood,
    input  wire logic         gt_tx_ready,
    input  wire logic         gt_rx_ready,
    input  wire logic         qsfp_modprs_l,
    input  wire logic         qsfp_int_l,
    input  wire logic         clk_los       // Si5328 loss-of-signal alarm (OP120 LA06_P)
);

localparam logic [31:0] POISON = 32'hDEADC10C;

// =====================================================================================
// MAC-clock half
// =====================================================================================
(* ASYNC_REG = "TRUE" *) logic [2:0] mreq_sync = '0;
logic        mack_t = 1'b0;               // ack toggle (MAC clock)
logic [31:0] qsm_rdata = '0;              // read data, captured in mac_clk, read by clk after the ack
logic [3:0]  hb_div = '0;
logic        mhb_t = 1'b0;                // heartbeat toggle
logic [10:0] mtmo = '0;
typedef enum logic [1:0] {M_IDLE, M_WR, M_RD} mst_t;
mst_t mst = M_IDLE;
// request fields (clk domain, stable while the request toggle differs from the ack)
logic        qsr_we;
logic [18:0] qsr_addr;
logic [31:0] qsr_wdata;
logic [3:0]  qsr_wstrb;
logic        req_t = 1'b0;

always_ff @(posedge mac_clk) begin
    mreq_sync <= {mreq_sync[1:0], req_t};
    hb_div    <= hb_div + 4'd1;
    if (hb_div == 4'd15) mhb_t <= ~mhb_t;
    unique case (mst)
        M_IDLE: if (mreq_sync[2] != mack_t) begin
            mtmo <= '0;
            if (qsr_we) begin
                m_awaddr <= qsr_addr; m_wdata <= qsr_wdata; m_wstrb <= qsr_wstrb;
                m_awvalid <= 1'b1; m_wvalid <= 1'b1; m_bready <= 1'b1;
                mst <= M_WR;
            end else begin
                m_araddr <= qsr_addr; m_arvalid <= 1'b1; m_rready <= 1'b1;
                mst <= M_RD;
            end
        end
        M_WR: begin
            mtmo <= mtmo + 11'd1;
            if (m_awready) m_awvalid <= 1'b0;
            if (m_wready)  m_wvalid  <= 1'b0;
            if (m_bvalid || mtmo == '1) begin
                m_awvalid <= 1'b0; m_wvalid <= 1'b0; m_bready <= 1'b0;
                mack_t <= mreq_sync[2];
                mst <= M_IDLE;
            end
        end
        M_RD: begin
            mtmo <= mtmo + 11'd1;
            if (m_arready) m_arvalid <= 1'b0;
            if (m_rvalid || mtmo == '1) begin
                qsm_rdata <= m_rvalid ? m_rdata : POISON;
                m_arvalid <= 1'b0; m_rready <= 1'b0;
                mack_t <= mreq_sync[2];
                mst <= M_IDLE;
            end
        end
        default: mst <= M_IDLE;
    endcase
end

// 40G lane events: free-running 16-bit counters in the MAC clock (no reset: the pl_clk0
// side accumulates the differences), gray-coded across (xpm_cdc_gray, lossless at one
// increment per MAC clock)
localparam int NLEV = 6;
logic [15:0] lev_cnt [NLEV] = '{default: '0};
always_ff @(posedge mac_clk)
    for (int i = 0; i < NLEV; i++) if (mac_lev[i]) lev_cnt[i] <= lev_cnt[i] + 16'd1;
wire logic [15:0] lev_now [NLEV];
for (genvar g = 0; g < NLEV; g++) begin : g_lev
    xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(16), .INIT_SYNC_FF(1), .REG_OUTPUT(1),
                   .SIM_ASSERT_CHK(0), .SIM_LOSSLESS_GRAY_CHK(0)) u_gray (
        .src_clk(mac_clk), .src_in_bin(lev_cnt[g]), .dest_clk(clk), .dest_out_bin(lev_now[g]));
end

// =====================================================================================
// pl_clk0 half
// =====================================================================================
(* ASYNC_REG = "TRUE" *) logic [2:0]  ack_sync = '0, hb_sync = '0;
(* ASYNC_REG = "TRUE" *) logic [15:0] st_s1 = '0, st_s2 = '0;
(* ASYNC_REG = "TRUE" *) logic [7:0]  ev_s1 = '0, ev_s2 = '0;
(* ASYNC_REG = "TRUE" *) logic [5:0]  io_s1 = '0, io_s2 = '0;
(* ASYNC_REG = "TRUE" *) logic [31:0] ln_s1 = '0, ln_s2 = '0;   // 40G lane status (quasi-static)
logic [15:0] hb_age = 16'hFFFF;
always_ff @(posedge clk) begin
    ack_sync <= {ack_sync[1:0], mack_t};
    hb_sync  <= {hb_sync[1:0], mhb_t};
    st_s1 <= mac_stat; st_s2 <= st_s1;
    ev_s1 <= sys_evt;  ev_s2 <= ev_s1;
    io_s1 <= {clk_los, qsfp_int_l, qsfp_modprs_l, gt_rx_ready, gt_tx_ready, gt_powergood};
    io_s2 <= io_s1;
    ln_s1 <= mac_lane; ln_s2 <= ln_s1;
    if (hb_sync[2] != hb_sync[1]) hb_age <= '0;
    else if (hb_age != 16'hFFFF) hb_age <= hb_age + 16'd1;
end
wire logic mac_alive = (hb_age < 16'(ALIVE_CLKS));
wire logic orphan    = (ack_sync[2] != req_t);
wire logic link_up   = st_s2[12];

// MAC clock frequency: MAC heartbeat toggles (one per 16 MAC clocks) counted over 1 ms
logic [31:0] ms_cnt = '0, hb_n = '0, mac_khz = '0;
logic [31:0] us_time = '0;
logic [7:0]  us_div = '0;
always_ff @(posedge clk) begin
    if (ms_cnt == 32'(PL_CLK_KHZ - 1)) begin
        ms_cnt  <= '0;
        mac_khz <= (hb_n + ((hb_sync[2] != hb_sync[1]) ? 32'd1 : 32'd0)) * 32'd16;
        hb_n    <= '0;
    end else begin
        ms_cnt <= ms_cnt + 32'd1;
        if (hb_sync[2] != hb_sync[1]) hb_n <= hb_n + 32'd1;
    end
    if (us_div == 8'(PL_CLK_KHZ / 1000 - 1)) begin us_div <= '0; us_time <= us_time + 32'd1; end
    else us_div <= us_div + 8'd1;
end

// ---------------- registers ----------------
logic [31:0] ctrl, scratch, irq_status, irq_enable, guard_tmo;
logic [31:0] n_poison_rd, n_drop_wr, n_tmo;
logic [15:0] n_link_up, n_link_dn;
logic [8:0]  irq_raw, irq_raw_q;
logic [15:0] lev_prev [NLEV];
logic [31:0] lev_acc  [NLEV];             // 40G lane event counts (pl_clk0), cleared by a LANE_STAT write
logic        poison_ev;

assign gt_reset      = ctrl[0];
assign mac_reset     = ctrl[1];
assign sys_reset     = ctrl[2];
assign qsfp_modsel_l = ctrl[8];
assign qsfp_reset_l  = ctrl[9];
assign qsfp_lpmode   = ctrl[10];
assign led_grn       = link_up;
assign led_red       = !io_s2[3] && !link_up;     // module present, link down

// interrupt sources: [0] link change (edge) [1] engine irq [2] control-plane RX FIFO not empty
// [3] work completion queued [4] receive completion queued [5] guard poison / drop (edge)
// [6] QSFP IntL asserted [7] QSFP presence change (edge) [8] Si5328 LOS change (edge)
// [9] DMA channel RX frames pending (level; informational, the AXI DMA has its own interrupts)
always_comb begin
    irq_raw    = '0;
    irq_raw[0] = link_up;
    irq_raw[1] = ev_s2[0];
    irq_raw[2] = ev_s2[1];
    irq_raw[3] = ev_s2[2];
    irq_raw[4] = ev_s2[3];
    irq_raw[5] = poison_ev;
    irq_raw[6] = !io_s2[4];
    irq_raw[7] = io_s2[3];
    irq_raw[8] = io_s2[5];
end
localparam logic [8:0] EDGE_SRC = 9'b110100001;   // both edges latch
localparam logic [8:0] LEVEL_SRC = ~EDGE_SRC;
assign irq = |(irq_status & irq_enable);

// STATUS (0x024)
logic [31:0] status;
always_comb begin
    status     = '0;
    status[0]  = mac_alive;
    status[1]  = io_s2[0];   // gt_powergood
    status[2]  = io_s2[1];   // gt_tx_ready
    status[3]  = io_s2[2];   // gt_rx_ready
    status[4]  = st_s2[0];   // block lock / aligned
    status[5]  = st_s2[12];  // link up
    status[6]  = st_s2[6];   // hi BER
    status[7]  = st_s2[2];   // local fault
    status[8]  = st_s2[3];   // remote fault
    status[12] = io_s2[3];   // QSFP ModPrsL (0 = module present)
    status[13] = io_s2[4];   // QSFP IntL (0 = interrupt)
    status[14] = io_s2[5];   // Si5328 LOS alarm
    status[16] = orphan;
    status[17] = sys_reset;
end

function automatic logic [31:0] reg_rd(input logic [7:0] a);
    unique case (a)
        8'h00: return 32'h52414F4E;          // "RAON"
        8'h04: return 32'h00010000;          // version 1.0
        8'h08: return BUILD_ID;
        8'h0C: return TARGET_ID;
        8'h10: return CAPS;
        8'h14: return mac_alive ? mac_khz : 32'd0;
        8'h18: return 32'(PL_CLK_KHZ);
        8'h1C: return us_time;
        8'h20: return ctrl;
        8'h24: return status;
        8'h28: return {n_link_dn, n_link_up};
        8'h2C: return {16'd0, st_s2};
        8'h30: return irq_status;
        8'h34: return irq_enable;
        8'h38: return {23'd0, irq_raw};
        8'h3C: return {24'd0, ev_s2};
        8'h40: return n_poison_rd;
        8'h44: return n_drop_wr;
        8'h48: return n_tmo;
        8'h4C: return guard_tmo;
        8'h50: return scratch;
        8'h60: return ln_s2;
        8'h64: return lev_acc[0];
        8'h68: return lev_acc[1];
        8'h6C: return lev_acc[2];
        8'h70: return lev_acc[3];
        8'h74: return lev_acc[4];
        8'h78: return lev_acc[5];
        default: return 32'd0;
    endcase
endfunction

// ---------------- AXI4-Lite slave ----------------
typedef enum logic [2:0] {A_IDLE, A_FWD, A_B, A_R} ast_t;
ast_t as = A_IDLE;
logic [31:0] tmo;
logic        fwd_we;
assign s_awready = (as == A_IDLE) && s_awvalid && s_wvalid;
assign s_wready  = (as == A_IDLE) && s_awvalid && s_wvalid;
assign s_arready = (as == A_IDLE) && !(s_awvalid && s_wvalid) && s_arvalid;
assign s_bresp   = 2'b00;
assign s_rresp   = 2'b00;
assign s_bvalid  = (as == A_B);
assign s_rvalid  = (as == A_R);
wire logic fwd_ok = mac_alive && !orphan && !sys_reset;

always_ff @(posedge clk) begin
    poison_ev <= 1'b0;
    irq_raw_q <= irq_raw;
    // latch: edge sources on any change, level sources while high
    irq_status <= irq_status | {23'd0, (EDGE_SRC & (irq_raw ^ irq_raw_q)) | (LEVEL_SRC & irq_raw)};
    if (link_up && !irq_raw_q[0]) n_link_up <= n_link_up + 16'd1;
    if (!link_up && irq_raw_q[0]) n_link_dn <= n_link_dn + 16'd1;
    for (int i = 0; i < NLEV; i++) begin
        lev_prev[i] <= lev_now[i];
        lev_acc[i]  <= lev_acc[i] + 32'(16'(lev_now[i] - lev_prev[i]));
    end
    unique case (as)
        A_IDLE: begin
            if (s_awvalid && s_wvalid) begin
                if (s_awaddr[19]) begin
                    unique case (s_awaddr[7:0])
                        8'h20: ctrl <= s_wdata;
                        8'h30: irq_status <= irq_status & ~s_wdata;      // write 1 to clear
                        8'h34: irq_enable <= s_wdata;
                        8'h40: n_poison_rd <= '0;
                        8'h44: n_drop_wr <= '0;
                        8'h48: n_tmo <= '0;
                        8'h4C: guard_tmo <= (s_wdata < 32'd64) ? 32'd64 : s_wdata;
                        8'h50: scratch <= s_wdata;
                        8'h60: for (int i = 0; i < NLEV; i++) begin lev_acc[i] <= '0; lev_prev[i] <= lev_now[i]; end
                        default: ;
                    endcase
                    as <= A_B;
                end else if (fwd_ok) begin
                    qsr_we <= 1'b1; qsr_addr <= s_awaddr[18:0]; qsr_wdata <= s_wdata; qsr_wstrb <= s_wstrb;
                    req_t <= ~req_t; fwd_we <= 1'b1; tmo <= '0;
                    as <= A_FWD;
                end else begin
                    n_drop_wr <= n_drop_wr + 32'd1; poison_ev <= 1'b1;
                    as <= A_B;
                end
            end else if (s_arvalid) begin
                if (s_araddr[19]) begin
                    s_rdata <= reg_rd(s_araddr[7:0]);
                    as <= A_R;
                end else if (fwd_ok) begin
                    qsr_we <= 1'b0; qsr_addr <= s_araddr[18:0];
                    req_t <= ~req_t; fwd_we <= 1'b0; tmo <= '0;
                    as <= A_FWD;
                end else begin
                    s_rdata <= POISON;
                    n_poison_rd <= n_poison_rd + 32'd1; poison_ev <= 1'b1;
                    as <= A_R;
                end
            end
        end
        A_FWD: begin
            tmo <= tmo + 32'd1;
            if (ack_sync[2] == req_t) begin
                s_rdata <= qsm_rdata;
                as <= fwd_we ? A_B : A_R;
            end else if (tmo >= guard_tmo) begin
                // the MAC clock stopped under the access: answer, leave it orphaned
                s_rdata <= POISON;
                n_tmo <= n_tmo + 32'd1; poison_ev <= 1'b1;
                as <= fwd_we ? A_B : A_R;
            end
        end
        A_B: if (s_bready) as <= A_IDLE;
        A_R: if (s_rready) as <= A_IDLE;
        default: as <= A_IDLE;
    endcase
    if (rst) begin
        as <= A_IDLE;
        // GT and MAC held in reset until software has programmed the reference clock;
        // QSFP module selected, out of reset, high power
        ctrl <= 32'h00000203;
        scratch <= '0; irq_status <= '0; irq_enable <= '0; guard_tmo <= 32'(GUARD_TMO);
        n_poison_rd <= '0; n_drop_wr <= '0; n_tmo <= '0; n_link_up <= '0; n_link_dn <= '0;
        for (int i = 0; i < NLEV; i++) begin lev_acc[i] <= '0; lev_prev[i] <= lev_now[i]; end
        // req_t is not reset: it must stay in step with the MAC-clock half
    end
end

wire logic unused_ok = &{1'b0, m_bresp, m_rresp, st_s2[15:13]};

endmodule

`resetall
