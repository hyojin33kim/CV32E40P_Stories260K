# Vivado xsim simulation of the POST-SYNTHESIS functional netlist of soc_chip (netlist_net.v, written by fpga/synth.tcl with the token
# NETLIST) with tb_chip.sv (defined NETLIST: no RTL-internal traces, GSR wait). Run from the work directory (fpga/xsim/run_xsim_net.sh).
#   vivado -mode batch -source run_xsim_net.tcl -tclargs <plusargs>      e.g. "MAXCYC=3000 LOADMAX=20000"
set plus {}
foreach a $argv { lappend plus "-testplusarg $a" }
create_project -force xsim_net ./xsim_net_proj -part xczu7ev-ffvc1156-2-e
add_files -norecurse [file normalize netlist_net.v]
add_files -fileset sim_1 -norecurse [list [file normalize tb_chip.sv] [file normalize imem.hex] [file normalize sram.hex]]
set_property top tb_chip [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property verilog_define {NETLIST} [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {-all} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.log_all_signals} -value {false} -objects [get_filesets sim_1]
if {[llength $plus] > 0} { set_property -name {xsim.simulate.xsim.more_options} -value [join $plus " "] -objects [get_filesets sim_1] }
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
close_sim
puts "XSIM NET FINISHED"
