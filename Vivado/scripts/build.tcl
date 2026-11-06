# Opsero Electronic Design Inc. Copyright 2026
#
# Project build script
#
# This script requires the target name to be specified upon launch. This can be done
# in two ways:
#
#   1. Using a single argument passed to the script via tclargs.
#      eg. vivado -mode batch -source build.tcl -notrace -tclargs <target-name>
#
#   2. By setting the target variable before sourcing the script.
#      eg. set target <target-name>
#          source build.tcl -notrace
#
# For a list of possible targets, see below.
#
# Sources: the rocelet engine (git submodule submodules/rocelet, file list
# rtl/rocelet.f, added by scripts/rocelet_sources.tcl) and this design's own RTL
# (src/hdl: the rocelet_sys module reference and its parts). The block design is
# src/bd/bd_<bdscript>.tcl.
#*****************************************************************************************

# Check the version of Vivado used
set version_required "2025.2"
set ver [lindex [split $::env(XILINX_VIVADO) /] end-1]
if {![string equal $ver $version_required]} {
  puts "###############################"
  puts "### Failed to build project ###"
  puts "###############################"
  puts "This project was designed for use with Vivado $version_required."
  puts "You are using Vivado $ver. Please install Vivado $version_required,"
  puts "or download the project sources from a commit of the Git repository"
  puts "that was intended for your version of Vivado ($ver)."
  return
}

# Add Xilinx board store to the repo paths
set_param board.repoPaths [get_property LOCAL_ROOT_DIR [xhub::get_xstores xilinx_board_store]]

# Possible targets
# (generated from config/data.json by config/update.py:
#  <label> { <url> <boardname> <bdscript> <port> <fec> <selftest> { <rocelet_sys parameters> } <mac>
#            { <GT placement: channels {<lane 0..3 sites>} refclk <clkN> | cmac_core <site>> } })
# UPDATER START
dict set target_dict kcu116 { xilinx.com kcu116 microblaze 0 rs 1 { NUM_QP 16 NUM_MR 16 READ_DEPTH 16 MAX_WR 128 RTX_MODE RING RING_BYTES 262144 HSB_EN 1 MEM_BYTES 262144 MAC_WIDTH 512 CLK_MHZ 322 CLK_KHZ 322266 CLK_HZ 322265625 LINK_GBPS 100 } cmac { channels {X0Y12 X0Y13 X0Y14 X0Y15} cmac_core CMACE4_X0Y0 } }
dict set target_dict zcu106 { xilinx.com zcu106 zynqmp 0 none 1 { NUM_QP 16 NUM_MR 16 READ_DEPTH 16 MAX_WR 128 RTX_MODE RING RING_BYTES 262144 HSB_EN 1 MEM_BYTES 262144 MAC_WIDTH 256 CLK_MHZ 156 CLK_KHZ 156250 CLK_HZ 156250000 LINK_GBPS 40 DDR_EN 1 DDR_PORTS 2 ODMA_EN 1 } omac_40g { channels {X0Y14 X0Y13 X0Y15 X0Y12} refclk clk0 } }
# UPDATER END

# Function to display the options and get user input
proc selectTarget {target_dict} {
    set keys_list [lsort [dict keys $target_dict]]
    while {1} {
        set counter 0
        puts "Possible target designs:"
        foreach key $keys_list {
            incr counter
            puts "  $counter: $key"
        }
        set user_choice -1
        while {($user_choice < 1) || ($user_choice > $counter)} {
            puts -nonewline "Choose target design (1-$counter): "
            flush stdout
            gets stdin user_choice
            if {![string is integer -strict $user_choice]} {
                set user_choice -1
                continue
            }
        }
        set selected_key [lindex $keys_list [expr {$user_choice - 1}]]
        puts -nonewline "Confirm selection '$selected_key' (Y/n): "
        flush stdout
        gets stdin confirmation
        if {[string match -nocase "y*" $confirmation] || [string equal -length 1 "" $confirmation]} {
            return $selected_key
        }
    }
}

