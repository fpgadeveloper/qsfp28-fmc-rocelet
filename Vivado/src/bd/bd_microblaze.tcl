################################################################
# Block design: rocelet RoCE v2 reference design for KCU116 + OP120
#
# Sourced by scripts/build.tcl, which sets: block_name, target, port (QSFP28 port
# of the OP120; the KCU116 HPC routes port 0 only), fec ("rs" or "none": the
# reset value of the RS-FEC control bit), selftest (1 = include the self-test
# logic) and eng_params (rocelet_sys_bd parameters from config/data.json).
#
#   300 MHz board clock -> clk_wiz -> 100 MHz system clock (MicroBlaze, peripherals,
#     CMAC init/DRP clock) and 200 MHz generator clock (rocelet_sys gen_clk: the HSB
#     producer's IQ16 generator and the device DNA reader)
#   MicroBlaze (local memory only) + UART 16550 + timer + Si5328 I2C (GT reference
#     clock) + QSFP0 I2C + QSFP0 GPIO (module control and CMAC reset out; CMAC and
#     engine status in)
#   cmac_usplus (UltraScale+ 100G Ethernet hard block, CAUI-4 on FMC DP0-3 = GTY
#     quad X0Y12-15, CMACE4_X0Y0; AXI-Stream user interface on gt_txusrclk2;
#     RS-FEC built in; no auto-negotiation). Its optional AXI-Lite register and
#     statistics block is NOT built: the CMAC is configured through its static
#     ctl_* ports, driven by rocelet_sys registers, and a few fabric counters
#     replace the statistics.
#   cmac_adapt (module reference mac_cmac_adapt): the CMAC's ctl_* / stat_* ports
#     behind rocelet_sys's generic MAC boundary (mac_ctl / mac_pz out, mac_stat /
#     mac_ev / mac_pause in), combinational
#   rocelet_sys_0 (module reference rocelet_sys_bd): the rocelet engine
#     (submodules/rocelet), its on-chip memory window, the firmware work-request
#     queue and (selftest) the self-test logic, all on the CMAC user clock
#     (322.265625 MHz); its AXI-Lite slave crosses from the 100 MHz system clock
#     in the SmartConnect.
# The CMAC / MicroBlaze / OP120 parts follow the hardware-proven kcu116 target of
# the Opsero 2x-qsfp28-fmc design.
################################################################

create_bd_design $block_name
current_bd_design $block_name

#########################################################
# Clocks and resets
#########################################################
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_0
set_property -dict [list CONFIG.CLK_IN1_BOARD_INTERFACE {default_sysclk1_300} \
                         CONFIG.RESET_BOARD_INTERFACE {reset} CONFIG.USE_BOARD_FLOW {true}] [get_bd_cells clk_wiz_0]
apply_bd_automation -rule xilinx.com:bd_rule:board -config { Board_Interface {default_sysclk1_300 ( 300 MHz System differential clock ) } Manual_Source {Auto}}  [get_bd_intf_pins clk_wiz_0/CLK_IN1_D]
apply_bd_automation -rule xilinx.com:bd_rule:board -config { Board_Interface {reset ( FPGA Reset ) } Manual_Source {Auto}}  [get_bd_pins clk_wiz_0/reset]
set_property -dict [list CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000}] [get_bd_cells clk_wiz_0]
# 200 MHz generator clock of rocelet_sys (HSB producer's IQ16 generator, device DNA)
set_property -dict [list CONFIG.CLKOUT2_USED {true} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {200.000}] [get_bd_cells clk_wiz_0]

#########################################################
# MicroBlaze (local memory only)
#########################################################
create_bd_cell -type ip -vlnv xilinx.com:ip:microblaze microblaze_0
apply_bd_automation -rule xilinx.com:bd_rule:microblaze -config { axi_intc {0} axi_periph {Enabled} cache {None} clk {/clk_wiz_0/clk_out1 (100 MHz)} cores {1} debug_module {Debug Only} ecc {None} local_mem {128KB} preset {None}}  [get_bd_cells microblaze_0]
set_property -dict [list \
  CONFIG.C_USE_BARREL {1} \
  CONFIG.C_USE_HW_MUL {2} \
  CONFIG.C_USE_DIV {1} \
  CONFIG.C_USE_MSR_INSTR {1} \
  CONFIG.C_USE_PCMP_INSTR {1} \
] [get_bd_cells microblaze_0]

