################################################################
# Block design: rocelet RoCE v2 reference design, Versal targets (VCK190 + OP120 on FMCP1)
#
# Sourced by scripts/build.tcl, which sets: block_name, target, port (QSFP28 port of the
# OP120), fec ("rs" = RS-FEC CL91 built into the MRMAC, "none" = bypass), selftest, mac_type
# (data.json "mac" = mrmac), eng_params (rocelet_sys_bd parameters from config/data.json, incl.
# MAC_WIDTH 512 / CLK_KHZ / CLK_HZ = the ENGINE clock / LINK_GBPS / DDR_EN / DDR_PORTS / ODMA_EN
# / DNA_EN 0), gt_quad, mrmac_core and gt_refclk_hz (data.json "gt_quad", "mrmac_core",
# "gt_refclk_hz"). Same system shell as bd_zynqmp.tcl (register map at 0x8000_0000, rsys_aon +
# clock guard, rocelet_sys, netdev DMA, Si5328 / QSFP IIC), with the Versal hard blocks:
#
#   versal_cips (VCK190 preset: A72, PS UART0 console, GEM0 RJ45 for SSH, SD1, QSPI, LPD I2C0/1)
#     + axi_noc_0 (the CIPS automation's NoC, one DDR4 controller on the 8 GB DIMM:
#       DDR_LOW0 2 GB @ 0x0 + DDR_CH1 6 GB @ 0x500_0000_0000 = Linux memory)
#   clk_wizard_0 (pl0_ref_clk 100 MHz): clk_sys 100 MHz (control plane, MRMAC s_axi, GT APB,
#     IIC), clk_gen 200 MHz (rocelet_sys gen_clk), clk_dma 250 MHz (netdev AXI DMA)
#   eng_clk_wiz: clk_eng = the engine clock (data.json clk_khz, 300 MHz): rocelet_sys and the
#     DDR window's NoC ports. Free-running: it does not stop on a link loss or GT reset
#   axis_clk_wiz: clk_axis 390.625 MHz, the MRMAC AXIS client clock (tx/rx_axi_clk) and the MAC
#     side of the adapter (free-running)
#   gt_quad_base_0 (GTY_QUAD_X1Y1 = FMCP1 DP0-3, GBTCLK0 322.265625 MHz from the OP120 Si5328;
#     the AMD VCK190 Ethernet TRD's 80-bit RAW 25.78125 Gb/s LCPLL settings) + qsfp_port0/mrmac
#     (MRMAC_X0Y0, 1x100GE CAUI-4, independent 384-bit non-segmented client, MAC+PCS+FEC with
#     RS(528,514) when fec = rs; per-lane BUFG_GT clocking). Configuration, clocking and
#     resets as the hardware-proven vck190_fmcp1 targets of the Opsero qsfp28-fmc-zircon (RS-FEC)
#     and 2x-qsfp28-fmc designs. The MRMAC registers (MODE, FEC, MTU, PAUSE quanta, stats) are
#     on its s_axi (firmware); the GT DRP on the APB bridge.
#   mac0 (module reference mac_mrmac100g, src/hdl/mac): MRMAC 6 x 64-bit client (390.625 MHz)
#     <-> rocelet_sys's 512-bit streams and generic MAC boundary (engine clock), incl. the
#     clock crossings. Every mac0 pin named like an MRMAC pin (exactly, or without the "_0"
#     port suffix) is connected to that MRMAC pin; see "MAC adapter" below.
#   rsys_aon_0: always-on registers + the clock guard (clk_sys <-> clk_eng), 1 MB window
#   rocelet_sys_0: engine + URAM window + DDR window masters + netdev DMA channel, on clk_eng
#   DDR window: rocelet_sys M_AXI_DDRW -> one 512-bit NoC port (write QoS), M_AXI_DDRR -> one
#     512-bit NoC port (read QoS), both on clk_eng (the NoC does the clock crossing), each to
#     ONE DDR4 controller port (one destination per NMU); DDR_PORTS 1, no interleaver
#   axi_dma_0 (netdev rl0, 64-bit addressing: Linux memory reaches 0x500_0000_0000 + 6 GB) ->
#     SmartConnect -> one NoC port
#   axi_iic_clk (Si5328 on the FMC), axi_iic_qsfp0
# VADJ (FMCP1 1.5 V) is enabled by software over LPD I2C0 (IR38164 behind the TCA9548): the
# u-boot fragment of the Yocto BSP, the console and roceletd. Nothing in the PL.
# QSFP28 port 1 (GTY_QUAD_X1Y2 / MRMAC_X0Y2 / GBTCLK1) is not built in v1; its module lines
# are held (deselected, reset, low power, LEDs off).
################################################################

create_bd_design $block_name
current_bd_design $block_name

proc const_cell {name width val} {
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 $name
  set_property -dict [list CONFIG.CONST_WIDTH $width CONFIG.CONST_VAL $val] [get_bd_cells $name]
  return [get_bd_pins $name/dout]
}
# one scalar net driving all bits of a 4-bit pin (the MRMAC / GT per-lane buses)
proc fan4 {name src dst} {
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 $name
  set_property CONFIG.NUM_PORTS {4} [get_bd_cells $name]
  foreach ch {0 1 2 3} { connect_bd_net [get_bd_pins $src] [get_bd_pins $name/In$ch] }
  connect_bd_net [get_bd_pins $name/dout] [get_bd_pins $dst]
}

set ddr_en    [expr {[dict exists $eng_params DDR_EN]    ? [dict get $eng_params DDR_EN]    : 0}]
set odma_en   [expr {[dict exists $eng_params ODMA_EN]   ? [dict get $eng_params ODMA_EN]   : 0}]
set link_gbps [expr {[dict exists $eng_params LINK_GBPS] ? [dict get $eng_params LINK_GBPS] : 100}]
set mac_width [expr {[dict exists $eng_params MAC_WIDTH] ? [dict get $eng_params MAC_WIDTH] : 512}]
set eng_khz   [expr {[dict exists $eng_params CLK_KHZ]   ? [dict get $eng_params CLK_KHZ]   : 300000}]
set eng_hz    [expr {[dict exists $eng_params CLK_HZ]    ? [dict get $eng_params CLK_HZ]    : $eng_khz * 1000}]
set ddr_ports [expr {$ddr_en && [dict exists $eng_params DDR_PORTS] ? [dict get $eng_params DDR_PORTS] : 1}]
if {$mac_type ne "mrmac"} { error "bd_versal.tcl: MAC type $mac_type is not supported on Versal (mrmac only)" }
if {$mac_width != 512} { error "bd_versal.tcl: MAC_WIDTH $mac_width: the MRMAC adapter delivers 512-bit beats" }
if {$ddr_en && $ddr_ports != 1} { error "bd_versal.tcl: DDR_PORTS $ddr_ports: one 512-bit NoC port per direction (DDR_PORTS 1)" }
if {$port != 0} { error "bd_versal.tcl: QSFP28 port $port: v1 builds port 0 (GTY_QUAD_X1Y1 / MRMAC_X0Y0) only" }
set eng_mhz [format %.6f [expr {$eng_hz / 1.0e6}]]
set refclk_mhz [format %.6f [expr {$gt_refclk_hz / 1.0e6}]]

#########################################################
# CIPS + NoC (DDR4 DIMM)
#########################################################
create_bd_cell -type ip -vlnv xilinx.com:ip:versal_cips versal_cips_0
apply_bd_automation -rule xilinx.com:bd_rule:cips -config { \
  board_preset {Yes} \
  boot_config {Custom} \
  configure_noc {Add new AXI NoC} \
  debug_config {JTAG} \
  design_flow {Full System} \
  mc_type {DDR} \
  num_mc_ddr {1} \
  num_mc_lpddr {None} \
  pl_clocks {None} \
  pl_resets {None} \
}  [get_bd_cells versal_cips_0]