# Target can be specified by creating the target variable before sourcing, or in the command line arguments
if { [info exists target] } {
  if { ![dict exists $target_dict $target] } {
    puts "Invalid target specified: $target"
    exit 1
  }
} elseif { $argc == 0 } {
  set target [selectTarget $target_dict]
} else {
  set target [lindex $argv 0]
  if { ![dict exists $target_dict $target] } {
    puts "Invalid target specified: $target"
    exit 1
  }
}

# At this point of the script, we are guaranteed to have a valid target
puts "Target design: $target"

set design_name ${target}
set block_name rocelet
set tdesc [dict get $target_dict $target]
set board_url  [lindex $tdesc 0]
set board_name [lindex $tdesc 1]
set bd_script  [lindex $tdesc 2]
set port       [lindex $tdesc 3]
set fec        [lindex $tdesc 4]
set selftest   [lindex $tdesc 5]
set mac_type   [lindex $tdesc 7]
if {$mac_type eq ""} { set mac_type cmac }
# rocelet_sys_bd parameters; RTX_MODE is passed as a number (0 RING, 1 REREAD, 2 LOSSY)
set eng_params {}
dict for {k v} [lindex $tdesc 6] {
  if {$k eq "RTX_MODE"} {
    set v [dict get {RING 0 REREAD 1 LOSSY 2} $v]
  }
  dict set eng_params $k $v
}
puts "Port $port, FEC $fec, self-test $selftest, MAC $mac_type, rocelet_sys parameters: $eng_params"

# GT placement of the QSFP28 port (data.json "gt_channels" / "gt_refclk" / "cmac_core"):
#   gt_channels  transceiver channel sites (X<x>Y<y>) in QSFP lane order 0-3; omac_10g uses
#                lane 0, omac_40g and cmac all four (one quad)
#   gt_refclk    omac: reference clock of the lane 0 channel as the gtwizard IP names it
#                (clk0 / clk1 = MGTREFCLK0 / 1 of its quad, clk0+1, clk0-1, ... = of the quad
#                above / below); default clk0
#   cmac_core    cmac: the CMAC hard block site (CMACE4_X<x>Y<y>)
# Derived: gt_quad_ch = the lane 0-3 channels' indices in ascending site order (the
# gtwizard / CMAC numbering of a quad's channels), ch_of_lane = the same packed as
# omac_gt_usp_gth_x4 CH_OF_LANE (lane l at [2l +: 2]), cmac_gt_group = CMAC GT_GROUP_SELECT
set gt_cfg      [lindex $tdesc 8]
set gt_channels [expr {[dict exists $gt_cfg channels]  ? [dict get $gt_cfg channels]  : {}}]
set gt_refclk   [expr {[dict exists $gt_cfg refclk]    ? [dict get $gt_cfg refclk]    : "clk0"}]
set cmac_core   [expr {[dict exists $gt_cfg cmac_core] ? [dict get $gt_cfg cmac_core] : ""}]
proc gt_site_xy {ch} {
  if {![regexp {^X([0-9]+)Y([0-9]+)$} $ch -> x y]} {
    puts "ERROR: GT channel '$ch' (data.json gt_channels) is not of the form X<x>Y<y>"
    exit 1
  }
  return [list $x $y]
}
foreach ch $gt_channels { gt_site_xy $ch }
if {[llength $gt_channels] == 0 || ($mac_type ne "omac_10g" && [llength $gt_channels] != 4)} {
  puts "ERROR: target $target (MAC $mac_type) needs [expr {$mac_type eq {omac_10g} ? {one} : {four}}] GT channel(s) in data.json gt_channels, has [llength $gt_channels]"
  exit 1
}
set ch_of_lane 0
set cmac_gt_group ""
if {[llength $gt_channels] == 4} {
  # four lanes: one quad (same X, Y / 4), every channel once
  lassign [gt_site_xy [lindex $gt_channels 0]] qx qy
  set qy [expr {$qy / 4}]
  set ys {}
  foreach ch $gt_channels {
    lassign [gt_site_xy $ch] x y
    if {$x != $qx || $y / 4 != $qy} {
      puts "ERROR: gt_channels $gt_channels are not the four channels of one quad"
      exit 1
    }
    lappend ys $y
  }
  if {[llength [lsort -unique -integer $ys]] != 4} {
    puts "ERROR: gt_channels $gt_channels name a channel twice"
    exit 1
  }
  set sorted [lsort -integer $ys]
  set gt_quad_ch {}
  set l 0
  foreach y $ys {
    set c [lsearch -exact $sorted $y]
    lappend gt_quad_ch $c
    set ch_of_lane [expr {$ch_of_lane | ($c << (2 * $l))}]
    incr l
  }
  set cmac_gt_group "X${qx}Y[lindex $sorted 0]~X${qx}Y[lindex $sorted end]"
}
if {$mac_type eq "cmac"} {
  puts "GT channels $gt_channels (QSFP lanes 0-3), CMAC $cmac_core, GT group $cmac_gt_group"
} else {
  puts "GT channels $gt_channels (QSFP lanes 0-[expr {[llength $gt_channels] - 1}]), refclk $gt_refclk, CH_OF_LANE [format 0x%02X $ch_of_lane]"
}
if {$mac_type eq "cmac" && $cmac_core eq ""} {
  puts "ERROR: target $target (MAC cmac) needs data.json cmac_core"
  exit 1
}

