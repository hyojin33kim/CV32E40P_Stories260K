# FPU-only check (run from a directory prepared by fpga/xsim/run_fpu_test.sh):
#   1. xsim RTL simulation of cv32e40p_fp_wrapper        -> fpu_out_rtl.hex
#   2. Vivado synthesis of cv32e40p_fp_wrapper (OOC, LAT 4) -> fpu_funcsim.v (post-synthesis functional netlist)
#   3. xsim simulation of that netlist                   -> fpu_out_net.hex
set part xczu7ev-ffvc1156-2-e
set fh [open files.tcl]
foreach line [split [read $fh] "\n"] {
  if {[string match "read_verilog*" $line]} { lappend srcs [file normalize [lindex $line end]]
  } elseif {[string match "set inc_dirs*" $line]} { eval $line }
}
close $fh
foreach d $inc_dirs { lappend incs [file normalize $d] }
proc run_sim {name files define} {
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
  file copy -force ./$name/$name.sim/sim_1/behav/xsim/fpu_out.hex fpu_out_$name.hex
  close_project
}
if {![file exists fpu_out_rtl.hex]} { run_sim rtl $srcs {XSIM} }
if {![file exists fpu_funcsim.v]} {
read_verilog -sv $srcs
synth_design -top cv32e40p_fp_wrapper -part $part -mode out_of_context -include_dirs $incs \
  -generic FPU_ADDMUL_LAT=4 -generic FPU_OTHERS_LAT=4 -flatten_hierarchy rebuilt
write_verilog -force -mode funcsim fpu_funcsim.v
close_design
}
run_sim net [list [file normalize fpu_funcsim.v]] {NETLIST}
puts "FPU TEST FINISHED"