# PS / PMC configuration of the Opsero 2x-qsfp28-fmc and qsfp28-fmc-zircon vck190_fmcp1
# targets (identical in both; hardware-proven with Linux on this board): PL CLK0 100 MHz,
# M_AXI_LPD, PL-to-PS interrupts IRQ0-15 (individual pins), one fabric reset, PS UART0
# (console), GEM0 + GEM1 (GEM0 = the RJ45 used for SSH), SD1, QSPI, LPD I2C0 (VADJ regulator,
# EEPROMs) + I2C1, USB. PL CLK1 is not used here (the fabric clocks come from MMCMs).
set_property -dict [list \
  CONFIG.CLOCK_MODE {Custom} \
  CONFIG.PS_BOARD_INTERFACE {Custom} \
  CONFIG.PS_PL_CONNECTIVITY_MODE {Custom} \
  CONFIG.PS_PMC_CONFIG { \
    CLOCK_MODE {Custom} \
    DDR_MEMORY_MODE {Connectivity to DDR via NOC} \
    DEBUG_MODE {JTAG} \
    DESIGN_MODE {1} \
    PMC_CRP_PL0_REF_CTRL_FREQMHZ {100} \
    PMC_GPIO0_MIO_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 0 .. 25}}} \
    PMC_GPIO1_MIO_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 26 .. 51}}} \
    PMC_MIO37 {{AUX_IO 0} {DIRECTION out} {DRIVE_STRENGTH 8mA} {OUTPUT_DATA high} {PULL pullup} {SCHMITT 0} {SLEW slow} {USAGE GPIO}} \
    PMC_OSPI_PERIPHERAL {{ENABLE 0} {IO {PMC_MIO 0 .. 11}} {MODE Single}} \
    PMC_QSPI_COHERENCY {0} \
    PMC_QSPI_FBCLK {{ENABLE 1} {IO {PMC_MIO 6}}} \
    PMC_QSPI_PERIPHERAL_DATA_MODE {x4} \
    PMC_QSPI_PERIPHERAL_ENABLE {1} \
    PMC_QSPI_PERIPHERAL_MODE {Dual Parallel} \
    PMC_REF_CLK_FREQMHZ {33.3333} \
    PMC_SD1 {{CD_ENABLE 1} {CD_IO {PMC_MIO 28}} {POW_ENABLE 1} {POW_IO {PMC_MIO 51}} {RESET_ENABLE 0} {RESET_IO {PMC_MIO 12}} {WP_ENABLE 0} {WP_IO {PMC_MIO 1}}} \
    PMC_SD1_COHERENCY {0} \
    PMC_SD1_DATA_TRANSFER_MODE {8Bit} \
    PMC_SD1_PERIPHERAL {{CLK_100_SDR_OTAP_DLY 0x3} {CLK_200_SDR_OTAP_DLY 0x2} {CLK_50_DDR_ITAP_DLY 0x36} {CLK_50_DDR_OTAP_DLY 0x3} {CLK_50_SDR_ITAP_DLY 0x2C} {CLK_50_SDR_OTAP_DLY 0x4} {ENABLE 1} {IO {PMC_MIO 26 .. 36}}} \
    PMC_SD1_SLOT_TYPE {SD 3.0} \
    PMC_USE_PMC_NOC_AXI0 {1} \
    PS_BOARD_INTERFACE {Custom} \
    PS_ENET0_MDIO {{ENABLE 1} {IO {PS_MIO 24 .. 25}}} \
    PS_ENET0_PERIPHERAL {{ENABLE 1} {IO {PS_MIO 0 .. 11}}} \
    PS_ENET1_PERIPHERAL {{ENABLE 1} {IO {PS_MIO 12 .. 23}}} \
    PS_GEN_IPI0_ENABLE {1} \
    PS_GEN_IPI0_MASTER {A72} \
    PS_GEN_IPI1_ENABLE {1} \
    PS_GEN_IPI2_ENABLE {1} \
    PS_GEN_IPI3_ENABLE {1} \
    PS_GEN_IPI4_ENABLE {1} \
    PS_GEN_IPI5_ENABLE {1} \
    PS_GEN_IPI6_ENABLE {1} \
    PS_HSDP_EGRESS_TRAFFIC {JTAG} \
    PS_HSDP_INGRESS_TRAFFIC {JTAG} \
    PS_HSDP_MODE {NONE} \
    PS_I2C0_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 46 .. 47}}} \
    PS_I2C1_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 44 .. 45}}} \
    PS_IRQ_USAGE {{CH0 1} {CH1 1} {CH10 1} {CH11 1} {CH12 1} {CH13 1} {CH14 1} {CH15 1} {CH2 1} {CH3 1} {CH4 1} {CH5 1} {CH6 1} {CH7 1} {CH8 1} {CH9 1}} \
    PS_NUM_FABRIC_RESETS {1} \
    PS_PCIE_EP_RESET1_IO {PMC_MIO 38} \
    PS_PCIE_EP_RESET2_IO {PMC_MIO 39} \
    PS_PCIE_RESET {ENABLE 1} \
    PS_PL_CONNECTIVITY_MODE {Custom} \
    PS_UART0_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 42 .. 43}}} \
    PS_USB3_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 13 .. 25}}} \
    PS_USE_FPD_CCI_NOC {1} \
    PS_USE_FPD_CCI_NOC0 {1} \
    PS_USE_M_AXI_LPD {1} \
    PS_USE_NOC_LPD_AXI0 {1} \
    PS_USE_PMCPL_CLK0 {1} \
    PS_USE_PMCPL_CLK1 {0} \
    PS_USE_PMCPL_CLK2 {0} \
    PS_USE_PMCPL_CLK3 {0} \
    SMON_ALARMS {Set_Alarms_On} \
    SMON_ENABLE_TEMP_AVERAGING {0} \
    SMON_TEMP_AVERAGING_SAMPLES {0} \
  } \
] [get_bd_cells versal_cips_0]

set cips versal_cips_0
# 8 GB of Linux memory: DDR_LOW0 2 GB @ 0x0 and DDR_CH1 6 GB @ 0x500_0000_0000 (as the
# fpga-drive-nvme-host vck190 target)
set_property CONFIG.MC_CHAN_REGION1 {DDR_CH1} [get_bd_cells axi_noc_0]

