#!/bin/bash
# FPU-only check in Verilator: same vectors as fpga/xsim/run_fpu_test.sh (numpy IEEE expected), for both PipeConfig variants.
# usage: fpga/xsim/run_fpu_verilator.sh [vector dir with vec.hex / expect.hex]   (default /mnt/e/fpga_work/fpu_test)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd); VD=${1:-/mnt/e/fpga_work/fpu_test}; S=$W/.scratch/fpuv
mkdir -p $S
for cfg in AFTER DISTRIBUTED; do
  C=$S/core_$cfg; rm -rf $C; mkdir -p $C; cp -r $W/cv32e40p-master/rtl $C/rtl; cp -r $W/cv32e40p-master/bhv $C/bhv
  sed -i "s/PipeConfig: fpnew_pkg::AFTER/PipeConfig: fpnew_pkg::$cfg/" $C/rtl/cv32e40p_fp_wrapper.sv
  grep -c "PipeConfig: fpnew_pkg::$cfg" $C/rtl/cv32e40p_fp_wrapper.sv > /dev/null || { echo "patch failed $cfg"; exit 1; }
  DESIGN_RTL_DIR=$C/rtl verilator --cc --exe --build -j 4 -Wno-fatal -Wno-BLKANDNBLK --top-module cv32e40p_fp_wrapper \
    -GFPU_ADDMUL_LAT=4 -GFPU_OTHERS_LAT=4 -f $W/cv32e40p-master/cv32e40p_fpu_manifest.flist $W/fpga/xsim/fpu_verilator.cpp \
    --Mdir $S/obj_$cfg > $S/build_$cfg.log 2>&1 || { echo "build failed $cfg"; tail -5 $S/build_$cfg.log; exit 1; }
  $S/obj_$cfg/Vcv32e40p_fp_wrapper $VD/vec.hex $S/out_$cfg.hex
done
python3 - $VD $S <<'EOF'
import sys
vd, s = sys.argv[1], sys.argv[2]
e = open(f'{vd}/expect.hex').read().split(); v = [l.split() for l in open(f'{vd}/vec.hex')]
names = {2: 'ADD', 3: 'MUL', 4: 'DIV', 5: 'SQRT', 12: 'I2F'}
for tag in ('AFTER', 'DISTRIBUTED'):
    r = open(f'{s}/out_{tag}.hex').read().split()
    bad = [i for i in range(len(e)) if i >= len(r) or r[i] != e[i]]
    by = {}
    for i in bad: by[names[int(v[i][0], 16)]] = by.get(names[int(v[i][0], 16)], 0) + 1
    print(f'Verilator {tag}: {len(e) - len(bad)}/{len(e)} correct, wrong by op {by}',
          '' if not bad else f'(first #{bad[0]}: {v[bad[0]]} -> {r[bad[0]] if bad[0] < len(r) else None}, expected {e[bad[0]]})')
EOF
