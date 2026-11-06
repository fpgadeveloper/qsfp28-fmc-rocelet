#---------------------------------------------------------------------
# Constraints: qsfp28-fmc-rocelet, target zcu106 with the 10G option "mac": "omac_10g" (ZCU106 +
# 2x QSFP28 FMC OP120 on HPC0; build.tcl uses this file instead of zcu106.xdc for that MAC)
#
# QSFP28 port 0 of the OP120 = HPC0 DP0-3 = GTH bank 226 (quad X0Y12-15). At 10G only
# lane 0 is used: QSFP lane 0 = FMC DP0 = GTHE4_CHANNEL_X0Y14 (the channel LOC comes from
# the gtwizard IP, gen_gt.tcl X0Y14); the 40G step (omac_40g) uses all four lanes:
#   lane 0 = DP0 (X0Y14, C2M R6/R5, M2C R2/R1)   lane 1 = DP1 (X0Y13, T4/T3, U2/U1)
#   lane 2 = DP2 (X0Y15, N6/N5, P4/P3)           lane 3 = DP3 (X0Y12, U6/U5, V4/V3)
# QSFP28 port 1 (DP4-7, GTH bank 227, GBTCLK1 T8/T7) is not used in v1: its module lines are
# held below, its lanes are reserved for a second engine (DP4 H4/H3 G2/G1, DP5 L6/L5 L2/L1,
# DP6 M4/M3 N2/N1, DP7 K4/K3 J2/J1).
# Pin locations from the FPGA Board Repository (generate_fmc_constraints OP120 / ZCU106 /
# HPC0), identical to the hardware-proven zcu106_hpc0 target of the Opsero 2x-qsfp28-fmc
# design. VADJ (HPC0 bank) 1.8 V: LVCMOS18.
#---------------------------------------------------------------------

# Si5328 clock generator I2C (LA02) and its loss-of-signal alarm (LA06_P)
set_property PACKAGE_PIN L20 [get_ports clk_i2c_scl_io]
set_property PACKAGE_PIN K20 [get_ports clk_i2c_sda_io]
set_property PACKAGE_PIN H19 [get_ports clk_los]
set_property IOSTANDARD LVCMOS18 [get_ports {clk_i2c_* clk_los}]
set_property SLEW SLOW [get_ports clk_i2c_*]
set_property DRIVE 4 [get_ports clk_i2c_*]

# QSFP0 module I2C (LA03)
set_property PACKAGE_PIN K19 [get_ports qsfp0_i2c_scl_io]
set_property PACKAGE_PIN K18 [get_ports qsfp0_i2c_sda_io]
set_property IOSTANDARD LVCMOS18 [get_ports qsfp0_i2c_*]
set_property SLEW SLOW [get_ports qsfp0_i2c_*]
set_property DRIVE 4 [get_ports qsfp0_i2c_*]

# GT reference clock from the Si5328 (GBTCLK0_M2C = MGTREFCLK0 of bank 226), 156.25 MHz
set_property PACKAGE_PIN V8 [get_ports gt_refclk0_p]
create_clock -period 6.400 -name gt_refclk0 [get_ports gt_refclk0_p]

# QSFP port 0 lane 0 (DP0, GTHE4_CHANNEL_X0Y14)
set_property PACKAGE_PIN R6 [get_ports qsfp0_tx0_p]
set_property PACKAGE_PIN R5 [get_ports qsfp0_tx0_n]
set_property PACKAGE_PIN R2 [get_ports qsfp0_rx0_p]
set_property PACKAGE_PIN R1 [get_ports qsfp0_rx0_n]

# QSFP slot 0 module I/O and LEDs
set_property PACKAGE_PIN L17 [get_ports modsell_qsfp0]
set_property PACKAGE_PIN L16 [get_ports resetl_qsfp0]
set_property PACKAGE_PIN G18 [get_ports modprsl_qsfp0]
set_property PACKAGE_PIN F18 [get_ports intl_qsfp0]
set_property PACKAGE_PIN A13 [get_ports lpmode_qsfp0]
set_property PACKAGE_PIN J16 [get_ports grn_led_qsfp0]
set_property PACKAGE_PIN J15 [get_ports red_led_qsfp0]
# QSFP slot 1 (not used): held deselected / in reset / low power
set_property PACKAGE_PIN D16 [get_ports modsell_qsfp1]
set_property PACKAGE_PIN C16 [get_ports resetl_qsfp1]
set_property PACKAGE_PIN A12 [get_ports lpmode_qsfp1]
set_property PACKAGE_PIN E18 [get_ports grn_led_qsfp1]
set_property PACKAGE_PIN E17 [get_ports red_led_qsfp1]
set_property IOSTANDARD LVCMOS18 [get_ports {modsell_qsfp* resetl_qsfp* modprsl_qsfp* intl_qsfp* lpmode_qsfp* grn_led_qsfp* red_led_qsfp*}]

# Clock-domain crossing constraints: zcu106_omac_10g_impl.xdc (implementation only: the GT clocks
# exist only once the gtwizard IP's netlist is linked)

# Bitstream
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
