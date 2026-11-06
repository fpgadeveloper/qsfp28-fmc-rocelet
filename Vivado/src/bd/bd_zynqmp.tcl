################################################################
# Block design: rocelet RoCE v2 reference design, Zynq UltraScale+ targets (ZCU106 + OP120)
#
# Sourced by scripts/build.tcl, which sets: block_name, target, port (QSFP28 port of the
# OP120), fec, selftest, mac_type (data.json "mac"), eng_params (rocelet_sys_bd
# parameters from config/data.json, incl. MAC_WIDTH / CLK_* / LINK_GBPS / DDR_EN / ODMA_EN)
# and ch_of_lane (the omac_40g lane map from data.json gt_channels).
# Register map, address map, interrupts and the DMA frame convention:
# docs/source/zynqmp_hw.md. Architecture (PS-centric, RFSoC-portable):
#
#   zynq_ultra_ps_e (board preset: GEM3 RJ45, SD, UART0, ...)
#     pl_clk0 100 MHz  AXI-Lite control plane (M_AXI_HPM0_LPD, 0x8000_0000), always-on
#                      block, AXI IIC, GT free-running clock
#     pl_clk1 250 MHz  PS DDR side: the DDR window's S_AXI ports (DDR_PORTS 1: HP0 write, HP1
#                      read; DDR_PORTS 2, address-interleaved by rsys_axi_ilv: HP0 + HPC0 write,
#                      HP1 + HP3 read), S_AXI_HP2 (AXI DMA of the netdev channel), the DMA and
#                      its stream width converters
#     pl_clk2 200 MHz  rocelet_sys gen_clk (IQ16 / beam generators, device DNA)
#     pl_ps_irq0[4:0]  always-on block (aggregated), DMA MM2S, DMA S2MM, IIC clk, IIC qsfp0
#   mac0 (module reference, data.json "mac"; omac_10g: mac_omac10g = omac_10g + one GTH
#     channel of OP120 port 0 lane 0; omac_40g: mac_omac40g = omac_40g + four GTH channels,
#     QSFP lanes 0-3, with the 40G lane status into the always-on block): the swappable MAC
#     block with rocelet_sys's generic MAC boundary; its clk_out (GT TXUSRCLK2, 156.25 MHz)
#     clocks rocelet_sys
#   rsys_aon_0: always-on registers (GT / MAC reset, QSFP lines, link status, interrupt
#     aggregation, build id) + the clock guard in front of rocelet_sys (1 MB window)
#   rocelet_sys_0: engine + URAM window + PS DDR window masters + netdev DMA channel
#     (+ self-test logic), all on the MAC clock
#   axi_iic_clk (Si5328 on the FMC, programmed by software: 156.25 MHz), axi_iic_qsfp0
################################################################

create_bd_design $block_name
current_bd_design $block_name

proc const_cell {name width val} {
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 $name
  set_property -dict [list CONFIG.CONST_WIDTH $width CONFIG.CONST_VAL $val] [get_bd_cells $name]
  return [get_bd_pins $name/dout]
}

set ddr_en  [expr {[dict exists $eng_params DDR_EN]  ? [dict get $eng_params DDR_EN]  : 0}]
set odma_en [expr {[dict exists $eng_params ODMA_EN] ? [dict get $eng_params ODMA_EN] : 0}]
set link_gbps [expr {[dict exists $eng_params LINK_GBPS] ? [dict get $eng_params LINK_GBPS] : 10}]
set mac_width [expr {[dict exists $eng_params MAC_WIDTH] ? [dict get $eng_params MAC_WIDTH] : 64}]
set ddr_ports [expr {$ddr_en && [dict exists $eng_params DDR_PORTS] ? [dict get $eng_params DDR_PORTS] : 1}]

