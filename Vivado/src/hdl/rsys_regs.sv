// SPDX-License-Identifier: MIT
//
// rsys_regs - AXI4-Lite system register window of the qsfp28-fmc-rocelet reference
// design (the rocelet engine has its own register map): configuration words with
// a write strobe per word, read-only status values, 32-bit event counters, 64-bit
// accumulators, and windows onto the raw TX frame buffer, the capture buffer and the
// control-plane receive FIFO (layout in rsys_pkg). The reset values of the configuration words (cfg_default)
// bring the CMAC link up without any firmware write: RX/TX enabled, RS-FEC on.
// Runs in the CMAC user clock (the SmartConnect in front does the clock
// crossing). Reads take a fixed 5 clocks (banked, registered read mux).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_regs
    import rsys_pkg::*;
#(
    parameter bit RSFEC = 1'b1          // reset value of C_MAC_CTL.RS-FEC
) (
    input  wire logic         clk,
    input  wire logic         rst,

    input  wire logic [15:0]  s_axil_awaddr,
    input  wire logic         s_axil_awvalid,
    output wire logic         s_axil_awready,
    input  wire logic [31:0]  s_axil_wdata,
    input  wire logic [3:0]   s_axil_wstrb,
    input  wire logic         s_axil_wvalid,
    output wire logic         s_axil_wready,
    output wire logic [1:0]   s_axil_bresp,
    output wire logic         s_axil_bvalid,
    input  wire logic         s_axil_bready,
    input  wire logic [15:0]  s_axil_araddr,
    input  wire logic         s_axil_arvalid,
    output wire logic         s_axil_arready,
    output wire logic [31:0]  s_axil_rdata,
    output wire logic [1:0]   s_axil_rresp,
    output wire logic         s_axil_rvalid,
    input  wire logic         s_axil_rready,

    output logic [31:0]       cfg    [NCFG],
    output logic [NCFG-1:0]   cfg_wr = '0,
    output logic              stats_clr,

    input  wire logic [31:0]  sv     [NSV],
    input  wire logic [NCNT-1:0] ev,
    input  wire logic [15:0]  bc_add [NBC],

    // raw TX buffer write port (32-bit words)
    output logic              raw_we,
    output logic [8:0]        raw_waddr,
    output logic [31:0]       raw_wdata,
    // capture buffer read port (32-bit words, 2-clock latency)
    output logic [11:0]       cap_raddr,
    input  wire logic [31:0]  cap_rdata,
    // control-plane receive FIFO, head frame (32-bit words, 2-clock latency)
    output logic [8:0]        crx_raddr,
    input  wire logic [31:0]  crx_rdata
);

// ---------------- configuration defaults ----------------
function automatic logic [31:0] cfg_default(input int i);
    case (i)
        C_MAC_CTL:  return 32'h00000003 | (32'(RSFEC) << 5);   // rx enable, tx enable, RS-FEC
        C_MAC_PZ:   return 32'h00800100;      // PAUSE quanta 0x100, refresh 0x80
        C_INJ_BYTE: return 32'd53;            // corrupt the BTH PSN low byte
        C_RINJ_BYTE: return 32'd53;
        C_CRX_PORTS: return {16'd12268, 16'd8192};   // HSB BOOTP reply, HSB register protocol
        C_HP_WRMAX:  return 32'd16384;
        C_IQ_CHUNK:  return 32'd1024;
        default:    return (i >= 128) ? bm_default(i) : 32'd0;
    endcase
endfunction

// ---------------- write channel ----------------
logic        aw_have = 1'b0, w_have = 1'b0, b_v = 1'b0;
logic [15:0] aw_a;
logic [31:0] w_d;
logic [3:0]  w_s;

assign s_axil_awready = !aw_have && !b_v;
assign s_axil_wready  = !w_have && !b_v;
assign s_axil_bvalid  = b_v;
assign s_axil_bresp   = 2'b00;

wire logic do_wr = aw_have && w_have && !b_v;
wire logic [7:0] widx = aw_a[9:2];