set sys_clk     "clk_wiz_0/clk_out1"
set rst_cell    [get_bd_cells -filter {VLNV =~ "*proc_sys_reset*"}]
set periph_rstn "$rst_cell/peripheral_aresetn"
set periph_rst  "$rst_cell/peripheral_reset"

# peripheral interconnect: 6 masters and a second clock for rocelet_sys (CMAC
# user clock); created here if the automation did not make one
if {[llength [get_bd_cells -quiet microblaze_0_axi_periph]] == 0} {
  set_property CONFIG.C_D_AXI {1} [get_bd_cells microblaze_0]
  create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect microblaze_0_axi_periph
  set_property CONFIG.NUM_SI {1} [get_bd_cells microblaze_0_axi_periph]
  connect_bd_intf_net [get_bd_intf_pins microblaze_0/M_AXI_DP] [get_bd_intf_pins microblaze_0_axi_periph/S00_AXI]
  connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins microblaze_0_axi_periph/aclk]
  connect_bd_net [get_bd_pins $rst_cell/interconnect_aresetn] [get_bd_pins microblaze_0_axi_periph/aresetn]
}
set periph [get_bd_cells microblaze_0_axi_periph]
set periph_vlnv [get_property VLNV $periph]
puts "INFO: peripheral interconnect $periph_vlnv"
set n_mi 6
if {[string match "*smartconnect*" $periph_vlnv]} {
  set_property -dict [list CONFIG.NUM_MI $n_mi CONFIG.NUM_CLKS {2}] $periph
} else {
  set_property CONFIG.NUM_MI $n_mi $periph
}

proc periph_m {i} { return [get_bd_intf_pins microblaze_0_axi_periph/M[format "%02d" $i]_AXI] }

# axi_interconnect (if that is what the automation made) needs a clock/reset per master
proc periph_clk {i clk rstn} {
  global periph_vlnv
  if {![string match "*smartconnect*" $periph_vlnv]} {
    connect_bd_net [get_bd_pins $clk]  [get_bd_pins microblaze_0_axi_periph/M[format "%02d" $i]_ACLK]
    connect_bd_net [get_bd_pins $rstn] [get_bd_pins microblaze_0_axi_periph/M[format "%02d" $i]_ARESETN]
  }
}

# constants
proc const_cell {name width val} {
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 $name
  set_property -dict [list CONFIG.CONST_WIDTH $width CONFIG.CONST_VAL $val] [get_bd_cells $name]
  return [get_bd_pins $name/dout]
}
const_cell const_low 1 0
const_cell const_high 1 1

#########################################################
# UART, timer
#########################################################
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uart16550 axi_uart16550_0
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins axi_uart16550_0/s_axi_aclk]
connect_bd_net [get_bd_pins $periph_rstn] [get_bd_pins axi_uart16550_0/s_axi_aresetn]
connect_bd_intf_net [get_bd_intf_pins axi_uart16550_0/S_AXI] [periph_m 0]
periph_clk 0 $sys_clk $periph_rstn
apply_bd_automation -rule xilinx.com:bd_rule:board -config { Board_Interface {rs232_uart ( UART ) } Manual_Source {Auto}}  [get_bd_intf_pins axi_uart16550_0/UART]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_timer axi_timer_0
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins axi_timer_0/s_axi_aclk]
connect_bd_net [get_bd_pins $periph_rstn] [get_bd_pins axi_timer_0/s_axi_aresetn]
connect_bd_intf_net [get_bd_intf_pins axi_timer_0/S_AXI] [periph_m 1]
periph_clk 1 $sys_clk $periph_rstn

