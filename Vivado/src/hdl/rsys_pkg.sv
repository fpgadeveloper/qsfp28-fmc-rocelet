// SPDX-License-Identifier: MIT
//
// rsys_pkg - constants shared by the qsfp28-fmc-rocelet reference design: the
// self-test payload pattern and the layout of the system register window
// (rsys_regs). The firmware header Vitis/common/src/rsys_regs.h is GENERATED
// from this file (Vivado/scripts/gen_regs_h.py): add registers here, then
// regenerate it.
//
// Payload pattern: every 64-byte beat of test payload is a function of its
// (64-byte aligned) address A and a 32-bit seed S:
//   beat[63:0]        = A                      (self-describing: a SEND checker
//                                               recovers the address from the data)
//   beat[64i +: 64]   = (A ^ {S, ~S}) + K[i]   i = 1..7
// The WR generator writes pattern(remote VA), the requester's MM2S source and the
// responder's memory return pattern(local address), and the checkers compare the
// committed data with pattern(local address). With identity MRs (VA == local
// address) the three agree, so every byte that lands is checked.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

package rsys_pkg;

localparam logic [63:0] PAT_K [8] = '{
    64'h0000000000000000, 64'h9E3779B97F4A7C15, 64'h3C6EF372FE94F82A, 64'hDAA66D2C7DDF743F,
    64'h78DDE6E5FD29F054, 64'h1715609F7C746C69, 64'hB54CDA58FBBEE87E, 64'h538454127B096493
};

function automatic logic [511:0] pat_beat(input logic [63:0] a, input logic [31:0] seed);
    logic [63:0] x;
    x = a ^ {seed, ~seed};
    pat_beat[63:0] = a;
    for (int i = 1; i < 8; i++) pat_beat[i*64 +: 64] = x + PAT_K[i];
endfunction

// byte-masked compare: 1 = mismatch in a kept byte
function automatic logic beat_mismatch(input logic [511:0] d, input logic [511:0] e,
                                       input logic [63:0] keep);
    logic m;
    m = 1'b0;
    for (int j = 0; j < 64; j++) if (keep[j] && (d[j*8 +: 8] != e[j*8 +: 8])) m = 1'b1;
    return m;
endfunction

function automatic logic [6:0] popcnt64(input logic [63:0] k);
    logic [6:0] n;
    n = '0;
    for (int j = 0; j < 64; j++) n = n + 7'(k[j]);
    return n;
endfunction

// ---------------- register banks (byte offsets in the 64 KB system window) ----------------
// The system window sits at +0x10000 of rocelet_sys's AXI-Lite port (the rocelet
// engine's own register map is at +0x00000, the memory window at +0x40000).
// 0x0000 + 4*i : cfg[i]   read/write configuration, NCFG words (write pulse per word);
//                         cfg[128..255] (0x0200-0x03FF) = the beam array generator (C_BM_*)
// 0x0400 + 4*i : sv[i]    read-only status values, NSV words
// 0x0800 + 4*i : cnt[i]   32-bit event counters, NCNT (cleared by CTRL.STATS_CLR)
// 0x0C00 + 8*i : bc[i]    64-bit accumulators, NBC (lo at +0 latches hi at +4)
// 0x1000-0x17FF: raw TX frame buffer (write-only, 32 x 64 B)
// 0x2000-0x3FFF: capture buffer (read-only, 128 x 64 B)
// 0x4000-0x47FF: capture aux window, 16 B per beat: keep lo, keep hi, {last, idle clocks}
// 0x8000-0x87FF: control-plane receive FIFO, the head frame (read-only, 32 x 64 B)
localparam int NCFG = 256;
localparam int NSV  = 64;
localparam int NCNT = 56;
localparam int NBC  = 16;

