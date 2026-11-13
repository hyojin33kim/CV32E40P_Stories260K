#!/bin/bash
# Step ④-a: per-region single-step profile with FFN + attention QK/AV on the accelerator.
# PROF_SIM can point at an alternative soc build (default obj_soc/Vsoc_top).
set -u
cd "$(dirname "$0")/.."
F="-O2 -funroll-loops"
PROF_CFLAGS="$F" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_ffn_L0_G1 > prof/acc_ffn_L0_G1.txt 2>&1 &
PROF_CFLAGS="$F -DUSE_ACC_ATTN" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_ffn_attn_L0_G1 > prof/acc_ffn_attn_L0_G1.txt 2>&1 &
wait
for v in acc_ffn_L0_G1 acc_ffn_attn_L0_G1; do echo "=== $v"; cat prof/$v/table.md 2>/dev/null || tail -8 prof/$v.txt; done
