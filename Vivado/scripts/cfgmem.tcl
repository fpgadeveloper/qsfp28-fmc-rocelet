# Opsero Electronic Design Inc. Copyright 2026
#
# Configuration-memory image: converts a bitstream into an .mcs (+ .prm) for the
# board's configuration flash, so that the FPGA loads the design at power-on.
#
# Run by build.py (stage 'cfgmem') for targets with "cfgmem": true in
# config/data.json:
#   vivado -mode batch -source scripts/cfgmem.tcl -notrace \
#     -tclargs <target> <bit> <out_mcs> [<flashsize_MB> [<flashintf>]]
#
#   <bit>      on a MicroBlaze bare-metal target: Vitis/boot/<target>/<bd_name>_boot.bit (rocelet_boot.bit)
#              (bitstream with the application embedded in the LMB BRAM)
#   <out_mcs>  the .mcs to write; the .prm is written next to it
#   flashsize  flash size in MB (data.json "flashsize", default 128)
#   flashintf  flash interface (data.json "flashintf", default SPIx4)
#
# KCU116: 128 MB (1 Gb MT25QU01G) QSPI in x4 mode. The bitstream properties that make the FPGA
# boot from it (SPI_BUSWIDTH 4, SPI_32BIT_ADDR, CONFIGRATE, COMPRESS) are in
# src/constraints/kcu116.xdc.
#*****************************************************************************************

if { $argc < 3 } {
  puts "Usage: vivado -mode batch -source cfgmem.tcl -tclargs <target> <bit> <out_mcs> \[<flashsize_MB> \[<flashintf>\]\]"
  exit 1
}
set target    [lindex $argv 0]
set bitfile   [file normalize [lindex $argv 1]]
set mcsfile   [file normalize [lindex $argv 2]]
set flashsize [expr { $argc > 3 ? [lindex $argv 3] : 128 }]
set flashintf [expr { $argc > 4 ? [lindex $argv 4] : "SPIx4" }]

if { ![file exists $bitfile] } {
  puts "ERROR: bitstream not found: $bitfile"
  exit 1
}
file mkdir [file dirname $mcsfile]

puts "Target: $target"
puts "Writing $mcsfile ($flashsize MB, $flashintf) from $bitfile"
if { [catch {
  write_cfgmem -force -format mcs -size $flashsize -interface $flashintf \
    -loadbit "up 0x00000000 $bitfile" -checksum -file $mcsfile
} err] } {
  puts "ERROR: write_cfgmem failed: $err"
  exit 1
}
exit 0