// cfg indices
localparam int C_CTRL        = 0;   // [0] self-test logic reset [1] statistics clear (pulse)
localparam int C_MAC_CTL     = 1;   // MAC static control (mac_ctl): [0] rx enable [1] tx enable [2] send RFI [3] send LFI [4] send idle [5] FEC (CMAC RS-FEC) [6] receive 802.3x PAUSE [7] send 802.3x PAUSE [10:8] GT loopback (0 off, 1 near-end PCS, 2 near-end PMA)
localparam int C_MAC_PZ      = 2;   // [15:0] PAUSE quanta sent [31:16] PAUSE refresh timer (512-bit times)
localparam int C_MAC_ADDR_LO = 3;   // MAC station address (source of the MAC's PAUSE frames; omac): bytes 0-3 on the wire, byte 0 = [7:0] (reset 02:0a:35:72)
localparam int C_MAC_ADDR_HI = 4;   // [15:0] bytes 4-5 (reset 6c:01)
localparam int C_DDR_BASE_LO = 5;   // PS DDR window (DDR_EN builds): physical base of the region, [31:12] (4 KB aligned)
localparam int C_DDR_BASE_HI = 6;   // [7:0] physical base [39:32]
localparam int C_DDR_SIZE    = 7;   // region size in bytes, multiple of 4 KB (reset 0 = window closed: every DDR-window access goes to the null target)
localparam int C_WG_CTRL     = 8;   // self-test WR generator, write: [0] start [1] stop
localparam int C_WG_QP       = 9;   // [7:0] first QP [15:8] number of QPs (round robin)
localparam int C_WG_OP       = 10;  // [3:0] opcode (0 WRITE 1 WRITE+imm 2 SEND 3 SEND+imm) [4] solicited event [5] HSB metadata
localparam int C_WG_VA_LO    = 11;
localparam int C_WG_VA_HI    = 12;
localparam int C_WG_WINDOW   = 13;  // bytes; the VA wraps to the base
localparam int C_WG_LEN      = 14;  // bytes per WR
localparam int C_WG_RKEY     = 15;
localparam int C_WG_COUNT    = 16;  // WRs per run, 0 = until stopped
localparam int C_WG_GAP      = 17;  // idle clocks between WRs
localparam int C_WG_SEED     = 18;
localparam int C_WG_IMM      = 19;  // immediate of the first WR (+1 per WR)
localparam int C_WC_BASE_LO  = 24;  // self-test write checker: window base for the gap check
localparam int C_WC_BASE_HI  = 25;
localparam int C_WC_SEED     = 26;  // pattern seed of the checkers and the memory pattern region
localparam int C_INJ_CTRL    = 32;  // TX fault injector: [1:0] action 0 off 1 drop 2 corrupt; [3:2] mode 0 once 1 periodic 2 random; write [8]=1 arms
localparam int C_INJ_CLASS   = 33;  // [0] request [1] ACK [2] NAK [3] READ response [4] other
localparam int C_INJ_SKIP    = 34;
localparam int C_INJ_COUNT   = 35;  // 0 = unlimited (periodic / random)
localparam int C_INJ_PERIOD  = 36;
localparam int C_INJ_THRESH  = 37;  // random: affect when lfsr32 < thresh
localparam int C_INJ_BYTE    = 38;  // corrupt: [5:0] byte of beat 0, [8] last beat byte 0 instead
localparam int C_RINJ_CTRL   = 40;  // RX fault injector (CMAC RX -> engine): as C_INJ_*
localparam int C_RINJ_CLASS  = 41;
localparam int C_RINJ_SKIP   = 42;
localparam int C_RINJ_COUNT  = 43;
localparam int C_RINJ_PERIOD = 44;
localparam int C_RINJ_THRESH = 45;
localparam int C_RINJ_BYTE   = 46;
localparam int C_LP_ARM      = 48;  // write: arm the first-event latency probe
localparam int C_RAW_LEN     = 52;  // raw TX frame length, bytes
localparam int C_RAW_SEND    = 53;  // write: send the raw frame (through the engine's other-traffic port)
localparam int C_CAP_CTRL    = 56;  // write [0]=1: arm; [2:1] filter 0 any 1 opcode 2 dest QPN 3 opcode+QPN; [3] TX side; [4] RX source = other-traffic port
localparam int C_CAP_MATCH   = 57;  // [7:0] opcode [31:8] dest QPN
localparam int C_WQ_QP       = 64;  // firmware work-request queue: QP index
localparam int C_WQ_OP       = 65;  // [3:0] opcode [4] solicited event [5] HSB metadata
localparam int C_WQ_VA_LO    = 66;  // remote VA
localparam int C_WQ_VA_HI    = 67;
localparam int C_WQ_RKEY     = 68;
localparam int C_WQ_LEN      = 69;  // bytes
localparam int C_WQ_IMM      = 70;
localparam int C_WQ_LA_LO    = 71;  // local address of the payload in the memory window
localparam int C_WQ_LA_HI    = 72;
localparam int C_WQ_ID       = 73;  // [15:0] WR id, returned in the completion
localparam int C_WQ_POST     = 74;  // write: queue the WR described by C_WQ_*
localparam int C_CQ_CTRL     = 76;  // [0] queue work completions [1] queue receive completions
localparam int C_CQ_POP      = 77;  // write: [0] pop the work completion [1] pop the receive completion
localparam int C_SEND_RNR    = 78;  // [n] = 1: QP n has no receive buffer (the engine answers SENDs with RNR NAKs)
localparam int C_CRX_CTRL    = 80;  // control-plane receive FIFO: [0] enable [1] take every other-traffic frame (no filter)
localparam int C_CRX_PORTS   = 81;  // [15:0] UDP destination port A (reset 8192) [31:16] port B (reset 12268)
localparam int C_CRX_POP     = 82;  // write: free the head frame
localparam int C_ODMA_CTRL   = 83;  // netdev DMA channel (ODMA_EN builds): [0] other-traffic frames to the PS (RX enable)
localparam int C_HP_CTRL     = 84;  // HSB producer: [0] run (0 -> 1 latches C_HP_* except C_HP_PERIOD; 1 -> 0 stops at a frame boundary) [2:1] source 0 IQ16 1 counter 2 beam array (3 = 0)
localparam int C_HP_QP       = 85;  // [7:0] QP index (type 2, UC-HSB)
localparam int C_HP_RKEY     = 86;  // host R_Key (DP_RKEY)
localparam int C_HP_VA_LO    = 87;  // VA of the first page (DP_PAGE_MSB/LSB + first page x stride)
localparam int C_HP_VA_HI    = 88;
localparam int C_HP_STRIDE   = 89;  // bytes from one page to the next (DP_PAGE_INC x 128)
localparam int C_HP_PAGES    = 90;  // [11:0] last page [27:16] first page (DP_MAX_BUFF layout)
localparam int C_HP_FRAME    = 91;  // frame bytes (DP_BUFFER_LENGTH)
localparam int C_HP_WRMAX    = 92;  // bytes per data WR, multiple of 64 (reset 16384)
localparam int C_HP_PERIOD   = 93;  // CMAC clocks from one frame start to the next (0 = back to back), sampled at every frame start (live)
localparam int C_HP_COUNT    = 94;  // frames per run, 0 = until stopped
localparam int C_IQ_CTRL     = 96;  // IQ16 generator, write: [0] commit the C_IQ_* configuration
localparam int C_IQ_CFG_ID   = 97;
localparam int C_IQ_TONE_INC0 = 98; // 98..101: tone t phase increment (2^32 = Fs)
localparam int C_IQ_TONE_AMP01 = 102; // [15:0] tone 0 [31:16] tone 1 amplitude
localparam int C_IQ_TONE_AMP23 = 103; // [15:0] tone 2 [31:16] tone 3 amplitude
localparam int C_IQ_CHIRP_START = 104;
localparam int C_IQ_CHIRP_RATE_LO = 105;
localparam int C_IQ_CHIRP_RATE_HI = 106; // [15:0] = rate[47:32]
localparam int C_IQ_CHIRP_PER_LO = 107;
localparam int C_IQ_CHIRP_PER_HI = 108;  // [15:0] = period[47:32]
localparam int C_IQ_AMPS     = 109; // [15:0] chirp amplitude [31:16] noise amplitude
localparam int C_IQ_SEED     = 110; // noise seed
localparam int C_IQ_CHUNK    = 111; // [17:0] beats between the points where a live re-commit may apply (reset 1024)
// beam array generator (docs/source/beam_contract.md section 4; Opsero 0x7F000100 + 4 (i - 128)):
// shadow registers, copied into the staged scene by a write to C_BM_APPLY
localparam int C_BM_S0_CTRL  = 128; // source s at 128 + 8 s: [2:0] type (0 off 1 CW 2 LFM pulse 3 QPSK 4 pulsed tone) [12:8] PRI log2 [19:16] symbol log2
localparam int C_BM_S0_AMP   = 129; // [15:0] amplitude (full scale 32768)
localparam int C_BM_S0_INC   = 130; // phase increment per time sample (2^32 = Fs)
localparam int C_BM_S0_RATE_LO = 131; // LFM rate r[31:0] (48-bit two's complement, 2^-16 phase units / sample^2)
localparam int C_BM_S0_RATE_HI = 132; // [15:0] = r[47:32]
localparam int C_BM_S0_WIDTH = 133; // pulse width (samples, types 2 and 4)
localparam int C_BM_S0_U     = 134; // u in Q2.30 (int32)
localparam int C_BM_S0_V     = 135; // v in Q2.30 (int32)
localparam int C_BM_SRC_STRIDE = 8; // words from one source's block to the next (sources 0..3)
localparam int C_BM_NOISE_AMP = 160; // [15:0] element noise amplitude
localparam int C_BM_NOISE_SEED = 161; // noise seed (also keys the QPSK symbols)
localparam int C_BM_EN_LO    = 162; // bit k: element k (0..31) enabled
localparam int C_BM_EN_HI    = 163; // bit k - 32: element k (32..63) enabled
localparam int C_BM_SCENE_ID = 164; // id of the scene being written
localparam int C_BM_APPLY    = 165; // write: apply (snapshot of all C_BM_* words, active at the next frame boundary)
localparam int C_BM_GAIN0    = 192; // 192..255: element k gain [15:0] I [31:16] Q, int16 Q2.14

