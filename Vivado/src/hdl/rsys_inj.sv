// SPDX-License-Identifier: MIT
//
// rsys_inj - frame error injector on the engine's TX stream (self-test fault injector).
// Classifies each frame on its first beat (IPv4 RoCE v2: request, ACK, NAK/RNR
// NAK, READ response; anything else = other) and, for frames of the selected
// classes, drops the whole frame or corrupts one byte (the ICRC then fails at
// the receiver):
//   mode 0 once:     skip SKIP matching frames after arming, affect the next COUNT
//   mode 1 periodic: affect every PERIOD-th matching frame (COUNT = 0: forever)
//   mode 2 random:   affect a matching frame when a 32-bit LFSR < THRESH
// Corrupt: XOR 0x01 into byte BYTE[5:0] of the first beat (default 53 = BTH PSN
// low byte), or (BYTE[8]) into byte 0 of the last beat (payload / ICRC).
// Frames with an 802.1Q tag (the engine's 'vlan tx' option, or a tagged host) are
// classified from the fields 4 bytes later, and BYTE[5:0] (< 60) refers to the
// untagged layout as well, so the same settings work with and without tags.
// One register stage plus an output register; no bubbles in pass-through.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsys_inj (
    input  wire logic          clk,
    input  wire logic          rst,

    input  wire logic [1:0]    cfg_action,     // 0 off, 1 drop, 2 corrupt
    input  wire logic [1:0]    cfg_mode,
    input  wire logic [4:0]    cfg_class,
    input  wire logic [31:0]   cfg_skip,
    input  wire logic [31:0]   cfg_count,
    input  wire logic [31:0]   cfg_period,
    input  wire logic [31:0]   cfg_thresh,
    input  wire logic [8:0]    cfg_byte,
    input  wire logic          arm,

    input  wire logic [511:0]  s_axis_tdata,
    input  wire logic [63:0]   s_axis_tkeep,
    input  wire logic          s_axis_tvalid,
    output wire logic          s_axis_tready,
    input  wire logic          s_axis_tlast,
    input  wire logic          s_axis_tuser,     // passed through (CMAC RX: bad frame)

    output wire logic [511:0]  m_axis_tdata,
    output wire logic [63:0]   m_axis_tkeep,
    output wire logic          m_axis_tvalid,
    input  wire logic          m_axis_tready,
    output wire logic          m_axis_tlast,
    output wire logic          m_axis_tuser,

    output logic               ev_seen,
    output logic               ev_done,
    output wire logic          armed,
    output wire logic [31:0]   lfsr_o
);

function automatic logic [7:0] B(input logic [511:0] d, input int i);
    return d[i*8 +: 8];
endfunction

// stage A (registered input)
logic         a_v = 1'b0, a_l, a_u, a_first;
logic [511:0] a_d;
logic [63:0]  a_k;
// stage B (output)
logic         o_v = 1'b0, o_l, o_u;
logic [511:0] o_d;
logic [63:0]  o_k;

logic         first_in = 1'b1;    // next input beat starts a frame
logic         arm_q = 1'b0;
logic [31:0]  seen, done, per;
logic [31:0]  lfsr = 32'hACE1_2468;
logic         f_drop, f_corr;     // decision for the frame in stage A

// Frame class {other, READ response, NAK, ACK, request} and 802.1Q tag of a beat, decoded when
// the beat enters stage A and registered with it (a_cls, a_tag): the decode stays out of the
// drop / corrupt decision cone (the counter compares feeding the output enables).
// An 802.1Q tag moves the fields 4 bytes.
function automatic logic [7:0] T(input logic [511:0] d, input logic t, input int i);
    return t ? d[(i+4)*8 +: 8] : d[i*8 +: 8];
endfunction
function automatic logic is_tag(input logic [511:0] d);
    return (B(d, 12) == 8'h81) && (B(d, 13) == 8'h00);