#########################################################
# Processing system
#########################################################
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1" } [get_bd_cells zynq_ultra_ps_e_0]
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0 {0} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} \
  CONFIG.PSU__USE__M_AXI_GP2 {1} \
  CONFIG.PSU__USE__S_AXI_GP2 {1} \
  CONFIG.PSU__USE__S_AXI_GP3 {1} \
  CONFIG.PSU__USE__S_AXI_GP4 {1} \
  CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
  CONFIG.PSU__SAXIGP3__DATA_WIDTH {128} \
  CONFIG.PSU__SAXIGP4__DATA_WIDTH {128} \
  CONFIG.PSU__USE__S_AXI_GP0 [expr {$ddr_ports == 2}] \
  CONFIG.PSU__USE__S_AXI_GP5 [expr {$ddr_ports == 2}] \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
  CONFIG.PSU__FPGA_PL1_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL1_REF_CTRL__FREQMHZ {250} \
  CONFIG.PSU__FPGA_PL2_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL2_REF_CTRL__FREQMHZ {200} \
  CONFIG.PSU__USE__IRQ0 {1} \
  CONFIG.PSU__HIGH_ADDRESS__ENABLE {1} \
] [get_bd_cells zynq_ultra_ps_e_0]

set ps      zynq_ultra_ps_e_0
set sys_clk $ps/pl_clk0
set hp_clk  $ps/pl_clk1
set gen_clk $ps/pl_clk2

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_ps_100m
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins rst_ps_100m/slowest_sync_clk]
connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins rst_ps_100m/ext_reset_in]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_ps_250m
connect_bd_net [get_bd_pins $hp_clk] [get_bd_pins rst_ps_250m/slowest_sync_clk]
connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins rst_ps_250m/ext_reset_in]

connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins $ps/maxihpm0_lpd_aclk]
foreach p {saxihp0_fpd_aclk saxihp1_fpd_aclk saxihp2_fpd_aclk} {
  connect_bd_net [get_bd_pins $hp_clk] [get_bd_pins $ps/$p]
}
if {$ddr_ports == 2} {
  set_property -dict [list CONFIG.PSU__SAXIGP0__DATA_WIDTH {128} CONFIG.PSU__SAXIGP5__DATA_WIDTH {128}] [get_bd_cells $ps]
  foreach p {saxihpc0_fpd_aclk saxihp3_fpd_aclk} {
    connect_bd_net [get_bd_pins $hp_clk] [get_bd_pins $ps/$p]
  }
}

# AXI-Lite control plane: M00 always-on block (+ rocelet_sys behind its guard), M01 Si5328
# IIC, M02 QSFP0 IIC, M03 AXI DMA registers
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_smc
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI [expr {$odma_en ? 4 : 3}]] [get_bd_cells axi_smc]
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins axi_smc/aclk]
connect_bd_net [get_bd_pins rst_ps_100m/interconnect_aresetn] [get_bd_pins axi_smc/aresetn]
connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM0_LPD] [get_bd_intf_pins axi_smc/S00_AXI]

const_cell const_low 1 0
const_cell const_high 1 1
set intr_list {}

