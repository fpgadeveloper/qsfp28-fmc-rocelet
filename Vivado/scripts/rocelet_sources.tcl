# SPDX-License-Identifier: MIT
#
# rocelet_sources.tcl - add the rocelet RoCE v2 engine to the current project:
# the RTL listed in submodules/rocelet/rtl/rocelet.f (paths relative to the
# rocelet repository root, compile order; '#' starts a comment) and, if the
# engine ships them, its constraint files (rtl/rocelet.xdc / *.tcl listed in
# rtl/rocelet_xdc.f, implementation only).
#
# Copyright (c) 2026 Opsero Electronic Design Inc.
#
# Usage (from scripts/build.tcl): set repo_root, define add_src_once (and add_src_list,
# which adds a list in one call), then
#   source $origin_dir/scripts/rocelet_sources.tcl
# Afterwards $rocelet_rtl holds the files that were added.

if {![info exists repo_root]} {
    error "rocelet_sources.tcl: set repo_root to the repository root before sourcing"
}
set rocelet_dir [file normalize "$repo_root/submodules/rocelet"]
set rocelet_f   "$rocelet_dir/rtl/rocelet.f"
if {![file exists $rocelet_f]} {
    puts "ERROR: the rocelet engine is not checked out ($rocelet_f not found)."
    puts "       It is a git submodule. Fetch it with:"
    puts "         git submodule update --init --recursive"
    error "rocelet submodule missing"
}

proc rocelet_read_list {f root} {
    set fh [open $f r]
    set lines [split [read $fh] "\n"]
    close $fh
    set out {}
    foreach line $lines {
        set line [string trim $line]
        if {$line eq "" || [string match "#*" $line] || [string match "//*" $line]} { continue }
        set p [file normalize [file join $root $line]]
        if {![file exists $p]} {
            error "rocelet_sources.tcl: $f lists a missing file: $line"
        }
        if {[lsearch -exact $out $p] < 0} { lappend out $p }
    }
    return $out
}

set rocelet_rtl [rocelet_read_list $rocelet_f $rocelet_dir]
if {[llength [info procs add_src_list]]} {
    add_src_list sources_1 $rocelet_rtl
} else {
    foreach f $rocelet_rtl { add_src_once sources_1 $f }
}
set rocelet_sv {}
foreach f $rocelet_rtl { if {[string match "*.sv" $f]} { lappend rocelet_sv $f } }
if {[llength $rocelet_sv]} {
    set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1] $rocelet_sv]
}

set rocelet_xdc {}
if {[file exists "$rocelet_dir/rtl/rocelet_xdc.f"]} {
    set rocelet_xdc [rocelet_read_list "$rocelet_dir/rtl/rocelet_xdc.f" $rocelet_dir]
    foreach f $rocelet_xdc {
        add_src_once constrs_1 $f
        set xf [get_files -of_objects [get_filesets constrs_1] $f]
        set_property used_in_synthesis false $xf
        set_property used_in_implementation true $xf
        set_property PROCESSING_ORDER LATE $xf
    }
}

set rocelet_rev "unknown"
catch { set rocelet_rev [string trim [exec git -C $rocelet_dir rev-parse --short HEAD]] }
puts "INFO: \[rocelet_sources\] rocelet $rocelet_rev: [llength $rocelet_rtl] RTL file(s), [llength $rocelet_xdc] constraint file(s)"
