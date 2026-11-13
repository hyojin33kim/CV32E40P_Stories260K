#!/bin/bash
# Step ③: per-region single-step profile (ctx 1/128/512) of the generation firmware,
# SW baseline vs FFN accelerator. Needs obj_prof (MDIR=obj_prof ./build_sim.sh) and
# obj_soc (TOP=soc_top ./build_sim.sh).
set -u
cd "$(dirname "$0")/.."
F="-O2 -funroll-loops"
PROF_CFLAGS="$F" python3 prof/run_prof.py gen/firmware_gen.c gen_O2u > prof/gen_O2u.txt 2>&1 &
PROF_CFLAGS="$F" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_L0_G1 > prof/acc_L0_G1.txt 2>&1 &
wait
for v in gen_O2u acc_L0_G1; do echo "=== $v"; cat prof/$v/table.md 2>/dev/null || tail -5 prof/$v.txt; done
