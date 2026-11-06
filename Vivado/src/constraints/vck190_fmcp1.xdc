#---------------------------------------------------------------------
# Constraints: qsfp28-fmc-rocelet, target vck190_fmcp1 (VCK190 + 2x QSFP28 FMC OP120 on FMCP1,
# QSFP28 port 0 at 100G: the Versal MRMAC, 1x100GE CAUI-4, RS-FEC)
#
# QSFP28 port 0 of the OP120 = FMCP1 DP0-3 = GTY_QUAD_X1Y1 (bank 201) -> MRMAC_X0Y0, reference
# clock GBTCLK0_M2C (M15/M14) = 322.265625 MHz from the OP120's Si5328. QSFP lane l = FMC DP l =
# gt_quad_base channel l (straight order, no polarity inversion). The GT quad is placed by
# its pins; the MRMAC site is a block-design parameter (data.json mrmac_core).
# QSFP28 port 1 (DP4-7 = GTY_QUAD_X1Y2 / bank 202 -> MRMAC_X0Y2, GBTCLK1 K15/K14) is not used
# in v1: its module lines are held below; its lanes are reserved for a second port
# (DP4 TX V7/V6 RX V2/V1, DP5 U9/U8 U4/U3, DP6 T7/T6 T2/T1, DP7 R9/R8 R4/R3).
# Pin locations from the FPGA Board Repository (generate_fmc_constraints OP120 / VCK190 /
# FMCP1), identical to the hardware-proven vck190_fmcp1 targets of the Opsero 2x-qsfp28-fmc
# and qsfp28-fmc-zircon designs. VADJ (FMCP1 LA banks) 1.5 V: LVCMOS15. VADJ is OFF after
# power-up on the VCK190 until software enables it (u-boot fragment / console / roceletd).
#---------------------------------------------------------------------

# Si5328 clock generator I2C (LA02) and its loss-of-signal alarm (LA06_P)
set_property PACKAGE_PIN AW24 [get_ports clk_i2c_scl_io]
set_property PACKAGE_PIN AY25 [get_ports clk_i2c_sda_io]
set_property PACKAGE_PIN BC20 [get_ports clk_los]
set_property IOSTANDARD LVCMOS15 [get_ports {clk_i2c_* clk_los}]
set_property SLEW SLOW [get_ports clk_i2c_*]
set_property DRIVE 4 [get_ports clk_i2c_*]

# QSFP0 module I2C (LA03)
set_property PACKAGE_PIN AV22 [get_ports qsfp0_i2c_scl_io]
set_property PACKAGE_PIN AW21 [get_ports qsfp0_i2c_sda_io]
set_property IOSTANDARD LVCMOS15 [get_ports qsfp0_i2c_*]
set_property SLEW SLOW [get_ports qsfp0_i2c_*]
set_property DRIVE 4 [get_ports qsfp0_i2c_*]

# GT reference clock from the Si5328 (GBTCLK0_M2C = GTY_QUAD_X1Y1 REFCLK0), 322.265625 MHz.
# The primary clock lets Vivado derive the GT TX / RX out clocks (and the BUFG_GT user clocks)
# at their real rates (TIMING-26 without it: they inherit the APB clock)
set_property PACKAGE_PIN M15 [get_ports {gt_ref_clk_0_clk_p[0]}]
create_clock -period 3.103 -name gt_refclk0 [get_ports {gt_ref_clk_0_clk_p[0]}]

# QSFP port 0 lanes 0-3 (DP0-3, GTY_QUAD_X1Y1 channels 0-3)
set_property PACKAGE_PIN AB7 [get_ports {qsfp0_gt_gtx_p[0]}]
set_property PACKAGE_PIN AB6 [get_ports {qsfp0_gt_gtx_n[0]}]
set_property PACKAGE_PIN AB2 [get_ports {qsfp0_gt_grx_p[0]}]
set_property PACKAGE_PIN AB1 [get_ports {qsfp0_gt_grx_n[0]}]
set_property PACKAGE_PIN AA9 [get_ports {qsfp0_gt_gtx_p[1]}]
set_property PACKAGE_PIN AA8 [get_ports {qsfp0_gt_gtx_n[1]}]
set_property PACKAGE_PIN AA4 [get_ports {qsfp0_gt_grx_p[1]}]
set_property PACKAGE_PIN AA3 [get_ports {qsfp0_gt_grx_n[1]}]
set_property PACKAGE_PIN Y7  [get_ports {qsfp0_gt_gtx_p[2]}]
set_property PACKAGE_PIN Y6  [get_ports {qsfp0_gt_gtx_n[2]}]
set_property PACKAGE_PIN Y2  [get_ports {qsfp0_gt_grx_p[2]}]
set_property PACKAGE_PIN Y1  [get_ports {qsfp0_gt_grx_n[2]}]
set_property PACKAGE_PIN W9  [get_ports {qsfp0_gt_gtx_p[3]}]
set_property PACKAGE_PIN W8  [get_ports {qsfp0_gt_gtx_n[3]}]
set_property PACKAGE_PIN W4  [get_ports {qsfp0_gt_grx_p[3]}]
set_property PACKAGE_PIN W3  [get_ports {qsfp0_gt_grx_n[3]}]

# QSFP slot 0 module I/O and LEDs
set_property PACKAGE_PIN AU21 [get_ports modsell_qsfp0]
set_property PACKAGE_PIN AV21 [get_ports resetl_qsfp0]
set_property PACKAGE_PIN BG21 [get_ports modprsl_qsfp0]
set_property PACKAGE_PIN BF22 [get_ports intl_qsfp0]
set_property PACKAGE_PIN BF23 [get_ports lpmode_qsfp0]
set_property PACKAGE_PIN BC25 [get_ports grn_led_qsfp0]
set_property PACKAGE_PIN BD25 [get_ports red_led_qsfp0]
# QSFP slot 1 (not used in v1): held deselected / in reset / low power, LEDs off
set_property PACKAGE_PIN AY22 [get_ports modsell_qsfp1]
set_property PACKAGE_PIN AY23 [get_ports resetl_qsfp1]
set_property PACKAGE_PIN BE22 [get_ports lpmode_qsfp1]
set_property PACKAGE_PIN BC22 [get_ports grn_led_qsfp1]
set_property PACKAGE_PIN BC21 [get_ports red_led_qsfp1]
set_property IOSTANDARD LVCMOS15 [get_ports {modsell_qsfp* resetl_qsfp* modprsl_qsfp* intl_qsfp* lpmode_qsfp* grn_led_qsfp* red_led_qsfp*}]

# Slow board I/O (static levels, I2C, LEDs): no timing relationship to any clock
set_false_path -to   [get_ports {modsell_qsfp* resetl_qsfp* lpmode_qsfp* grn_led_qsfp* red_led_qsfp*}]
set_false_path -from [get_ports {modprsl_qsfp0 intl_qsfp0 clk_los}]
set_false_path -to   [get_ports {clk_i2c_scl_io clk_i2c_sda_io qsfp0_i2c_scl_io qsfp0_i2c_sda_io}]
set_false_path -from [get_ports {clk_i2c_scl_io clk_i2c_sda_io qsfp0_i2c_scl_io qsfp0_i2c_sda_io}]

# Clock-domain crossing constraints: vck190_fmcp1_impl.xdc (implementation only)
