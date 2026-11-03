#---------------------------------------------------------------------
# Constraints: qsfp28-fmc-rocelet, target kcu116 (KCU116 + 2x QSFP28 FMC OP120)
#
# OP120 on the KCU116 FMC HPC. Only DP0-3 (QSFP28 port 0) are routed on this
# board: GTY bank 227, quad X0Y12-15, CMACE4_X0Y0. Pin locations from the FPGA
# Board Repository (generate_fmc_constraints OP120 / KCU116 / HPC), identical to
# the hardware-proven kcu116 target of the Opsero 2x-qsfp28-fmc design. The
# MicroBlaze system I/O (300 MHz clock, reset, UART) comes from the board files.
#---------------------------------------------------------------------

# Si5328 clock generator I2C (LA02)
set_property PACKAGE_PIN Y17 [get_ports clk_i2c_scl_io]
set_property PACKAGE_PIN AA17 [get_ports clk_i2c_sda_io]
set_property IOSTANDARD LVCMOS18 [get_ports clk_i2c_*]
set_property SLEW SLOW [get_ports clk_i2c_*]
set_property DRIVE 4 [get_ports clk_i2c_*]

# QSFP0 module I2C (LA03)
set_property PACKAGE_PIN AB17 [get_ports qsfp0_i2c_scl_io]
set_property PACKAGE_PIN AC17 [get_ports qsfp0_i2c_sda_io]
set_property IOSTANDARD LVCMOS18 [get_ports qsfp0_i2c_*]
set_property SLEW SLOW [get_ports qsfp0_i2c_*]
set_property DRIVE 4 [get_ports qsfp0_i2c_*]

# GT reference clock from the Si5328 (GBTCLK0_M2C, bank 227)
set_property PACKAGE_PIN K7 [get_ports gt_ref_clk_0_clk_p*]

# QSFP port 0 lanes (DP0-3, quad X0Y12-15, lane i = channel i)
set_property PACKAGE_PIN F7 [get_ports {qsfp0_gt_gtx_p[0]}]
set_property PACKAGE_PIN F6 [get_ports {qsfp0_gt_gtx_n[0]}]
set_property PACKAGE_PIN D2 [get_ports {qsfp0_gt_grx_p[0]}]
set_property PACKAGE_PIN D1 [get_ports {qsfp0_gt_grx_n[0]}]
set_property PACKAGE_PIN E5 [get_ports {qsfp0_gt_gtx_p[1]}]
set_property PACKAGE_PIN E4 [get_ports {qsfp0_gt_gtx_n[1]}]
set_property PACKAGE_PIN C4 [get_ports {qsfp0_gt_grx_p[1]}]
set_property PACKAGE_PIN C3 [get_ports {qsfp0_gt_grx_n[1]}]
set_property PACKAGE_PIN D7 [get_ports {qsfp0_gt_gtx_p[2]}]
set_property PACKAGE_PIN D6 [get_ports {qsfp0_gt_gtx_n[2]}]
set_property PACKAGE_PIN B2 [get_ports {qsfp0_gt_grx_p[2]}]
set_property PACKAGE_PIN B1 [get_ports {qsfp0_gt_grx_n[2]}]
set_property PACKAGE_PIN B7 [get_ports {qsfp0_gt_gtx_p[3]}]
set_property PACKAGE_PIN B6 [get_ports {qsfp0_gt_gtx_n[3]}]
set_property PACKAGE_PIN A4 [get_ports {qsfp0_gt_grx_p[3]}]
set_property PACKAGE_PIN A3 [get_ports {qsfp0_gt_grx_n[3]}]

# QSFP slot 0 module I/O and LEDs
set_property PACKAGE_PIN AA20 [get_ports {modsell_qsfp0*}]
set_property PACKAGE_PIN AB20 [get_ports {resetl_qsfp0*}]
set_property PACKAGE_PIN AC22 [get_ports modprsl_qsfp0]
set_property PACKAGE_PIN AC23 [get_ports intl_qsfp0]
set_property PACKAGE_PIN Y18 [get_ports {lpmode_qsfp0*}]
set_property PACKAGE_PIN AD16 [get_ports {grn_led_qsfp0*}]
set_property PACKAGE_PIN AE16 [get_ports {red_led_qsfp0*}]

# QSFP slot 1 (not connected on the KCU116): held deselected / in reset
set_property PACKAGE_PIN AB24 [get_ports {modsell_qsfp1*}]
set_property PACKAGE_PIN AC24 [get_ports {resetl_qsfp1*}]
set_property PACKAGE_PIN AA18 [get_ports {lpmode_qsfp1*}]
set_property PACKAGE_PIN AE17 [get_ports {grn_led_qsfp1*}]
set_property PACKAGE_PIN AF17 [get_ports {red_led_qsfp1*}]

set_property IOSTANDARD LVCMOS18 [get_ports {modsell_qsfp* resetl_qsfp* modprsl_qsfp* intl_qsfp* lpmode_qsfp* grn_led_qsfp* red_led_qsfp*}]

# Clock-domain crossings outside the SmartConnect:
#  - the system reset into rocelet_sys is synchronised there (rs_sync, ASYNC_REG)
#  - the CMAC / engine status bits sampled by the QSFP0 GPIO (sys clock) are polled levels
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *rocelet_sys_0*rs_sync_reg*/PRE}]
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *rocelet_sys_0*rs_sync_reg*/D}]
set_false_path -through [get_pins -hierarchical -filter {NAME =~ *axi_gpio_qsfp0/gpio2_io_i*}]
#  - rocelet_sys CMAC user clock <-> 200 MHz generator clock (gen_clk): pulses, levels, the
#    beat FIFO and the generator reset use XPM CDC macros (their own constraints); the IQ16
#    configuration words (qsg_*, captured in gen_clk; the commit pulse follows them by 4+
#    clocks) and the device DNA (qsc_*, captured in clk; constant once its valid flag rises)
#    are quasi-static
#    (-to the cells: every data input pin of the capture registers, D and any R/S/CE)
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rocelet_sys_0*qsg_*_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rocelet_sys_0*qsc_*_reg*}]
#  - the beam array generator's staged scene (qsb, loaded in clk by APPLY) is read by its
#    gen_clk scene engine only; the APPLY pulse reaches gen_clk ~6 clocks later and restarts the
#    engine, which declares a result only 16 clocks after its last read (rsys_beam_src.sv)
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *rocelet_sys_0*u_bms/qsb_reg*}]

# Bitstream
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 31.9 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR YES [current_design]