endfunction
function automatic logic [4:0] fr_cls(input logic [511:0] d);
    logic t, roce, c_req, c_rdrsp, c_ack, c_nak;
    logic [7:0] op, syn;
    t       = is_tag(d);
    op      = T(d, t, 42);
    syn     = T(d, t, 54);
    roce    = ({T(d, t, 12), T(d, t, 13)} == 16'h0800) && (T(d, t, 23) == 8'd17) &&
              ({T(d, t, 36), T(d, t, 37)} == 16'd4791);
    c_req   = roce && (op[7:6] == 2'b00) && (op[4:0] <= 5'h0C);
    c_rdrsp = roce && (op[7:5] == 3'b000) && (op[4:0] >= 5'h0D) && (op[4:0] <= 5'h10);
    c_ack   = roce && (op == 8'h11) && (syn[7:5] == 3'b000);
    c_nak   = roce && (op == 8'h11) && (syn[7:5] != 3'b000);
    return {!(c_req || c_rdrsp || c_ack || c_nak), c_rdrsp, c_nak, c_ack, c_req};
endfunction
logic [4:0] a_cls;
logic       a_tag;
// corrupted byte of the first beat, in the frame's own layout
wire logic [5:0] cbyte = cfg_byte[5:0] + ((a_tag && cfg_byte[5:0] < 6'd60) ? 6'd4 : 6'd0);
wire logic match   = |(cfg_class & a_cls);
wire logic left_ok = (cfg_count == 0 && cfg_mode != 2'd0) || (done < cfg_count);
logic sel;
always_comb begin
    case (cfg_mode)
        2'd0:    sel = (seen >= cfg_skip);
        2'd1:    sel = (per + 32'd1 >= cfg_period);
        default: sel = (lfsr < cfg_thresh);
    endcase
    sel = sel && match && left_ok && arm_q && (cfg_action != 2'd0);
end
wire logic drop_a = a_first ? (sel && cfg_action == 2'd1) : f_drop;
wire logic corr_a = a_first ? (sel && cfg_action == 2'd2) : f_corr;

// a dropped beat still takes the output slot's turn: the drop / corrupt
// decision (class decode, 32-bit compares) never reaches tready
wire logic o_slot = !o_v || m_axis_tready;
wire logic take_a = a_v && o_slot;
assign s_axis_tready = !a_v || take_a;

assign armed  = arm_q;
assign lfsr_o = lfsr;

always_ff @(posedge clk) begin
    ev_seen <= 1'b0;
    ev_done <= 1'b0;
    if (m_axis_tready) o_v <= 1'b0;
    if (take_a) begin
        a_v <= 1'b0;
        if (a_first) begin
            f_drop <= drop_a;
            f_corr <= corr_a;
            if (match && arm_q) begin
                ev_seen <= 1'b1;
                seen    <= seen + 32'd1;
                per     <= (cfg_mode == 2'd1 && sel) ? 32'd0 : per + 32'd1;
                lfsr    <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
                if (sel) begin
                    ev_done <= 1'b1;
                    done    <= done + 32'd1;
                end
            end
        end
        if (!drop_a) begin
            logic [511:0] d;
            d = a_d;
            if (corr_a && !cfg_byte[8] && a_first) d[cbyte*8] = ~d[cbyte*8];
            if (corr_a && cfg_byte[8] && a_l) d[0] = ~d[0];
            o_v <= 1'b1;
            o_d <= d;
            o_k <= a_k;
            o_l <= a_l;
            o_u <= a_u;
        end
    end
    if (s_axis_tvalid && s_axis_tready) begin
        a_v      <= 1'b1;
        a_d      <= s_axis_tdata;
        a_cls    <= fr_cls(s_axis_tdata);
        a_tag    <= is_tag(s_axis_tdata);
        a_k      <= s_axis_tkeep;
        a_l      <= s_axis_tlast;
        a_u      <= s_axis_tuser;
        a_first  <= first_in;
        first_in <= s_axis_tlast;
    end
    if (arm) begin
        arm_q <= 1'b1;
        seen  <= '0;
        done  <= '0;
        per   <= '0;
    end
    if (rst) begin
        a_v      <= 1'b0;
        o_v      <= 1'b0;
        first_in <= 1'b1;
        arm_q    <= 1'b0;
        seen     <= '0;
        done     <= '0;
        per      <= '0;
    end
end

assign m_axis_tdata  = o_d;
assign m_axis_tkeep  = o_k;
assign m_axis_tvalid = o_v;
assign m_axis_tlast  = o_l;
assign m_axis_tuser  = o_u;

endmodule

`resetall
