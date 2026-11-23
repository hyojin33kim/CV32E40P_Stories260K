#!/bin/bash
# FPU-only check: numpy IEEE expected vs xsim RTL vs xsim post-synthesis netlist (and Verilator on demand).
# Usage: fpga/xsim/run_fpu_test.sh [workdir]
set -u
W=$(cd "$(dirname "$0")/../.." && pwd); WD=${1:-/mnt/e/fpga_work/fpu_test}
[ -f "$WD/fpu_funcsim.v" ] || PIPE_DIST=1 python3 "$W/fpga/prepare.py" "$WD" > /dev/null
# xsim evaluates FP_ENCODINGS[<variable>] wrongly (docs/XSIM_VS_VERILATOR.md); patch the RTL copy (the netlist is not affected)
python3 "$W/fpga/xsim/xsim_workaround.py" "$WD" || exit 1
cp "$W/fpga/xsim/tb_fpu.sv" "$W/fpga/xsim/run_fpu_test.tcl" "$WD/"
python3 "$W/fpga/xsim/fpu_vectors.py" "$WD"
cd "$WD"
rm -f fpu_out_rtl.hex fpu_out_net.hex   # run_fpu_test.tcl skips a simulation whose result file exists: never compare against stale results
~/bin/vivado -mode batch -nojournal -log fpu.log -source run_fpu_test.tcl > fpu.out 2>&1
grep -E "TB_FPU|FPU TEST FINISHED|^ERROR" fpu.out | head
python3 "$W/fpga/xsim/fpu_compare.py" vec.hex expect.hex cat.txt rtl=fpu_out_rtl.hex net=fpu_out_net.hex
