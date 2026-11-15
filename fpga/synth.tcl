# Out-of-context synthesis + implementation of the SoC (CV32E40P + gemv_acc + vfu) for ZCU104.
# Run from the prepared work directory (fpga/prepare.py):  vivado -mode batch -source synth.tcl
#   -tclargs <top> <period_ns> <impl 0|1>
set top    [lindex $argv 0]
set period [lindex $argv 1]
set impl   [lindex $argv 2]
set part   xczu7ev-ffvc1156-2-e
file mkdir reports_$top
source files.tcl
synth_design -top $top -part $part -mode out_of_context -include_dirs $inc_dirs -flatten_hierarchy rebuilt
create_clock -name clk -period $period [get_ports clk_i]
report_utilization -file reports_$top/util_synth.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file reports_$top/util_synth_hier.rpt
report_timing_summary -max_paths 10 -file reports_$top/timing_synth.rpt
if {$impl} {
  opt_design
  place_design
  route_design
  report_utilization -file reports_$top/util_route.rpt
  report_utilization -hierarchical -hierarchical_depth 3 -file reports_$top/util_route_hier.rpt
  report_timing_summary -max_paths 10 -file reports_$top/timing_route.rpt
}
puts "DONE $top"
