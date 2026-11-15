#!/bin/bash
# CPU alone (FPU=1), 200 MHz target, FPU pipeline experiments:
#   A) global retiming, FPU_ADDMUL_LAT 3/4 (registers AFTER the FMA, retimed by synthesis)
#   B) PipeConfig DISTRIBUTED (patched only in a separate work-dir copy), FPU_ADDMUL_LAT 2/3/4
# Register placement only -> same arithmetic. Usage: fpga/run_cpu_pipe.sh
set -u
H="$(cd "$(dirname "$0")" && pwd)"
WA=/mnt/e/fpga_work/cv32e40p_stories
WB=/mnt/e/fpga_work/cv32e40p_dist
python3 "$H/prepare.py" "$WA" > /dev/null
python3 "$H/prepare.py" "$WB" > /dev/null
sed -i 's/PipeConfig: fpnew_pkg::AFTER/PipeConfig: fpnew_pkg::DISTRIBUTED/' "$WB/rtl/cv32e40p_fp_wrapper.sv"
grep -q 'PipeConfig: fpnew_pkg::DISTRIBUTED' "$WB/rtl/cv32e40p_fp_wrapper.sv" || { echo "patch failed"; exit 1; }
run() { (cd "$1" && ~/bin/vivado -mode batch -nojournal -log $2.log -source synth.tcl \
  -tclargs cv32e40p_top 5.0 1 $2 FPU:1 FPU_ADDMUL_LAT:$3 FPU_OTHERS_LAT:$3 $4 > $2.out 2>&1) & }
run "$WA" cpu_grt3 3 RETIME
run "$WA" cpu_grt4 4 RETIME
run "$WB" cpu_dist2 2 ""
run "$WB" cpu_dist3 3 ""
run "$WB" cpu_dist4 4 ""
wait
for x in "$WA cpu_grt3" "$WA cpu_grt4" "$WB cpu_dist2" "$WB cpu_dist3" "$WB cpu_dist4"; do
  set -- $x
  echo "== $2"; grep -A2 'WNS(ns)' $1/reports_$2/timing_route.rpt | sed -n 3p
  grep -m1 'Data Path Delay' $1/reports_$2/timing_route.rpt
  grep -E '^\| CLB LUTs|^\| CLB Registers' $1/reports_$2/util_route.rpt | head -2
done