#########################################################
# I2C: Si5328 (GT refclk) and QSFP0 module
#########################################################
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic axi_iic_clk
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins axi_iic_clk/s_axi_aclk]
connect_bd_net [get_bd_pins $periph_rstn] [get_bd_pins axi_iic_clk/s_axi_aresetn]
connect_bd_intf_net [get_bd_intf_pins axi_iic_clk/S_AXI] [periph_m 2]
periph_clk 2 $sys_clk $periph_rstn
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 clk_i2c
connect_bd_intf_net [get_bd_intf_ports clk_i2c] [get_bd_intf_pins axi_iic_clk/IIC]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic axi_iic_qsfp0
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins axi_iic_qsfp0/s_axi_aclk]
connect_bd_net [get_bd_pins $periph_rstn] [get_bd_pins axi_iic_qsfp0/s_axi_aresetn]
connect_bd_intf_net [get_bd_intf_pins axi_iic_qsfp0/S_AXI] [periph_m 3]
periph_clk 3 $sys_clk $periph_rstn
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 qsfp0_i2c
connect_bd_intf_net [get_bd_intf_ports qsfp0_i2c] [get_bd_intf_pins axi_iic_qsfp0/IIC]

#########################################################
# QSFP0 GPIO: ch1 out {cmac_reset, lpmode, resetl, modsell} (default 0x2: selected,
# out of reset, high power, CMAC not held in reset);
# ch2 in {engine irq, rx_aligned, usr_rx_reset, usr_tx_reset, intl, modprsl}
#########################################################
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_qsfp0
set_property -dict [list \
  CONFIG.C_GPIO_WIDTH {4} \
  CONFIG.C_GPIO2_WIDTH {6} \
  CONFIG.C_ALL_OUTPUTS {1} \
  CONFIG.C_ALL_INPUTS_2 {1} \
  CONFIG.C_IS_DUAL {1} \
  CONFIG.C_DOUT_DEFAULT {0x00000002} \
] [get_bd_cells axi_gpio_qsfp0]
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins axi_gpio_qsfp0/s_axi_aclk]
connect_bd_net [get_bd_pins $periph_rstn] [get_bd_pins axi_gpio_qsfp0/s_axi_aresetn]
connect_bd_intf_net [get_bd_intf_pins axi_gpio_qsfp0/S_AXI] [periph_m 4]
periph_clk 4 $sys_clk $periph_rstn

foreach {name bit} {modsell 0 resetl 1 lpmode 2 cmac_rst 3} {
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilslice:1.0 slice_$name
  set_property -dict [list CONFIG.DIN_WIDTH {4} CONFIG.DIN_FROM $bit CONFIG.DIN_TO $bit CONFIG.DOUT_WIDTH {1}] [get_bd_cells slice_$name]
  connect_bd_net [get_bd_pins axi_gpio_qsfp0/gpio_io_o] [get_bd_pins slice_$name/Din]
  if {$name ne "cmac_rst"} {
    create_bd_port -dir O -from 0 -to 0 ${name}_qsfp0
    connect_bd_net [get_bd_pins slice_$name/Dout] [get_bd_ports ${name}_qsfp0]
  }
}

#########################################################
# CMAC 100G (port 0 of the OP120 = FMC DP0-3)
# Placement from data.json (scripts/build.tcl): cmac_core = the CMAC site, cmac_gt_group =
# the quad of gt_channels (lowest~highest site; the IP numbers the lanes in ascending site
# order, qsfp0_gt[i] = channel i, the XDC pins follow it)
#########################################################
create_bd_cell -type ip -vlnv xilinx.com:ip:cmac_usplus cmac
set_property -dict [list \
  CONFIG.CMAC_CAUI4_MODE {1} \
  CONFIG.NUM_LANES {4x25} \
  CONFIG.GT_REF_CLK_FREQ {322.265625} \
  CONFIG.GT_DRP_CLK {100.00} \
  CONFIG.USER_INTERFACE {AXIS} \
  CONFIG.ENABLE_AXI_INTERFACE {0} \
  CONFIG.INCLUDE_STATISTICS_COUNTERS {0} \
  CONFIG.INCLUDE_RS_FEC {1} \
  CONFIG.INCLUDE_AUTO_NEG_LT_LOGIC {0} \
  CONFIG.TX_FLOW_CONTROL {1} \
  CONFIG.RX_FLOW_CONTROL {1} \
  CONFIG.CMAC_CORE_SELECT $cmac_core \
  CONFIG.GT_GROUP_SELECT $cmac_gt_group \
] [get_bd_cells cmac]
# 802.3x PAUSE frames sent by the CMAC carry the FPGA's MAC as source address
# (default 00:00:00:00:00:00); the firmware's default MAC is 02:0a:35:72:6c:01
if {[catch {set_property CONFIG.TX_SA_GPP {0x020A35726C01} [get_bd_cells cmac]} err]} {
  puts "WARNING: CMAC TX_SA_GPP not set ($err)"
}
foreach k {TX_FRAME_CRC_CHECKING RX_FRAME_CRC_CHECKING RX_MAX_PACKET_LEN TX_IPG_VALUE RX_CHECK_ACK RX_FORWARD_CONTROL_FRAMES} {
  catch { puts "INFO: CMAC CONFIG.$k = [get_property CONFIG.$k [get_bd_cells cmac]]" }
}