#########################################################
# Fabric clocks (MMCMs on pl0_ref_clk) and resets
#########################################################
# clk_wizard_0: VCO 3000 MHz, /30 /15 /12
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wizard clk_wizard_0
set_property -dict [list \
  CONFIG.CLKOUT_DRIVES {BUFG,BUFG,BUFG,BUFG,BUFG,BUFG,BUFG} \
  CONFIG.CLKOUT_DYN_PS {None,None,None,None,None,None,None} \
  CONFIG.CLKOUT_GROUPING {Auto,Auto,Auto,Auto,Auto,Auto,Auto} \
  CONFIG.CLKOUT_MATCHED_ROUTING {false,false,false,false,false,false,false} \
  CONFIG.CLKOUT_PORT {clk_sys,clk_gen,clk_dma,clk_out4,clk_out5,clk_out6,clk_out7} \
  CONFIG.CLKOUT_REQUESTED_DUTY_CYCLE {50.000,50.000,50.000,50.000,50.000,50.000,50.000} \
  CONFIG.CLKOUT_REQUESTED_OUT_FREQUENCY {100.000,200.000,250.000,100.000,100.000,100.000,100.000} \
  CONFIG.CLKOUT_REQUESTED_PHASE {0.000,0.000,0.000,0.000,0.000,0.000,0.000} \
  CONFIG.CLKOUT_USED {true,true,true,false,false,false,false} \
  CONFIG.USE_LOCKED {true} \
] [get_bd_cells clk_wizard_0]
connect_bd_net [get_bd_pins $cips/pl0_ref_clk] [get_bd_pins clk_wizard_0/clk_in1]
# eng_clk_wiz: the engine clock (data.json clk_khz / clk_hz), its own MMCM so that any
# frequency the manifest asks for leaves the other clocks alone
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wizard eng_clk_wiz
set_property -dict [list \
  CONFIG.CLKOUT_DRIVES {BUFG,BUFG,BUFG,BUFG,BUFG,BUFG,BUFG} \
  CONFIG.CLKOUT_DYN_PS {None,None,None,None,None,None,None} \
  CONFIG.CLKOUT_GROUPING {Auto,Auto,Auto,Auto,Auto,Auto,Auto} \
  CONFIG.CLKOUT_MATCHED_ROUTING {false,false,false,false,false,false,false} \
  CONFIG.CLKOUT_PORT {clk_eng,clk_out2,clk_out3,clk_out4,clk_out5,clk_out6,clk_out7} \
  CONFIG.CLKOUT_REQUESTED_OUT_FREQUENCY [list "$eng_mhz,100.000,100.000,100.000,100.000,100.000,100.000"] \
  CONFIG.CLKOUT_USED {true,false,false,false,false,false,false} \
  CONFIG.USE_LOCKED {true} \
] [get_bd_cells eng_clk_wiz]
connect_bd_net [get_bd_pins $cips/pl0_ref_clk] [get_bd_pins eng_clk_wiz/clk_in1]
catch { puts "INFO: engine clock requested $eng_mhz MHz, clk_wizard actual [get_property CONFIG.CLKOUT1_ACTUAL_FREQ [get_bd_cells eng_clk_wiz]]" }
# axis_clk_wiz: the MRMAC AXIS client clock, 390.625 MHz (>= tx_core_clk / 2; as both precedents)
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wizard axis_clk_wiz
set_property -dict [list \
  CONFIG.CLKOUT_DRIVES {BUFG,BUFG,BUFG,BUFG,BUFG,BUFG,BUFG} \
  CONFIG.CLKOUT_DYN_PS {None,None,None,None,None,None,None} \
  CONFIG.CLKOUT_GROUPING {Auto,Auto,Auto,Auto,Auto,Auto,Auto} \
  CONFIG.CLKOUT_MATCHED_ROUTING {false,false,false,false,false,false,false} \
  CONFIG.CLKOUT_PORT {clk_axis,clk_out2,clk_out3,clk_out4,clk_out5,clk_out6,clk_out7} \
  CONFIG.CLKOUT_REQUESTED_OUT_FREQUENCY {390.625,100.000,100.000,100.000,100.000,100.000,100.000} \
  CONFIG.CLKOUT_USED {true,false,false,false,false,false,false} \
  CONFIG.USE_LOCKED {true} \
] [get_bd_cells axis_clk_wiz]
connect_bd_net [get_bd_pins $cips/pl0_ref_clk] [get_bd_pins axis_clk_wiz/clk_in1]

set sys_clk  clk_wizard_0/clk_sys
set gen_clk  clk_wizard_0/clk_gen
set dma_clk  clk_wizard_0/clk_dma
set eng_clk  eng_clk_wiz/clk_eng
set axis_clk axis_clk_wiz/clk_axis

foreach {rst clk lck} [list rst_sys $sys_clk clk_wizard_0/locked rst_dma $dma_clk clk_wizard_0/locked \
                            rst_eng $eng_clk eng_clk_wiz/locked] {
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset $rst
  connect_bd_net [get_bd_pins $clk] [get_bd_pins $rst/slowest_sync_clk]
  connect_bd_net [get_bd_pins $cips/pl0_resetn] [get_bd_pins $rst/ext_reset_in]
  connect_bd_net [get_bd_pins $lck] [get_bd_pins $rst/dcm_locked]
}
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins $cips/m_axi_lpd_aclk]

# AXI-Lite control plane (M_AXI_LPD, clk_sys): M00 always-on block (+ rocelet_sys behind its
# guard), M01 Si5328 IIC, M02 QSFP0 IIC, M03 AXI DMA, M04 MRMAC s_axi, M05 GT APB bridge
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_smc
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {6}] [get_bd_cells axi_smc]
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins axi_smc/aclk]
connect_bd_net [get_bd_pins rst_sys/interconnect_aresetn] [get_bd_pins axi_smc/aresetn]
connect_bd_intf_net [get_bd_intf_pins $cips/M_AXI_LPD] [get_bd_intf_pins axi_smc/S00_AXI]

const_cell const_low 1 0
const_cell const_high 1 1
const_cell const_zero4 4 0
set intr_list {}

