// SPDX-License-Identifier: MIT
//
// mrmac_rx_packer - MRMAC 100G RX client (6 x 64-bit lanes, 48 bytes/beat,
// no back-pressure) -> 512-bit AXI4-Stream with tkeep/tlast and tuser[0] =
// "bad frame" (Taxi convention), for zircon_nic's s_axis_mac_rx.
//
// qsfp28-fmc-zircon reference design (Opsero 2x QSFP28 FMC, VCK190).
// Copied unchanged into qsfp28-fmc-rocelet (Vivado/src/hdl/mac, used by mac_mrmac100g)
// from qsfp28-fmc-zircon 1.3.0 (commit 34a206c, Vivado/src/hdl/mrmac_rx_packer.v).
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// Why: the MRMAC RX client cannot be back-pressured (there is no rx tready).
// The previous RX path (mrmac_rx_axis_adapter -> AMD axis_dwidth_converter
// 48->64 B -> mrmac_rx_tuser) lost beats: the converter's upsizer drops
// S_AXIS_TREADY for a cycle when a frame ends and the next frame's first two
// beats follow without an idle cycle, and a beat offered in that cycle was lost
// (seen on the bench: a frame truncated at 48 bytes merged with the next one).
// This module accepts one MRMAC beat EVERY cycle, unconditionally.
//
// Operation (clock = the MRMAC RX client clock, 390.625 MHz):
//   stage 1  register the lanes; keep = tkeep_user[7:0] of every lane on the
//            TLAST beat (all ones otherwise: mid-frame beats are always full);
//            err = MRMAC Err (tkeep_user[8]) of the lanes holding bytes, on a
//            valid TLAST beat only
//   stage 2  n = number of valid bytes (popcount of the contiguous keep), then
//            the frame-end cases / tkeep masks for each accumulator level
//   stage 3  accumulator: holds r = 0/16/32/48 bytes of the current frame
//            (a frame's mid beats are 48 bytes, so r is always a multiple of 16
//            and the realignment is a 4:1 mux, no barrel shifter).
//              mid beat : r+48 >= 64 -> one full 512-bit beat out, r -= 16;
//                         r = 0      -> nothing out, r = 48
//              TLAST    : r+n <= 64  -> one beat out (tlast, tkeep = r+n bytes)
//                         r+n >  64  -> a full beat and a flush beat (tlast)
//            tuser[0] (bad frame) is set on the TLAST output beat only.
//   output   a FIFO_DEPTH-entry FIFO (two LUTRAM banks, so the "full + flush"
//            case can write two entries in one cycle) and an output register.
// A frame of L bytes takes ceil(L/48) input cycles and produces ceil(L/64)
// output beats, so the FIFO holds at most one extra beat when tready is always
// high (zircon_nic's MAC-side RX FIFO is drop-when-full: tready is 1 except
// while that FIFO is in reset). A longer tready-low stretch is absorbed by the
// FIFO; if it would overflow, the beats are dropped, the frame they belong to
// (and, if its TLAST beat was the one lost, the frame it merges with) is
// delivered with tuser[0] = 1 so zircon_nic drops it, and stat_ovf pulses.
// stat_stall pulses for every cycle the output is valid while tready is low.
// Both are counted into zircon_nic STATUS (RX_PACK_STALL / RX_PACK_OVF).
//
// Assumes (MRMAC 100G non-segmented client): every beat except the TLAST beat
// carries 48 bytes; the TLAST beat carries 1..48 bytes, contiguous from lane 0
// byte 0.
//
// RX timestamp (1.3.0, docs/DESIGN_SPEC.md §11): rx_ptp_tstamp is the MRMAC
// rx_ptp_tstamp_out (55 bits, units of 2^-8 ns, RX client clock). It is sampled
// on client beat RX_TS_BEAT of every frame (0 = the first beat after a TLAST
// beat, the SOF beat; -1 = the TLAST beat; N > 0 = the N-th beat, or the TLAST
// beat of a shorter frame) and delivered as m_axis_tuser[48:1] = ts[54:7]
// (units of 0.5 ns, wraps after 2^47 ns = 39 h). With RX_TS_BEAT = 0 the value is
// valid on EVERY output beat of the frame; otherwise it is guaranteed on the
// frame's last output beat only (the one zircon_nic uses). The timestamp rides
// through the same pipeline and FIFO entries as the data, so it can never be
// attached to the wrong frame, and a frame dropped anywhere downstream drops
// its timestamp with it.

