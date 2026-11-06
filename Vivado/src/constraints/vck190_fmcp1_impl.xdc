#---------------------------------------------------------------------
# Constraints: qsfp28-fmc-rocelet, target vck190_fmcp1 - clock-domain crossings
# (implementation only; build.tcl adds <target>_impl.xdc with USED_IN_SYNTHESIS false)
#---------------------------------------------------------------------
# Fabric clocks, all from MMCMs on the CIPS pl0_ref_clk (100 MHz), so Vivado would time them
# as related; every crossing between them is a CDC (XPM FIFOs / synchronisers with their own
# constraints, the clock guard's toggle handshake, quasi-static words), so they are
# asynchronous groups:
#   clk_wizard_0   CLKOUT0 clk_sys   100 MHz  control plane (M_AXI_LPD, rsys_aon, IIC, MRMAC
#                                             s_axi, GT APB, DMA registers)
#                  CLKOUT1 clk_gen   200 MHz  rocelet_sys gen_clk (HSB generators)
#                  CLKOUT2 clk_dma   250 MHz  netdev AXI DMA + its NoC port
#   eng_clk_wiz    CLKOUT0 clk_eng   engine (rocelet_sys clk, DDR window NoC ports; data.json clk_khz)
#   axis_clk_wiz   CLKOUT0 clk_axis  390.625 MHz MRMAC AXIS client (tx/rx_axi_clk) + adapter MAC side
# The GT clocks (created by the gt_quad_base / MRMAC constraints) meet the fabric only inside
# the hard MRMAC (its own constraints); no fabric path crosses to them, so they are not grouped.
set clk_sys  [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *clk_wizard_0/inst/clock_primitive_inst/*/CLKOUT0}]]
set clk_gen  [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *clk_wizard_0/inst/clock_primitive_inst/*/CLKOUT1}]]
set clk_dma  [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *clk_wizard_0/inst/clock_primitive_inst/*/CLKOUT2}]]
set clk_eng  [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *eng_clk_wiz/inst/clock_primitive_inst/*/CLKOUT0}]]
set clk_axis [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *axis_clk_wiz/inst/clock_primitive_inst/*/CLKOUT0}]]
set_clock_groups -asynchronous -group $clk_sys -group $clk_gen -group $clk_dma -group $clk_eng \
  -group $clk_axis

# rocelet_sys (as on the KCU116 / ZCU106): the system reset synchroniser; gen_clk quasi-static words
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *rocelet_sys_0*rs_sync_reg*/PRE}]
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *rocelet_sys_0*rs_sync_reg*/D}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rocelet_sys_0*qsg_*_reg*}]
# (no qsc_* device-DNA registers: DNA_EN 0 on Versal)
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *rocelet_sys_0*u_bms/qsb_reg*}]

# rsys_aon clock guard (clk_sys <-> engine clock): toggle handshake through ASYNC_REG
# synchronisers; the request fields (qsr_*) and the read data (qsm_rdata) are stable while
# the toggles differ; status levels into clk_sys are synchronised (st_s1, ev_s1, io_s1, ln_s1)
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*mreq_sync_reg[0]*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*ack_sync_reg[0]*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*hb_sync_reg[0]*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*st_s1_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*ev_s1_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*io_s1_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*ln_s1_reg*}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*qsr_*_reg*}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*qsm_rdata_reg*}]

# mac_mrmac100g: its clock crossings are XPM macros (self-constrained; the gray-pointer bus
# skew still applies under the clock groups above); the GT loopback selects (chN_loopback of
# gt_quad_base) are asynchronous static levels
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *mac0*loop_r_reg*}]
