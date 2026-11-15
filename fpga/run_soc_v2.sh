#!/bin/bash
# SoC v2 RTL (BRAM/LUT-RAM buffers, pipelined accelerator FPUs) at 150 MHz on ZCU104:
# CPU FPU latency 4, accelerator FPU latency 4, GEMV RUN 8, FPU registers DISTRIBUTED.
# Synthesis + implementation (OOC). Usage: fpga/run_soc_v2.sh [workdir] [extra synth.tcl tokens, e.g. EXPLORE]
set -u
WD=${1:-/mnt/e/fpga_work/soc_v2}; shift || true
PIPE_DIST=1 python3 "$(dirname "$0")/prepare.py" "$WD"
cd "$WD"
~/bin/vivado -mode batch -nojournal -log soc_v2.log -source synth.tcl \
  -tclargs soc_top 6.667 1 soc_v2 CPU_FPU_LAT:4 ACC_FPU_LAT:4 VFU_FPU_LAT:4 ACC_RUN:8 "$@" > soc_v2.out 2>&1
echo "== synthesis"; grep -A2 'WNS(ns)' reports_soc_v2/timing_synth.rpt | sed -n 3p
grep -E '^\| (CLB LUTs|CLB Registers|Block RAM Tile|URAM|DSPs)' reports_soc_v2/util_synth.rpt
echo "== route"; grep -A2 'WNS(ns)' reports_soc_v2/timing_route.rpt | sed -n 3p
grep -E '^\| (CLB LUTs|CLB Registers|Block RAM Tile|URAM|DSPs)' reports_soc_v2/util_route.rpt
grep -m1 'Data Path Delay' reports_soc_v2/timing_route.rpt
