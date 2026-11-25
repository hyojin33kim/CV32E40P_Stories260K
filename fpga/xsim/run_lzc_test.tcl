# xsim RTL simulation of the common_cells lzc for the widths fpnew uses (run from the fpu_test work directory)
set part xczu7ev-ffvc1156-2-e
set srcs [list [file normalize rtl/vendor/pulp_platform_common_cells/src/cf_math_pkg.sv] [file normalize rtl/vendor/pulp_platform_common_cells/src/lzc.sv]]
create_project -force lzc ./lzc_proj -part $part
add_files -norecurse $srcs
add_files -fileset sim_1 -norecurse [file normalize tb_lzc.sv]
set_property top tb_lzc [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {-all} -objects [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
close_sim
close_project
puts "LZC TEST FINISHED"
