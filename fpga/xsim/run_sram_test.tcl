# xsim unit test: sram_dp (XPM URAM model) vs sram_beh (behavioural). Run in a directory holding
# sram_dp.sv, sram_beh.sv, tb_sram.sv:  vivado -mode batch -source run_sram_test.tcl
create_project -force sram_test ./sram_proj -part xczu7ev-ffvc1156-2-e
add_files -norecurse [list [file normalize sram_dp.sv] [file normalize sram_beh.sv]]
add_files -fileset sim_1 -norecurse [file normalize tb_sram.sv]
set_property top tb_sram [get_filesets sim_1]
set_property verilog_define {USE_XPM} [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {-all} -objects [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
close_sim
puts "SRAM TEST FINISHED"