`timescale 1ns / 1ps

module mrmac_rx_packer #(
    parameter FIFO_DEPTH = 16,         // output FIFO RAM entries (power of two, >= 4); holds FIFO_DEPTH - 2
    parameter integer RX_TS_BEAT = 0   // client beat of a frame that carries its rx_ptp_tstamp (0 = SOF, -1 = TLAST)
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF M_AXIS, ASSOCIATED_RESET aresetn" *)
    input  wire         aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire         aresetn,

    // From the MRMAC 100G client (loose ports; not part of an AXIS interface)
    (* X_INTERFACE_IGNORE = "true" *) input wire [63:0] rx_axis_tdata0,
    (* X_INTERFACE_IGNORE = "true" *) input wire [63:0] rx_axis_tdata1,
    (* X_INTERFACE_IGNORE = "true" *) input wire [63:0] rx_axis_tdata2,
    (* X_INTERFACE_IGNORE = "true" *) input wire [63:0] rx_axis_tdata3,
    (* X_INTERFACE_IGNORE = "true" *) input wire [63:0] rx_axis_tdata4,
    (* X_INTERFACE_IGNORE = "true" *) input wire [63:0] rx_axis_tdata5,
    (* X_INTERFACE_IGNORE = "true" *) input wire [10:0] rx_axis_tkeep_user0,
    (* X_INTERFACE_IGNORE = "true" *) input wire [10:0] rx_axis_tkeep_user1,
    (* X_INTERFACE_IGNORE = "true" *) input wire [10:0] rx_axis_tkeep_user2,
    (* X_INTERFACE_IGNORE = "true" *) input wire [10:0] rx_axis_tkeep_user3,
    (* X_INTERFACE_IGNORE = "true" *) input wire [10:0] rx_axis_tkeep_user4,
    (* X_INTERFACE_IGNORE = "true" *) input wire [10:0] rx_axis_tkeep_user5,
    (* X_INTERFACE_IGNORE = "true" *) input wire        rx_axis_tlast,
    (* X_INTERFACE_IGNORE = "true" *) input wire        rx_axis_tvalid,
    // MRMAC rx_ptp_tstamp_out (2^-8 ns units, RX client clock; tie 0 without PTP)
    (* X_INTERFACE_IGNORE = "true" *) input wire [54:0] rx_ptp_tstamp,

    // To zircon_nic s_axis_mac_rx (512 b, tuser[0] = bad frame, tuser[48:1] = RX timestamp [54:7])
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA"  *) output wire [511:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TKEEP"  *) output wire [63:0]  m_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TUSER"  *) output wire [48:0]  m_axis_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TLAST"  *) output wire         m_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID" *) output wire         m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *) input  wire         m_axis_tready,

    // status pulses (aclk domain): [0] stall (output valid, tready low),
    // [1] overflow (beats dropped, frame delivered as bad)
    output wire [1:0]   stat
);

localparam AW   = $clog2(FIFO_DEPTH);   // entry index width
localparam TW = 48;                     // timestamp bits carried (rx_ptp_tstamp[54:7])
localparam EW = TW + 512 + 64 + 2;      // {ts, user, last, keep, data}

// ---------------------------------------------------------------------------
// stage 1: register the client ports
// ---------------------------------------------------------------------------
wire [7:0]  lk [0:5];
wire        le [0:5];
assign lk[0] = rx_axis_tkeep_user0[7:0]; assign le[0] = rx_axis_tkeep_user0[8];
assign lk[1] = rx_axis_tkeep_user1[7:0]; assign le[1] = rx_axis_tkeep_user1[8];
assign lk[2] = rx_axis_tkeep_user2[7:0]; assign le[2] = rx_axis_tkeep_user2[8];
assign lk[3] = rx_axis_tkeep_user3[7:0]; assign le[3] = rx_axis_tkeep_user3[8];
assign lk[4] = rx_axis_tkeep_user4[7:0]; assign le[4] = rx_axis_tkeep_user4[8];
assign lk[5] = rx_axis_tkeep_user5[7:0]; assign le[5] = rx_axis_tkeep_user5[8];

wire in_err = (|lk[0] & le[0]) | (|lk[1] & le[1]) | (|lk[2] & le[2]) |
              (|lk[3] & le[3]) | (|lk[4] & le[4]) | (|lk[5] & le[5]);

reg [383:0] s1_data = 384'd0;
reg [47:0]  s1_keep = 48'd0;
reg         s1_last = 1'b0;
reg         s1_err  = 1'b0;
reg         s1_valid = 1'b0;
reg [TW-1:0] s1_ts  = {TW{1'b0}};   // rx_ptp_tstamp[54:7] of this beat, registered (no logic before it)

always @(posedge aclk) begin
    s1_ts    <= rx_ptp_tstamp[54:55-TW];
    s1_data  <= {rx_axis_tdata5, rx_axis_tdata4, rx_axis_tdata3,
                 rx_axis_tdata2, rx_axis_tdata1, rx_axis_tdata0};
    s1_keep  <= rx_axis_tlast ? {lk[5], lk[4], lk[3], lk[2], lk[1], lk[0]} : {48{1'b1}};
    s1_last  <= rx_axis_tlast;
    s1_err   <= rx_axis_tvalid & rx_axis_tlast & in_err;
    s1_valid <= rx_axis_tvalid;
    if (!aresetn) s1_valid <= 1'b0;
end

// timestamp capture on the registered beat: beat index within the frame and the
// held value of the frame
reg [15:0]   in_beat = 16'd0;
reg [TW-1:0] fr_ts   = {TW{1'b0}};
wire         ts_take = s1_valid &&
                       ((RX_TS_BEAT < 0) ? s1_last :
                        (in_beat == RX_TS_BEAT[15:0]) || (s1_last && in_beat < RX_TS_BEAT[15:0]));
wire [TW-1:0] ts_cur = ts_take ? s1_ts : fr_ts;

always @(posedge aclk) begin
    if (s1_valid) begin
        in_beat <= s1_last ? 16'd0 : ((in_beat == 16'hFFFF) ? in_beat : in_beat + 16'd1);
    end
    if (ts_take) begin
        fr_ts <= s1_ts;
    end
    if (!aresetn) in_beat <= 16'd0;
end

// ---------------------------------------------------------------------------
// stage 2: byte count of the beat, and (to keep adders out of stage 3) the
// frame-end cases and tkeep masks precomputed for each accumulator level q
// (r = 16q bytes held): total = 16q + n
// ---------------------------------------------------------------------------
function [63:0] keep_mask(input [6:0] n);   // lowest n (0..64) bits set
    begin
        keep_mask = (n >= 7'd64) ? {64{1'b1}} : ~({64{1'b1}} << n);
    end
endfunction

function [5:0] popcount48(input [47:0] k);
    integer i;
    begin
        popcount48 = 6'd0;
        for (i = 0; i < 48; i = i + 1) popcount48 = popcount48 + {5'd0, k[i]};
    end
endfunction

// stage 2a: popcount
reg [383:0] s2a_data = 384'd0;
reg         s2a_last = 1'b0;
reg         s2a_err  = 1'b0;
reg         s2a_valid = 1'b0;
reg [5:0]   s2a_n = 6'd0;
reg [TW-1:0] s2a_ts = {TW{1'b0}};

always @(posedge aclk) begin
    s2a_ts    <= ts_cur;
    s2a_data  <= s1_data;
    s2a_last  <= s1_last;
    s2a_err   <= s1_err;
    s2a_valid <= s1_valid;
    s2a_n     <= popcount48(s1_keep);
    if (!aresetn) s2a_valid <= 1'b0;
end

// stage 2b: frame-end cases and masks per accumulator level
reg [383:0] s2_data = 384'd0;
reg         s2_last = 1'b0;
reg         s2_err  = 1'b0;
reg         s2_valid = 1'b0;
reg [3:0]   s2_one = 4'd0;          // [q]: 16q + n <= 64 (one output beat)
reg [63:0]  s2_m1 [0:3];            // [q]: keep of the single / flush beat: 16q + n bytes
reg [63:0]  s2_m2 [2:3];            // [q]: keep of the flush beat: 16q + n - 64 bytes
reg [TW-1:0] s2_ts = {TW{1'b0}};

integer qi;
always @(posedge aclk) begin
    s2_ts    <= s2a_ts;
    s2_data  <= s2a_data;
    s2_last  <= s2a_last;
    s2_err   <= s2a_err;
    s2_valid <= s2a_valid;
    for (qi = 0; qi < 4; qi = qi + 1) begin
        s2_one[qi] <= ({1'b0, s2a_n} + qi * 16) <= 64;
        s2_m1[qi]  <= keep_mask({1'b0, s2a_n} + qi * 16);
    end
    s2_m2[2] <= keep_mask({1'b0, s2a_n} + 7'd32 - 7'd64);
    s2_m2[3] <= keep_mask({1'b0, s2a_n} + 7'd48 - 7'd64);
    if (!aresetn) s2_valid <= 1'b0;
end

// ---------------------------------------------------------------------------
// stage 3: accumulator
// ---------------------------------------------------------------------------

reg [383:0] acc = 384'd0;       // r = 16*q bytes of the current frame, from byte 0
reg [1:0]   q = 2'd0;
reg         corrupt = 1'b0;     // beats of the current frame were dropped

// window = accumulated bytes followed by the new beat (at most 96 bytes)
reg [767:0] win;
always @* begin
    case (q)
        2'd0: win = {384'd0, s2_data};
        2'd1: win = {256'd0, s2_data, acc[127:0]};
        2'd2: win = {128'd0, s2_data, acc[255:0]};
        default: win = {s2_data, acc[383:0]};
    endcase
end

wire        one_beat = s2_one[q];                        // TLAST: 16q + n <= 64
wire [63:0] keep1    = s2_m1[q];
wire [63:0] keep2    = q[0] ? s2_m2[3] : s2_m2[2];         // only used for q = 2, 3

// up to two output beats per input beat
reg          push0, push1;
reg [EW-1:0] out0, out1;
always @* begin
    push0 = 1'b0;
    push1 = 1'b0;
    out0  = {s2_ts, 2'b00, {64{1'b1}}, win[511:0]};
    out1  = {s2_ts, 1'b0, 1'b1, keep2, 256'd0, win[767:512]};
    if (s2_valid) begin
        if (!s2_last) begin
            push0 = (q != 2'd0);                                   // r + 48 >= 64
        end else if (one_beat) begin
            push0 = 1'b1;
            out0  = {s2_ts, 1'b0, 1'b1, keep1, win[511:0]};        // tlast
        end else begin
            push0 = 1'b1;                                          // full beat
            push1 = 1'b1;                                          // flush, tlast
        end
    end
end

// ---------------------------------------------------------------------------
// output FIFO: two LUTRAM banks (entry i in bank i[0]), up to two writes/cycle.
// It holds at most FIFO_DEPTH - 2 entries, so the slots at wr_ptr and wr_ptr + 1
// are always free: the RAM is written whenever a beat is produced (the write
// enables do not wait for the space check) and only the pointer update depends
// on whether the entries fit.
// ---------------------------------------------------------------------------
(* ram_style = "distributed" *) reg [EW-1:0] mem0 [0:FIFO_DEPTH/2-1];
(* ram_style = "distributed" *) reg [EW-1:0] mem1 [0:FIFO_DEPTH/2-1];

reg [AW:0] wr_ptr = {(AW+1){1'b0}};
reg [AW:0] rd_ptr = {(AW+1){1'b0}};

wire [AW:0] wr_ptr1 = wr_ptr + 1'b1;
wire [AW:0] used    = wr_ptr - rd_ptr;
wire [1:0]  n_push  = {1'b0, push0} + {1'b0, push1};
wire        fits    = ({1'b0, used} + {{AW{1'b0}}, n_push}) <= (FIFO_DEPTH - 2);
wire        wr      = (push0 || push1) && fits;
wire        ovf     = (push0 || push1) && !fits;

// the frame-end entry carries the bad-frame flag (MRMAC error or dropped beats;
// an entry written in an overflow cycle is never committed)
wire        bad_now = s2_err || corrupt;
localparam UB = 577;                    // entry bit: tuser[0] (bad frame); 576 = tlast
wire [EW-1:0] w0 = push1 ? out0 : {out0[EW-1:UB+1], out0[UB] | (out0[UB-1] & bad_now), out0[UB-1:0]};
wire [EW-1:0] w1 = {out1[EW-1:UB+1], bad_now, out1[UB-1:0]};

// bank write ports
wire         b0_we0 = push0 && (wr_ptr[0]  == 1'b0);
wire         b0_we1 = push1 && (wr_ptr1[0] == 1'b0);
wire         b1_we0 = push0 && (wr_ptr[0]  == 1'b1);
wire         b1_we1 = push1 && (wr_ptr1[0] == 1'b1);

always @(posedge aclk) begin
    if (b0_we0 || b0_we1) mem0[b0_we0 ? wr_ptr[AW-1:1] : wr_ptr1[AW-1:1]] <= b0_we0 ? w0 : w1;
    if (b1_we0 || b1_we1) mem1[b1_we0 ? wr_ptr[AW-1:1] : wr_ptr1[AW-1:1]] <= b1_we0 ? w0 : w1;
end

// output register
reg [EW-1:0] m_reg = {EW{1'b0}};
reg          m_valid = 1'b0;

wire         fifo_empty = (wr_ptr == rd_ptr);
wire         load = !fifo_empty && (!m_valid || m_axis_tready);
wire [EW-1:0] rd_data = rd_ptr[0] ? mem1[rd_ptr[AW-1:1]] : mem0[rd_ptr[AW-1:1]];

reg stall_reg = 1'b0;
reg ovf_reg = 1'b0;

always @(posedge aclk) begin
    // accumulator
    if (s2_valid) begin
        if (!s2_last) begin
            case (q)
                2'd0: begin acc <= s2_data;                        q <= 2'd3; end
                2'd1: begin                                        q <= 2'd0; end
                2'd2: begin acc[127:0] <= win[639:512];            q <= 2'd1; end
                default: begin acc[255:0] <= win[767:512];         q <= 2'd2; end
            endcase
        end else begin
            q <= 2'd0;
        end
    end

    // dropped-beat tracking: set on overflow, cleared once a frame end is stored
    if (ovf) begin
        corrupt <= 1'b1;
    end else if (wr && s2_last) begin
        corrupt <= 1'b0;
    end

    if (wr) wr_ptr <= wr_ptr + {{(AW-1){1'b0}}, n_push};

    if (load) begin
        m_reg   <= rd_data;
        m_valid <= 1'b1;
        rd_ptr  <= rd_ptr + 1'b1;
    end else if (m_axis_tready) begin
        m_valid <= 1'b0;
    end

    stall_reg <= m_valid && !m_axis_tready;
    ovf_reg   <= ovf;

    if (!aresetn) begin
        q         <= 2'd0;
        corrupt   <= 1'b0;
        wr_ptr    <= {(AW+1){1'b0}};
        rd_ptr    <= {(AW+1){1'b0}};
        m_valid   <= 1'b0;
        stall_reg <= 1'b0;
        ovf_reg   <= 1'b0;
    end
end

assign m_axis_tdata  = m_reg[511:0];
assign m_axis_tkeep  = m_reg[575:512];
assign m_axis_tlast  = m_reg[576];
assign m_axis_tuser  = {m_reg[EW-1:UB+1], m_reg[UB]};
assign m_axis_tvalid = m_valid;
assign stat          = {ovf_reg, stall_reg};

endmodule