#########################################################
# GT quad (QSFP28 port 0: FMCP1 DP0-3, GTY_QUAD_X1Y1 placed by the XDC pins)
#########################################################
# The MRMAC needs an 80-bit RAW GT datapath that no named Ethernet preset provides, so PROT0
# replicates the AMD VCK190 Ethernet TRD's manual PROT0_LR0_SETTINGS (PRESET None, 80-bit
# RAW, 25.78125 Gb/s, LCPLL integer-N, 322.265625 MHz reference), merged onto this IP
# version's default dict (fields that no longer exist are dropped) - verbatim from the
# qsfp28-fmc-zircon / 2x-qsfp28-fmc vck190_fmcp1 block designs.
set trd_gt {
  PRESET None
  RX_PAM_SEL NRZ
  TX_PAM_SEL NRZ
  RX_GRAY_BYP true
  TX_GRAY_BYP true
  RX_GRAY_LITTLEENDIAN true
  TX_GRAY_LITTLEENDIAN true
  RX_PRECODE_BYP true
  TX_PRECODE_BYP true
  RX_PRECODE_LITTLEENDIAN false
  TX_PRECODE_LITTLEENDIAN false
  INTERNAL_PRESET None
  GT_TYPE GTY
  GT_DIRECTION DUPLEX
  TX_LINE_RATE 25.78125
  TX_PLL_TYPE LCPLL
  TX_REFCLK_FREQUENCY 322.265625
  TX_ACTUAL_REFCLK_FREQUENCY 322.265625000000
  TX_FRACN_ENABLED false
  TX_FRACN_NUMERATOR 0
  TX_REFCLK_SOURCE R0
  TX_DATA_ENCODING RAW
  TX_USER_DATA_WIDTH 80
  TX_INT_DATA_WIDTH 80
  TX_BUFFER_MODE 1
  TX_BUFFER_BYPASS_MODE Fast_Sync
  TX_PIPM_ENABLE false
  TX_OUTCLK_SOURCE TXPROGDIVCLK
  TXPROGDIV_FREQ_ENABLE true
  TXPROGDIV_FREQ_SOURCE LCPLL
  TXPROGDIV_FREQ_VAL 644.531
  TX_DIFF_SWING_EMPH_MODE CUSTOM
  TX_64B66B_SCRAMBLER false
  TX_64B66B_ENCODER false
  TX_64B66B_CRC false
  TX_RATE_GROUP A
  RX_LINE_RATE 25.78125
  RX_PLL_TYPE LCPLL
  RX_REFCLK_FREQUENCY 322.265625
  RX_ACTUAL_REFCLK_FREQUENCY 322.265625000000
  RX_FRACN_ENABLED false
  RX_FRACN_NUMERATOR 0
  RX_REFCLK_SOURCE R0
  RX_DATA_DECODING RAW
  RX_USER_DATA_WIDTH 80
  RX_INT_DATA_WIDTH 80
  RX_BUFFER_MODE 1
  RX_OUTCLK_SOURCE RXPROGDIVCLK
  RXPROGDIV_FREQ_ENABLE true
  RXPROGDIV_FREQ_SOURCE LCPLL
  RXPROGDIV_FREQ_VAL 644.531
  INS_LOSS_NYQ 20
  RX_EQ_MODE AUTO
  RX_COUPLING AC
  RX_TERMINATION PROGRAMMABLE
  RX_RATE_GROUP A
  RX_TERMINATION_PROG_VALUE 800
  RX_PPM_OFFSET 0
  RX_64B66B_DESCRAMBLER false
  RX_64B66B_DECODER false
  RX_64B66B_CRC false
  OOB_ENABLE false
  RX_COMMA_ALIGN_WORD 1
  RX_COMMA_SHOW_REALIGN_ENABLE true
  PCIE_ENABLE false
  TX_LANE_DESKEW_HDMI_ENABLE false
  RX_COMMA_P_ENABLE false
  RX_COMMA_M_ENABLE false
  RX_COMMA_DOUBLE_ENABLE false
  RX_COMMA_P_VAL 0101111100
  RX_COMMA_M_VAL 1010000011
  RX_COMMA_MASK 0000000000
  RX_SLIDE_MODE OFF
  RX_SSC_PPM 0
  RX_CB_NUM_SEQ 0
  RX_CB_LEN_SEQ 1
  RX_CB_MAX_SKEW 1
  RX_CB_MAX_LEVEL 1
  RX_CB_MASK_0_0 false
  RX_CB_VAL_0_0 0000000000
  RX_CB_K_0_0 false
  RX_CB_DISP_0_0 false
  RX_CB_MASK_0_1 false
  RX_CB_VAL_0_1 0000000000
  RX_CB_K_0_1 false
  RX_CB_DISP_0_1 false
  RX_CB_MASK_0_2 false
  RX_CB_VAL_0_2 0000000000
  RX_CB_K_0_2 false
  RX_CB_DISP_0_2 false
  RX_CB_MASK_0_3 false
  RX_CB_VAL_0_3 0000000000
  RX_CB_K_0_3 false
  RX_CB_DISP_0_3 false
  RX_CB_MASK_1_0 false
  RX_CB_VAL_1_0 0000000000
  RX_CB_K_1_0 false
  RX_CB_DISP_1_0 false
  RX_CB_MASK_1_1 false
  RX_CB_VAL_1_1 0000000000
  RX_CB_K_1_1 false
  RX_CB_DISP_1_1 false
  RX_CB_MASK_1_2 false
  RX_CB_VAL_1_2 0000000000
  RX_CB_K_1_2 false
  RX_CB_DISP_1_2 false
  RX_CB_MASK_1_3 false
  RX_CB_VAL_1_3 0000000000
  RX_CB_K_1_3 false
  RX_CB_DISP_1_3 false
  RX_CC_NUM_SEQ 0
  RX_CC_LEN_SEQ 1
  RX_CC_PERIODICITY 5000
  RX_CC_KEEP_IDLE DISABLE
  RX_CC_PRECEDENCE ENABLE
  RX_CC_REPEAT_WAIT 0
  RX_CC_VAL 00000000000000000000000000000000000000000000000000000000000000000000000000000000
  RX_CC_MASK_0_0 false
  RX_CC_VAL_0_0 0000000000
  RX_CC_K_0_0 false
  RX_CC_DISP_0_0 false
  RX_CC_MASK_0_1 false
  RX_CC_VAL_0_1 0000000000
  RX_CC_K_0_1 false
  RX_CC_DISP_0_1 false
  RX_CC_MASK_0_2 false
  RX_CC_VAL_0_2 0000000000
  RX_CC_K_0_2 false
  RX_CC_DISP_0_2 false
  RX_CC_MASK_0_3 false
  RX_CC_VAL_0_3 0000000000
  RX_CC_K_0_3 false
  RX_CC_DISP_0_3 false
  RX_CC_MASK_1_0 false
  RX_CC_VAL_1_0 0000000000
  RX_CC_K_1_0 false
  RX_CC_DISP_1_0 false
  RX_CC_MASK_1_1 false
  RX_CC_VAL_1_1 0000000000
  RX_CC_K_1_1 false
  RX_CC_DISP_1_1 false
  RX_CC_MASK_1_2 false
  RX_CC_VAL_1_2 0000000000
  RX_CC_K_1_2 false
  RX_CC_DISP_1_2 false
  RX_CC_MASK_1_3 false
  RX_CC_VAL_1_3 0000000000
  RX_CC_K_1_3 false
  RX_CC_DISP_1_3 false
  PCIE_USERCLK2_FREQ 250
  PCIE_USERCLK_FREQ 250
  RX_JTOL_FC 10
  RX_JTOL_LF_SLOPE -20
  RX_BUFFER_BYPASS_MODE Fast_Sync
  RX_BUFFER_BYPASS_MODE_LANE MULTI
  RX_BUFFER_RESET_ON_CB_CHANGE ENABLE
  RX_BUFFER_RESET_ON_COMMAALIGN DISABLE
  RX_BUFFER_RESET_ON_RATE_CHANGE ENABLE
  TX_BUFFER_RESET_ON_RATE_CHANGE ENABLE
  RESET_SEQUENCE_INTERVAL 0
  RX_COMMA_PRESET NONE
  RX_COMMA_VALID_ONLY 0
}
if {$gt_refclk_hz != 322265625} {
  error "bd_versal.tcl: GT reference clock $gt_refclk_hz Hz: the MRMAC GT settings are the TRD's 322.265625 MHz LCPLL integer-N plan"
}
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 gt_ref_clk_0
set_property CONFIG.FREQ_HZ $gt_refclk_hz [get_bd_intf_ports /gt_ref_clk_0]
create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf util_ds_buf_0
set_property CONFIG.C_BUF_TYPE {IBUFDSGTE} [get_bd_cells util_ds_buf_0]
connect_bd_intf_net [get_bd_intf_ports gt_ref_clk_0] [get_bd_intf_pins util_ds_buf_0/CLK_IN_D]

create_bd_cell -type ip -vlnv xilinx.com:ip:gt_quad_base gt_quad_base_0
set_property -dict [list \
  CONFIG.PROT0_LR0_SETTINGS.VALUE_MODE MANUAL \
  CONFIG.PROT0_NO_OF_LANES.VALUE_MODE MANUAL \
] [get_bd_cells gt_quad_base_0]
array set gtset [get_property CONFIG.PROT0_LR0_SETTINGS [get_bd_cells gt_quad_base_0]]
foreach {k v} $trd_gt {
  if {[info exists gtset($k)]} { set gtset($k) $v }
}
set_property -dict [list \
  CONFIG.PROT0_LR0_SETTINGS [array get gtset] \
  CONFIG.PROT0_NO_OF_LANES {4} \
] [get_bd_cells gt_quad_base_0]
connect_bd_net [get_bd_pins util_ds_buf_0/IBUF_OUT] [get_bd_pins gt_quad_base_0/GT_REFCLK0]
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins gt_quad_base_0/apb3clk]
connect_bd_net [get_bd_pins rst_sys/peripheral_aresetn] [get_bd_pins gt_quad_base_0/apb3presetn]
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:gt_rtl:1.0 qsfp0_gt
connect_bd_intf_net [get_bd_intf_pins gt_quad_base_0/GT_Serial] [get_bd_intf_ports qsfp0_gt]

