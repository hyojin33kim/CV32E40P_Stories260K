#!/bin/bash
# Option A (S3) reference results on D2: single-step profiles (SW, full offload ideal + DDR)
# and E2E 8/64/512 (OPTA=1). Bit-exactness: accelerator vs the RISC SW Option A (-Os) run
# (8/64 steps) and vs the host Option A model (logits_bitexact_steps, every length).
# Needs the D2 SoC build with acc/vfu_exp2.sv: TOP=soc_top ./build_sim.sh
set -u
cd "$(dirname "$0")/.."
F="-O2 -funroll-loops -DOPTA"
FULL="$F -DUSE_ACC_ATTN -DUSE_ACC_VFU -DUSE_ACC_MM -DUSE_ACC_VFU_DIV -DRMS_SRAM -DEMB_WORDS"
SIM=${OPTA_SIM:-$PWD/obj_soc/Vsoc_top}
if [ "${SKIP_PROF:-0}" != 1 ]; then
  PROF_CFLAGS="$F" python3 prof/run_prof.py gen/firmware_gen.c gen_O2u_opta_d2 > prof/gen_O2u_opta_d2.txt 2>&1 &
  PROF_SIM=$SIM PROF_CFLAGS="$FULL" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_full_opta_d2 > prof/acc_full_opta_d2.txt 2>&1 &
  SIM_DDR=1 PROF_SIM=$SIM PROF_CFLAGS="$FULL" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c ddr_full_opta_d2 > prof/ddr_full_opta_d2.txt 2>&1 &
fi
OPTA=1 GEN_SIM=$SIM GEN_ACC=full python3 gen/run_gen.py 512 > gen/run_512_full_opta_d2.txt 2>&1 & sleep 3
OPTA=1 GEN_SIM=$SIM SIM_DDR=1 GEN_HW=_d2_ddr GEN_ACC=full python3 gen/run_gen.py 512 > gen/run_512_full_opta_d2_ddr.txt 2>&1 & sleep 3
(OPTA=1 GEN_CFLAGS="" python3 gen/run_gen.py 64 > gen/run_64_Os_opta_d2.txt 2>&1   # SW reference (after the 8-step one)
 OPTA=1 python3 gen/run_gen.py 64 > gen/run_64_O2u_opta_d2.txt 2>&1 &
 OPTA=1 GEN_SIM=$SIM GEN_ACC=full python3 gen/run_gen.py 64 > gen/run_64_full_opta_d2.txt 2>&1 & sleep 3
 OPTA=1 GEN_SIM=$SIM SIM_DDR=1 GEN_HW=_d2_ddr GEN_ACC=full python3 gen/run_gen.py 64 > gen/run_64_full_opta_d2_ddr.txt 2>&1 &
 OPTA=1 GEN_SIM=$SIM GEN_ACC=full python3 gen/run_gen.py 8 > gen/run_8_full_opta_d2.txt 2>&1 &
 wait) &
wait
for r in 8_Os_opta_d2 8_O2u_opta_d2 64_Os_opta_d2 64_O2u_opta_d2 8_O2u_opta_accfull_d2_L0_G1 \
         64_O2u_opta_accfull_d2_L0_G1 64_O2u_opta_accfull_d2_ddr_L0_G1 \
         512_O2u_opta_accfull_d2_L0_G1 512_O2u_opta_accfull_d2_ddr_L0_G1; do
  python3 -c "import json;r=json.load(open('gen/out_$r/result.json'));print('$r',r['pass'],r['cycles_total'],r['logits_bitexact_steps'],r['logits_kv_tokens_bitexact_vs_Os'])" \
    || echo "$r MISSING"
done
