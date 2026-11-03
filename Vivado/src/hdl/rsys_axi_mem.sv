// SPDX-License-Identifier: MIT
//
// rsys_axi_mem - the FPGA memory window of the reference design: BYTES of on-chip
// memory (URAM, 512 bits wide, byte writes) shared by
//   * the rocelet engine's AXI4 memory master (s_axi: 512-bit INCR bursts of up
//     to 64 beats, 64-byte aligned; responder WRITE data, RDMA READ data and,
//     in the re-read requester mode, requester payload);
//   * the payload reader of the firmware work-request queue (pcmd / pdat:
//     address + length command, 512-bit data stream);
//   * the MicroBlaze (s_fw: a 32-bit AXI4-Lite window onto the same memory).
// The URAM is used as a true dual-port memory: port A writes (firmware first,
// then AXI write beats), port B reads (firmware first, then the AXI read
// stream and the payload stream, round robin per beat). Each read stream has
// its own output FIFO with a credit check, so a stalled consumer never blocks
// the other one. Write responses are OKAY; addresses wrap at BYTES.
//
// PAT_EN (self-test builds) adds a virtual "pattern" region, selected by
// address bit PAT_BIT: reads return pattern(address) (rsys_pkg), writes are
// discarded, so a line-rate stream of any length can be written and verified
// (the write-beat tap feeds the self-test checker).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_axi_mem
    import rsys_pkg::*;
#(
    parameter int BYTES   = 262144,
    parameter bit PAT_EN  = 1'b1,
    parameter int PAT_BIT = 40,
    parameter int ID_W    = 2,
    parameter int ADDR_W  = 64,
    parameter int FW_AW   = 18,
    parameter int RD_LAT  = 3
) (
    input  wire logic              clk,
    input  wire logic              rst,
    input  wire logic [31:0]       seed,

    // AXI4 slave (the engine's memory master)
    input  wire logic [ID_W-1:0]   s_axi_awid,
    input  wire logic [ADDR_W-1:0] s_axi_awaddr,
    input  wire logic [7:0]        s_axi_awlen,
    input  wire logic              s_axi_awvalid,
    output wire logic              s_axi_awready,
    input  wire logic [511:0]      s_axi_wdata,
    input  wire logic [63:0]       s_axi_wstrb,
    input  wire logic              s_axi_wlast,
    input  wire logic              s_axi_wvalid,
    output wire logic              s_axi_wready,
    output wire logic [ID_W-1:0]   s_axi_bid,
    output wire logic [1:0]        s_axi_bresp,
    output wire logic              s_axi_bvalid,
    input  wire logic              s_axi_bready,
    input  wire logic [ID_W-1:0]   s_axi_arid,
    input  wire logic [ADDR_W-1:0] s_axi_araddr,
    input  wire logic [7:0]        s_axi_arlen,
    input  wire logic              s_axi_arvalid,
    output wire logic              s_axi_arready,
    output wire logic [ID_W-1:0]   s_axi_rid,
    output wire logic [511:0]      s_axi_rdata,
    output wire logic [1:0]        s_axi_rresp,
    output wire logic              s_axi_rlast,
    output wire logic              s_axi_rvalid,
    input  wire logic              s_axi_rready,

    // payload reader port (firmware work-request queue)
    input  wire logic              s_pcmd_valid,
    output wire logic              s_pcmd_ready,
    input  wire logic [63:0]       s_pcmd_addr,
    input  wire logic [12:0]       s_pcmd_len,
    output wire logic [511:0]      m_pdat_tdata,
    output wire logic              m_pdat_tvalid,
    input  wire logic              m_pdat_tready,

    // firmware window (AXI4-Lite, 32-bit)
    input  wire logic [FW_AW-1:0]  s_fw_awaddr,
    input  wire logic              s_fw_awvalid,
    output wire logic              s_fw_awready,
    input  wire logic [31:0]       s_fw_wdata,
    input  wire logic [3:0]        s_fw_wstrb,
    input  wire logic              s_fw_wvalid,
    output wire logic              s_fw_wready,
    output wire logic [1:0]        s_fw_bresp,
    output wire logic              s_fw_bvalid,
    input  wire logic              s_fw_bready,
    input  wire logic [FW_AW-1:0]  s_fw_araddr,
    input  wire logic              s_fw_arvalid,
    output wire logic              s_fw_arready,
    output logic      [31:0]       s_fw_rdata,
    output wire logic [1:0]        s_fw_rresp,
    output wire logic              s_fw_rvalid,
    input  wire logic              s_fw_rready,

    // write-beat tap (every accepted AXI write beat with its address)
    output logic                   wtap_valid,
    output logic [63:0]            wtap_addr,
    output logic [511:0]           wtap_data,
    output logic [63:0]            wtap_keep,
    output logic                   wtap_last,
    // statistics
    output logic                   ev_wr_burst,
    output logic                   ev_rd_burst,
    output logic [15:0]            rd0_bytes_add    // bytes of ARID 0 bursts (READ responses)
);

