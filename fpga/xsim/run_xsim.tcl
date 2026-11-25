# Vivado xsim behavioural simulation of soc_chip with the synthesized memory models (XPM URAM via
# USE_XPM, UNISIM BUFGCE clock gate). Run from the prepared work directory (fpga/xsim/run_xsim.sh).
#   vivado -mode batch -source run_xsim.tcl -tclargs [gui]
# "gui" opens the project in the Vivado GUI (waveform window) instead of running in batch.
set gui [expr {[llength $argv] > 0 && [lindex $argv 0] eq "gui"}]
set trace_n [expr {[llength $argv] > 1 && [lindex $argv 0] eq "trace" ? [lindex $argv 1] : 0}]
create_project -force xsim_chip ./xsim_proj -part xczu7ev-ffvc1156-2-e
# files.tcl (fpga/prepare.py) is a non-project list: "set inc_dirs [...]" + "read_verilog [-sv] <file>"
set fh [open files.tcl]
foreach line [split [read $fh] "\n"] {
  if {[string match "read_verilog*" $line]} { add_files -norecurse [lindex $line end]
  } elseif {[string match "set inc_dirs*" $line]} { eval $line }
}
close $fh
foreach d $inc_dirs { lappend incs [file normalize $d] }
set_property include_dirs $incs [current_fileset]
set_property include_dirs $incs [get_filesets sim_1]
add_files -fileset sim_1 tb_chip.sv
set_property top tb_chip [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property verilog_define {USE_XPM XSIM} [get_filesets sim_1]   ;# XSIM: vendor SVA guards
set_property -name {xsim.simulate.runtime} -value {-all} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.log_all_signals} -value {false} -objects [get_filesets sim_1]
if {$trace_n > 0} { set_property -name {xsim.simulate.xsim.more_options} -value "-testplusarg TRACE_N=$trace_n" -objects [get_filesets sim_1] }
if {[file exists plusargs.txt]} {   ;# e.g. "MAXCYC=400000" written by run_xsim.sh from XSIM_PLUS (env vars do not reach Windows vivado)
  set fh [open plusargs.txt]; set pa [string trim [read $fh]]; close $fh
  set pl {}; foreach a $pa { lappend pl "-testplusarg $a" }
  set_property -name {xsim.simulate.xsim.more_options} -value [join $pl " "] -objects [get_filesets sim_1]
}
foreach f {imem.hex sram.hex} { add_files -fileset sim_1 -norecurse $f }
update_compile_order -fileset sim_1
if {$gui} {
  start_gui
} else {
  launch_simulation -simset sim_1 -mode behavioral
  close_sim
  puts "XSIM FINISHED"
}
