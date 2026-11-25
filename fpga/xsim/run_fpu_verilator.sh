#!/bin/bash
# FPU-only check in Verilator: same vectors as fpga/xsim/run_fpu_test.sh (numpy IEEE expected), for both PipeConfig variants.
# usage: fpga/xsim/run_fpu_verilator.sh [vector dir with vec.hex / expect.hex / cat.txt]   (default: generated into .scratch/fpuv/vec)
# Runs every vector one at a time (like xsim) and again in stream mode (V-F4: back-to-back requests per operation group).
set -u
W=$(cd "$(dirname "$0")/../.." && pwd); S=$W/.scratch/fpuv
mkdir -p $S
VD=${1:-$S/vec}; [ -f "$VD/vec.hex" ] || python3 "$W/fpga/xsim/fpu_vectors.py" "$VD"
for cfg in AFTER DISTRIBUTED; do
  C=$S/core_$cfg; rm -rf $C; mkdir -p $C; cp -r $W/cv32e40p-master/rtl $C/rtl; cp -r $W/cv32e40p-master/bhv $C/bhv
  sed -i "s/PipeConfig: fpnew_pkg::AFTER/PipeConfig: fpnew_pkg::$cfg/" $C/rtl/cv32e40p_fp_wrapper.sv
  grep -c "PipeConfig: fpnew_pkg::$cfg" $C/rtl/cv32e40p_fp_wrapper.sv > /dev/null || { echo "patch failed $cfg"; exit 1; }
  DESIGN_RTL_DIR=$C/rtl verilator --cc --exe --build -j 4 -Wno-fatal -Wno-BLKANDNBLK --top-module cv32e40p_fp_wrapper \
    -GFPU_ADDMUL_LAT=4 -GFPU_OTHERS_LAT=4 -f $W/cv32e40p-master/cv32e40p_fpu_manifest.flist $W/fpga/xsim/fpu_verilator.cpp \
    --Mdir $S/obj_$cfg > $S/build_$cfg.log 2>&1 || { echo "build failed $cfg"; tail -5 $S/build_$cfg.log; exit 1; }
  $S/obj_$cfg/Vcv32e40p_fp_wrapper $VD/vec.hex $S/out_$cfg.hex
  $S/obj_$cfg/Vcv32e40p_fp_wrapper $VD/vec.hex $S/outs_$cfg.hex stream
done
python3 "$W/fpga/xsim/fpu_compare.py" $VD/vec.hex $VD/expect.hex $( [ -f $VD/cat.txt ] && echo $VD/cat.txt || echo - ) \
  AFTER=$S/out_AFTER.hex DISTRIBUTED=$S/out_DISTRIBUTED.hex AFTER-stream=$S/outs_AFTER.hex DISTRIBUTED-stream=$S/outs_DISTRIBUTED.hex
