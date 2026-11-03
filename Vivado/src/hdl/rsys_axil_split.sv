// SPDX-License-Identifier: MIT
//
// rsys_axil_split - AXI4-Lite 1-to-3 address decoder of rocelet_sys's register
// port (one transaction per direction at a time; the MicroBlaze issues one):
//   0x00000-0x0FFFF  M0: the rocelet engine's register map
//   0x10000-0x1FFFF  M1: the system registers (rsys_regs)
//   0x40000-0x7FFFF  M2: the memory window (rsys_axi_mem firmware port)
// Anything else answers DECERR (writes ignored, reads 0xDEC0DEAD).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_axil_split #(
    parameter int AW = 19
) (
    input  wire logic          clk,
    input  wire logic          rst,

    input  wire logic [AW-1:0] s_awaddr,
    input  wire logic          s_awvalid,
    output wire logic          s_awready,
    input  wire logic [31:0]   s_wdata,
    input  wire logic [3:0]    s_wstrb,
    input  wire logic          s_wvalid,
    output wire logic          s_wready,
    output logic      [1:0]    s_bresp,
    output logic               s_bvalid,
    input  wire logic          s_bready,
    input  wire logic [AW-1:0] s_araddr,
    input  wire logic          s_arvalid,
    output wire logic          s_arready,
    output logic      [31:0]   s_rdata,
    output logic      [1:0]    s_rresp,
    output logic               s_rvalid,
    input  wire logic          s_rready,

    // masters: index 0, 1, 2 (shared address/data, per-master valid/ready)
    output logic      [AW-1:0] m_awaddr,
    output logic      [2:0]    m_awvalid,
    input  wire logic [2:0]    m_awready,
    output logic      [31:0]   m_wdata,
    output logic      [3:0]    m_wstrb,
    output logic      [2:0]    m_wvalid,
    input  wire logic [2:0]    m_wready,
    input  wire logic [1:0]    m_bresp [3],
    input  wire logic [2:0]    m_bvalid,
    output logic      [2:0]    m_bready,
    output logic      [AW-1:0] m_araddr,
    output logic      [2:0]    m_arvalid,
    input  wire logic [2:0]    m_arready,
    input  wire logic [31:0]   m_rdata [3],
    input  wire logic [1:0]    m_rresp [3],
    input  wire logic [2:0]    m_rvalid,
    output logic      [2:0]    m_rready
);

function automatic logic [2:0] decode(input logic [AW-1:0] a);
    case (a[AW-1:16])
        0:       return 3'b001;
        1:       return 3'b010;
        4, 5, 6, 7: return 3'b100;
        default: return 3'b000;
    endcase
endfunction

// ---------------- write ----------------
logic       aw_have = 1'b0, w_have = 1'b0, w_busy = 1'b0;
logic [2:0] w_sel;
assign s_awready = !aw_have && !w_busy;
assign s_wready  = !w_have && !w_busy;

always_ff @(posedge clk) begin
    if (s_awvalid && s_awready) begin
        aw_have  <= 1'b1;
        m_awaddr <= s_awaddr;
        w_sel    <= decode(s_awaddr);
    end
    if (s_wvalid && s_wready) begin
        w_have  <= 1'b1;
        m_wdata <= s_wdata;
        m_wstrb <= s_wstrb;
    end
    // both halves in: start the transaction
    if (aw_have && w_have && !w_busy) begin
        w_busy    <= 1'b1;
        m_awvalid <= w_sel;
        m_wvalid  <= w_sel;
        m_bready  <= w_sel;
        if (w_sel == 3'b000) begin       // DECERR
            s_bvalid <= 1'b1;
            s_bresp  <= 2'b11;
        end
    end
    for (int i = 0; i < 3; i++) begin
        if (m_awvalid[i] && m_awready[i]) m_awvalid[i] <= 1'b0;
        if (m_wvalid[i] && m_wready[i])   m_wvalid[i]  <= 1'b0;
        if (m_bready[i] && m_bvalid[i]) begin
            m_bready[i] <= 1'b0;
            s_bvalid    <= 1'b1;
            s_bresp     <= m_bresp[i];
        end
    end
    if (s_bvalid && s_bready) begin
        s_bvalid <= 1'b0;
        aw_have  <= 1'b0;
        w_have   <= 1'b0;
        w_busy   <= 1'b0;
    end
    if (rst) begin
        aw_have   <= 1'b0;
        w_have    <= 1'b0;
        w_busy    <= 1'b0;
        m_awvalid <= '0;
        m_wvalid  <= '0;
        m_bready  <= '0;
        s_bvalid  <= 1'b0;
    end
end

// ---------------- read ----------------
logic r_busy = 1'b0;
assign s_arready = !r_busy;

always_ff @(posedge clk) begin
    if (s_arvalid && s_arready) begin
        logic [2:0] sel;
        sel = decode(s_araddr);
        r_busy    <= 1'b1;
        m_araddr  <= s_araddr;
        m_arvalid <= sel;
        m_rready  <= sel;
        if (sel == 3'b000) begin
            s_rvalid <= 1'b1;
            s_rdata  <= 32'hDEC0DEAD;
            s_rresp  <= 2'b11;
        end
    end
    for (int i = 0; i < 3; i++) begin
        if (m_arvalid[i] && m_arready[i]) m_arvalid[i] <= 1'b0;
        if (m_rready[i] && m_rvalid[i]) begin
            m_rready[i] <= 1'b0;
            s_rvalid    <= 1'b1;
            s_rdata     <= m_rdata[i];
            s_rresp     <= m_rresp[i];
        end
    end
    if (s_rvalid && s_rready) begin
        s_rvalid <= 1'b0;
        r_busy   <= 1'b0;
    end
    if (rst) begin
        r_busy    <= 1'b0;
        m_arvalid <= '0;
        m_rready  <= '0;
        s_rvalid  <= 1'b0;
    end
end

endmodule

`resetall
