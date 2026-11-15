# Out-of-context synthesis (+ optional implementation) for ZCU104 (xczu7ev-ffvc1156-2-e).
# Run from the prepared work directory (fpga/prepare.py):
#   vivado -mode batch -source synth.tcl -tclargs <top> <period_ns> <impl 0|1> [tag] [NAME:VALUE ...]
# NAME:VALUE pairs become top-level generics (":" because Windows cmd.exe splits "=" in
# arguments); the token RETIME adds synth_design -global_retiming on. Reports: reports_<tag>/.
set top    [lindex $argv 0]
set period [lindex $argv 1]
set impl   [lindex $argv 2]
set tag    [expr {[llength $argv] > 3 ? [lindex $argv 3] : $top}]
set gens   [lrange $argv 4 end]
set part   xczu7ev-ffvc1156-2-e
file mkdir reports_$tag
source files.tcl
set gopt {}
foreach g $gens {
  if {$g eq "RETIME"} { lappend gopt -global_retiming on } else { lappend gopt -generic [string map {: =} $g] }
}
synth_design -top $top -part $part -mode out_of_context -include_dirs $inc_dirs -flatten_hierarchy rebuilt {*}$gopt
create_clock -name clk -period $period [get_ports clk_i]
report_utilization -file reports_$tag/util_synth.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file reports_$tag/util_synth_hier.rpt
report_timing_summary -max_paths 10 -file reports_$tag/timing_synth.rpt
if {$impl} {
  opt_design
  place_design
  route_design
  report_utilization -file reports_$tag/util_route.rpt
  report_utilization -hierarchical -hierarchical_depth 3 -file reports_$tag/util_route_hier.rpt
  report_timing_summary -max_paths 10 -file reports_$tag/timing_route.rpt
}
puts "DONE $tag"
