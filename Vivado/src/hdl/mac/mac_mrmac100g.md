# mac_mrmac100g — developer note (not customer documentation)

The VCK190 (`vck190_fmcp1`) MAC adapter: Versal hard MRMAC, 1x100GE CAUI-4, "independent"
non-segmented 384-bit client (`ctl_axis_cfg` 3'b101, MODE_REG CTL_AXIS_CFG = 5), behind
rocelet_sys's generic MAC boundary at 512 bits. The MRMAC and the gt_quad_base are block-design
cells; this module is the glue between them and owns every clock crossing. The architecture
is described in the header of `mac_mrmac100g.v`.

Files (build.tcl, mac "mrmac"): `mac_mrmac100g.v` (top + `mrmac_ev_cdc`), `mrmac_rx_packer.v`
(copied unchanged from qsfp28-fmc-zircon 1.3.0, MIT, Opsero). XPM only: `xpm_fifo_async`,
`xpm_fifo_axis`, `xpm_cdc_*`. No AMD soft IP.

## Parameters

| name | default | meaning |
|---|---|---|
| `RX_FIFO_DEPTH` | 512 | engine-side RX FIFO, 512-bit entries (9 BRAM36) |
| `TX_FIFO_DEPTH` | 512 | TX packet FIFO (store-and-forward), 512-bit entries = 32 KB; must hold >= 2 of the largest frames |
| `FIFO_MEM` | "block" | xpm memory type of both FIFOs |
| `PAD_MIN` | 60 | TX frames shorter than this (bytes, without FCS) are zero-padded |

## Ports

Clocks: `clk` = engine clock (rocelet_sys `clk`), `axis_clk` = MRMAC `tx_axi_clk` = `rx_axi_clk`
(>= 390.625 MHz, free-running), `ctl_clk` = MRMAC `s_axi_aclk` (pl0 100 MHz). All three
asynchronous to each other.

| port | dir | width | clock | connects to |
|---|---|---|---|---|
| `gt_reset`, `mac_reset` | in | 1 | any | `rsys_aon` |
| `tx_tdata/tkeep/tvalid/tready/tlast/tuser` (`S_AXIS_TX`) | | 512/64/1/1/1/1 | clk | rocelet_sys `M_AXIS_TX` |
| `rx_tdata/tkeep/tvalid/tlast/tuser` (`M_AXIS_RX`, no tready) | out | 512/64/1/1/1 | clk | rocelet_sys `S_AXIS_RX` |
| `mac_ctl`, `mac_pz`, `mac_addr` | in | 32/32/48 | clk | rocelet_sys (`mac_pz`, `mac_addr` unused: MRMAC registers) |
| `mac_stat`, `mac_ev`, `mac_pause` | out | 16/16/18 | clk | rocelet_sys (`mac_stat` also rsys_aon) |
| `mac_lane`, `mac_lev` | out | 32/6 | clk | rsys_aon |
| `gt_powergood`, `gt_tx_ready`, `gt_rx_ready` | out | 1 | async | rsys_aon |
| `gtpowergood_in` | in | 1 | async | gt_quad_base `gtpowergood` |
| `ch0_loopback` .. `ch3_loopback` | out | 3 | static | gt_quad_base `chN_loopback` |
| `gt_reset_all_in` | out | 4 | async | MRMAC `gt_reset_all_in` |
| `gt_tx_reset_done_out`, `gt_rx_reset_done_out` | in | 4 | async | MRMAC |
| `tx_core_reset`, `rx_core_reset`, `tx_serdes_reset`, `rx_serdes_reset` | out | 4 | async | MRMAC |
| `rx_axis_tdata0..5`, `rx_axis_tkeep_user0..5`, `rx_axis_tvalid_0`, `rx_axis_tlast_0` | in | 64/11/1/1 | axis_clk | MRMAC |
| `tx_axis_tdata0..5`, `tx_axis_tkeep_user0..5`, `tx_axis_tvalid_0`, `tx_axis_tlast_0` | out | 64/11/1/1 | axis_clk | MRMAC |
| `tx_axis_tready_0` | in | 1 | axis_clk | MRMAC |
| `ctl_tx_pause_req_0`, `ctl_tx_pause_enable_0` | out | 9 | axis_clk (tx_axi_clk) | MRMAC |
| `ctl_rx_pause_enable_0`, `ctl_rx_pause_ack_0` | out | 9 | axis_clk (rx_axi_clk) | MRMAC |
| `ctl_tx_resend_pause_0` (0), `ctl_tx_send_rfi_in_0`, `ctl_tx_send_lfi_in_0`, `ctl_tx_send_idle_in_0` | out | 1 | async | MRMAC |
| `stat_rx_aligned_0`, `stat_rx_status_0`, `stat_rx_local_fault_0`, `stat_rx_remote_fault_0`, `stat_rx_received_local_fault_0`, `stat_rx_internal_local_fault_0`, `stat_rx_hi_ber_0`, `stat_rx_misaligned_0`, `stat_rx_fec_hi_ser_0`, `stat_rx_fec_aligned_0` | in | 1 | s_axi_aclk | MRMAC |
| `stat_rx_fec_lane_lock_0` [3:0], `stat_rx_fec_mapping_0` [1:0], `stat_rx_block_lock_0` [19:0] | in | | s_axi_aclk | MRMAC |
| `stat_rx_bad_fcs_0`, `stat_rx_bad_code_0`, `stat_tx_bad_fcs_0` (events), `stat_tx_axis_unf_0` (level) | in | 1 | s_axi_aclk | MRMAC |
| `stat_rx_fec_corrected_cw_0_0..3`, `stat_rx_fec_uncorrected_cw_0_0..3` | in | 1 | rx_axi_clk | MRMAC |
| `stat_rx_pause_req_0`, `stat_rx_pause_valid_0` [8:0], `stat_rx_pause_quanta8_0` [15:0] | in | | rx_axi_clk | MRMAC |
| `stat_tx_pause_valid_0` [8:0] | in | | tx_axi_clk | MRMAC |

The MRMAC-side ports carry the MRMAC pin names, so bd_versal.tcl connects them by name (and
`chN_loopback` / `gtpowergood_in` to the gt_quad_base / the existing gtpowergood net).

## Bundle mapping (rocelet_sys.sv header semantics)

- `mac_ctl`: [2]/[3]/[4] `ctl_tx_send_rfi/lfi/idle_in_0`; [6] `ctl_rx_pause_enable_0[8]` and
  `ctl_rx_pause_ack_0[8]` (as mac_cmac_adapt); [7] `ctl_tx_pause_enable_0[8]`; [16]
  `ctl_tx_pause_req_0[8]`; [10:8] all four `chN_loopback`. [0]/[1]/[5] are MRMAC registers.
- `mac_stat` = the mac_cmac_adapt map: [0] aligned [1] status [2] LF [3] RF [4] received LF
  [5] internal LF [6] hi BER [7] misaligned [8] FEC hi SER [9] FEC aligned [10] RX in reset
  (adapter RX path, incl. the RX FIFO read-side reset) [11] TX in reset [12] link = aligned &
  ~LF & ~RF [13] engine PAUSE request & TX PAUSE enabled.
- `mac_ev`: [2:0] RX frames delivered to the engine [5:3] RX bad FCS [8:6] RX bad code [9] TX
  frames accepted from the engine [10] TX bad FCS [11] TX underflow (rising edge) [12]/[13] FEC
  corrected / uncorrected codewords (sum of the four `_0_x` pulses) [14] PAUSE received (rising
  edge of `stat_rx_pause_valid_0[8]`) [15] PAUSE sent (rising edge of `stat_tx_pause_valid_0[8]`).
- `mac_pause` = {`stat_rx_pause_req_0[8]` (2-FF), one-clk pulse per received PAUSE, its quanta}.
- `mac_lane` (LANE_STAT, MAC code 4): [3:0] FEC lane lock per physical lane [5:4] FEC mapping
  [6] FEC aligned [27:8] PCS lane block lock 0-19 [31] 1. `mac_lev[5]` = RX frame lost in the
  adapter (AON RX_OVF); other bits 0.

## Behaviour

- RX never back-pressures the MRMAC. A frame whose first beat finds < 2 free FIFO entries is
  dropped whole; a frame that already started and reaches the last free entry is cut there
  and flagged `tuser` = 1 (the engine drops it), the remainder discarded. One `mac_lev[5]` per
  frame lost. Unreachable at clk >= 300 MHz (packer worst case 281 M beats/s, 65-byte frames).
- TX: frames swallowed whole while the MRMAC TX is in reset (no engine stall, no fragment
  after the reset); packet FIFO (frame complete before read) -> 64 -> 48 B downsizer -> skid,
  so `tx_axis_tvalid_0` never drops inside a frame and no MRMAC `tready` path is combinational
  into the FIFO. Padding to `PAD_MIN`; `tx_tuser` -> `tkeep_user[8]` on the lanes of the last beat.

## Block design / constraints (M1-B)

- `MRMAC_IS_GT_WIZ_OLD 1` (the GT reset handshake runs through the MRMAC: `gt_reset_all_in`,
  `gt_*_reset_done_out`). Leave `gt_reset_tx/rx_datapath_in` at 0, `rx_flexif_reset` as the
  precedents, tie the other unused MRMAC inputs to 0.
- **GT loopback**: gt_quad_base has `ch0_loopback[2:0]` .. `ch3_loopback[2:0]` (members of
  its `CH0_DEBUG`..`CH3_DEBUG` `gt_channel_debug` interfaces; present with the default
  configuration, checked in Vivado 2025.2 by instantiating `gt_quad_base` on
  xcvc1902-vsva2197-2MP-e-S). GTYE5 encoding as UltraScale+: 000 normal, 001 near-end PCS,
  010 near-end PMA, 100 far-end PMA, 110 far-end PCS. The pins are asynchronous: constrain
  `set_false_path -from [get_cells -hier -filter {NAME =~ *mac0*loop_r_reg*}]`. The firmware's
  existing flow (write mac_ctl, then the reset pulse via rsys_aon `gt_reset`) re-initialises
  the GT with the loopback applied. No MRMAC register or port does loopback.
- XPM CDC macros constrain themselves; `set_clock_groups -asynchronous` between clk_eng,
  axis_clk and clk_sys is compatible (the gray-pointer `set_bus_skew` still applies).

## Firmware (MRMAC s_axi, port-0 page; zircon `mrmac.c` sequence + PAUSE)

1. `RESET_REG_0` 0x004: assert RX_SERDES_RESET[3:0], TX_SERDES_RESET, RX_RESET, TX_RESET (0x7F).
2. `MODE_REG_0` 0x008: CTL_DATA_RATE [2:0] = 4 (100G), CTL_SERDES_WIDTH [6:4] = 6 (100G wide),
   CTL_AXIS_CFG [11:9] = 5 (100G independent 384), TICK_REG_MODE_SEL [30] = 1.
3. `FEC_CONFIGURATION_REG1_0` 0x0D0: 0x1008 = RS(528,514) CL91 (CTL_FEC_MODE 8 +
   CTL_TX_FEC_FOUR_LANE_PMD [12]); 0x0 = FEC off (mac_ctl[5]). A change needs a port reset (PG314).
4. `CONFIGURATION_RX_MTU_0` 0x014: CTL_RX_MAX_PACKET_LEN [30:16] >= 9600, MIN [7:0] = 64.
5. Release the resets; `CONFIGURATION_TX_REG1_0` 0x00C = 0xC03 (enable, FCS insert, IPG 12),
   `CONFIGURATION_RX_REG1_0` 0x010 = 0x33 (enable, FCS delete, SFD / preamble check):
   mac_ctl[1] / [0] = CTL_TX_ENABLE / CTL_RX_ENABLE.
6. PAUSE (CMAC had these as IP parameters / ports; reset values unverified, write them):
   `CONFIGURATION_TX_FLOW_CONTROL_QUANTA_REG5_0` 0x070 CTL_TX_PAUSE_QUANTA8 = mac_pz[15:0];
   `..._REFRESH_REG5_0` 0x05C CTL_TX_PAUSE_REFRESH_TIMER8 = mac_pz[31:16];
   `..._GPP_SA_REG_0_LSB/MSB` 0x084/0x088 = station MAC; `..._GPP_DA_REG_0_LSB/MSB` 0x07C/0x080 =
   01:80:C2:00:00:01; `..._GPP_ETYPE_OP_REG_0` 0x078 = 0x0001_8808;
   `CONFIGURATION_RX_FLOW_CONTROL_REG1_0` 0x09C CTL_RX_ENABLE_GCP [0] = 1 (CTL_RX_CHECK_ACK [4]);
   `..._REG2_0` 0x0A0 GCP checks [4:0]; `..._GCP_PCP_TYPE_REG_0` 0x0AC CTL_RX_ETYPE_GCP = 0x8808;
   `..._GCP_OP_REG_0` 0x0B4 opcode min/max = 1; `..._DA_REG2_0` (MCAST) 0x0C0/0x0C4 =
   01:80:C2:00:00:01; `..._DA_REG1_0` (UCAST) 0x0B8/0x0BC = station MAC.
7. `TICK_REG_0` 0x02C = 1; status `STAT_RX_STATUS_REG1_0` 0x744 (latched) / 0x74C (live),
   `STAT_RX_FEC_STATUS` 0x784 / 0x788, `STAT_RX_BLOCK_LOCK` 0x754.
8. CAPS MAC code 4 = MRMAC.

## Simulation

`Vivado/src/hdl/tb/run_xsim_mrmac.sh` (xsim 2025.2; `SEED=<n>` for another random seed;
build dir `tb/build_mrmac/`, gitignored). `tb_mrmac100g.sv` checks every frame bit-exact in
order against an MRMAC client model: control / status / PAUSE / event pass-through, random
60-9000 B both ways at line rate, RX idle cycles + garbage keep on non-last beats + MRMAC Err,
TX tready stalls, mac_reset mid-traffic (frames vanish whole, never merge), RX overflow at a
200 / 150 MHz engine clock (whole-frame drops and cut + flagged frames, accounting =
mac_lev[5]), 250 MHz engine clock. Prints `SIM PASS` / `SIM FAIL`.

## OOC synthesis (2025.2, xcvc1902-vsva2197-2MP-e-S, 2026-11-05)

`synth_design -mode out_of_context`, clk 3.333 ns, axis_clk 2.560 ns, ctl_clk 10 ns
(asynchronous groups): 5332 LUT (664 LUTRAM, the packer's output FIFO), 6180 FF, 16 BRAM tiles
(RX FIFO 8.5, TX FIFO 7.5), no DSP / URAM. WNS axis_clk +0.278 ns, clk +1.555 ns, ctl_clk
+8.05 ns; report_cdc: 168 endpoints, all safe. The worst path is TX: skid `os_v` -> downsizer
accept -> TX FIFO read enable (BRAM REGCE), 4 LUT levels. If it fails after placement, put a
register slice between the TX FIFO and the downsizer.
