# xsim check of the fpnew_pkg format-table construct (run from the fpu_test work directory)
create_project -force fpfmt ./fpfmt_proj -part xczu7ev-ffvc1156-2-e
add_files -fileset sim_1 -norecurse [file normalize tb_fpfmt.sv]
set_property top tb_fpfmt [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {-all} -objects [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
close_sim
close_project
puts "FPFMT TEST FINISHED"
