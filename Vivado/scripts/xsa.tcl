# Opsero Electronic Design Inc. Copyright 2026
# SPDX-License-Identifier: MIT
#
# Synthesis, implementation, bitstream and XSA export for one target, run INSIDE
# this one Vivado process (no launch_runs child processes): the shared build host
# allows at most two Vivado jobs, counted as Vivado binaries.
#
#   vivado -mode batch -source scripts/xsa.tcl -notrace -tclargs <target> <jobs>
#
# Outputs (where build.py / make-boot.py expect them):
#   <target>/<target>.runs/impl_1/rocelet_wrapper.bit / .mmi / routed.dcp
#   <target>/rocelet_wrapper.xsa
#   <target>/reports/ : utilisation (flat + hierarchical), timing, RAM, clocks
#*****************************************************************************************

if { $argc >= 1 } {
  set target [lindex $argv 0]
  set jobs [expr {$argc >= 2 ? [lindex $argv 1] : 8}]
} elseif { ![info exists target] } {
  puts "Usage: xsa.tcl <target> [jobs]"
  return
}
set design_name ${target}
set block_name rocelet
set origin_dir "."
set_param general.maxThreads [expr {$jobs > 8 ? 8 : $jobs}]

open_project $origin_dir/$design_name/$design_name.xpr
set part [get_property PART [current_project]]
set impl_dir [file normalize "$origin_dir/$design_name/$design_name.runs/impl_1"]
set rpt_dir  [file normalize "$origin_dir/$design_name/reports"]
file mkdir $impl_dir
file mkdir $rpt_dir

# block design: global synthesis (no out-of-context IP runs = no child processes)
set bd_file [get_files ${block_name}.bd]
set_property synth_checkpoint_mode None $bd_file
generate_target all $bd_file

proc stamp {msg} { puts "XSA_STEP [clock format [clock seconds] -format %H:%M:%S] $msg" }

stamp "synth_design"
synth_design -top ${block_name}_wrapper -part $part -flatten_hierarchy rebuilt
write_checkpoint -force $impl_dir/synth.dcp
report_utilization -file $rpt_dir/synth_util.rpt
report_utilization -hierarchical -hierarchical_depth 6 -file $rpt_dir/synth_util_hier.rpt
report_timing_summary -max_paths 20 -file $rpt_dir/synth_timing.rpt

stamp "opt_design"
opt_design
stamp "place_design"
place_design -directive ExtraTimingOpt
stamp "phys_opt_design"
phys_opt_design -directive AggressiveExplore
stamp "route_design"
route_design -directive AggressiveExplore
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
if {$wns < 0} {
  stamp "post-route phys_opt_design (WNS $wns)"
  phys_opt_design -directive AggressiveExplore
}
write_checkpoint -force $impl_dir/routed.dcp

report_timing_summary -max_paths 50 -report_unconstrained -file $rpt_dir/timing.rpt
report_utilization -file $rpt_dir/util.rpt
report_utilization -hierarchical -hierarchical_depth 8 -file $rpt_dir/util_hier.rpt
report_ram_utilization -file $rpt_dir/ram.rpt
report_clock_utilization -file $rpt_dir/clocks.rpt
report_drc -file $rpt_dir/drc.rpt
report_methodology -file $rpt_dir/methodology.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
set fh [open $rpt_dir/summary.txt w]
puts $fh "target $target WNS $wns WHS $whs"
close $fh
stamp "timing WNS $wns WHS $whs"

stamp "write_bitstream"
write_bitstream -force $impl_dir/${block_name}_wrapper.bit
write_mem_info -force $impl_dir/${block_name}_wrapper.mmi

stamp "write_hw_platform"
# The bitstream must be inside the XSA for the Linux flows (sdtgen extracts it for BOOT.BIN).
# In project mode write_hw_platform -include_bit looks for the bitstream of the impl_1 RUN, which
# this in-process flow never launches ("Unable to get BIT file from implementation run"), so
# export from the routed checkpoint instead (non-project: the in-memory design's bitstream).
set xsa_file [file normalize $origin_dir/$design_name/${block_name}_wrapper.xsa]
if {[catch {write_hw_platform -fixed -include_bit -force -file $xsa_file} err]} {
  puts "INFO: project-mode write_hw_platform -include_bit unavailable; exporting from routed.dcp"
  close_project
  open_checkpoint $impl_dir/routed.dcp
  if {[catch {write_hw_platform -fixed -include_bit -force -file $xsa_file} err2]} {
    puts "WARNING: write_hw_platform -include_bit failed ($err2); writing without the bitstream"
    write_hw_platform -fixed -force -file $xsa_file
  }
}
stamp "done"
