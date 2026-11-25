#!/bin/bash
# Post-synthesis functional simulation of the full chip (D4, V-S1): the netlist of soc_chip written by fpga/synth.tcl (token NETLIST)
# on one image through the loader port, compared with the Verilator chip sim.
# Usage: [PLUS="MAXCYC=3000 LOADMAX=20000"] fpga/xsim/run_xsim_net.sh <image.bin> [workdir (default /mnt/e/fpga_work/chip_net)]
#   workdir must contain netlist_net.v:  PIPE_DIST=1 fpga/prepare.py <workdir>; cd <workdir>;
#     vivado -mode batch -source synth.tcl -tclargs soc_chip 8.0 0 net NETLIST
#   PLUS: plusargs for tb_chip.sv; with MAXCYC or LOADMAX the run is a speed measurement and no dump is compared.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
IMG=$(readlink -f "$1"); WD=${2:-/mnt/e/fpga_work/chip_net}
[ -f "$WD/netlist_net.v" ] || { echo "no $WD/netlist_net.v (run the synthesis with the NETLIST token first)"; exit 2; }
cp "$W/fpga/xsim/tb_chip.sv" "$W/fpga/xsim/run_xsim_net.tcl" "$WD/"
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
rm -rf xsim_net_proj
START=$(date +%s)
~/bin/vivado -mode batch -nojournal -log xsim_net.log -source run_xsim_net.tcl ${PLUS:+-tclargs $PLUS} > xsim_net.out 2>&1
END=$(date +%s)
SIMDIR=xsim_net_proj/xsim_net.sim/sim_1/behav/xsim
echo "wall time $((END - START)) s (vivado project creation, elaboration and simulation)"
grep -E "^TB |XSIM NET FINISHED|^ERROR|Fatal" xsim_net.out $SIMDIR/simulate.log 2>/dev/null | sort -u | head -20
[ -n "${PLUS:-}" ] && exit 0
[ -f $SIMDIR/dump.hex ] || { echo "no dump.hex"; exit 1; }
python3 - "$SIMDIR/dump.hex" "$WD/xsim_net_dump.bin" <<'EOF'
import struct, sys
w = [int(l, 16) for l in open(sys.argv[1]) if l.strip()]
open(sys.argv[2], 'wb').write(struct.pack('<%dI' % len(w), *w))
EOF
cd "$W"
obj_chip/Vsoc_chip "$IMG" "$WD/verilator_dump.bin" > "$WD/verilator.log" 2>&1
grep DONE "$WD/verilator.log"
cmp -s "$WD/xsim_net_dump.bin" "$WD/verilator_dump.bin" && echo "NETLIST dump == Verilator chip dump (2 MiB, incl. cycle words)" \
  || echo "NETLIST dump DIFF: $(cmp -l "$WD/xsim_net_dump.bin" "$WD/verilator_dump.bin" | wc -l) bytes"
