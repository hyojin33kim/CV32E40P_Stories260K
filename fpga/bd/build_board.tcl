# ZCU104 board build: Zynq UltraScale+ PS + chip_axi_wrap (chip_axi_top) through IP Integrator.
# Run from a work directory prepared by fpga/bd/run_board.sh:
#   vivado -mode batch -source build_board.tcl -tclargs <pl_clk MHz> [gui]
# Result: out/board.bit, out/board.hwh (PYNQ overlay), out/timing_impl.rpt, out/util_impl.rpt,
#         the project xsim-free in ./board_proj (open board_proj/board.xpr in the GUI to see the diagram).
set mhz [expr {[llength $argv] > 0 ? [lindex $argv 0] : 125}]
set gui [expr {[llength $argv] > 1 && [lindex $argv 1] eq "gui"}]
set part xczu7ev-ffvc1156-2-e
create_project -force board ./board_proj -part $part
set bp [lindex [get_board_parts -quiet *zcu104*] end]
if {$bp ne ""} { set_property board_part $bp [current_project]; puts "BOARD_PART $bp" } else { puts "BOARD_PART none (no preset)" }

# RTL (same list as the OOC synthesis) + the Verilog wrapper
set fh [open files.tcl]
foreach line [split [read $fh] "\n"] {
  if {[string match "read_verilog*" $line]} { lappend srcs [file normalize [lindex $line end]]
  } elseif {[string match "set inc_dirs*" $line]} { eval $line }
}
close $fh
lappend srcs [file normalize chip_axi_wrap.v]
add_files -norecurse $srcs
foreach d $inc_dirs { lappend incs [file normalize $d] }
set_property include_dirs $incs [current_fileset]
# headers must be project files for the module-reference (create_bd_cell) elaboration
set hdrs {}
# only the header the elaboration asked for
foreach d $incs { foreach f [glob -nocomplain $d/*/registers.svh] { lappend hdrs $f } }
if {[llength $hdrs]} {
  add_files -norecurse $hdrs
  set_property file_type {Verilog Header} [get_files $hdrs]
}
update_compile_order -fileset sources_1

# block design
create_bd_design board
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq]
if {$bp ne ""} { apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps }
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0 {1} CONFIG.PSU__USE__M_AXI_GP1 {0} CONFIG.PSU__USE__M_AXI_GP2 {0} \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $mhz \
  CONFIG.PSU__USE__IRQ0 {1}] $ps
set chip [create_bd_cell -type module -reference chip_axi_wrap chip]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
  -config {Master /zynq/M_AXI_HPM0_FPD Clk_master Auto Clk_slave Auto Clk_xbar Auto intc_ip Auto master_apm 0} \
  [get_bd_intf_pins chip/s_axi]
connect_bd_net [get_bd_pins chip/done] [get_bd_pins zynq/pl_ps_irq0]
assign_bd_address
set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces zynq/Data] -filter {NAME =~ *chip*}]
set_property offset 0xA0000000 $seg
set_property range 64M $seg
validate_bd_design
save_bd_design
puts "PL0_ACTUAL_MHZ [get_property CONFIG.PSU__CRL_APB__PL0_REF_CTRL__ACT_FREQMHZ $ps]"
make_wrapper -files [get_files board.bd] -top
add_files -norecurse [glob ./board_proj/board.gen/sources_1/bd/board/hdl/board_wrapper.v]
set_property top board_wrapper [current_fileset]
update_compile_order -fileset sources_1

if {$gui} { start_gui; return }

set_property strategy Performance_Explore [get_runs impl_1]
# Windows Vivado fails (system resources) with parallel child runs and hung with a queued single job:
# run every out-of-context IP synthesis one at a time, then implement with one job.
generate_target all [get_files board.bd]
foreach r [get_runs -filter {IS_SYNTHESIS == 1 && NAME != synth_1}] {
  puts "IP_RUN $r"
  launch_runs $r -jobs 1
  wait_on_run $r
  if {[get_property PROGRESS [get_runs $r]] ne "100%"} { puts "ERROR: IP run $r not finished"; return -code error }
}
launch_runs impl_1 -to_step write_bitstream -jobs 1
wait_on_run impl_1
open_run impl_1
file mkdir out
report_timing_summary -max_paths 10 -file out/timing_impl.rpt
report_utilization -file out/util_impl.rpt
report_clocks -file out/clocks.rpt
file copy -force [glob ./board_proj/board.runs/impl_1/*.bit] out/board.bit
file copy -force [glob ./board_proj/board.gen/sources_1/bd/board/hw_handoff/board.hwh] out/board.hwh
puts "BOARD BUILD DONE"
