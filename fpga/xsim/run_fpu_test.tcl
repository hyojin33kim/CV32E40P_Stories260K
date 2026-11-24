# FPU-only check (run from a directory prepared by fpga/xsim/run_fpu_test.sh):
#   1. xsim RTL simulation of cv32e40p_fp_wrapper        -> fpu_out_rtl.hex, fpu_out_rtl_stream.hex
#   2. Vivado synthesis of cv32e40p_fp_wrapper (OOC, LAT 4) -> fpu_funcsim.v (post-synthesis functional netlist)
#   3. xsim simulation of that netlist                   -> fpu_out_net.hex, fpu_out_net_stream.hex
# "stream" = back-to-back requests per operation group (V-F4, tb_fpu.sv with STREAM defined)
set part xczu7ev-ffvc1156-2-e
set fh [open files.tcl]
foreach line [split [read $fh] "\n"] {
  if {[string match "read_verilog*" $line]} { lappend srcs [file normalize [lindex $line end]]
  } elseif {[string match "set inc_dirs*" $line]} { eval $line }
}
close $fh
foreach d $inc_dirs { lappend incs [file normalize $d] }
proc run_sim {name files define outname} {
  global part incs
  create_project -force $name ./$name -part $part
  add_files -norecurse $files
  set_property include_dirs $incs [current_fileset]
  add_files -fileset sim_1 -norecurse [list [file normalize tb_fpu.sv] [file normalize vec.hex]]
  set_property include_dirs $incs [get_filesets sim_1]
  set_property top tb_fpu [get_filesets sim_1]
  set_property verilog_define $define [get_filesets sim_1]
  set_property -name {xsim.simulate.runtime} -value {-all} -objects [get_filesets sim_1]
  update_compile_order -fileset sim_1
  launch_simulation -simset sim_1 -mode behavioral
  close_sim
  file copy -force ./$name/$name.sim/sim_1/behav/xsim/$outname fpu_out_$name.hex
  close_project
}
if {![file exists fpu_out_rtl.hex]} { run_sim rtl $srcs {XSIM} fpu_out.hex }
if {![file exists fpu_out_rtl_stream.hex]} { run_sim rtl_stream $srcs {XSIM STREAM} fpu_out_stream.hex }
if {![file exists fpu_funcsim.v]} {
read_verilog -sv $srcs
synth_design -top cv32e40p_fp_wrapper -part $part -mode out_of_context -include_dirs $incs \
  -generic FPU_ADDMUL_LAT=4 -generic FPU_OTHERS_LAT=4 -flatten_hierarchy rebuilt
write_verilog -force -mode funcsim fpu_funcsim.v
close_design
}
run_sim net [list [file normalize fpu_funcsim.v]] {NETLIST} fpu_out.hex
run_sim net_stream [list [file normalize fpu_funcsim.v]] {NETLIST STREAM} fpu_out_stream.hex
puts "FPU TEST FINISHED"