# GT DRP (APB3) for the firmware: per-channel PMA settings, loopback, eye/BER diagnostics
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_apb_bridge axi_apb_bridge_0
set_property -dict [list CONFIG.C_APB_NUM_SLAVES {1} CONFIG.C_M_APB_PROTOCOL {apb3}] [get_bd_cells axi_apb_bridge_0]
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins axi_apb_bridge_0/s_axi_aclk]
connect_bd_net [get_bd_pins rst_sys/peripheral_aresetn] [get_bd_pins axi_apb_bridge_0/s_axi_aresetn]
connect_bd_intf_net [get_bd_intf_pins axi_apb_bridge_0/APB_M] [get_bd_intf_pins gt_quad_base_0/APB3_INTF]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M05_AXI] [get_bd_intf_pins axi_apb_bridge_0/AXI4_LITE]

#########################################################
# MAC adapter mac0 (module reference mac_mrmac100g, src/hdl/mac), created first: where the
# adapter itself drives an MRMAC / GT input (resets, loopback), the block design does not
#########################################################
create_bd_cell -type module -reference mac_mrmac100g mac0
proc mac_drives {n} {
  set p [get_bd_pins -quiet mac0/$n]
  return [expr {$p ne "" && [get_property DIR $p] eq "O"}]
}

#########################################################
# MRMAC (1x100GE CAUI-4) on MRMAC_X0Y0 (data.json mrmac_core)
#########################################################
create_bd_cell -type ip -vlnv xilinx.com:ip:mrmac mrmac_0
set mrmac mrmac_0
# the "old" GT wizard model: the MRMAC exposes gt_*_serdes_interface_* that connect straight
# to gt_quad_base TXn/RXn_GT_IP_Interface
set_property CONFIG.MRMAC_IS_GT_WIZ_OLD {1} [get_bd_cells $mrmac]
set_property CONFIG.MRMAC_LOCATION_C0 $mrmac_core [get_bd_cells $mrmac]
set_property -dict [list \
  CONFIG.GT_REF_CLK_FREQ_C0 $refclk_mhz \
  CONFIG.GT_CH0_RX_REFCLK_FREQUENCY_C0 $refclk_mhz \
  CONFIG.GT_CH0_TX_REFCLK_FREQUENCY_C0 $refclk_mhz \
  CONFIG.GT_CH1_RX_REFCLK_FREQUENCY_C0 $refclk_mhz \
  CONFIG.GT_CH1_TX_REFCLK_FREQUENCY_C0 $refclk_mhz \
  CONFIG.GT_CH2_RX_REFCLK_FREQUENCY_C0 $refclk_mhz \
  CONFIG.GT_CH2_TX_REFCLK_FREQUENCY_C0 $refclk_mhz \
  CONFIG.GT_CH3_RX_REFCLK_FREQUENCY_C0 $refclk_mhz \
  CONFIG.GT_CH3_TX_REFCLK_FREQUENCY_C0 $refclk_mhz \
] [get_bd_cells $mrmac]
# RS-FEC (fec = rs, the shipping configuration): 100GBASE-CR4 clause 91 RS(528,514) in FEC
# slice 0, "MAC+PCS+FEC" (qsfp28-fmc-zircon, hardware-proven against the ConnectX-6 Dx with
# its FEC on auto). The FEC can still be bypassed at run time (FEC configuration register).
if {$fec eq "rs"} {
  set_property -dict [list \
    CONFIG.MRMAC_MODE_C0 {MAC+PCS+FEC} \
    CONFIG.FEC_SLICE0_CFG_C0 {100G (IEEE 802.3) - RS(528 514)} \
  ] [get_bd_cells $mrmac]
}
# PAUSE (802.3x, the engine's lossless mode): MAC_PORT0_TX_FLOW / RX_FLOW bring out the
# ctl_tx_pause_* / ctl_rx_pause_* / stat_*_pause_* ports the adapter drives / reads (without
# them the IP leaves those ports out); quanta, refresh and addresses are registers (firmware)
set_property -dict [list CONFIG.MAC_PORT0_TX_FLOW_C0 {1} CONFIG.MAC_PORT0_RX_FLOW_C0 {1}] [get_bd_cells $mrmac]
foreach k {MAC_PORT0_TX_FLOW_C0 MAC_PORT0_RX_FLOW_C0 MRMAC_MODE_C0 MRMAC_DATA_PATH_INTERFACE_C0 MRMAC_LOCATION_C0 FEC_SLICE0_CFG_C0 MAC_PORT0_RATE_C0 GT_REF_CLK_FREQ_C0} {
  catch { puts "INFO: MRMAC CONFIG.$k = [get_property CONFIG.$k [get_bd_cells $mrmac]]" }
}
connect_bd_net [get_bd_pins gt_quad_base_0/gtpowergood] [get_bd_pins $mrmac/gtpowergood_in]
foreach ch {0 1 2 3} {
  connect_bd_intf_net [get_bd_intf_pins $mrmac/gt_tx_serdes_interface_$ch] [get_bd_intf_pins gt_quad_base_0/TX${ch}_GT_IP_Interface]
  connect_bd_intf_net [get_bd_intf_pins $mrmac/gt_rx_serdes_interface_$ch] [get_bd_intf_pins gt_quad_base_0/RX${ch}_GT_IP_Interface]
}

