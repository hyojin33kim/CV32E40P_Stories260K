#!/bin/bash
# ZCU104 board build (block design + bitstream). Usage: fpga/bd/run_board.sh [MHz=125] [workdir] [gui]
#   gui: build the block design and open the Vivado GUI (no implementation) to look at the diagram.
# Results in <workdir>/out: board.bit, board.hwh (PYNQ), timing_impl.rpt, util_impl.rpt, clocks.rpt.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
MHZ=${1:-125}; WD=${2:-/mnt/e/fpga_work/board_$MHZ}; MODE=${3:-}
PIPE_DIST=1 python3 "$W/fpga/prepare.py" "$WD" > /dev/null
cp "$W/fpga/bd/build_board.tcl" "$W/fpga/bd/chip_axi_wrap.v" "$WD/"
cd "$WD"
~/bin/vivado -mode batch -nojournal -log board.log -source build_board.tcl -tclargs "$MHZ" $MODE > board.out 2>&1
grep -E "BOARD_PART|PL0_ACTUAL_MHZ|BOARD BUILD DONE|^ERROR|CRITICAL WARNING: \[(BD|Timing)" board.out | head -20
[ -f out/timing_impl.rpt ] && { echo "== timing"; grep -A2 'WNS(ns)' out/timing_impl.rpt | sed -n 3p;
  grep -E '^\| (CLB LUTs|CLB Registers|Block RAM Tile|URAM|DSPs) ' out/util_impl.rpt; ls -la out/; }