always_ff @(posedge clk) begin
    cfg_wr    <= '0;
    stats_clr <= 1'b0;
    raw_we    <= 1'b0;
    if (s_axil_awvalid && s_axil_awready) begin aw_have <= 1'b1; aw_a <= s_axil_awaddr; end
    if (s_axil_wvalid && s_axil_wready)   begin w_have <= 1'b1; w_d <= s_axil_wdata; w_s <= s_axil_wstrb; end
    if (do_wr) begin
        aw_have <= 1'b0;
        w_have  <= 1'b0;
        b_v     <= 1'b1;
        if (aw_a[15:10] == 6'd0 && int'(widx) < NCFG) begin
            for (int b = 0; b < 4; b++) if (w_s[b]) cfg[widx][b*8 +: 8] <= w_d[b*8 +: 8];
            cfg_wr[widx] <= 1'b1;
            if (widx == 8'(C_CTRL) && w_d[1]) stats_clr <= 1'b1;
        end else if (aw_a[15:11] == 5'b00010) begin       // 0x1000 - 0x17FF
            raw_we    <= 1'b1;
            raw_waddr <= aw_a[10:2];
            raw_wdata <= w_d;
        end
    end
    if (b_v && s_axil_bready) b_v <= 1'b0;
    if (rst) begin
        aw_have <= 1'b0;
        w_have  <= 1'b0;
        b_v     <= 1'b0;
        for (int i = 0; i < NCFG; i++) cfg[i] <= cfg_default(i);
    end
end

// ---------------- counters ----------------
logic [31:0] cnt [NCNT];
logic [63:0] bc  [NBC];
always_ff @(posedge clk) begin
    for (int i = 0; i < NCNT; i++) if (ev[i]) cnt[i] <= cnt[i] + 32'd1;
    for (int i = 0; i < NBC; i++) bc[i] <= bc[i] + {48'd0, bc_add[i]};
    if (rst || stats_clr) begin
        for (int i = 0; i < NCNT; i++) cnt[i] <= '0;
        for (int i = 0; i < NBC; i++) bc[i] <= '0;
    end
end

// ---------------- read channel: AR -> bank mux -> select -> R ----------------
logic        r_busy = 1'b0, r_v = 1'b0;
logic [3:0]  r_st = '0;   // read pipeline stages
logic [15:0] ra;
logic [31:0] m_cfg, m_cfg_a, m_cfg_b, m_sv, m_cnt, m_bc, bc_hi_l;
logic [31:0] r_d;

assign s_axil_arready = !r_busy;
assign s_axil_rvalid  = r_v;
assign s_axil_rdata   = r_d;
assign s_axil_rresp   = 2'b00;

always_ff @(posedge clk) begin
    r_st <= {r_st[2:0], 1'b0};
    if (s_axil_arvalid && s_axil_arready) begin
        r_busy <= 1'b1;
        ra     <= s_axil_araddr;
        r_st   <= 4'b0001;
    end
    // stage 1: per-bank muxes
    if (r_st[0]) begin
        // 256 configuration words: two 128-word halves here, the half in stage 2
        m_cfg_a <= cfg[{1'b0, ra[8:2]}];
        m_cfg_b <= cfg[{1'b1, ra[8:2]}];
        m_sv  <= sv[ra[7:2]];
        m_cnt <= (int'(ra[8:2]) < NCNT) ? cnt[ra[8:2]] : 32'd0;
        m_bc  <= ra[2] ? bc_hi_l : bc[ra[6:3]][31:0];
        if (ra[15:10] == 6'b000011 && !ra[2]) bc_hi_l <= bc[ra[6:3]][63:32];
        cap_raddr <= (ra[15:12] == 4'h4) ? {1'b1, 2'b00, ra[10:2]} : {1'b0, ra[12:2]};
        crx_raddr <= ra[10:2];
    end
    if (r_st[1]) m_cfg <= ra[9] ? m_cfg_b : m_cfg_a;
    // stage 4: region select (capture data valid 2 clocks after cap_raddr)
    if (r_st[3]) begin
        case (ra[15:10])
            6'b000000: r_d <= m_cfg;
            6'b000001: r_d <= m_sv;
            6'b000010: r_d <= m_cnt;
            6'b000011: r_d <= m_bc;
            6'b001000, 6'b001001, 6'b001010, 6'b001011,
            6'b001100, 6'b001101, 6'b001110, 6'b001111,                       // 0x2000 - 0x3FFF
            6'b010000, 6'b010001: r_d <= cap_rdata;                          // 0x4000 - 0x47FF aux
            6'b100000, 6'b100001: r_d <= crx_rdata;                          // 0x8000 - 0x87FF receive FIFO head
            default:   r_d <= 32'hDEC0DEAD;
        endcase
        r_v <= 1'b1;
    end
    if (r_v && s_axil_rready) begin
        r_v    <= 1'b0;
        r_busy <= 1'b0;
    end
    if (rst) begin
        r_busy <= 1'b0;
        r_v    <= 1'b0;
        r_st   <= '0;
    end
end

endmodule

`resetall
