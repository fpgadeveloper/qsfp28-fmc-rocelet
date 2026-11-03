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
#  <label> { <url> <boardname> <bdscript> <port> <fec> <selftest> { <rocelet_sys parameters> } })
# UPDATER START
dict set target_dict kcu116 { xilinx.com kcu116 microblaze 0 rs 1 { NUM_QP 16 NUM_MR 16 READ_DEPTH 16 MAX_WR 128 RTX_MODE RING RING_BYTES 262144 HSB_EN 1 MEM_BYTES 262144 } }
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
# rocelet_sys_bd parameters; RTX_MODE is passed as a number (0 RING, 1 REREAD, 2 LOSSY)
set eng_params {}
dict for {k v} [lindex $tdesc 6] {
  if {$k eq "RTX_MODE"} {
    set v [dict get {RING 0 REREAD 1 LOSSY 2} $v]
  }
  dict set eng_params $k $v
}
puts "Port $port, FEC $fec, self-test $selftest, rocelet_sys parameters: $eng_params"

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
set sv_files [get_files -quiet -of_objects [get_filesets sources_1] *.sv]
if { [llength $sv_files] > 0 } { set_property file_type SystemVerilog $sv_files }
update_compile_order -fileset sources_1

# Constraints
set xdc [file normalize "$origin_dir/src/constraints/${target}.xdc"]
add_files -norecurse -fileset constrs_1 $xdc
set_property target_constrs_file $xdc [get_filesets constrs_1]

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