#########################################################
# MAC (swappable block; OP120 port 0)
#########################################################
switch -- $mac_type {
  omac_10g {
    create_bd_cell -type module -reference mac_omac10g mac0
    create_bd_port -dir I gt_refclk0_p
    create_bd_port -dir I gt_refclk0_n
    create_bd_port -dir I qsfp0_rx0_p
    create_bd_port -dir I qsfp0_rx0_n
    create_bd_port -dir O qsfp0_tx0_p
    create_bd_port -dir O qsfp0_tx0_n
    connect_bd_net [get_bd_ports gt_refclk0_p] [get_bd_pins mac0/gt_refclk_p]
    connect_bd_net [get_bd_ports gt_refclk0_n] [get_bd_pins mac0/gt_refclk_n]
    connect_bd_net [get_bd_ports qsfp0_rx0_p]  [get_bd_pins mac0/gt_rxp]
    connect_bd_net [get_bd_ports qsfp0_rx0_n]  [get_bd_pins mac0/gt_rxn]
    connect_bd_net [get_bd_pins mac0/gt_txp] [get_bd_ports qsfp0_tx0_p]
    connect_bd_net [get_bd_pins mac0/gt_txn] [get_bd_ports qsfp0_tx0_n]
    connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins mac0/freerun_clk]
    # one lane: no 40G lane status
    set mac_lane [const_cell const_lane 32 0]
    set mac_lev  [const_cell const_lev 6 0]
  }
  omac_40g {
    # omac_40g + omac_gt_usp_gth_x4: OP120 port 0 QSFP lanes 0-3 (ZCU106: HPC0 DP0-3, GTH quad
    # 226, channels X0Y14 X0Y13 X0Y15 X0Y12 from the gtwizard IP), one 156.25 MHz reference
    # clock; the lane map CH_OF_LANE comes from data.json gt_channels (scripts/build.tcl)
    create_bd_cell -type module -reference mac_omac40g mac0
    set_property CONFIG.CH_OF_LANE $ch_of_lane [get_bd_cells mac0]
    create_bd_port -dir I gt_refclk0_p
    create_bd_port -dir I gt_refclk0_n
    create_bd_port -dir I -from 3 -to 0 qsfp0_rx_p
    create_bd_port -dir I -from 3 -to 0 qsfp0_rx_n
    create_bd_port -dir O -from 3 -to 0 qsfp0_tx_p
    create_bd_port -dir O -from 3 -to 0 qsfp0_tx_n
    connect_bd_net [get_bd_ports gt_refclk0_p] [get_bd_pins mac0/gt_refclk_p]
    connect_bd_net [get_bd_ports gt_refclk0_n] [get_bd_pins mac0/gt_refclk_n]
    connect_bd_net [get_bd_ports qsfp0_rx_p]   [get_bd_pins mac0/gt_rxp]
    connect_bd_net [get_bd_ports qsfp0_rx_n]   [get_bd_pins mac0/gt_rxn]
    connect_bd_net [get_bd_pins mac0/gt_txp] [get_bd_ports qsfp0_tx_p]
    connect_bd_net [get_bd_pins mac0/gt_txn] [get_bd_ports qsfp0_tx_n]
    connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins mac0/freerun_clk]
    set mac_lane [get_bd_pins mac0/mac_lane]
    set mac_lev  [get_bd_pins mac0/mac_lev]
  }
  default {
    error "bd_zynqmp.tcl: MAC type $mac_type is not supported on Zynq UltraScale+ (yet)"
  }
}
set mac_clk mac0/clk_out

#########################################################
# Always-on block + clock guard
#########################################################
create_bd_cell -type module -reference rsys_aon_bd rsys_aon_0
# CAPS: [7:0] link Gb/s [15:8] MAC width / 8 [19:16] MAC type (1 CMAC 2 omac_10g 3 omac_40g)
# [23:20] QSFP port [24] PS DDR window [25] netdev DMA channel [26] clock guard
set mac_code [dict get {cmac 1 omac_10g 2 omac_40g 3} $mac_type]
set caps [expr {$link_gbps | (($mac_width / 8) << 8) | ($mac_code << 16) | ($port << 20) | ($ddr_en << 24) | ($odma_en << 25) | (1 << 26)}]
set tid 0
foreach c [split [string toupper [string range [string map {zcu Z} $target]0000 0 3]] ""] { set tid [expr {($tid << 8) | [scan $c %c]}] }
set build_id [clock seconds]
set_property -dict [list CONFIG.PL_CLK_KHZ {100000} CONFIG.BUILD_ID $build_id CONFIG.TARGET_ID $tid CONFIG.CAPS $caps] [get_bd_cells rsys_aon_0]
puts "INFO: rsys_aon CAPS [format 0x%08X $caps], target id [format 0x%08X $tid], build id $build_id"
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins rsys_aon_0/clk]
connect_bd_net [get_bd_pins rst_ps_100m/peripheral_reset] [get_bd_pins rsys_aon_0/rst]
connect_bd_net [get_bd_pins $mac_clk] [get_bd_pins rsys_aon_0/mac_clk]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] [get_bd_intf_pins rsys_aon_0/S_AXIL]
connect_bd_net [get_bd_pins rsys_aon_0/gt_reset]  [get_bd_pins mac0/gt_reset]
connect_bd_net [get_bd_pins rsys_aon_0/mac_reset] [get_bd_pins mac0/mac_reset]
foreach p {gt_powergood gt_tx_ready gt_rx_ready} {
  connect_bd_net [get_bd_pins mac0/$p] [get_bd_pins rsys_aon_0/$p]
}
connect_bd_net $mac_lane [get_bd_pins rsys_aon_0/mac_lane]
connect_bd_net $mac_lev  [get_bd_pins rsys_aon_0/mac_lev]
lappend intr_list rsys_aon_0/irq

