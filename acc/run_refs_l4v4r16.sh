#!/bin/bash
# Reference results for the default SoC build after 11-14 (4 MAC lanes, RUN 16, FIFO 256,
# 4 VFU lanes; tag _l4v4r16): single-step profiles (ideal + DDR model) and E2E 8/64/512.
set -u
cd "$(dirname "$0")/.."
F="-O2 -funroll-loops"; HW=_l4v4r16
FULL="$F -DUSE_ACC_ATTN -DUSE_ACC_VFU -DUSE_ACC_MM -DUSE_ACC_VFU_DIV -DRMS_SRAM -DEMB_WORDS"
LOG=/dev/null TOP=soc_top ./build_sim.sh
PROF_CFLAGS="$F" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_ffn$HW > prof/acc_ffn$HW.txt 2>&1 &
PROF_CFLAGS="$F -DUSE_ACC_ATTN" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_attn$HW > prof/acc_attn$HW.txt 2>&1 &
PROF_CFLAGS="$F -DUSE_ACC_ATTN -DUSE_ACC_VFU" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_all$HW > prof/acc_all$HW.txt 2>&1 &
PROF_CFLAGS="$FULL" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_full$HW > prof/acc_full$HW.txt 2>&1 &
SIM_DDR=1 PROF_CFLAGS="$FULL" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c ddr_full$HW > prof/ddr_full$HW.txt 2>&1 &
wait
for m in attn all full; do GEN_ACC=$m python3 gen/run_gen.py 8 > gen/run_8_${m}$HW.txt 2>&1 & sleep 3; done
wait
for m in 1 attn all full; do GEN_ACC=$m python3 gen/run_gen.py 64 > gen/run_64_${m}$HW.txt 2>&1 & sleep 3; done
SIM_DDR=1 GEN_HW=${HW}_ddr GEN_ACC=full python3 gen/run_gen.py 64 > gen/run_64_full${HW}_ddr.txt 2>&1 &
wait
GEN_ACC=full python3 gen/run_gen.py 512 > gen/run_512_full$HW.txt 2>&1 &
sleep 3
SIM_DDR=1 GEN_HW=${HW}_ddr GEN_ACC=full python3 gen/run_gen.py 512 > gen/run_512_full${HW}_ddr.txt 2>&1 &
wait
for t in acc_ffn acc_attn acc_all acc_full ddr_full; do echo "== $t$HW"; grep -E 'bit-exact|mcycle' prof/$t$HW/table.md; done
for r in 8_O2u_accattn 8_O2u_accall 8_O2u_accfull 64_O2u_acc 64_O2u_accattn 64_O2u_accall 64_O2u_accfull 512_O2u_accfull; do
  python3 -c "import json;r=json.load(open('gen/out_${r}${HW}_L0_G1/result.json'));print('$r',r['pass'],r['cycles_total'],r['logits_kv_tokens_bitexact_vs_Os'])"
done
for r in 64 512; do
  python3 -c "import json;r=json.load(open('gen/out_${r}_O2u_accfull${HW}_ddr_L0_G1/result.json'));print('${r} ddr',r['pass'],r['cycles_total'],r['logits_kv_tokens_bitexact_vs_Os'])"
done