# CAUI-4 GT clocking (the MRMAC 1x100GE example design / VCK190 Ethernet TRD, as both
# precedents): RX - every lane recovers its own clock: one full-rate (rx_core_clk,
# rx_serdes_clk) and one half-rate BUFG_GT (rx_alt_serdes_clk, the GT chN_rxusrclk) per lane
# (lanes 1-3 never lock on lane 0's clock); TX - the lanes share the TX PLL: lane 0's
# full-rate (tx_core_clk x4) and half-rate (tx_alt_serdes_clk, every chN_txusrclk) BUFG_GTs
const_cell bufg_gt_div_val 3 1
foreach ch {0 1 2 3} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:bufg_gt bufg_gt_rx$ch
  connect_bd_net [get_bd_pins gt_quad_base_0/ch${ch}_rxoutclk] [get_bd_pins bufg_gt_rx$ch/outclk]
  create_bd_cell -type ip -vlnv xilinx.com:ip:bufg_gt bufg_gt_rx_div2_$ch
  connect_bd_net [get_bd_pins gt_quad_base_0/ch${ch}_rxoutclk] [get_bd_pins bufg_gt_rx_div2_$ch/outclk]
  connect_bd_net [get_bd_pins bufg_gt_div_val/dout] [get_bd_pins bufg_gt_rx_div2_$ch/gt_bufgtdiv]
  connect_bd_net [get_bd_pins bufg_gt_rx_div2_$ch/usrclk] [get_bd_pins gt_quad_base_0/ch${ch}_rxusrclk]
}
create_bd_cell -type ip -vlnv xilinx.com:ip:bufg_gt bufg_gt_tx0
connect_bd_net [get_bd_pins gt_quad_base_0/ch0_txoutclk] [get_bd_pins bufg_gt_tx0/outclk]
create_bd_cell -type ip -vlnv xilinx.com:ip:bufg_gt bufg_gt_tx_div2_0
connect_bd_net [get_bd_pins gt_quad_base_0/ch0_txoutclk] [get_bd_pins bufg_gt_tx_div2_0/outclk]
connect_bd_net [get_bd_pins bufg_gt_div_val/dout] [get_bd_pins bufg_gt_tx_div2_0/gt_bufgtdiv]
foreach ch {0 1 2 3} {
  connect_bd_net [get_bd_pins bufg_gt_tx_div2_0/usrclk] [get_bd_pins gt_quad_base_0/ch${ch}_txusrclk]
}
foreach {cat pins srcfmt} {
  rx_serdes_clk_cat     {rx_core_clk rx_serdes_clk} bufg_gt_rx%d/usrclk
  rx_alt_serdes_clk_cat {rx_alt_serdes_clk}         bufg_gt_rx_div2_%d/usrclk
  tx_core_clk_cat       {tx_core_clk}               bufg_gt_tx0/usrclk
  tx_alt_serdes_clk_cat {tx_alt_serdes_clk}         bufg_gt_tx_div2_0/usrclk
} {
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 $cat
  set_property CONFIG.NUM_PORTS {4} [get_bd_cells $cat]
  foreach ch {0 1 2 3} {
    set src [expr {[string match *%d* $srcfmt] ? [format $srcfmt $ch] : $srcfmt}]
    connect_bd_net [get_bd_pins $src] [get_bd_pins $cat/In$ch]
  }
  foreach p $pins { connect_bd_net [get_bd_pins $cat/dout] [get_bd_pins $mrmac/$p] }
}
# AXIS client clocks (4-bit buses from the one free-running 390.625 MHz net)
connect_bd_net [get_bd_pins $axis_clk] [get_bd_pins $mrmac/tx_axi_clk]
connect_bd_net [get_bd_pins $axis_clk] [get_bd_pins $mrmac/rx_axi_clk]
# MRMAC core / serdes resets: released by GT reset-done (per lane; both precedents), unless
# the adapter drives them (then its gt_*_reset_done_out inputs are connected by name below)
foreach dir {rx tx} {
  if {![mac_drives ${dir}_core_reset]} {
    create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilvector_logic:1.0 logic_${dir}_reset
    set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {4}] [get_bd_cells logic_${dir}_reset]
    connect_bd_net [get_bd_pins $mrmac/gt_${dir}_reset_done_out] [get_bd_pins logic_${dir}_reset/Op1]
    connect_bd_net [get_bd_pins logic_${dir}_reset/Res] [get_bd_pins $mrmac/${dir}_core_reset]
    connect_bd_net [get_bd_pins logic_${dir}_reset/Res] [get_bd_pins $mrmac/${dir}_serdes_reset]
  }
  # all four lanes out of reset -> the always-on block (gt_tx_ready / gt_rx_ready), unless
  # the adapter reports them itself
  if {![mac_drives gt_${dir}_ready]} {
    create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilreduced_logic:1.0 and_gt_${dir}_done
    set_property -dict [list CONFIG.C_OPERATION {and} CONFIG.C_SIZE {4}] [get_bd_cells and_gt_${dir}_done]
    connect_bd_net [get_bd_pins $mrmac/gt_${dir}_reset_done_out] [get_bd_pins and_gt_${dir}_done/Op1]
    set gt_ready_src($dir) and_gt_${dir}_done/Res
  } else {
    set gt_ready_src($dir) mac0/gt_${dir}_ready
  }
}
set gt_pg_src [expr {[mac_drives gt_powergood] ? "mac0/gt_powergood" : "gt_quad_base_0/gtpowergood"}]
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilvector_logic:1.0 logic_not_rstn
set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] [get_bd_cells logic_not_rstn]
connect_bd_net [get_bd_pins rst_sys/peripheral_aresetn] [get_bd_pins logic_not_rstn/Op1]
fan4 flexif_rst_cat logic_not_rstn/Res $mrmac/rx_flexif_reset
# unused: FlexE / timestamp clocks, pm_tick, the GT TX / RX datapath resets
foreach p {tx_flexif_clk rx_flexif_clk tx_ts_clk rx_ts_clk pm_tick} {
  connect_bd_net [get_bd_pins const_zero4/dout] [get_bd_pins $mrmac/$p]
}
foreach p {gt_reset_tx_datapath_in gt_reset_rx_datapath_in} {
  connect_bd_net [get_bd_pins const_zero4/dout] [get_bd_pins $mrmac/$p]
}

#########################################################
# MAC adapter mac0: MRMAC side by name
#########################################################
# MRMAC side by name: a mac0 pin named like an MRMAC pin (exactly, or without the "_0" port
# suffix) connects to it, then likewise to a gt_quad_base_0 pin (e.g. chN_loopback); direction
# from the adapter's pin. Engine-side pins below.
set mac_known {eng_clk clk axis_clk sys_clk ctl_clk gt_reset mac_reset gt_tx_ready gt_rx_ready \
               gt_powergood mac_ctl mac_pz mac_addr mac_stat mac_ev mac_pause mac_lane mac_lev}
set mac_unmatched {}
set mac_auto 0
foreach p [get_bd_pins -of_objects [get_bd_cells mac0]] {
  set n [get_property NAME $p]
  if {[lsearch -exact $mac_known $n] >= 0} { continue }
  # members of the engine-side S_AXIS_TX / M_AXIS_RX interfaces (connected as interfaces)
  if {[regexp {^(tx|rx)_t(data|keep|valid|ready|last|user)$} $n]} { continue }
  set peer ""
  foreach c [list $mrmac/$n $mrmac/${n}_0 gt_quad_base_0/$n] {
    set q [get_bd_pins -quiet $c]
    if {$q ne ""} { set peer $q; break }
  }
  if {$peer eq ""} { lappend mac_unmatched $n; continue }
  if {[get_property DIR $p] eq "O"} {
    connect_bd_net $p $peer
  } else {
    connect_bd_net $peer $p
  }
  incr mac_auto
}
puts "INFO: mac0 <-> MRMAC / GT quad: $mac_auto pin(s) connected by name"
if {[llength $mac_unmatched]} {
  # TODO(M1-A reconciliation): adapter pins that match no MRMAC / GT pin
  puts "CRITICAL WARNING: \[bd_versal\] mac0 pins with no MRMAC / GT quad pin of that name (left open): $mac_unmatched"
}
foreach n {eng_clk clk} {
  if {[get_bd_pins -quiet mac0/$n] ne ""} { connect_bd_net [get_bd_pins $eng_clk] [get_bd_pins mac0/$n] }
}
foreach {n src} [list axis_clk $axis_clk sys_clk $sys_clk ctl_clk $sys_clk gt_tx_ready $gt_ready_src(tx) \
                      gt_rx_ready $gt_ready_src(rx) gt_powergood $gt_pg_src] {
  set p [get_bd_pins -quiet mac0/$n]
  if {$p ne "" && [get_property DIR $p] eq "I"} { connect_bd_net [get_bd_pins $src] $p }
}
# MRMAC AXI-Lite (clk_sys) connected last: wiring the 100 MHz control clock before the AXIS
# client makes the MRMAC client report a 4-segment PHASE (validate error; both precedents)
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins $mrmac/s_axi_aclk]
connect_bd_net [get_bd_pins rst_sys/peripheral_aresetn] [get_bd_pins $mrmac/s_axi_aresetn]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M04_AXI] [get_bd_intf_pins $mrmac/s_axi]