localparam int DEPTH = BYTES / 64;
localparam int AW    = $clog2(DEPTH);
localparam int OFD   = 16;
localparam int CW    = $clog2(OFD) + 1;
localparam int PL    = RD_LAT + 2;

function automatic logic is_pat(input logic [63:0] a);
    return PAT_EN && a[PAT_BIT];
endfunction

// ---------------- memory (true dual port: A writes, B reads) ----------------
(* ram_style = "ultra" *) logic [511:0] mem [DEPTH];
logic          a_we = 1'b0;
logic [63:0]   a_be;
logic [AW-1:0] a_wa;
logic [511:0]  a_wd;
logic          b_re = 1'b0;
logic [AW-1:0] b_ra;
logic [511:0]  b_q [RD_LAT];

always_ff @(posedge clk) begin
    if (a_we) begin
        for (int b = 0; b < 64; b++) if (a_be[b]) mem[a_wa][b*8 +: 8] <= a_wd[b*8 +: 8];
    end
end
always_ff @(posedge clk) begin
    if (b_re) b_q[0] <= mem[b_ra];
    for (int i = 1; i < RD_LAT; i++) b_q[i] <= b_q[i-1];
end

// ---------------- firmware window: one access at a time ----------------
logic             fw_aw = 1'b0, fw_w = 1'b0, fw_b = 1'b0;
logic [FW_AW-1:0] fw_wa;
logic [31:0]      fw_wd;
logic [3:0]       fw_ws;
logic             fw_ar = 1'b0, fw_r = 1'b0, fw_rd_issued = 1'b0;
logic [FW_AW-1:0] fw_ra;
wire  logic       fw_wgo = fw_aw && fw_w && !fw_b;     // perform the write this clock
assign s_fw_awready = !fw_aw && !fw_b;
assign s_fw_wready  = !fw_w && !fw_b;
assign s_fw_bvalid  = fw_b;
assign s_fw_bresp   = 2'b00;
assign s_fw_arready = !fw_ar && !fw_r;
assign s_fw_rvalid  = fw_r;
assign s_fw_rresp   = 2'b00;

// ---------------- port A: firmware write, else AXI write beats ----------------
wire logic        awq_v, awq_full;
wire logic [ID_W-1:0] awq_id;
wire logic [63:0] awq_a;
logic             awq_pop;
rsys_fifo #(.WIDTH(ID_W + 64), .DEPTH(4), .RAM_STYLE("distributed")) u_awq (
    .clk(clk), .rst(rst), .din({s_axi_awid, 64'(s_axi_awaddr)}), .wr_en(s_axi_awvalid && s_axi_awready),
    .full(awq_full), .dout({awq_id, awq_a}), .valid(awq_v), .rd_en(awq_pop), .count()
);
assign s_axi_awready = !awq_full;

logic [63:0] w_a;            // address of the next beat of the head burst
logic        w_mid = 1'b0;   // inside a burst (w_a valid)
wire  logic [63:0] w_cur = w_mid ? w_a : {awq_a[63:6], 6'd0};
wire  logic  bq_full;
assign s_axi_wready = awq_v && !fw_wgo && !bq_full;
wire  logic  w_beat = s_axi_wvalid && s_axi_wready;
assign awq_pop = w_beat && s_axi_wlast;

rsys_fifo #(.WIDTH(ID_W), .DEPTH(4), .RAM_STYLE("distributed")) u_bq (
    .clk(clk), .rst(rst), .din(awq_id), .wr_en(awq_pop), .full(bq_full),
    .dout(s_axi_bid), .valid(s_axi_bvalid), .rd_en(s_axi_bready), .count()
);
assign s_axi_bresp = 2'b00;

always_ff @(posedge clk) begin
    a_we        <= 1'b0;
    wtap_valid  <= w_beat;
    ev_wr_burst <= awq_pop;
    if (w_beat) begin
        a_we      <= !is_pat(w_cur);
        a_be      <= s_axi_wstrb;
        a_wa      <= w_cur[AW+5:6];
        a_wd      <= s_axi_wdata;
        w_a       <= w_cur + 64'd64;
        w_mid     <= !s_axi_wlast;
        wtap_addr <= w_cur;
        wtap_data <= s_axi_wdata;
        wtap_keep <= s_axi_wstrb;
        wtap_last <= s_axi_wlast;
    end else if (fw_wgo) begin
        a_we <= 1'b1;
        a_be <= 64'(fw_ws) << {fw_wa[5:2], 2'b00};
        a_wa <= AW'(fw_wa >> 6);
        a_wd <= {16{fw_wd}};
    end
    // firmware write handshakes
    if (s_fw_awvalid && s_fw_awready) begin fw_aw <= 1'b1; fw_wa <= s_fw_awaddr; end
    if (s_fw_wvalid && s_fw_wready)   begin fw_w <= 1'b1; fw_wd <= s_fw_wdata; fw_ws <= s_fw_wstrb; end
    if (fw_wgo) begin
        fw_aw <= 1'b0;
        fw_w  <= 1'b0;
        fw_b  <= 1'b1;
    end
    if (fw_b && s_fw_bready) fw_b <= 1'b0;
    if (rst) begin
        w_mid <= 1'b0;
        fw_aw <= 1'b0;
        fw_w  <= 1'b0;
        fw_b  <= 1'b0;
    end