#########################################################
# rocelet_sys
#########################################################
create_bd_cell -type module -reference rocelet_sys_bd rocelet_sys_0
set cfg [list CONFIG.SELFTEST $selftest CONFIG.RSFEC [expr {$fec eq "rs" ? 1 : 0}]]
dict for {k v} $eng_params { lappend cfg CONFIG.$k $v }
set_property -dict $cfg [get_bd_cells rocelet_sys_0]

connect_bd_net [get_bd_pins $mac_clk] [get_bd_pins rocelet_sys_0/clk]
connect_bd_net [get_bd_pins $gen_clk] [get_bd_pins rocelet_sys_0/gen_clk]
connect_bd_net [get_bd_pins $hp_clk]  [get_bd_pins rocelet_sys_0/dma_clk]
# system reset: the PS reset or the always-on block's soft reset (synchronised in rocelet_sys)
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilvector_logic:1.0 sys_rst_or
set_property -dict [list CONFIG.C_OPERATION {or} CONFIG.C_SIZE {1}] [get_bd_cells sys_rst_or]
connect_bd_net [get_bd_pins rst_ps_100m/peripheral_reset] [get_bd_pins sys_rst_or/Op1]
connect_bd_net [get_bd_pins rsys_aon_0/sys_reset] [get_bd_pins sys_rst_or/Op2]
connect_bd_net [get_bd_pins sys_rst_or/Res] [get_bd_pins rocelet_sys_0/sys_rst]

connect_bd_intf_net [get_bd_intf_pins rsys_aon_0/M_AXIL] [get_bd_intf_pins rocelet_sys_0/S_AXIL]
connect_bd_intf_net [get_bd_intf_pins mac0/M_AXIS_RX] [get_bd_intf_pins rocelet_sys_0/S_AXIS_RX]
connect_bd_intf_net [get_bd_intf_pins rocelet_sys_0/M_AXIS_TX] [get_bd_intf_pins mac0/S_AXIS_TX]
foreach p {mac_ctl mac_pz mac_addr} {
  connect_bd_net [get_bd_pins rocelet_sys_0/$p] [get_bd_pins mac0/$p]
}
foreach p {mac_stat mac_ev mac_pause} {
  connect_bd_net [get_bd_pins mac0/$p] [get_bd_pins rocelet_sys_0/$p]
}
connect_bd_net [get_bd_pins mac0/mac_stat] [get_bd_pins rsys_aon_0/mac_stat]
connect_bd_net [get_bd_pins rocelet_sys_0/evt] [get_bd_pins rsys_aon_0/sys_evt]

# PS DDR window (512 bits in the MAC clock -> 128 bits at 250 MHz in the SmartConnects):
#   DDR_PORTS 1: write channels -> S_AXI_HP0_FPD, read channels -> S_AXI_HP1_FPD
#   DDR_PORTS 2: rocelet_sys interleaves 512-byte granules over two masters per direction
#     (port = physical address bit 9): writes M_AXI_DDRW -> HP0 (DDR controller port 3) and
#     M_AXI_DDRW1 -> HPC0 (non-coherent use: AxCACHE 0011, through the CCI), reads M_AXI_DDRR ->
#     HP1 (DDR port 4, shared with HP2 = the netdev DMA) and M_AXI_DDRR1 -> HP3 (DDR port 5);
#     each port 128 bits at 250 MHz = 32 Gb/s raw, two per direction = 64 Gb/s
if {$ddr_en} {
  set ddr_map {w S_AXI_HP0_FPD r S_AXI_HP1_FPD}
  if {$ddr_ports == 2} { lappend ddr_map w1 S_AXI_HPC0_FPD r1 S_AXI_HP3_FPD }
  foreach {dir hp} $ddr_map {
    create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smc_ddr$dir
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {2}] [get_bd_cells smc_ddr$dir]
    connect_bd_net [get_bd_pins $mac_clk] [get_bd_pins smc_ddr$dir/aclk]
    connect_bd_net [get_bd_pins $hp_clk] [get_bd_pins smc_ddr$dir/aclk1]
    connect_bd_net [get_bd_pins rst_ps_250m/interconnect_aresetn] [get_bd_pins smc_ddr$dir/aresetn]
    connect_bd_intf_net [get_bd_intf_pins rocelet_sys_0/M_AXI_DDR[string toupper $dir]] [get_bd_intf_pins smc_ddr$dir/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins smc_ddr$dir/M00_AXI] [get_bd_intf_pins $ps/$hp]
  }
}