create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 gt_ref_clk_0
set_property CONFIG.FREQ_HZ 322265625 [get_bd_intf_ports gt_ref_clk_0]
connect_bd_intf_net [get_bd_intf_ports gt_ref_clk_0] [get_bd_intf_pins cmac/gt_ref_clk]
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:gt_rtl:1.0 qsfp0_gt
connect_bd_intf_net [get_bd_intf_pins cmac/gt_serial_port] [get_bd_intf_ports qsfp0_gt]

connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins cmac/init_clk]
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins cmac/drp_clk]
connect_bd_net [get_bd_pins cmac/gt_txusrclk2] [get_bd_pins cmac/rx_clk]

# CMAC reset: system reset or the firmware's GPIO bit (relink, RS-FEC change)
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilvector_logic:1.0 cmac_rst_or
set_property -dict [list CONFIG.C_OPERATION {or} CONFIG.C_SIZE {1}] [get_bd_cells cmac_rst_or]
connect_bd_net [get_bd_pins $periph_rst] [get_bd_pins cmac_rst_or/Op1]
connect_bd_net [get_bd_pins slice_cmac_rst/Dout] [get_bd_pins cmac_rst_or/Op2]
connect_bd_net [get_bd_pins cmac_rst_or/Res] [get_bd_pins cmac/sys_reset]

#########################################################
# rocelet_sys: rocelet engine + memory window + firmware WR queue (+ self-test)
#########################################################
create_bd_cell -type module -reference rocelet_sys_bd rocelet_sys_0
set cfg [list CONFIG.SELFTEST $selftest CONFIG.RSFEC [expr {$fec eq "rs" ? 1 : 0}]]
dict for {k v} $eng_params { lappend cfg CONFIG.$k $v }
set_property -dict $cfg [get_bd_cells rocelet_sys_0]

connect_bd_net [get_bd_pins cmac/gt_txusrclk2] [get_bd_pins rocelet_sys_0/clk]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins rocelet_sys_0/gen_clk]
connect_bd_net [get_bd_pins $periph_rst] [get_bd_pins rocelet_sys_0/sys_rst]
# no netdev DMA channel on this target: its clock input is tied to the system clock, its
# frame input to idle and its frame output to ready
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins rocelet_sys_0/dma_clk]
connect_bd_net [get_bd_pins const_low/dout] [get_bd_pins rocelet_sys_0/s_axis_otx_tvalid]
connect_bd_net [get_bd_pins const_high/dout] [get_bd_pins rocelet_sys_0/m_axis_orx_tready]

# AXI-Lite (512 KB window: engine registers, system registers, memory window)
connect_bd_intf_net [get_bd_intf_pins rocelet_sys_0/S_AXIL] [periph_m 5]
if {[string match "*smartconnect*" $periph_vlnv]} {
  connect_bd_net [get_bd_pins cmac/gt_txusrclk2] [get_bd_pins microblaze_0_axi_periph/aclk1]
} else {
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_mac
  connect_bd_net [get_bd_pins cmac/gt_txusrclk2] [get_bd_pins rst_mac/slowest_sync_clk]
  connect_bd_net [get_bd_pins $periph_rstn] [get_bd_pins rst_mac/ext_reset_in]
  periph_clk 5 cmac/gt_txusrclk2 rst_mac/peripheral_aresetn
}

