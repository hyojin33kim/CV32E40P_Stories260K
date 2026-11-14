#!/bin/bash
# MAC lanes: single-step profile (ctx 1/128/512) of the all-offload firmware on 1/2/4-lane
# gemv_acc builds (128-bit accelerator port). Builds obj_soc_l<n> if missing.
set -u
cd "$(dirname "$0")/.."
F="-O2 -funroll-loops -DUSE_ACC_ATTN -DUSE_ACC_VFU -DUSE_ACC_MM"
for n in 1 2 4; do
  [ -x obj_soc_l$n/Vsoc_top ] || LOG=/dev/null ACC_LANES=$n MDIR=obj_soc_l$n TOP=soc_top ./build_sim.sh
  PROF_SIM=$PWD/obj_soc_l$n/Vsoc_top PROF_CFLAGS="$F" PROF_ACC=1 \
    python3 prof/run_prof.py gen/firmware_gen.c acc_full_lanes$n > prof/acc_full_lanes$n.txt 2>&1 &
done
wait
for n in 1 2 4; do
  echo "== lanes $n"; grep -E 'forward total|bit-exact|mcycle' prof/acc_full_lanes$n/table.md
done