# omac: set the gtwizard reference clock of the master channel (lane 0) when it is not
# MGTREFCLK0 of its quad (gen_gt.tcl uses "<master> clk0")
proc omac_set_refclk {ip master refclk} {
  if {$refclk eq "clk0"} { return }
  set_property -dict [list CONFIG.TX_REFCLK_SOURCE "$master $refclk" CONFIG.RX_REFCLK_SOURCE "$master $refclk"] $ip
  foreach k {TX_REFCLK_SOURCE RX_REFCLK_SOURCE} {
    if {[get_property CONFIG.$k $ip] ne "$master $refclk"} {
      puts "ERROR: gtwizard $k = [get_property CONFIG.$k $ip], expected $master $refclk (data.json gt_refclk)"
      exit 1
    }
  }
}

set proj_board [get_board_parts "$board_url:$board_name:*" -latest_file_version]
# Check if the board files are installed, if not, install them
if { $proj_board == "" } {
    puts "Failed to find board files for $board_name. Installing board files..."
    xhub::refresh_catalog [xhub::get_xstores xilinx_board_store]
    xhub::install [xhub::get_xitems $board_url:xilinx_board_store:$board_name*]
    set proj_board [get_board_parts "$board_url:$board_name:*" -latest_file_version]
} else {
    puts "Board files found for $board_name"
}
set fpga_part [get_property PART_NAME [get_board_parts $proj_board]]

# Set the reference directory for source file relative paths (by default the value is script directory path)
set origin_dir "."
set repo_root [file normalize "$origin_dir/.."]

# Create project
create_project $design_name $origin_dir/$design_name -part ${fpga_part}
set_property board_part $proj_board [current_project]
set_property target_language Verilog [current_project]

# ---------------------------------------------------------------------------
# HDL sources. They MUST be in the project before the block design is sourced,
# so that 'create_bd_cell -type module -reference' can resolve them.
#  - the rocelet engine from the git submodule (MIT, see submodules/README.md)
#  - src/hdl: rsys_pkg first, then everything else (*.sv, *.v)
# ---------------------------------------------------------------------------
# one add_files call per list (single-file calls in a loop raise CRITICAL WARNING 12-3645)
proc add_src_list {fileset files} {
  set new {}
  foreach f $files {
    set f [file normalize $f]
    if { [llength [get_files -quiet -of_objects [get_filesets $fileset] $f]] == 0 && [lsearch -exact $new $f] < 0 } {
      lappend new $f
    }
  }
  if { [llength $new] > 0 } { add_files -norecurse -fileset $fileset $new }
}
proc add_src_once {fileset f} { add_src_list $fileset [list $f] }
source [file normalize "$origin_dir/scripts/rocelet_sources.tcl"]
set hdl_dir [file normalize "$origin_dir/src/hdl"]
add_src_list sources_1 [concat [list "$hdl_dir/rsys_pkg.sv"] [lsort [glob -nocomplain "$hdl_dir/*.sv" "$hdl_dir/*.v"]]]