# AXI-Streams: try whole interfaces, fall back to pins
if {[catch {connect_bd_intf_net [get_bd_intf_pins cmac/axis_rx] [get_bd_intf_pins rocelet_sys_0/S_AXIS_RX]} err]} {
  puts "INFO: axis_rx by pins ($err)"
  foreach {a b} {rx_axis_tdata rx_tdata rx_axis_tkeep rx_tkeep rx_axis_tvalid rx_tvalid rx_axis_tlast rx_tlast rx_axis_tuser rx_tuser} {
    connect_bd_net [get_bd_pins cmac/$a] [get_bd_pins rocelet_sys_0/$b]
  }
}
if {[catch {connect_bd_intf_net [get_bd_intf_pins rocelet_sys_0/M_AXIS_TX] [get_bd_intf_pins cmac/axis_tx]} err]} {
  puts "INFO: axis_tx by pins ($err)"
  foreach {a b} {tx_axis_tdata tx_tdata tx_axis_tkeep tx_tkeep tx_axis_tvalid tx_tvalid tx_axis_tlast tx_tlast tx_axis_tuser tx_tuser tx_axis_tready tx_tready} {
    connect_bd_net [get_bd_pins rocelet_sys_0/$b] [get_bd_pins cmac/$a]
  }
}

# generic MAC boundary <-> CMAC: the adapter (802.3x flow control: received PAUSE honoured by
# the engine's TX gate, PAUSE requests from the engine's RX FIFO level; static control from
# rocelet_sys C_MAC_CTL / C_MAC_PZ; status and statistics)
create_bd_cell -type module -reference mac_cmac_adapt cmac_adapt
foreach p {mac_ctl mac_pz} {
  connect_bd_net [get_bd_pins rocelet_sys_0/$p] [get_bd_pins cmac_adapt/$p]
}
foreach p {mac_stat mac_ev mac_pause} {
  connect_bd_net [get_bd_pins cmac_adapt/$p] [get_bd_pins rocelet_sys_0/$p]
}
foreach p {stat_rx_pause_req stat_rx_pause_valid stat_rx_pause_quanta8 stat_rx_pause stat_tx_pause \
           usr_rx_reset usr_tx_reset} {
  connect_bd_net [get_bd_pins cmac/$p] [get_bd_pins cmac_adapt/$p]
}
connect_bd_net [get_bd_pins cmac_adapt/ctl_tx_pause_req] [get_bd_pins cmac/ctl_tx_pause_req]

foreach {a b} {ctl_rx_enable ctl_rx_enable ctl_tx_enable ctl_tx_enable ctl_tx_send_rfi ctl_tx_send_rfi \
               ctl_tx_send_lfi ctl_tx_send_lfi ctl_tx_send_idle ctl_tx_send_idle \
               ctl_rsfec ctl_tx_rsfec_enable ctl_rsfec ctl_rx_rsfec_enable \
               ctl_rsfec ctl_rx_rsfec_enable_correction ctl_rsfec ctl_rx_rsfec_enable_indication \
               ctl_rx_pause ctl_rx_enable_gcp ctl_rx_pause ctl_rx_enable_gpp \
               ctl_rx_pause ctl_rx_check_mcast_gcp ctl_rx_pause ctl_rx_check_etype_gcp \
               ctl_rx_pause ctl_rx_check_opcode_gcp ctl_rx_pause ctl_rx_check_mcast_gpp \
               ctl_rx_pause ctl_rx_check_etype_gpp ctl_rx_pause ctl_rx_check_opcode_gpp \
               ctl_rx_pause_vec ctl_rx_pause_enable ctl_rx_pause_vec ctl_rx_pause_ack \
               ctl_tx_pause_vec ctl_tx_pause_enable ctl_tx_pause_quanta ctl_tx_pause_quanta8 \
               ctl_tx_pause_refresh ctl_tx_pause_refresh_timer8 ctl_gt_loopback gt_loopback_in} {
  connect_bd_net [get_bd_pins cmac_adapt/$a] [get_bd_pins cmac/$b]
}

