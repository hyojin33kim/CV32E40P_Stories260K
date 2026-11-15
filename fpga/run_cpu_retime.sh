#!/bin/bash
# CPU alone (FPU=1) with synthesis retiming, FPU_ADDMUL_LAT = 2/3/4: can register retiming
# pull the FPU's output pipeline registers into the FMA logic? Usage: fpga/run_cpu_retime.sh <workdir>
set -u
WD=${1:-/mnt/e/fpga_work/cv32e40p_stories}
python3 "$(dirname "$0")/prepare.py" "$WD"
cd "$WD"
for lat in 2 3 4; do
  ~/bin/vivado -mode batch -nojournal -log cpu_rt$lat.log -source synth.tcl \
    -tclargs cv32e40p_top 5.0 1 cpu_rt$lat FPU:1 FPU_ADDMUL_LAT:$lat FPU_OTHERS_LAT:$lat RETIME > cpu_rt$lat.out 2>&1 &
done
wait
for lat in 2 3 4; do
  echo "== retiming, FPU_ADDMUL_LAT=$lat"
  grep -A2 'WNS(ns)' reports_cpu_rt$lat/timing_route.rpt | sed -n 3p
  grep -m1 'Data Path Delay' reports_cpu_rt$lat/timing_route.rpt
done