// status values
localparam int S_ID          = 0;   // "RSYS"
localparam int S_SYS_CFG     = 1;   // [0] self-test logic built in [1] pattern region [2] payload from the stream port [3] PS DDR window [4] netdev DMA channel [15:8] log2 memory window bytes [23:16] link Gb/s [31:24] MAC width / 8
localparam int S_STATUS      = 2;   // [0] self-test reset [1] WR generator running [2] capture done [3] latency tracker overflow [4] TX injector armed [5] RX injector armed [6] engine irq
localparam int S_MAC_STAT    = 3;   // MAC (mac_stat): [0] rx aligned / block lock [1] rx status [2] local fault [3] remote fault [4] received local fault [5] internal local fault [6] hi BER [7] misaligned [8] RS-FEC hi SER [9] RS-FEC lanes aligned [10] RX in reset [11] TX in reset [12] link up [13] TX PAUSE active
localparam int S_WQ_STATUS   = 4;   // [8:0] queued WRs [16] queue full [17] payload pending
localparam int S_WCQ         = 5;   // work completion head: [31] valid [30:24] status [23:16] qp [15:0] wr_id
localparam int S_RCQ         = 6;   // receive completion head: [31] valid [30] SEND [29] with immediate [23:16] qp
localparam int S_RCQ_IMM     = 7;   // receive completion head: immediate
localparam int S_RCQ_LEN     = 8;   // receive completion head: message length (bytes)
localparam int S_CQ_LEVEL    = 9;   // [7:0] work completions queued [23:16] receive completions queued
localparam int S_WG_ISSUED   = 10;
localparam int S_INJ_LFSR    = 11;
localparam int S_CAP_STATUS  = 12;  // [0] done [1] tuser [16:4] length
localparam int S_WC_LAST     = 13;  // last work completion (any source): [30:24] status [23:16] qp [15:0] wr_id
localparam int S_RC_IMM_LAST = 14;  // immediate of the last receive completion
localparam int S_WC_EXP_LO   = 16;
localparam int S_WC_EXP_HI   = 17;
localparam int S_WC_ERR_LO   = 18;
localparam int S_WC_ERR_HI   = 19;
localparam int S_SC_EXP_LO   = 20;
localparam int S_SC_EXP_HI   = 21;
localparam int S_SC_ERR_LO   = 22;
localparam int S_SC_ERR_HI   = 23;
localparam int S_LAT_MIN     = 24;
localparam int S_LAT_MAX     = 25;
localparam int S_LAT_CNT     = 26;
localparam int S_LP_FLAGS    = 27;  // [3:0] tx captured [7:4] rx captured [8] wr [9] cpl
localparam int S_LP_T_WR     = 28;
localparam int S_LP_T_CPL    = 29;
localparam int S_LP_TX_T0    = 32;  // 32..35 TX SOF times
localparam int S_LP_TX_I0    = 36;  // 36..39 TX info [7:0] opcode [31:8] PSN
localparam int S_LP_RX_T0    = 40;  // 40..43 RX SOF times
localparam int S_LP_RX_I0    = 44;  // 44..47 RX info
localparam int S_CRX_STATUS  = 48;  // control-plane receive FIFO: [7:0] frames queued [27:16] head frame length (bytes)
localparam int S_HP_STATUS   = 49;  // HSB producer: [0] running [1] IQ configuration pending [2] raw TX busy [3] device DNA valid
localparam int S_HP_FRAMES   = 50;  // frames completed in the current run
localparam int S_HP_PAGE     = 51;  // [11:0] current page [31:16] frame number of the next frame
localparam int S_DNA0        = 52;  // device DNA [31:0]
localparam int S_DNA1        = 53;  // device DNA [63:32]
localparam int S_DNA2        = 54;  // device DNA [95:64]
localparam int S_TIME_S      = 55;  // producer time (since reset): seconds [31:0]
localparam int S_TIME_NS     = 56;  // nanoseconds
localparam int S_BM_STATUS   = 57;  // beam array generator: [0] APPLY pending [1] running (producer with source 2) [2] clipped [15:8] model version
localparam int S_BM_APPLIED_ID = 58; // SCENE_ID of the active scene
localparam int S_BM_APPLIED_FRAME = 59; // frame index (since the run start) of the active scene's first frame
localparam int S_BM_APPLIES  = 60;  // scenes activated since the FPGA reset (the reset scene included)
localparam int S_BM_CAPS     = 61;  // 0x01440808: [31:24] model version [23:20] sources [19:16] log2 lanes [15:8] NY [7:0] NX