# The MAC of this target ("mac" in data.json) and its adapter to rocelet_sys's generic MAC
# boundary (src/hdl/mac): cmac = the CMAC IP (created by the block design) + mac_cmac_adapt;
# omac_10g = the open-source 10GBASE-R MAC of the opsero-ethernet-mac submodule on one GTH
# channel (the free gtwizard_ultrascale IP, generated here by the submodule's gen_gt.tcl)
# + mac_omac10g; omac_40g = the open-source 40GBASE-R4 MAC of the same submodule on the four
# GTH channels of OP120 port 0 (gtwizard omac_gth_40g, gen_gt.tcl omac_gen_gth_x4) + mac_omac40g
proc omac_read_f {omac_dir f} {
  if {![file exists $f]} {
    puts "ERROR: the opsero-ethernet-mac submodule is not checked out ($f not found)."
    puts "       Fetch it with: git submodule update --init --recursive"
    exit 1
  }
  set src {}
  set fh [open $f r]
  foreach line [split [read $fh] "\n"] {
    set line [string trim $line]
    if {$line eq "" || [string match "#*" $line]} { continue }
    lappend src [file normalize "$omac_dir/$line"]
  }
  close $fh
  return $src
}
set mac_dir [file normalize "$hdl_dir/mac"]
switch -- $mac_type {
  cmac {
    add_src_list sources_1 [list "$mac_dir/mac_cmac_adapt.v"]
  }
  omac_10g {
    set omac_dir [file normalize "$repo_root/submodules/opsero-ethernet-mac"]
    set omac_f "$omac_dir/ip/omac_10g/rtl/omac_10g.f"
    if {![file exists $omac_f]} {
      puts "ERROR: the opsero-ethernet-mac submodule is not checked out ($omac_f not found)."
      puts "       Fetch it with: git submodule update --init --recursive"
      exit 1
    }
    set omac_src {}
    set fh [open $omac_f r]
    foreach line [split [read $fh] "\n"] {
      set line [string trim $line]
      if {$line eq "" || [string match "#*" $line]} { continue }
      lappend omac_src [file normalize "$omac_dir/$line"]
    }
    close $fh
    lappend omac_src [file normalize "$omac_dir/gt/omac_gt_usp_gth/omac_gt_usp_gth.sv"]
    add_src_list sources_1 $omac_src
    # GTH channel of OP120 port 0 lane 0 on this board (data.json gt_channels entry 0, e.g.
    # ZCU106 HPC0 DP0 = GTHE4_CHANNEL_X0Y14) and its reference clock (gt_refclk, e.g. clk0 =
    # MGTREFCLK0 of quad 226 = GBTCLK0)
    set omac_gen_gth_noauto 1
    source "$omac_dir/gt/omac_gt_usp_gth/gen_gt.tcl"
    set gt_ip [omac_gen_gth [file normalize "$origin_dir/$design_name/ip"] [lindex $gt_channels 0] 100]
    omac_set_refclk $gt_ip [lindex $gt_channels 0] $gt_refclk
    # scripts/xsa.tcl synthesises in memory (synth_design): no out-of-context run for the IP
    set_property generate_synth_checkpoint false [get_files -of_objects [get_filesets sources_1] omac_gth_10g.xci]
    generate_target all [get_files -of_objects [get_filesets sources_1] omac_gth_10g.xci]
    add_src_list sources_1 [list "$mac_dir/mac_omac10g.v"]
    set omac_rev "unknown"
    catch { set omac_rev [string trim [exec git -C $omac_dir rev-parse --short HEAD]] }
    puts "INFO: opsero-ethernet-mac $omac_rev: omac_10g, [llength $omac_src] RTL file(s), gtwizard [lindex $gt_channels 0] $gt_refclk"
  }
  omac_40g {
    set omac_dir [file normalize "$repo_root/submodules/opsero-ethernet-mac"]
    set omac_src [omac_read_f $omac_dir "$omac_dir/ip/omac_40g/rtl/omac_40g.f"]
    lappend omac_src [file normalize "$omac_dir/gt/omac_gt_usp_gth/omac_gt_usp_gth_x4.sv"]
    add_src_list sources_1 $omac_src
    # GTH channels of OP120 port 0 lanes 0-3 on this board (data.json gt_channels, e.g. ZCU106
    # HPC0 DP0-3 = GTHE4_CHANNEL X0Y14 X0Y13 X0Y15 X0Y12, master = lane 0) and the master's
    # reference clock (gt_refclk, e.g. clk0 = MGTREFCLK0 of quad 226 = GBTCLK0); the lane map
    # of mac_omac40g (CH_OF_LANE, set by bd_zynqmp.tcl) follows from the same list
    set omac_gen_gth_noauto 1
    source "$omac_dir/gt/omac_gt_usp_gth/gen_gt.tcl"
    set gt_ip [omac_gen_gth_x4 [file normalize "$origin_dir/$design_name/ip"] $gt_channels 100]
    omac_set_refclk $gt_ip [lindex $gt_channels 0] $gt_refclk
    # scripts/xsa.tcl synthesises in memory (synth_design): no out-of-context run for the IP
    set_property generate_synth_checkpoint false [get_files -of_objects [get_filesets sources_1] omac_gth_40g.xci]
    generate_target all [get_files -of_objects [get_filesets sources_1] omac_gth_40g.xci]
    add_src_list sources_1 [list "$mac_dir/mac_omac40g.v"]
    set omac_rev "unknown"
    catch { set omac_rev [string trim [exec git -C $omac_dir rev-parse --short HEAD]] }
    puts "INFO: opsero-ethernet-mac $omac_rev: omac_40g, [llength $omac_src] RTL file(s), gtwizard $gt_channels $gt_refclk, CH_OF_LANE [format 0x%02X $ch_of_lane]"
  }
  default {
    puts "ERROR: unknown MAC type $mac_type"
    exit 1
  }
}
set sv_files [get_files -quiet -of_objects [get_filesets sources_1] *.sv]
if { [llength $sv_files] > 0 } { set_property file_type SystemVerilog $sv_files }
update_compile_order -fileset sources_1