#########################################################
# Always-on block + clock guard (clk_sys <-> clk_eng)
#########################################################
create_bd_cell -type module -reference rsys_aon_bd rsys_aon_0
# CAPS: [7:0] link Gb/s [15:8] MAC width / 8 [19:16] MAC type (1 CMAC 2 omac_10g 3 omac_40g
# 4 MRMAC) [23:20] QSFP port [24] PS DDR window [25] netdev DMA channel [26] clock guard
set mac_code [dict get {cmac 1 omac_10g 2 omac_40g 3 mrmac 4} $mac_type]
set caps [expr {$link_gbps | (($mac_width / 8) << 8) | ($mac_code << 16) | ($port << 20) | ($ddr_en << 24) | ($odma_en << 25) | (1 << 26)}]
# target id: the first four characters of the label ("VCK1")
set tid 0
foreach c [split [string toupper [string range ${target}0000 0 3]] ""] { set tid [expr {($tid << 8) | [scan $c %c]}] }
set build_id [clock seconds]
set_property -dict [list CONFIG.PL_CLK_KHZ {100000} CONFIG.BUILD_ID $build_id CONFIG.TARGET_ID $tid CONFIG.CAPS $caps] [get_bd_cells rsys_aon_0]
puts "INFO: rsys_aon CAPS [format 0x%08X $caps], target id [format 0x%08X $tid], build id $build_id"
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins rsys_aon_0/clk]
connect_bd_net [get_bd_pins rst_sys/peripheral_reset] [get_bd_pins rsys_aon_0/rst]
connect_bd_net [get_bd_pins $eng_clk] [get_bd_pins rsys_aon_0/mac_clk]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] [get_bd_intf_pins rsys_aon_0/S_AXIL]
# GT reset (held by the always-on block until software has the Si5328 at 322.265625 MHz) ->
# the quad's reset sequencer through the MRMAC (gt_reset_all_in, every lane): through the
# adapter when it has a gt_reset input (it then drives gt_reset_all_in), else directly
if {[get_bd_pins -quiet mac0/gt_reset] ne ""} {
  connect_bd_net [get_bd_pins rsys_aon_0/gt_reset] [get_bd_pins mac0/gt_reset]
}
if {![mac_drives gt_reset_all_in]} {
  fan4 gt_rst_cat rsys_aon_0/gt_reset $mrmac/gt_reset_all_in
}
connect_bd_net [get_bd_pins rsys_aon_0/mac_reset] [get_bd_pins mac0/mac_reset]
connect_bd_net [get_bd_pins $gt_pg_src] [get_bd_pins rsys_aon_0/gt_powergood]
connect_bd_net [get_bd_pins $gt_ready_src(tx)] [get_bd_pins rsys_aon_0/gt_tx_ready]
connect_bd_net [get_bd_pins $gt_ready_src(rx)] [get_bd_pins rsys_aon_0/gt_rx_ready]
foreach {n w} {mac_lane 32 mac_lev 6} {
  if {[get_bd_pins -quiet mac0/$n] ne ""} {
    connect_bd_net [get_bd_pins mac0/$n] [get_bd_pins rsys_aon_0/$n]
  } else {
    connect_bd_net [const_cell const_$n $w 0] [get_bd_pins rsys_aon_0/$n]
  }
}
lappend intr_list rsys_aon_0/irq

#########################################################
# rocelet_sys (engine clock)
#########################################################
create_bd_cell -type module -reference rocelet_sys_bd rocelet_sys_0
set cfg [list CONFIG.SELFTEST $selftest CONFIG.RSFEC [expr {$fec eq "rs" ? 1 : 0}]]
dict for {k v} $eng_params { lappend cfg CONFIG.$k $v }
set_property -dict $cfg [get_bd_cells rocelet_sys_0]
connect_bd_net [get_bd_pins $eng_clk] [get_bd_pins rocelet_sys_0/clk]
connect_bd_net [get_bd_pins $gen_clk] [get_bd_pins rocelet_sys_0/gen_clk]
connect_bd_net [get_bd_pins $dma_clk] [get_bd_pins rocelet_sys_0/dma_clk]
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilvector_logic:1.0 sys_rst_or
set_property -dict [list CONFIG.C_OPERATION {or} CONFIG.C_SIZE {1}] [get_bd_cells sys_rst_or]
connect_bd_net [get_bd_pins rst_sys/peripheral_reset] [get_bd_pins sys_rst_or/Op1]
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

#########################################################
# NoC ports: DDR window (clk_eng) and netdev DMA (clk_dma) -> the DDR4 controller
#########################################################
# The CIPS automation uses S00..S05 / aclk0..5. Added: S06 = DDR window writes, S07 = DDR
# window reads (512 bits, aclk6 = clk_eng), S08 = AXI DMA (aclk7 = clk_dma). One destination
# (one MC port) per NMU: the first-generation NoC orders an NMU's writes strictly, and an NMU
# spread over two controllers collapsed to ~2 GB/s on this board (fpga-drive-nvme-offload).
# QoS: 12500 MB/s per direction = 100G line rate (one 512-bit NMU measured 14.5 GB/s each way
# on this DIMM); the DMA asks for 1600 MB/s each way (Linux TCP rate, nvme-host pattern).
set noc_si   [get_property CONFIG.NUM_SI [get_bd_cells axi_noc_0]]
set noc_clks [get_property CONFIG.NUM_CLKS [get_bd_cells axi_noc_0]]
set ddr_qos 12500
set noc_ports {}
if {$ddr_en} {
  lappend noc_ports w $eng_clk 512 MC_2 [format {read_bw {5} write_bw {%d} read_avg_burst {64} write_avg_burst {64}} $ddr_qos]
  lappend noc_ports r $eng_clk 512 MC_3 [format {read_bw {%d} write_bw {5} read_avg_burst {64} write_avg_burst {64}} $ddr_qos]
}
if {$odma_en} {
  lappend noc_ports dma $dma_clk 64 MC_1 {read_bw {1600} write_bw {1600} read_avg_burst {16} write_avg_burst {16}}
}
set n_new [expr {[llength $noc_ports] / 5}]
set clk_list {}
foreach {tag clk w mc qos} $noc_ports { if {[lsearch -exact $clk_list $clk] < 0} { lappend clk_list $clk } }
set_property -dict [list CONFIG.NUM_SI [expr {$noc_si + $n_new}] CONFIG.NUM_CLKS [expr {$noc_clks + [llength $clk_list]}]] [get_bd_cells axi_noc_0]
array set clk_busif {}
set i $noc_si
foreach {tag clk w mc qos} $noc_ports {
  set si [format "S%02d_AXI" $i]
  set_property -dict [list CONFIG.DATA_WIDTH $w CONFIG.CATEGORY {pl} CONFIG.CONNECTIONS [list $mc $qos]] [get_bd_intf_pins /axi_noc_0/$si]
  set noc_si_of($tag) $si
  lappend clk_busif($clk) $si
  puts "INFO: NoC $si ($tag, $w bits, [file tail $clk]) -> $mc: $qos"
  incr i
}
set k $noc_clks
foreach clk $clk_list {
  connect_bd_net [get_bd_pins $clk] [get_bd_pins axi_noc_0/aclk$k]
  set_property CONFIG.ASSOCIATED_BUSIF [join $clk_busif($clk) ":"] [get_bd_pins axi_noc_0/aclk$k]
  incr k
}

# DDR window: rocelet_sys M_AXI_DDRW / M_AXI_DDRR (512 bits, 40-bit addresses, clk_eng) ->
# 1:1 SmartConnects (write-only / read-only masters onto a full AXI4 NoC port, 40 -> 64-bit
# addresses; no clock or width conversion) -> S06 / S07
if {$ddr_en} {
  foreach dir {w r} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smc_ddr$dir
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {1}] [get_bd_cells smc_ddr$dir]
    connect_bd_net [get_bd_pins $eng_clk] [get_bd_pins smc_ddr$dir/aclk]
    connect_bd_net [get_bd_pins rst_eng/interconnect_aresetn] [get_bd_pins smc_ddr$dir/aresetn]
    connect_bd_intf_net [get_bd_intf_pins rocelet_sys_0/M_AXI_DDR[string toupper $dir]] [get_bd_intf_pins smc_ddr$dir/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins smc_ddr$dir/M00_AXI] [get_bd_intf_pins axi_noc_0/$noc_si_of($dir)]
  }
}