// event counters
localparam int E_WG_ISSUED      = 0;   // WRs issued by the self-test generator
localparam int E_WC             = 1;   // work completions
localparam int E_WC_ERR         = 2;   // work completions with a non-zero status
localparam int E_WC_LOST        = 3;   // work completions with status "lost"
localparam int E_RC             = 4;   // receive completions (SEND, WRITE with immediate)
localparam int E_RC_SEND        = 5;   // receive completions of SENDs
localparam int E_RC_IMM_SEQ     = 6;   // receive completions whose immediate broke the +1 sequence
localparam int E_WCHK_BURSTS    = 7;   // memory write bursts checked
localparam int E_WC_MISM        = 8;   // write bursts with data != pattern(address)
localparam int E_WC_GAPS        = 9;   // write bursts not following the previous one
localparam int E_SC_OK          = 10;  // SEND packets committed
localparam int E_SC_BAD         = 11;  // SEND packets discarded (bad ICRC)
localparam int E_SC_MISM        = 12;  // committed SEND packets with data != pattern
localparam int E_SC_GAPS        = 13;  // committed SEND packets not following the previous one
localparam int E_INJ_SEEN       = 14;
localparam int E_INJ_DONE       = 15;
localparam int E_RINJ_SEEN      = 16;
localparam int E_RINJ_DONE      = 17;
localparam int E_RAW_SENT       = 18;
localparam int E_CAP_DONE       = 19;
localparam int E_LAT_OVF        = 20;
localparam int E_TX_UNDERRUN    = 21;  // clocks with tvalid low inside a frame at the CMAC TX interface
localparam int E_MAC_TX_UNF     = 22;  // CMAC TX underflow (tx_unfout)
localparam int E_MAC_TX_BAD_FCS = 23;  // CMAC TX frames sent with a bad FCS
localparam int E_MAC_ALIGN_LOST = 24;  // CMAC RX alignment lost (link down events)
localparam int E_WCQ_OVF        = 25;  // work completions lost (queue full)
localparam int E_RCQ_OVF        = 26;  // receive completions lost (queue full)
localparam int E_WQ_POSTED      = 27;  // WRs queued by the firmware
localparam int E_WQ_DROP        = 28;  // WRs posted while the queue was full (dropped)
localparam int E_MEM_WR_BURSTS  = 29;  // memory window: AXI write bursts
localparam int E_MEM_RD_BURSTS  = 30;  // memory window: AXI read bursts
localparam int E_TX_FRAMES      = 31;  // frames at the CMAC TX interface
localparam int E_RX_FRAMES      = 32;  // frames at the CMAC RX interface
localparam int E_TX_OP_REQ      = 33;  // RoCE requests sent (opcodes 0x00-0x0C, RC and UC)
localparam int E_TX_OP_ACK      = 34;
localparam int E_TX_OP_NAK      = 35;  // NAKs and RNR NAKs sent
localparam int E_TX_OP_RDRSP    = 36;  // READ responses sent
localparam int E_RX_OP_REQ      = 37;  // the same, received at the CMAC RX interface
localparam int E_RX_OP_ACK      = 38;
localparam int E_RX_OP_NAK      = 39;
localparam int E_RX_OP_RDRSP    = 40;
localparam int E_RX_ROCE        = 41;  // RoCE (UDP 4791) frames received
localparam int E_TX_ROCE        = 42;  // RoCE (UDP 4791) frames sent
localparam int E_CRX_FRAMES     = 43;  // control-plane receive FIFO: frames queued
localparam int E_CRX_DROP       = 44;  // matching frames dropped: FIFO full
localparam int E_CRX_LONG       = 45;  // matching frames dropped: longer than 2 KB
localparam int E_CRX_FILT       = 46;  // other-traffic frames that did not match the filter
localparam int E_HP_FRAMES      = 47;  // HSB frames produced (metadata WR sent to the engine)
localparam int E_ODMA_RX        = 48;  // netdev DMA channel: other-traffic frames queued for the PS
localparam int E_ODMA_DROP      = 49;  // netdev DMA channel: frames dropped (RX disabled, FIFO full or longer than 10240 bytes)
localparam int E_ODMA_TX        = 50;  // netdev DMA channel: frames from the PS sent
localparam int E_DDR_WR_BURSTS  = 51;  // PS DDR window: AXI write bursts
localparam int E_DDR_RD_BURSTS  = 52;  // PS DDR window: AXI read bursts
localparam int E_DDR_OOR        = 53;  // PS DDR window: bursts outside the region (writes discarded, reads return zeros)

