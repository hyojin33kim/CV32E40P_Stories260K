#!/bin/bash
# Vivado xsim run of soc_chip (XPM URAM + UNISIM models) on one image, compared with the Verilator chip sim.
# Usage: [CG=bhv] [TRACE_N=<cycles>] [FIXCLK=0] [FIXFMT=0] fpga/xsim/run_xsim.sh <image.bin> [workdir] [gui]
#   image.bin : e.g. repro/hold/image_1.bin or gen/out_8_*/image.bin
#   workdir   : default /mnt/e/fpga_work/xsim
#   gui       : open the Vivado GUI (Flow Navigator > Run Simulation for waveforms) instead of batch
# Batch result: <workdir>/xsim_dump.bin and a byte compare with obj_chip/Vsoc_chip on the same image.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
IMG=$(readlink -f "$1"); WD=${2:-/mnt/e/fpga_work/xsim}; MODE=${3:-}
PIPE_DIST=1 python3 "$W/fpga/prepare.py" "$WD" > /dev/null
cp "$W/fpga/xsim/tb_chip.sv" "$W/fpga/xsim/run_xsim.tcl" "$WD/"
# CG=bhv: behavioural latch clock gate (the Verilator sim's) instead of the FPGA BUFGCE in this run
if [ "${CG:-fpga}" = bhv ]; then cp "$W/cv32e40p-master/bhv/cv32e40p_sim_clock_gate.sv" "$WD/fpga/cv32e40p_clock_gate_fpga.sv" || exit 1; fi
# FIXCLK=1 (default): OpenE906 FDSU/FPU-dp "gated" clocks are plain pass-throughs (assign clk_out = clk_in);
# in an event-driven simulator that delays them by a delta and races the clk_i flops (fsqrt/fdiv finish
# early with wrong results). Clock those flops from forever_cpuclk directly in this work copy only.
if [ "${FIXCLK:-1}" = 1 ]; then python3 - "$WD" <<'PYEOF'
import re, sys
from pathlib import Path
base = Path(sys.argv[1]) / 'rtl/vendor/pulp_platform_fpnew/vendor/opene906/E906_RTL_FACTORY/gen_rtl'
gated = ['fdsu_clk', 'ex1_pipe_clk', 'ex2_pipe_clk', 'expnt_rst_clk', 'ex3_pipe_clk', 'ex1_ex2_pipe_clk',
         'srt_div_clk', 'qt_clk', 'ex2_data_clk']
n = 0
for f in list((base / 'fdsu/rtl').glob('*.v')) + [base / 'fpu/rtl/pa_fpu_dp.v']:
    t = f.read_text()
    t2 = re.sub(r'posedge\s+(' + '|'.join(gated) + r')\b', 'posedge forever_cpuclk', t)
    if t2 != t: n += len(re.findall(r'posedge\s+(?:' + '|'.join(gated) + r')\b', t)); f.write_text(t2)
print(f'FIXCLK: {n} always blocks reclocked to forever_cpuclk')
PYEOF
fi
# FIXFMT=1 (default): xsim evaluates FP_ENCODINGS[<variable>] in fpnew_pkg wrongly (exp_bits 7 for every format), which breaks fp
# add/mul/int-to-float; rewrite those functions with constant indices in this work copy (docs/XSIM_VS_VERILATOR.md)
if [ "${FIXFMT:-1}" = 1 ]; then python3 "$W/fpga/xsim/xsim_workaround.py" "$WD" || exit 1; fi
python3 - "$IMG" "$WD" <<'EOF'
import struct, sys
from pathlib import Path
img, wd = Path(sys.argv[1]).read_bytes(), Path(sys.argv[2])
def hexfile(name, base, words):
    with open(wd / name, 'w') as f:
        for i in range(words):
            f.write('%08x\n' % struct.unpack_from('<I', img, base + 4 * i)[0])
hexfile('imem.hex', 0x1000000, 4096)
hexfile('sram.hex', 0x0, 524288)
EOF
cd "$WD"
if [ "$MODE" = gui ]; then
  ~/bin/vivado -mode batch -nojournal -log xsim.log -source run_xsim.tcl -tclargs gui
  exit
fi
rm -f xsim_proj/xsim_chip.sim/sim_1/behav/xsim/dump.hex
~/bin/vivado -mode batch -nojournal -log xsim.log -source run_xsim.tcl ${TRACE_N:+-tclargs trace $TRACE_N} > xsim.out 2>&1
if [ -n "${TRACE_N:-}" ]; then cp xsim_proj/xsim_chip.sim/sim_1/behav/xsim/trace_xsim.txt . 2>/dev/null; echo "trace -> $WD/trace_xsim.txt"; exit; fi
SIMDIR=xsim_proj/xsim_chip.sim/sim_1/behav/xsim
grep -E "^TB |XSIM FINISHED|ERROR|Fatal" xsim.out $SIMDIR/simulate.log 2>/dev/null | head -20
[ -f $SIMDIR/dump.hex ] || { echo "no dump.hex"; exit 1; }
python3 - "$SIMDIR/dump.hex" "$WD/xsim_dump.bin" <<'EOF'
import struct, sys
w = [int(l, 16) for l in open(sys.argv[1]) if l.strip()]
open(sys.argv[2], 'wb').write(struct.pack('<%dI' % len(w), *w))
EOF
cd "$W"
obj_chip/Vsoc_chip "$IMG" "$WD/verilator_dump.bin" > "$WD/verilator.log" 2>&1
grep DONE "$WD/verilator.log"
cmp -s "$WD/xsim_dump.bin" "$WD/verilator_dump.bin" && echo "XSIM (XPM) dump == Verilator chip dump (2 MiB, incl. cycle words)" \
  || echo "XSIM dump DIFF: $(cmp -l "$WD/xsim_dump.bin" "$WD/verilator_dump.bin" | wc -l) bytes"