# Constraints: src/constraints/<target>.xdc, or <target>_<mac>.xdc when the target is built with
# one of its other MAC options (data.json "mac_options"; zcu106 + omac_10g: zcu106_omac_10g.xdc);
# the implementation-only <name>_impl.xdc goes with it
set xdc_name $target
if {[file exists [file normalize "$origin_dir/src/constraints/${target}_${mac_type}.xdc"]]} {
  set xdc_name ${target}_${mac_type}
}
puts "INFO: constraints src/constraints/${xdc_name}.xdc"
set xdc [file normalize "$origin_dir/src/constraints/${xdc_name}.xdc"]
add_files -norecurse -fileset constrs_1 $xdc
set_property target_constrs_file $xdc [get_filesets constrs_1]
# optional implementation-only constraints (clocks that exist only after the IP netlists are linked)
set xdc_impl [file normalize "$origin_dir/src/constraints/${xdc_name}_impl.xdc"]
if {[file exists $xdc_impl]} {
  add_files -norecurse -fileset constrs_1 $xdc_impl
  set_property used_in_synthesis false [get_files $xdc_impl]
  set_property used_in_implementation true [get_files $xdc_impl]
}

puts "INFO: Project created:${design_name}"

# Create block design
set bd_script_path "$origin_dir/src/bd/bd_${bd_script}.tcl"
if {![file exists $bd_script_path]} {
    puts "ERROR: Block design script not found: $bd_script_path"
    close_project
    exit 1
}
if {[catch {source $bd_script_path} errmsg]} {
    puts "ERROR: Block design creation failed: $errmsg"
    catch {save_bd_design}
    close_project
    exit 1
}

# Generate the wrapper
make_wrapper -files [get_files *${block_name}.bd] -top
add_files -norecurse ${design_name}/${design_name}.gen/sources_1/bd/${block_name}/hdl/${block_name}_wrapper.v
set_property top ${block_name}_wrapper [get_filesets sources_1]

# Update the compile order
update_compile_order -fileset sources_1

# Ensure parameter propagation has been performed
close_bd_design [current_bd_design]
open_bd_design [get_files ${block_name}.bd]
validate_bd_design -force
save_bd_design
close_project