# netdev DMA channel: rocelet_sys M_AXIS_ORX (512) -> 64-bit -> AXI DMA S2MM, AXI DMA MM2S ->
# 512-bit -> rocelet_sys S_AXIS_OTX; DMA masters -> S_AXI_HP2_FPD
if {$odma_en} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma axi_dma_0
  set_property -dict [list \
    CONFIG.c_include_sg {1} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_sg_length_width {16} \
    CONFIG.c_addr_width {40} \
    CONFIG.c_include_mm2s_dre {1} \
    CONFIG.c_include_s2mm_dre {1} \
    CONFIG.c_m_axi_mm2s_data_width {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {64} \
    CONFIG.c_m_axi_s2mm_data_width {64} \
    CONFIG.c_s_axis_s2mm_tdata_width {64} \
    CONFIG.c_mm2s_burst_size {64} \
    CONFIG.c_s2mm_burst_size {64} \
  ] [get_bd_cells axi_dma_0]
  connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins axi_dma_0/s_axi_lite_aclk]
  foreach p {m_axi_sg_aclk m_axi_mm2s_aclk m_axi_s2mm_aclk} {
    connect_bd_net [get_bd_pins $hp_clk] [get_bd_pins axi_dma_0/$p]
  }
  connect_bd_net [get_bd_pins rst_ps_100m/peripheral_aresetn] [get_bd_pins axi_dma_0/axi_resetn]
  connect_bd_intf_net [get_bd_intf_pins axi_smc/M03_AXI] [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

  create_bd_cell -type ip -vlnv xilinx.com:ip:axis_dwidth_converter odma_rx_dw
  set_property -dict [list CONFIG.S_TDATA_NUM_BYTES {64} CONFIG.M_TDATA_NUM_BYTES {8} CONFIG.HAS_TLAST {1} CONFIG.HAS_TKEEP {1}] [get_bd_cells odma_rx_dw]
  create_bd_cell -type ip -vlnv xilinx.com:ip:axis_dwidth_converter odma_tx_dw
  set_property -dict [list CONFIG.S_TDATA_NUM_BYTES {8} CONFIG.M_TDATA_NUM_BYTES {64} CONFIG.HAS_TLAST {1} CONFIG.HAS_TKEEP {1}] [get_bd_cells odma_tx_dw]
  foreach c {odma_rx_dw odma_tx_dw} {
    connect_bd_net [get_bd_pins $hp_clk] [get_bd_pins $c/aclk]
    connect_bd_net [get_bd_pins rst_ps_250m/peripheral_aresetn] [get_bd_pins $c/aresetn]
  }
  connect_bd_intf_net [get_bd_intf_pins rocelet_sys_0/M_AXIS_ORX] [get_bd_intf_pins odma_rx_dw/S_AXIS]
  connect_bd_intf_net [get_bd_intf_pins odma_rx_dw/M_AXIS] [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]
  connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] [get_bd_intf_pins odma_tx_dw/S_AXIS]
  connect_bd_intf_net [get_bd_intf_pins odma_tx_dw/M_AXIS] [get_bd_intf_pins rocelet_sys_0/S_AXIS_OTX]

  create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smc_dma
  set_property -dict [list CONFIG.NUM_SI {3} CONFIG.NUM_MI {1}] [get_bd_cells smc_dma]
  connect_bd_net [get_bd_pins $hp_clk] [get_bd_pins smc_dma/aclk]
  connect_bd_net [get_bd_pins rst_ps_250m/interconnect_aresetn] [get_bd_pins smc_dma/aresetn]
  connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_SG]   [get_bd_intf_pins smc_dma/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] [get_bd_intf_pins smc_dma/S01_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] [get_bd_intf_pins smc_dma/S02_AXI]
  connect_bd_intf_net [get_bd_intf_pins smc_dma/M00_AXI] [get_bd_intf_pins $ps/S_AXI_HP2_FPD]
  lappend intr_list axi_dma_0/mm2s_introut axi_dma_0/s2mm_introut
}