# CMAC status and statistics
foreach p {stat_rx_aligned stat_rx_status stat_rx_local_fault stat_rx_remote_fault \
           stat_rx_received_local_fault stat_rx_internal_local_fault stat_rx_hi_ber \
           stat_rx_misaligned stat_rx_rsfec_hi_ser stat_rx_rsfec_lane_alignment_status \
           stat_rx_total_packets stat_rx_bad_fcs stat_rx_bad_code stat_rx_rsfec_corrected_cw_inc \
           stat_rx_rsfec_uncorrected_cw_inc stat_tx_total_packets stat_tx_bad_fcs tx_unfout} {
  connect_bd_net [get_bd_pins cmac/$p] [get_bd_pins cmac_adapt/$p]
}

# every other CMAC input (test patterns, priority PAUSE, DRP,
# preamble, datapath resets, ...) is tied to 0
set n_tie 0
foreach p [get_bd_pins -of_objects [get_bd_cells cmac] -filter {DIR == I}] {
  if {[llength [get_bd_nets -quiet -of_objects $p]]} { continue }
  # a pin of a connected interface (AXI-Stream, GT serial, reference clock) is driven
  set ip [get_bd_intf_pins -quiet -of_objects $p]
  if {[llength $ip] && [llength [get_bd_intf_nets -quiet -of_objects $ip]]} { continue }
  set l [get_property LEFT $p]
  set r [get_property RIGHT $p]
  set w [expr {($l eq "" || $r eq "") ? 1 : abs($l - $r) + 1}]
  set c "tie_cmac_[file tail $p]"
  const_cell $c $w 0
  connect_bd_net [get_bd_pins $c/dout] $p
  incr n_tie
}
puts "INFO: $n_tie CMAC inputs tied to 0"

#########################################################
# QSFP0 status in: {engine irq, rx_aligned, usr_rx_reset, usr_tx_reset, intl, modprsl}
#########################################################
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 qsfp_in_cat
set_property CONFIG.NUM_PORTS {6} [get_bd_cells qsfp_in_cat]
create_bd_port -dir I modprsl_qsfp0
create_bd_port -dir I intl_qsfp0
connect_bd_net [get_bd_ports modprsl_qsfp0] [get_bd_pins qsfp_in_cat/In0]
connect_bd_net [get_bd_ports intl_qsfp0] [get_bd_pins qsfp_in_cat/In1]
connect_bd_net [get_bd_pins cmac/usr_tx_reset] [get_bd_pins qsfp_in_cat/In2]
connect_bd_net [get_bd_pins cmac/usr_rx_reset] [get_bd_pins qsfp_in_cat/In3]
connect_bd_net [get_bd_pins cmac/stat_rx_aligned] [get_bd_pins qsfp_in_cat/In4]
connect_bd_net [get_bd_pins rocelet_sys_0/irq] [get_bd_pins qsfp_in_cat/In5]
connect_bd_net [get_bd_pins qsfp_in_cat/dout] [get_bd_pins axi_gpio_qsfp0/gpio2_io_i]

# LEDs: green = RX aligned, red off
create_bd_port -dir O -from 0 -to 0 grn_led_qsfp0
connect_bd_net [get_bd_pins cmac/stat_rx_aligned] [get_bd_ports grn_led_qsfp0]
create_bd_port -dir O -from 0 -to 0 red_led_qsfp0
connect_bd_net [get_bd_pins const_low/dout] [get_bd_ports red_led_qsfp0]

# QSFP1 is not wired on the KCU116 FMC (DP0-3 only): deselected, in reset, low power
foreach {port net} {modsell const_high resetl const_low lpmode const_high grn_led const_low red_led const_low} {
  create_bd_port -dir O -from 0 -to 0 ${port}_qsfp1
  connect_bd_net [get_bd_pins ${net}/dout] [get_bd_ports ${port}_qsfp1]
}

#########################################################
# Addresses
#########################################################
assign_bd_address
foreach seg [get_bd_addr_segs -quiet microblaze_0/Data/*rocelet_sys_0*] {
  set_property range 512K $seg
  set_property offset 0x44800000 $seg
}

regenerate_bd_layout
save_bd_design
validate_bd_design
save_bd_design
