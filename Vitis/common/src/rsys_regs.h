/*
 * rsys_regs.h - system register window of rocelet_sys (qsfp28-fmc-rocelet), byte
 * offsets from the window base (rocelet_sys base + 0x10000).
 * GENERATED from Vivado/src/hdl/rsys_pkg.sv by Vivado/scripts/gen_regs_h.py - do not edit.
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 * SPDX-License-Identifier: MIT
 */
#ifndef RSYS_REGS_H_
#define RSYS_REGS_H_

#define RSYS_CFG(i)   (0x0000u + 4u * (i))
#define RSYS_SV(i)    (0x0400u + 4u * (i))
#define RSYS_CNT(i)   (0x0800u + 4u * (i))
#define RSYS_BC(i)    (0x0C00u + 8u * (i))
#define RSYS_RAW_TX   0x1000u
#define RSYS_CAP      0x2000u
#define RSYS_CAP_AUX  0x4000u

#define RSYS_NCFG               256
#define RSYS_NSV                64
#define RSYS_NCNT               56
#define RSYS_NBC                16
#define RSYS_C_CTRL             0   /* [0] self-test logic reset [1] statistics clear (pulse) */
#define RSYS_C_MAC_CTL          1   /* MAC static control (mac_ctl): [0] rx enable [1] tx enable [2] send RFI [3] send LFI [4] send idle [5] FEC (CMAC RS-FEC) [6] receive 802.3x PAUSE [7] send 802.3x PAUSE [10:8] GT loopback (0 off, 1 near-end PCS, 2 near-end PMA) */
#define RSYS_C_MAC_PZ           2   /* [15:0] PAUSE quanta sent [31:16] PAUSE refresh timer (512-bit times) */
#define RSYS_C_MAC_ADDR_LO      3   /* MAC station address (source of the MAC's PAUSE frames; omac): bytes 0-3 on the wire, byte 0 = [7:0] (reset 02:0a:35:72) */
#define RSYS_C_MAC_ADDR_HI      4   /* [15:0] bytes 4-5 (reset 6c:01) */
#define RSYS_C_DDR_BASE_LO      5   /* PS DDR window (DDR_EN builds): physical base of the region, [31:12] (4 KB aligned) */
#define RSYS_C_DDR_BASE_HI      6   /* [7:0] physical base [39:32] */
#define RSYS_C_DDR_SIZE         7   /* region size in bytes, multiple of 4 KB (reset 0 = window closed: every DDR-window access goes to the null target) */
#define RSYS_C_WG_CTRL          8   /* self-test WR generator, write: [0] start [1] stop */
#define RSYS_C_WG_QP            9   /* [7:0] first QP [15:8] number of QPs (round robin) */
#define RSYS_C_WG_OP            10   /* [3:0] opcode (0 WRITE 1 WRITE+imm 2 SEND 3 SEND+imm) [4] solicited event [5] HSB metadata */
#define RSYS_C_WG_VA_LO         11
#define RSYS_C_WG_VA_HI         12
#define RSYS_C_WG_WINDOW        13   /* bytes; the VA wraps to the base */
#define RSYS_C_WG_LEN           14   /* bytes per WR */
#define RSYS_C_WG_RKEY          15
#define RSYS_C_WG_COUNT         16   /* WRs per run, 0 = until stopped */
#define RSYS_C_WG_GAP           17   /* idle clocks between WRs */
#define RSYS_C_WG_SEED          18
#define RSYS_C_WG_IMM           19   /* immediate of the first WR (+1 per WR) */
#define RSYS_C_WC_BASE_LO       24   /* self-test write checker: window base for the gap check */
#define RSYS_C_WC_BASE_HI       25
#define RSYS_C_WC_SEED          26   /* pattern seed of the checkers and the memory pattern region */
#define RSYS_C_INJ_CTRL         32   /* TX fault injector: [1:0] action 0 off 1 drop 2 corrupt; [3:2] mode 0 once 1 periodic 2 random; write [8]=1 arms */
#define RSYS_C_INJ_CLASS        33   /* [0] request [1] ACK [2] NAK [3] READ response [4] other */
#define RSYS_C_INJ_SKIP         34
#define RSYS_C_INJ_COUNT        35   /* 0 = unlimited (periodic / random) */
#define RSYS_C_INJ_PERIOD       36
#define RSYS_C_INJ_THRESH       37   /* random: affect when lfsr32 < thresh */
#define RSYS_C_INJ_BYTE         38   /* corrupt: [5:0] byte of beat 0, [8] last beat byte 0 instead */
#define RSYS_C_RINJ_CTRL        40   /* RX fault injector (CMAC RX -> engine): as C_INJ_* */
#define RSYS_C_RINJ_CLASS       41
#define RSYS_C_RINJ_SKIP        42
#define RSYS_C_RINJ_COUNT       43
#define RSYS_C_RINJ_PERIOD      44
#define RSYS_C_RINJ_THRESH      45
#define RSYS_C_RINJ_BYTE        46
#define RSYS_C_LP_ARM           48   /* write: arm the first-event latency probe */
#define RSYS_C_RAW_LEN          52   /* raw TX frame length, bytes */
#define RSYS_C_RAW_SEND         53   /* write: send the raw frame (through the engine's other-traffic port) */
#define RSYS_C_CAP_CTRL         56   /* write [0]=1: arm; [2:1] filter 0 any 1 opcode 2 dest QPN 3 opcode+QPN; [3] TX side; [4] RX source = other-traffic port */
#define RSYS_C_CAP_MATCH        57   /* [7:0] opcode [31:8] dest QPN */
#define RSYS_C_WQ_QP            64   /* firmware work-request queue: QP index */
#define RSYS_C_WQ_OP            65   /* [3:0] opcode [4] solicited event [5] HSB metadata */
#define RSYS_C_WQ_VA_LO         66   /* remote VA */
#define RSYS_C_WQ_VA_HI         67
#define RSYS_C_WQ_RKEY          68
#define RSYS_C_WQ_LEN           69   /* bytes */
#define RSYS_C_WQ_IMM           70
#define RSYS_C_WQ_LA_LO         71   /* local address of the payload in the memory window */
#define RSYS_C_WQ_LA_HI         72
#define RSYS_C_WQ_ID            73   /* [15:0] WR id, returned in the completion */
#define RSYS_C_WQ_POST          74   /* write: queue the WR described by C_WQ_* */
#define RSYS_C_CQ_CTRL          76   /* [0] queue work completions [1] queue receive completions */
#define RSYS_C_CQ_POP           77   /* write: [0] pop the work completion [1] pop the receive completion */
#define RSYS_C_SEND_RNR         78   /* [n] = 1: QP n has no receive buffer (the engine answers SENDs with RNR NAKs) */
#define RSYS_C_CRX_CTRL         80   /* control-plane receive FIFO: [0] enable [1] take every other-traffic frame (no filter) */
#define RSYS_C_CRX_PORTS        81   /* [15:0] UDP destination port A (reset 8192) [31:16] port B (reset 12268) */
#define RSYS_C_CRX_POP          82   /* write: free the head frame */
#define RSYS_C_ODMA_CTRL        83   /* netdev DMA channel (ODMA_EN builds): [0] other-traffic frames to the PS (RX enable) */
#define RSYS_C_HP_CTRL          84   /* HSB producer: [0] run (0 -> 1 latches C_HP_* except C_HP_PERIOD; 1 -> 0 stops at a frame boundary) [2:1] source 0 IQ16 1 counter 2 beam array (3 = 0) */
#define RSYS_C_HP_QP            85   /* [7:0] QP index (type 2, UC-HSB) */
#define RSYS_C_HP_RKEY          86   /* host R_Key (DP_RKEY) */
#define RSYS_C_HP_VA_LO         87   /* VA of the first page (DP_PAGE_MSB/LSB + first page x stride) */
#define RSYS_C_HP_VA_HI         88
#define RSYS_C_HP_STRIDE        89   /* bytes from one page to the next (DP_PAGE_INC x 128) */
#define RSYS_C_HP_PAGES         90   /* [11:0] last page [27:16] first page (DP_MAX_BUFF layout) */
#define RSYS_C_HP_FRAME         91   /* frame bytes (DP_BUFFER_LENGTH) */
#define RSYS_C_HP_WRMAX         92   /* bytes per data WR, multiple of 64 (reset 16384) */
#define RSYS_C_HP_PERIOD        93   /* CMAC clocks from one frame start to the next (0 = back to back), sampled at every frame start (live) */
#define RSYS_C_HP_COUNT         94   /* frames per run, 0 = until stopped */
#define RSYS_C_IQ_CTRL          96   /* IQ16 generator, write: [0] commit the C_IQ_* configuration */
#define RSYS_C_IQ_CFG_ID        97
#define RSYS_C_IQ_TONE_INC0     98   /* 98..101: tone t phase increment (2^32 = Fs) */
#define RSYS_C_IQ_TONE_AMP01    102   /* [15:0] tone 0 [31:16] tone 1 amplitude */
#define RSYS_C_IQ_TONE_AMP23    103   /* [15:0] tone 2 [31:16] tone 3 amplitude */
#define RSYS_C_IQ_CHIRP_START   104
#define RSYS_C_IQ_CHIRP_RATE_LO 105
#define RSYS_C_IQ_CHIRP_RATE_HI 106   /* [15:0] = rate[47:32] */
#define RSYS_C_IQ_CHIRP_PER_LO  107
#define RSYS_C_IQ_CHIRP_PER_HI  108   /* [15:0] = period[47:32] */
#define RSYS_C_IQ_AMPS          109   /* [15:0] chirp amplitude [31:16] noise amplitude */
#define RSYS_C_IQ_SEED          110   /* noise seed */
#define RSYS_C_IQ_CHUNK         111   /* [17:0] beats between the points where a live re-commit may apply (reset 1024) */
#define RSYS_C_BM_S0_CTRL       128   /* source s at 128 + 8 s: [2:0] type (0 off 1 CW 2 LFM pulse 3 QPSK 4 pulsed tone) [12:8] PRI log2 [19:16] symbol log2 */
#define RSYS_C_BM_S0_AMP        129   /* [15:0] amplitude (full scale 32768) */
#define RSYS_C_BM_S0_INC        130   /* phase increment per time sample (2^32 = Fs) */
#define RSYS_C_BM_S0_RATE_LO    131   /* LFM rate r[31:0] (48-bit two's complement, 2^-16 phase units / sample^2) */
#define RSYS_C_BM_S0_RATE_HI    132   /* [15:0] = r[47:32] */
#define RSYS_C_BM_S0_WIDTH      133   /* pulse width (samples, types 2 and 4) */
#define RSYS_C_BM_S0_U          134   /* u in Q2.30 (int32) */
#define RSYS_C_BM_S0_V          135   /* v in Q2.30 (int32) */
#define RSYS_C_BM_SRC_STRIDE    8   /* words from one source's block to the next (sources 0..3) */
#define RSYS_C_BM_NOISE_AMP     160   /* [15:0] element noise amplitude */
#define RSYS_C_BM_NOISE_SEED    161   /* noise seed (also keys the QPSK symbols) */
#define RSYS_C_BM_EN_LO         162   /* bit k: element k (0..31) enabled */
#define RSYS_C_BM_EN_HI         163   /* bit k - 32: element k (32..63) enabled */
#define RSYS_C_BM_SCENE_ID      164   /* id of the scene being written */
#define RSYS_C_BM_APPLY         165   /* write: apply (snapshot of all C_BM_* words, active at the next frame boundary) */
#define RSYS_C_BM_GAIN0         192   /* 192..255: element k gain [15:0] I [31:16] Q, int16 Q2.14 */
#define RSYS_S_ID               0   /* "RSYS" */
#define RSYS_S_SYS_CFG          1   /* [0] self-test logic built in [1] pattern region [2] payload from the stream port [3] PS DDR window [4] netdev DMA channel [15:8] log2 memory window bytes [23:16] link Gb/s [31:24] MAC width / 8 */
#define RSYS_S_STATUS           2   /* [0] self-test reset [1] WR generator running [2] capture done [3] latency tracker overflow [4] TX injector armed [5] RX injector armed [6] engine irq */
#define RSYS_S_MAC_STAT         3   /* MAC (mac_stat): [0] rx aligned / block lock [1] rx status [2] local fault [3] remote fault [4] received local fault [5] internal local fault [6] hi BER [7] misaligned [8] RS-FEC hi SER [9] RS-FEC lanes aligned [10] RX in reset [11] TX in reset [12] link up [13] TX PAUSE active */
#define RSYS_S_WQ_STATUS        4   /* [8:0] queued WRs [16] queue full [17] payload pending */
#define RSYS_S_WCQ              5   /* work completion head: [31] valid [30:24] status [23:16] qp [15:0] wr_id */
#define RSYS_S_RCQ              6   /* receive completion head: [31] valid [30] SEND [29] with immediate [23:16] qp */
#define RSYS_S_RCQ_IMM          7   /* receive completion head: immediate */
#define RSYS_S_RCQ_LEN          8   /* receive completion head: message length (bytes) */
#define RSYS_S_CQ_LEVEL         9   /* [7:0] work completions queued [23:16] receive completions queued */
#define RSYS_S_WG_ISSUED        10
#define RSYS_S_INJ_LFSR         11
#define RSYS_S_CAP_STATUS       12   /* [0] done [1] tuser [16:4] length */
#define RSYS_S_WC_LAST          13   /* last work completion (any source): [30:24] status [23:16] qp [15:0] wr_id */
#define RSYS_S_RC_IMM_LAST      14   /* immediate of the last receive completion */
#define RSYS_S_WC_EXP_LO        16
#define RSYS_S_WC_EXP_HI        17
#define RSYS_S_WC_ERR_LO        18
#define RSYS_S_WC_ERR_HI        19
#define RSYS_S_SC_EXP_LO        20
#define RSYS_S_SC_EXP_HI        21
#define RSYS_S_SC_ERR_LO        22
#define RSYS_S_SC_ERR_HI        23
#define RSYS_S_LAT_MIN          24
#define RSYS_S_LAT_MAX          25
#define RSYS_S_LAT_CNT          26
#define RSYS_S_LP_FLAGS         27   /* [3:0] tx captured [7:4] rx captured [8] wr [9] cpl */
#define RSYS_S_LP_T_WR          28
#define RSYS_S_LP_T_CPL         29
#define RSYS_S_LP_TX_T0         32   /* 32..35 TX SOF times */
#define RSYS_S_LP_TX_I0         36   /* 36..39 TX info [7:0] opcode [31:8] PSN */
#define RSYS_S_LP_RX_T0         40   /* 40..43 RX SOF times */
#define RSYS_S_LP_RX_I0         44   /* 44..47 RX info */
#define RSYS_S_CRX_STATUS       48   /* control-plane receive FIFO: [7:0] frames queued [27:16] head frame length (bytes) */
#define RSYS_S_HP_STATUS        49   /* HSB producer: [0] running [1] IQ configuration pending [2] raw TX busy [3] device DNA valid */
#define RSYS_S_HP_FRAMES        50   /* frames completed in the current run */
#define RSYS_S_HP_PAGE          51   /* [11:0] current page [31:16] frame number of the next frame */
#define RSYS_S_DNA0             52   /* device DNA [31:0] */
#define RSYS_S_DNA1             53   /* device DNA [63:32] */
#define RSYS_S_DNA2             54   /* device DNA [95:64] */
#define RSYS_S_TIME_S           55   /* producer time (since reset): seconds [31:0] */
#define RSYS_S_TIME_NS          56   /* nanoseconds */
#define RSYS_S_BM_STATUS        57   /* beam array generator: [0] APPLY pending [1] running (producer with source 2) [2] clipped [15:8] model version */
#define RSYS_S_BM_APPLIED_ID    58   /* SCENE_ID of the active scene */
#define RSYS_S_BM_APPLIED_FRAME 59   /* frame index (since the run start) of the active scene's first frame */
#define RSYS_S_BM_APPLIES       60   /* scenes activated since the FPGA reset (the reset scene included) */
#define RSYS_S_BM_CAPS          61   /* 0x01440808: [31:24] model version [23:20] sources [19:16] log2 lanes [15:8] NY [7:0] NX */
#define RSYS_E_WG_ISSUED        0   /* WRs issued by the self-test generator */
#define RSYS_E_WC               1   /* work completions */
#define RSYS_E_WC_ERR           2   /* work completions with a non-zero status */
#define RSYS_E_WC_LOST          3   /* work completions with status "lost" */
#define RSYS_E_RC               4   /* receive completions (SEND, WRITE with immediate) */
#define RSYS_E_RC_SEND          5   /* receive completions of SENDs */
#define RSYS_E_RC_IMM_SEQ       6   /* receive completions whose immediate broke the +1 sequence */
#define RSYS_E_WCHK_BURSTS      7   /* memory write bursts checked */
#define RSYS_E_WC_MISM          8   /* write bursts with data != pattern(address) */
#define RSYS_E_WC_GAPS          9   /* write bursts not following the previous one */
#define RSYS_E_SC_OK            10   /* SEND packets committed */
#define RSYS_E_SC_BAD           11   /* SEND packets discarded (bad ICRC) */
#define RSYS_E_SC_MISM          12   /* committed SEND packets with data != pattern */
#define RSYS_E_SC_GAPS          13   /* committed SEND packets not following the previous one */
#define RSYS_E_INJ_SEEN         14
#define RSYS_E_INJ_DONE         15
#define RSYS_E_RINJ_SEEN        16
#define RSYS_E_RINJ_DONE        17
#define RSYS_E_RAW_SENT         18
#define RSYS_E_CAP_DONE         19
#define RSYS_E_LAT_OVF          20
#define RSYS_E_TX_UNDERRUN      21   /* clocks with tvalid low inside a frame at the CMAC TX interface */
#define RSYS_E_MAC_TX_UNF       22   /* CMAC TX underflow (tx_unfout) */
#define RSYS_E_MAC_TX_BAD_FCS   23   /* CMAC TX frames sent with a bad FCS */
#define RSYS_E_MAC_ALIGN_LOST   24   /* CMAC RX alignment lost (link down events) */
#define RSYS_E_WCQ_OVF          25   /* work completions lost (queue full) */
#define RSYS_E_RCQ_OVF          26   /* receive completions lost (queue full) */
#define RSYS_E_WQ_POSTED        27   /* WRs queued by the firmware */
#define RSYS_E_WQ_DROP          28   /* WRs posted while the queue was full (dropped) */
#define RSYS_E_MEM_WR_BURSTS    29   /* memory window: AXI write bursts */
#define RSYS_E_MEM_RD_BURSTS    30   /* memory window: AXI read bursts */
#define RSYS_E_TX_FRAMES        31   /* frames at the CMAC TX interface */
#define RSYS_E_RX_FRAMES        32   /* frames at the CMAC RX interface */
#define RSYS_E_TX_OP_REQ        33   /* RoCE requests sent (opcodes 0x00-0x0C, RC and UC) */
#define RSYS_E_TX_OP_ACK        34
#define RSYS_E_TX_OP_NAK        35   /* NAKs and RNR NAKs sent */
#define RSYS_E_TX_OP_RDRSP      36   /* READ responses sent */
#define RSYS_E_RX_OP_REQ        37   /* the same, received at the CMAC RX interface */
#define RSYS_E_RX_OP_ACK        38
#define RSYS_E_RX_OP_NAK        39
#define RSYS_E_RX_OP_RDRSP      40
#define RSYS_E_RX_ROCE          41   /* RoCE (UDP 4791) frames received */
#define RSYS_E_TX_ROCE          42   /* RoCE (UDP 4791) frames sent */
#define RSYS_E_CRX_FRAMES       43   /* control-plane receive FIFO: frames queued */
#define RSYS_E_CRX_DROP         44   /* matching frames dropped: FIFO full */
#define RSYS_E_CRX_LONG         45   /* matching frames dropped: longer than 2 KB */
#define RSYS_E_CRX_FILT         46   /* other-traffic frames that did not match the filter */
#define RSYS_E_HP_FRAMES        47   /* HSB frames produced (metadata WR sent to the engine) */
#define RSYS_E_ODMA_RX          48   /* netdev DMA channel: other-traffic frames queued for the PS */
#define RSYS_E_ODMA_DROP        49   /* netdev DMA channel: frames dropped (RX disabled, FIFO full or longer than 10240 bytes) */
#define RSYS_E_ODMA_TX          50   /* netdev DMA channel: frames from the PS sent */
#define RSYS_E_DDR_WR_BURSTS    51   /* PS DDR window: AXI write bursts */
#define RSYS_E_DDR_RD_BURSTS    52   /* PS DDR window: AXI read bursts */
#define RSYS_E_DDR_OOR          53   /* PS DDR window: bursts outside the region (writes discarded, reads return zeros) */
#define RSYS_B_CYCLES           0
#define RSYS_B_WG_BYTES         1   /* bytes of the WRs issued by the self-test generator */
#define RSYS_B_WC_BYTES         2   /* bytes written to memory (checked) */
#define RSYS_B_SC_BYTES         3   /* SEND bytes committed (checked) */
#define RSYS_B_RD_BYTES         4   /* bytes read from memory for READ responses */
#define RSYS_B_LAT_SUM          5   /* sum of the WR -> completion latencies (clocks) */
#define RSYS_B_TX_BYTES         6   /* bytes at the CMAC TX interface */
#define RSYS_B_RX_BYTES         7   /* bytes at the CMAC RX interface */
#define RSYS_B_MAC_RX_PKTS      8   /* CMAC: frames received (stat_rx_total_packets) */
#define RSYS_B_MAC_RX_BAD_FCS   9   /* CMAC: frames received with a bad FCS */
#define RSYS_B_MAC_RX_BAD_CODE  10   /* CMAC: 64b/66b code violations */
#define RSYS_B_MAC_TX_PKTS      11   /* CMAC: frames sent (stat_tx_total_packets) */
#define RSYS_B_HP_BYTES         12   /* HSB producer: frame payload bytes (64 per beat) */
#define RSYS_B_HP_IQ_STALL      13   /* HSB producer: clocks it waited for IQ16 beats */
#define RSYS_B_IQ_CLIP          14   /* IQ16 beats taken with a saturated sample */

#endif
