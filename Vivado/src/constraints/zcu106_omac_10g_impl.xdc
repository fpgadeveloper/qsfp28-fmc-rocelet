#---------------------------------------------------------------------
# Constraints: qsfp28-fmc-rocelet, target zcu106, 10G option (omac_10g) - clock-domain crossings
# (implementation only; build.tcl adds <target>_impl.xdc with USED_IN_SYNTHESIS false)
#---------------------------------------------------------------------
#---------------------------------------------------------------------
# omac_10g: the GT TX user clock (MAC / rocelet_sys clock) and the recovered RX user clock;
# every crossing is a synchroniser, gray-coded or quasi-static (omac_10g docs "Timing and
# constraints"): bounded to one clock period
set omac_tx [get_clocks -include_generated_clocks -of_objects [get_pins -hierarchical -filter {REF_PIN_NAME == TXOUTCLK && PARENT_CELL =~ *mac0*}]]
set omac_rx [get_clocks -include_generated_clocks -of_objects [get_pins -hierarchical -filter {REF_PIN_NAME == RXOUTCLK && PARENT_CELL =~ *mac0*}]]
set_max_delay -datapath_only -from $omac_tx -to $omac_rx 6.400
set_max_delay -datapath_only -from $omac_rx -to $omac_tx 6.400

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
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*qsr_*_reg*}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *rsys_aon_0*qsm_rdata_reg*}]

