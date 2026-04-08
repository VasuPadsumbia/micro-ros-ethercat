# ============================================================================
# project.tcl — Gowin IDE synthesis script (alternative to open-source flow)
#
# Usage (from Gowin IDE Tcl console or command line):
#   gowin_ide -batch -run project.tcl
#
# Prerequisites:
#   - Gowin EDA (GWIN_EDU or commercial) installed
#   - RTL source files in ../rtl/
#   - Constraints in ../constraints/tang_nano_20k.cst
# ============================================================================

# ── Project settings ──────────────────────────────────────────────────────
set proj_name   "micro_ros_ethercat_slave"
set proj_dir    [file normalize [file dirname [info script]]/gowin_proj]
set device      "GW2AR-LV18QN88C8/I7"   ;# Tang Nano 20K
set top_module  "top"

# ── Create project ────────────────────────────────────────────────────────
create_project -name $proj_name -dir $proj_dir -device $device -pn GW2AR-18C

# ── Add RTL sources ───────────────────────────────────────────────────────
set rtl_dir [file normalize [file dirname [info script]]/../rtl]
foreach vfile [glob -directory $rtl_dir *.v] {
    add_file -type verilog $vfile
}

# ── Add constraints ───────────────────────────────────────────────────────
set cst_file [file normalize [file dirname [info script]]/../constraints/tang_nano_20k.cst]
add_file -type cst $cst_file

# ── Synthesis options ─────────────────────────────────────────────────────
set_option -synthesis_tool gowinsynthesis
set_option -output_base_name $proj_name
set_option -verilog_std sysv2017
set_option -top_module $top_module

# Timing options
set_option -use_cpu_as_gpio 0
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -use_done_as_gpio 1
set_option -use_reconfign_as_gpio 1

# Optimisation
set_option -strategy "timing"
set_option -gen_text_timing_rpt 1

# ── Run synthesis + place & route ─────────────────────────────────────────
run all

# ── Report ────────────────────────────────────────────────────────────────
puts "Build complete. Bitstream: $proj_dir/impl/pnr/$proj_name.fs"
