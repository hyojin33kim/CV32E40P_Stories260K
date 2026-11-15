#!/bin/bash
# CPU alone, PipeConfig DISTRIBUTED (work-dir copy), 200 MHz: separate FPU_ADDMUL_LAT / FPU_OTHERS_LAT
# (the CONV group became the worst path at ADDMUL=OTHERS=4). 3 runs at a time (5 crashed Vivado).
set -u
WB=/mnt/e/fpga_work/cv32e40p_dist
cd "$WB"
grep -q 'PipeConfig: fpnew_pkg::DISTRIBUTED' rtl/cv32e40p_fp_wrapper.sv || { echo "work dir not patched"; exit 1; }
for c in "4 6" "5 5" "5 6"; do
  set -- $c
  ~/bin/vivado -mode batch -nojournal -log cpu_d$1o$2.log -source synth.tcl \
    -tclargs cv32e40p_top 5.0 1 cpu_d$1o$2 FPU:1 FPU_ADDMUL_LAT:$1 FPU_OTHERS_LAT:$2 > cpu_d$1o$2.out 2>&1 &
done
wait
for c in "4 6" "5 5" "5 6"; do
  set -- $c
  echo "== DISTRIBUTED addmul $1 others $2"
  grep -A2 'WNS(ns)' reports_cpu_d$1o$2/timing_route.rpt | sed -n 3p
  grep -m1 'Data Path Delay' reports_cpu_d$1o$2/timing_route.rpt
  grep -m1 -E '^  Destination:' reports_cpu_d$1o$2/timing_route.rpt
done
