#!/bin/bash
# CPU alone (cv32e40p_top, FPU=1): synthesis + implementation at 200 MHz for
# FPU_ADDMUL_LAT = 0/1/2 (FPU_OTHERS_LAT same), to find the CPU's own Fmax.
# Work dir must be under /mnt/<drive> (Windows Vivado). Usage: fpga/run_cpu_lat.sh <workdir>
set -u
WD=${1:-/mnt/e/fpga_work/cv32e40p_stories}
python3 "$(dirname "$0")/prepare.py" "$WD"
cd "$WD"
for lat in 0 1 2; do
  ~/bin/vivado -mode batch -nojournal -log cpu_lat$lat.log -source synth.tcl \
    -tclargs cv32e40p_top 5.0 1 cpu_lat$lat FPU:1 FPU_ADDMUL_LAT:$lat FPU_OTHERS_LAT:$lat > cpu_lat$lat.out 2>&1 &
done
wait
for lat in 0 1 2; do
  echo "== FPU_ADDMUL_LAT=$lat"
  grep -A2 'WNS(ns)' reports_cpu_lat$lat/timing_route.rpt | sed -n 3p
  grep -E '^\| CLB LUTs|^\| CLB Registers|^\| DSPs' reports_cpu_lat$lat/util_route.rpt
done