// 64-bit accumulators
localparam int B_CYCLES          = 0;
localparam int B_WG_BYTES        = 1;   // bytes of the WRs issued by the self-test generator
localparam int B_WC_BYTES        = 2;   // bytes written to memory (checked)
localparam int B_SC_BYTES        = 3;   // SEND bytes committed (checked)
localparam int B_RD_BYTES        = 4;   // bytes read from memory for READ responses
localparam int B_LAT_SUM         = 5;   // sum of the WR -> completion latencies (clocks)
localparam int B_TX_BYTES        = 6;   // bytes at the CMAC TX interface
localparam int B_RX_BYTES        = 7;   // bytes at the CMAC RX interface
localparam int B_MAC_RX_PKTS     = 8;   // CMAC: frames received (stat_rx_total_packets)
localparam int B_MAC_RX_BAD_FCS  = 9;   // CMAC: frames received with a bad FCS
localparam int B_MAC_RX_BAD_CODE = 10;  // CMAC: 64b/66b code violations
localparam int B_MAC_TX_PKTS     = 11;  // CMAC: frames sent (stat_tx_total_packets)
localparam int B_HP_BYTES        = 12;  // HSB producer: frame payload bytes (64 per beat)
localparam int B_HP_IQ_STALL     = 13;  // HSB producer: clocks it waited for IQ16 beats
localparam int B_IQ_CLIP         = 14;  // IQ16 beats taken with a saturated sample

// reset values of the beam array generator words cfg[128..255] (contract section 4: one CW
// emitter at boresight, A 8000, Fs / 16, noise 128, all elements on, gains 1)
localparam logic [31:0] BM_CAPS = 32'h01440808;
localparam logic [7:0]  BM_MODEL_VERSION = 8'd1;
function automatic logic [31:0] bm_default(input int i);
    if (i >= C_BM_GAIN0 && i < C_BM_GAIN0 + 64) return 32'h00004000;
    case (i)
        C_BM_S0_CTRL:    return 32'h00000001;
        C_BM_S0_AMP:     return 32'd8000;
        C_BM_S0_INC:     return 32'h10000000;
        C_BM_NOISE_AMP:  return 32'd128;
        C_BM_NOISE_SEED: return 32'h5EED0000;
        C_BM_EN_LO:      return 32'hFFFFFFFF;
        C_BM_EN_HI:      return 32'hFFFFFFFF;
        default:         return 32'd0;
    endcase
endfunction

endpackage

`resetall
