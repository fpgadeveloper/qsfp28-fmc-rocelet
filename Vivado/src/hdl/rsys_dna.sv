// SPDX-License-Identifier: MIT
//
// rsys_dna - reads the FPGA's 96-bit device DNA (DNA_PORTE2) once after reset, in the
// 200 MHz generator clock (DNA_PORTE2 is specified up to 200 MHz), and hands it to the CMAC
// user clock: the value is held in gen_clk registers and captured in clk by the qsc_*
// registers (a quasi-static crossing: it never changes after 'valid' rises, whose crossing
// uses xpm_cdc_single; kcu116.xdc sets a false path to the qsc_* register inputs).
// The firmware derives the board's Holoscan Sensor Bridge serial number from it.
// Bit order: dna[0] is the first bit DNA_PORTE2 shifts out.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_dna #(
    parameter logic [95:0] SIM_DNA = 96'h0123_4567_89AB_CDEF_0F1E_2D3C
) (
    input  wire logic         gen_clk,
    input  wire logic         g_rst,       // gen_clk synchronous
    input  wire logic         clk,
    output logic [95:0]       dna,         // clk domain
    output wire logic         valid        // clk domain
);

logic        rd = 1'b0, sh = 1'b0, done = 1'b0;
logic [6:0]  n = '0;
logic [95:0] v = '0;
wire  logic  dout;

DNA_PORTE2 #(.SIM_DNA_VALUE(SIM_DNA)) u_dna (
    .CLK(gen_clk), .DIN(1'b0), .READ(rd), .SHIFT(sh), .DOUT(dout)
);

// READ for one clock (loads the shift register), then 96 x SHIFT, sampling DOUT before each shift
always_ff @(posedge gen_clk) begin
    rd <= 1'b0;
    if (!done && !rd && !sh && n == 0) begin
        rd <= 1'b1;
    end else if (rd) begin
        sh <= 1'b1;
    end else if (sh) begin
        v <= {dout, v[95:1]};
        n <= n + 7'd1;
        if (n == 7'd95) begin
            sh   <= 1'b0;
            done <= 1'b1;
        end
    end
    if (g_rst) begin
        rd   <= 1'b0;
        sh   <= 1'b0;
        done <= 1'b0;
        n    <= '0;
    end
end

xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1)) u_vsync (
    .src_clk(gen_clk), .src_in(done), .dest_clk(clk), .dest_out(valid)
);

logic [95:0] qsc_dna = '0;
always_ff @(posedge clk) qsc_dna <= v;
assign dna = qsc_dna;

endmodule

`resetall
