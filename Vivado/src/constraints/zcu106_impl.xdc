#---------------------------------------------------------------------
# Constraints: qsfp28-fmc-rocelet, target zcu106 (omac_40g) - clock-domain crossings
# (implementation only; build.tcl adds <target>_impl.xdc with USED_IN_SYNTHESIS false)
#---------------------------------------------------------------------
#---------------------------------------------------------------------
# omac_40g: five clocks - the GT TX user clock (the master channel's TXOUTCLK, gtwizard
# channel 2 = X0Y14: the MAC / rocelet_sys clock) and one recovered RX user clock per channel
# (each channel's RXOUTCLK and its BUFG_GTs); every crossing between them is a gray-coded FIFO
# / event counter, an ASYNC_REG synchroniser or quasi-static (omac_40g docs "Timing and
# constraints"): every ordered pair bounded to one clock period. Written out pair by pair (XDC
# has no foreach); the channel index is the gtwizard's (ascending site order: 0 = X0Y12,
# 1 = X0Y13, 2 = X0Y14, 3 = X0Y15), "?" matches the brackets of gen_gthe4_channel_inst[c].
set omac_tx  [get_clocks -include_generated_clocks -of_objects [get_pins -hierarchical -filter {REF_PIN_NAME == TXOUTCLK && PARENT_CELL =~ *mac0*}]]
set omac_rx0 [get_clocks -include_generated_clocks -of_objects [get_pins -of_objects [get_cells -hierarchical -filter {NAME =~ *mac0*gen_gthe4_channel_inst?0?.GTHE4_CHANNEL_PRIM_INST}] -filter {REF_PIN_NAME == RXOUTCLK}]]
set omac_rx1 [get_clocks -include_generated_clocks -of_objects [get_pins -of_objects [get_cells -hierarchical -filter {NAME =~ *mac0*gen_gthe4_channel_inst?1?.GTHE4_CHANNEL_PRIM_INST}] -filter {REF_PIN_NAME == RXOUTCLK}]]
set omac_rx2 [get_clocks -include_generated_clocks -of_objects [get_pins -of_objects [get_cells -hierarchical -filter {NAME =~ *mac0*gen_gthe4_channel_inst?2?.GTHE4_CHANNEL_PRIM_INST}] -filter {REF_PIN_NAME == RXOUTCLK}]]
set omac_rx3 [get_clocks -include_generated_clocks -of_objects [get_pins -of_objects [get_cells -hierarchical -filter {NAME =~ *mac0*gen_gthe4_channel_inst?3?.GTHE4_CHANNEL_PRIM_INST}] -filter {REF_PIN_NAME == RXOUTCLK}]]
set_max_delay -datapath_only -from $omac_tx -to $omac_rx0 6.400
set_max_delay -datapath_only -from $omac_tx -to $omac_rx1 6.400
set_max_delay -datapath_only -from $omac_tx -to $omac_rx2 6.400
set_max_delay -datapath_only -from $omac_tx -to $omac_rx3 6.400
set_max_delay -datapath_only -from $omac_rx0 -to $omac_tx 6.400
set_max_delay -datapath_only -from $omac_rx0 -to $omac_rx1 6.400
set_max_delay -datapath_only -from $omac_rx0 -to $omac_rx2 6.400
set_max_delay -datapath_only -from $omac_rx0 -to $omac_rx3 6.400
set_max_delay -datapath_only -from $omac_rx1 -to $omac_tx 6.400
set_max_delay -datapath_only -from $omac_rx1 -to $omac_rx0 6.400
set_max_delay -datapath_only -from $omac_rx1 -to $omac_rx2 6.400
set_max_delay -datapath_only -from $omac_rx1 -to $omac_rx3 6.400
set_max_delay -datapath_only -from $omac_rx2 -to $omac_tx 6.400
set_max_delay -datapath_only -from $omac_rx2 -to $omac_rx0 6.400
set_max_delay -datapath_only -from $omac_rx2 -to $omac_rx1 6.400
set_max_delay -datapath_only -from $omac_rx2 -to $omac_rx3 6.400
set_max_delay -datapath_only -from $omac_rx3 -to $omac_tx 6.400
set_max_delay -datapath_only -from $omac_rx3 -to $omac_rx0 6.400
set_max_delay -datapath_only -from $omac_rx3 -to $omac_rx1 6.400
set_max_delay -datapath_only -from $omac_rx3 -to $omac_rx2 6.400

# rocelet_sys (as on the KCU116): the system reset synchroniser; gen_clk quasi-static words
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *rocelet_sys_0*rs_sync_reg*/PRE}]
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *rocelet_sys_0*rs_sync_reg*/D}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rocelet_sys_0*qsg_*_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rocelet_sys_0*qsc_*_reg*}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *rocelet_sys_0*u_bms/qsb_reg*}]

# rsys_aon clock guard (pl_clk0 <-> MAC clock): toggle handshake through ASYNC_REG
# synchronisers; the request fields (qsr_*) and the read data (qsm_rdata) are stable while
# the toggles differ; status levels into pl_clk0 are synchronised (st_s1, ev_s1, io_s1)
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*mreq_sync_reg[0]*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*ack_sync_reg[0]*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*hb_sync_reg[0]*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*st_s1_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*ev_s1_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*io_s1_reg*}]
# 40G lane status levels (quasi-static; the lane event counters cross in xpm_cdc_gray, which
# carries its own constraints)
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*ln_s1_reg*}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*qsr_*_reg*}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*qsm_rdata_reg*}]