#########################################################
# I2C: Si5328 (GT reference clock) and the QSFP0 module (PL pins on the FMC LA bank)
#########################################################
foreach {iic port mi} {axi_iic_clk clk_i2c M01_AXI axi_iic_qsfp0 qsfp0_i2c M02_AXI} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic $iic
  connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins $iic/s_axi_aclk]
  connect_bd_net [get_bd_pins rst_ps_100m/peripheral_aresetn] [get_bd_pins $iic/s_axi_aresetn]
  connect_bd_intf_net [get_bd_intf_pins axi_smc/$mi] [get_bd_intf_pins $iic/S_AXI]
  create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 $port
  connect_bd_intf_net [get_bd_intf_ports $port] [get_bd_intf_pins $iic/IIC]
  lappend intr_list $iic/iic2intc_irpt
}

#########################################################
# QSFP0 module lines, LEDs, Si5328 LOS (always-on block); QSFP1 not used
#########################################################
foreach {port pin} {modsell_qsfp0 qsfp_modsel_l resetl_qsfp0 qsfp_reset_l lpmode_qsfp0 qsfp_lpmode \
                    grn_led_qsfp0 led_grn red_led_qsfp0 led_red} {
  create_bd_port -dir O $port
  connect_bd_net [get_bd_pins rsys_aon_0/$pin] [get_bd_ports $port]
}
foreach {port pin} {modprsl_qsfp0 qsfp_modprs_l intl_qsfp0 qsfp_int_l clk_los clk_los} {
  create_bd_port -dir I $port
  connect_bd_net [get_bd_ports $port] [get_bd_pins rsys_aon_0/$pin]
}
# QSFP1 (port 1) is not used by this design: deselected, in reset, low power, LEDs off
foreach {port net} {modsell const_high resetl const_low lpmode const_high grn_led const_low red_led const_low} {
  create_bd_port -dir O ${port}_qsfp1
  connect_bd_net [get_bd_pins ${net}/dout] [get_bd_ports ${port}_qsfp1]
}

#########################################################
# Interrupts (pl_ps_irq0: GIC SPI 121 + n, Linux DT <0 89+n 4>)
#########################################################
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 intr_concat
set_property CONFIG.NUM_PORTS [llength $intr_list] [get_bd_cells intr_concat]
set i 0
foreach intr $intr_list {
  connect_bd_net [get_bd_pins $intr] [get_bd_pins intr_concat/In$i]
  incr i
}
connect_bd_net [get_bd_pins intr_concat/dout] [get_bd_pins $ps/pl_ps_irq0]
puts "INFO: pl_ps_irq0: $intr_list"

#########################################################
# Addresses (M_AXI_HPM0_LPD): 0x8000_0000 always-on block + rocelet_sys (1 MB),
# 0x8010_0000 Si5328 IIC, 0x8011_0000 QSFP0 IIC, 0x8012_0000 AXI DMA
#########################################################
foreach {intf off rng} {rsys_aon_0/S_AXIL 0x80000000 1M axi_iic_clk/S_AXI 0x80100000 64K \
                        axi_iic_qsfp0/S_AXI 0x80110000 64K axi_dma_0/S_AXI_LITE 0x80120000 64K} {
  set segs [get_bd_addr_segs -quiet -of_objects [get_bd_intf_pins -quiet $intf]]
  if {[llength $segs]} {
    assign_bd_address -offset $off -range $rng -target_address_space [get_bd_addr_spaces $ps/Data] $segs
  }
}
assign_bd_address
foreach seg [get_bd_addr_segs -quiet] { puts "INFO: address segment $seg" }

regenerate_bd_layout
save_bd_design
validate_bd_design
save_bd_design
