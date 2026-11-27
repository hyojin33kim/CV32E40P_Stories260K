#!/bin/bash
# S6: board top chip_axi_top (soc_chip D2 + 16 KB imem + 2 MiB SRAM in URAM + AXI4-Lite slave) at
# 150 MHz on ZCU104, synthesis + implementation (OOC, FPU registers DISTRIBUTED).
# Usage: [TOP=soc_chip] [PERIOD=8.0 (125 MHz)] fpga/run_chip.sh [workdir] [extra synth.tcl tokens, e.g. EXPLORE]
set -u
# portable: VIVADO = vivado command (default ~/bin/vivado of the WSL setup if it exists, else vivado on PATH); FPGA_WORK = parent of the default work dir
[ -n "${VIVADO:-}" ] || { if [ -x ~/bin/vivado ]; then VIVADO=~/bin/vivado; else VIVADO=vivado; fi; }
FPGA_WORK=${FPGA_WORK:-/mnt/e/fpga_work}
WD=${1:-$FPGA_WORK/chip}; shift || true
PIPE_DIST=1 python3 "$(dirname "$0")/prepare.py" "$WD"
cd "$WD"
"$VIVADO" -mode batch -nojournal -log chip.log -source synth.tcl \
  -tclargs ${TOP:-chip_axi_top} ${PERIOD:-6.667} 1 chip "$@" > chip.out 2>&1
echo "== synthesis"; grep -A2 'WNS(ns)' reports_chip/timing_synth.rpt | sed -n 3p
grep -E '^\| (CLB LUTs|CLB Registers|Block RAM Tile|URAM|DSPs)' reports_chip/util_synth.rpt
echo "== route"; grep -A2 'WNS(ns)' reports_chip/timing_route.rpt | sed -n 3p
grep -E '^\| (CLB LUTs|CLB Registers|Block RAM Tile|URAM|DSPs)' reports_chip/util_route.rpt
grep -m1 'Data Path Delay' reports_chip/timing_route.rpt