# netdev DMA channel: rocelet_sys M_AXIS_ORX (512) -> 64-bit -> AXI DMA S2MM, AXI DMA MM2S ->
# 512-bit -> rocelet_sys S_AXIS_OTX; DMA masters (64-bit addressing: Linux memory reaches
# 0x500_0000_0000 + 6 GB) -> SmartConnect -> S08
if {$odma_en} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma axi_dma_0
  set_property -dict [list \
    CONFIG.c_include_sg {1} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_sg_length_width {16} \
    CONFIG.c_addr_width {64} \
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
    connect_bd_net [get_bd_pins $dma_clk] [get_bd_pins axi_dma_0/$p]
  }
  connect_bd_net [get_bd_pins rst_sys/peripheral_aresetn] [get_bd_pins axi_dma_0/axi_resetn]
  connect_bd_intf_net [get_bd_intf_pins axi_smc/M03_AXI] [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

  create_bd_cell -type ip -vlnv xilinx.com:ip:axis_dwidth_converter odma_rx_dw
  set_property -dict [list CONFIG.S_TDATA_NUM_BYTES {64} CONFIG.M_TDATA_NUM_BYTES {8} CONFIG.HAS_TLAST {1} CONFIG.HAS_TKEEP {1}] [get_bd_cells odma_rx_dw]
  create_bd_cell -type ip -vlnv xilinx.com:ip:axis_dwidth_converter odma_tx_dw
  set_property -dict [list CONFIG.S_TDATA_NUM_BYTES {8} CONFIG.M_TDATA_NUM_BYTES {64} CONFIG.HAS_TLAST {1} CONFIG.HAS_TKEEP {1}] [get_bd_cells odma_tx_dw]
  foreach c {odma_rx_dw odma_tx_dw} {
    connect_bd_net [get_bd_pins $dma_clk] [get_bd_pins $c/aclk]
    connect_bd_net [get_bd_pins rst_dma/peripheral_aresetn] [get_bd_pins $c/aresetn]
  }
  connect_bd_intf_net [get_bd_intf_pins rocelet_sys_0/M_AXIS_ORX] [get_bd_intf_pins odma_rx_dw/S_AXIS]
  connect_bd_intf_net [get_bd_intf_pins odma_rx_dw/M_AXIS] [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]
  connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] [get_bd_intf_pins odma_tx_dw/S_AXIS]
  connect_bd_intf_net [get_bd_intf_pins odma_tx_dw/M_AXIS] [get_bd_intf_pins rocelet_sys_0/S_AXIS_OTX]

  create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smc_dma
  set_property -dict [list CONFIG.NUM_SI {3} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {1}] [get_bd_cells smc_dma]
  connect_bd_net [get_bd_pins $dma_clk] [get_bd_pins smc_dma/aclk]
  connect_bd_net [get_bd_pins rst_dma/interconnect_aresetn] [get_bd_pins smc_dma/aresetn]
  connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_SG]   [get_bd_intf_pins smc_dma/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] [get_bd_intf_pins smc_dma/S01_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] [get_bd_intf_pins smc_dma/S02_AXI]
  connect_bd_intf_net [get_bd_intf_pins smc_dma/M00_AXI] [get_bd_intf_pins axi_noc_0/$noc_si_of(dma)]
  lappend intr_list axi_dma_0/mm2s_introut axi_dma_0/s2mm_introut
}

#########################################################
# I2C: Si5328 (GT reference clock) and the QSFP0 module (PL pins on the FMC LA bank)
#########################################################
foreach {iic port mi} {axi_iic_clk clk_i2c M01_AXI axi_iic_qsfp0 qsfp0_i2c M02_AXI} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic $iic
  connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins $iic/s_axi_aclk]
  connect_bd_net [get_bd_pins rst_sys/peripheral_aresetn] [get_bd_pins $iic/s_axi_aresetn]
  connect_bd_intf_net [get_bd_intf_pins axi_smc/$mi] [get_bd_intf_pins $iic/S_AXI]
  create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 $port
  connect_bd_intf_net [get_bd_intf_ports $port] [get_bd_intf_pins $iic/IIC]
  lappend intr_list $iic/iic2intc_irpt
}

#########################################################
# QSFP0 module lines, LEDs, Si5328 LOS (always-on block); QSFP1 held
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
foreach {port net} {modsell const_high resetl const_low lpmode const_high grn_led const_low red_led const_low} {
  create_bd_port -dir O ${port}_qsfp1
  connect_bd_net [get_bd_pins ${net}/dout] [get_bd_ports ${port}_qsfp1]
}

#########################################################
# Interrupts: one CIPS pl_ps_irqN pin each, in the ZCU106's pl_ps_irq0 bit order
#   pl_ps_irq0 rsys_aon (aggregated)  1 DMA MM2S  2 DMA S2MM  3 Si5328 IIC  4 QSFP0 IIC
#########################################################
set i 0
foreach intr $intr_list {
  connect_bd_net [get_bd_pins $intr] [get_bd_pins $cips/pl_ps_irq$i]
  incr i
}
puts "INFO: pl_ps_irq0..[expr {$i - 1}]: $intr_list"

#########################################################
# Addresses (M_AXI_LPD, as the ZCU106's M_AXI_HPM0_LPD): 0x8000_0000 always-on block +
# rocelet_sys (1 MB), 0x8010_0000 Si5328 IIC, 0x8011_0000 QSFP0 IIC, 0x8012_0000 AXI DMA,
# 0x8013_0000 MRMAC (64 KB), 0x8014_0000 GT quad APB (64 KB)
#########################################################
set lpd_space [get_bd_addr_spaces $cips/M_AXI_LPD]
foreach {intf off rng} {rsys_aon_0/S_AXIL 0x80000000 1M axi_iic_clk/S_AXI 0x80100000 64K \
                        axi_iic_qsfp0/S_AXI 0x80110000 64K axi_dma_0/S_AXI_LITE 0x80120000 64K \
                        mrmac_0/s_axi 0x80130000 64K axi_apb_bridge_0/AXI4_LITE 0x80140000 64K} {
  set segs [get_bd_addr_segs -quiet -of_objects [get_bd_intf_pins -quiet $intf]]
  if {[llength $segs]} {
    assign_bd_address -offset $off -range $rng -target_address_space $lpd_space $segs
  }
}
# the DDR window masters' view: DDR_LOW0 only (their 40-bit address reaches the 2 GB at 0x0,
# where the reserved-memory region lives; DDR_CH1 at 0x500_0000_0000 is out of reach)
assign_bd_address
foreach dir {W R} {
  set sp [get_bd_addr_spaces -quiet rocelet_sys_0/M_AXI_DDR$dir]
  if {$sp eq ""} { continue }
  foreach seg [get_bd_addr_segs -quiet -of_objects $sp] {
    if {[get_property OFFSET $seg] >= 0x10000000000} {
      puts "INFO: excluding $seg ([get_property OFFSET $seg]) from the 40-bit DDR window master"
      exclude_bd_addr_seg $seg
    }
  }
}
foreach seg [get_bd_addr_segs -quiet] { puts "INFO: address segment $seg" }

regenerate_bd_layout
save_bd_design
validate_bd_design
save_bd_design
