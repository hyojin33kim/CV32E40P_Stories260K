#!/bin/bash
# S6: soc_chip (soc_top D2 + 16 KB imem + 1 MB SRAM) at 150 MHz on ZCU104, synthesis + implementation
# (OOC, FPU registers DISTRIBUTED). Usage: fpga/run_chip.sh [workdir] [extra synth.tcl tokens, e.g. EXPLORE]
set -u
WD=${1:-/mnt/e/fpga_work/chip}; shift || true
PIPE_DIST=1 python3 "$(dirname "$0")/prepare.py" "$WD"
cd "$WD"
~/bin/vivado -mode batch -nojournal -log chip.log -source synth.tcl \
  -tclargs soc_chip 6.667 1 chip "$@" > chip.out 2>&1
echo "== synthesis"; grep -A2 'WNS(ns)' reports_chip/timing_synth.rpt | sed -n 3p
grep -E '^\| (CLB LUTs|CLB Registers|Block RAM Tile|URAM|DSPs)' reports_chip/util_synth.rpt
echo "== route"; grep -A2 'WNS(ns)' reports_chip/timing_route.rpt | sed -n 3p
grep -E '^\| (CLB LUTs|CLB Registers|Block RAM Tile|URAM|DSPs)' reports_chip/util_route.rpt
grep -m1 'Data Path Delay' reports_chip/timing_route.rpt