end

// ---------------- port B: firmware read, else AXI read stream / payload stream ----------------
wire logic        arq_v, arq_full;
wire logic [ID_W-1:0] arq_id;
wire logic [63:0] arq_a;
wire logic [7:0]  arq_len;
logic             arq_pop;
rsys_fifo #(.WIDTH(ID_W + 64 + 8), .DEPTH(4), .RAM_STYLE("distributed")) u_arq (
    .clk(clk), .rst(rst), .din({s_axi_arid, 64'(s_axi_araddr), s_axi_arlen}),
    .wr_en(s_axi_arvalid && s_axi_arready),
    .full(arq_full), .dout({arq_id, arq_a, arq_len}), .valid(arq_v), .rd_en(arq_pop), .count()
);
assign s_axi_arready = !arq_full;

// read pipeline stages (see below)
logic [PL-1:0]   s_pat, s_fw, s_last;
logic [63:0]     s_a  [PL];
logic [ID_W-1:0] s_id [PL];
// stream 1: AXI read bursts
logic            r1_act = 1'b0, r1_pat;
logic [63:0]     r1_a;
logic [8:0]      r1_left;
logic [ID_W-1:0] r1_id;
// stream 2: payload commands
logic            r2_act = 1'b0, r2_pat;
logic [63:0]     r2_a;
logic [7:0]      r2_left;
wire  logic [CW-1:0] of1_cnt, of2_cnt;
logic [PL-1:0]   f1 = '0, f2 = '0;
logic [CW-1:0]   n1, n2;
always_comb begin
    n1 = '0;
    n2 = '0;
    for (int i = 0; i < PL; i++) begin
        n1 = n1 + CW'(f1[i]);
        n2 = n2 + CW'(f2[i]);
    end
end
wire logic fw_rgo = fw_ar && !fw_rd_issued;
wire logic ok1 = r1_act && !fw_rgo && (of1_cnt + n1 < CW'(OFD - 1));
wire logic ok2 = r2_act && !fw_rgo && (of2_cnt + n2 < CW'(OFD - 1));
logic      rr = 1'b0;                       // 1 = stream 2 has priority this clock
wire logic iss1 = ok1 && (!ok2 || !rr);
wire logic iss2 = ok2 && (!ok1 || rr);
assign arq_pop = !r1_act && arq_v;
assign s_pcmd_ready = !r2_act;

always_ff @(posedge clk) begin
    ev_rd_burst   <= arq_pop;
    rd0_bytes_add <= (arq_pop && arq_id == '0) ? 16'(({8'd0, arq_len} + 16'd1) << 6) : 16'd0;
    if (iss1 || iss2) rr <= iss1;
    if (arq_pop) begin
        r1_act  <= 1'b1;
        r1_pat  <= is_pat(arq_a);
        r1_a    <= {arq_a[63:6], 6'd0};
        r1_left <= {1'b0, arq_len} + 9'd1;
        r1_id   <= arq_id;
    end else if (iss1) begin
        r1_a    <= r1_a + 64'd64;
        r1_left <= r1_left - 9'd1;
        if (r1_left == 9'd1) r1_act <= 1'b0;
    end
    if (s_pcmd_valid && !r2_act) begin
        r2_act  <= (s_pcmd_len != 0);
        r2_pat  <= is_pat(s_pcmd_addr);
        r2_a    <= {s_pcmd_addr[63:6], 6'd0};
        r2_left <= 8'((s_pcmd_len + 13'd63) >> 6);
    end else if (iss2) begin
        r2_a    <= r2_a + 64'd64;
        r2_left <= r2_left - 8'd1;
        if (r2_left == 8'd1) r2_act <= 1'b0;
    end
    // firmware read handshakes
    if (s_fw_arvalid && s_fw_arready) begin fw_ar <= 1'b1; fw_ra <= s_fw_araddr; end
    if (fw_rgo) fw_rd_issued <= 1'b1;
    if (s_fw[PL-2]) fw_r <= 1'b1;
    if (fw_r && s_fw_rready) begin
        fw_r         <= 1'b0;
        fw_ar        <= 1'b0;
        fw_rd_issued <= 1'b0;
    end
    if (rst) begin
        r1_act       <= 1'b0;
        r2_act       <= 1'b0;
        fw_ar        <= 1'b0;
        fw_r         <= 1'b0;
        fw_rd_issued <= 1'b0;
    end
end

// pipeline: issue -> b_re/b_ra (stage 0) -> b_q[0] .. b_q[RD_LAT-1] -> output FIFOs
always_ff @(posedge clk) begin
    f1     <= {f1[PL-2:0], iss1};
    f2     <= {f2[PL-2:0], iss2};
    s_fw   <= {s_fw[PL-2:0], fw_rgo};
    s_pat  <= {s_pat[PL-2:0], iss1 ? r1_pat : (iss2 ? r2_pat : 1'b0)};
    s_last <= {s_last[PL-2:0], iss1 && (r1_left == 9'd1)};
    s_a[0]  <= iss1 ? r1_a : (iss2 ? r2_a : 64'(fw_ra));
    s_id[0] <= r1_id;
    for (int i = 1; i < PL; i++) begin
        s_a[i]  <= s_a[i-1];
        s_id[i] <= s_id[i-1];
    end
    b_re <= iss1 || iss2 || fw_rgo;
    b_ra <= iss1 ? r1_a[AW+5:6] : (iss2 ? r2_a[AW+5:6] : AW'(fw_ra >> 6));
    if (rst) begin
        f1   <= '0;
        f2   <= '0;
        s_fw <= '0;
        b_re <= 1'b0;
    end
end
wire  logic [511:0] ram_q = b_q[RD_LAT-1];
logic [511:0] word;
if (PAT_EN) begin : g_pat
    logic [511:0] pat_q;
    always_ff @(posedge clk) pat_q <= pat_beat(s_a[PL-3], seed);
    assign word = s_pat[PL-2] ? pat_q : ram_q;
end else begin : g_nopat
    assign word = ram_q;
end

always_ff @(posedge clk) begin
    if (s_fw[PL-2]) s_fw_rdata <= ram_q[s_a[PL-2][5:2]*32 +: 32];
end

rsys_fifo #(.WIDTH(512 + ID_W + 1), .DEPTH(OFD), .RAM_STYLE("distributed")) u_of1 (
    .clk(clk), .rst(rst), .din({word, s_id[PL-2], s_last[PL-2]}), .wr_en(f1[PL-2]), .full(),
    .dout({s_axi_rdata, s_axi_rid, s_axi_rlast}), .valid(s_axi_rvalid), .rd_en(s_axi_rready), .count(of1_cnt)
);
assign s_axi_rresp = 2'b00;
rsys_fifo #(.WIDTH(512), .DEPTH(OFD), .RAM_STYLE("distributed")) u_of2 (
    .clk(clk), .rst(rst), .din(word), .wr_en(f2[PL-2]), .full(),
    .dout(m_pdat_tdata), .valid(m_pdat_tvalid), .rd_en(m_pdat_tready), .count(of2_cnt)
);

endmodule

`resetall
