#!/bin/bash
# Reference results for the default configuration D2 (FPGA-real, 11-15): CPU / accelerator /
# VFU FPU latency 4, gemv_acc 4 MAC lanes RUN 8 FIFO 256, 4 VFU lanes. Tags end in _d2.
# Single-step profiles (SW baseline + every offload level, ideal and DDR model) and E2E 8/64/512.
# Needs the CFG=d2 builds: ./build_sim.sh; MDIR=obj_prof ./build_sim.sh; TOP=soc_top ./build_sim.sh
set -u
cd "$(dirname "$0")/.."
F="-O2 -funroll-loops"; HW=_d2
FULL="$F -DUSE_ACC_ATTN -DUSE_ACC_VFU -DUSE_ACC_MM -DUSE_ACC_VFU_DIV -DRMS_SRAM -DEMB_WORDS"
# longest runs first (SW baseline 512 steps at CPU FPU latency 4)
python3 gen/run_gen.py 512 > gen/run_512_O2u$HW.txt 2>&1 &
GEN_ACC=full python3 gen/run_gen.py 512 > gen/run_512_full$HW.txt 2>&1 &
SIM_DDR=1 GEN_HW=${HW}_ddr GEN_ACC=full python3 gen/run_gen.py 512 > gen/run_512_full${HW}_ddr.txt 2>&1 &
PROF_CFLAGS="$F" python3 prof/run_prof.py baseline/firmware.c O2u$HW > prof/O2u$HW.txt 2>&1 &
PROF_CFLAGS="$F" python3 prof/run_prof.py gen/firmware_gen.c gen_O2u$HW > prof/gen_O2u$HW.txt 2>&1 &
PROF_CFLAGS="$F" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_ffn$HW > prof/acc_ffn$HW.txt 2>&1 &
PROF_CFLAGS="$F -DUSE_ACC_ATTN" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_attn$HW > prof/acc_attn$HW.txt 2>&1 &
PROF_CFLAGS="$F -DUSE_ACC_ATTN -DUSE_ACC_VFU" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_all$HW > prof/acc_all$HW.txt 2>&1 &
PROF_CFLAGS="$FULL" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_full$HW > prof/acc_full$HW.txt 2>&1 &
SIM_DDR=1 PROF_CFLAGS="$FULL" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c ddr_full$HW > prof/ddr_full$HW.txt 2>&1 &
sleep 5
(GEN_CFLAGS="" python3 gen/run_gen.py 8 > gen/run_8_Os$HW.txt 2>&1; GEN_CFLAGS="" python3 gen/run_gen.py 64 > gen/run_64_Os$HW.txt 2>&1) &   # same firmware: not in parallel
wait %4 %5 %6 %7 %8 %9 %10 %11   # profiles + Os runs (the 512-step runs keep going)
for m in attn all full; do GEN_ACC=$m python3 gen/run_gen.py 8 > gen/run_8_${m}$HW.txt 2>&1 & sleep 3; done
python3 gen/run_gen.py 64 > gen/run_64_O2u$HW.txt 2>&1 & sleep 3
for m in 1 attn all full; do GEN_ACC=$m python3 gen/run_gen.py 64 > gen/run_64_${m}$HW.txt 2>&1 & sleep 3; done
SIM_DDR=1 GEN_HW=${HW}_ddr GEN_ACC=full python3 gen/run_gen.py 64 > gen/run_64_full${HW}_ddr.txt 2>&1 &
wait
for t in O2u gen_O2u acc_ffn acc_attn acc_all acc_full ddr_full; do echo "== $t$HW"; grep -E 'bit-exact|mcycle' prof/$t$HW/table.md; done
for r in 8_Os_d2 64_Os_d2 64_O2u_d2 512_O2u_d2 \
         8_O2u_accattn${HW}_L0_G1 8_O2u_accall${HW}_L0_G1 8_O2u_accfull${HW}_L0_G1 \
         64_O2u_acc${HW}_L0_G1 64_O2u_accattn${HW}_L0_G1 64_O2u_accall${HW}_L0_G1 64_O2u_accfull${HW}_L0_G1 \
         64_O2u_accfull${HW}_ddr_L0_G1 512_O2u_accfull${HW}_L0_G1 512_O2u_accfull${HW}_ddr_L0_G1; do
  python3 -c "import json;r=json.load(open('gen/out_$r/result.json'));print('$r',r['pass'],r['cycles_total'],r['logits_kv_tokens_bitexact_vs_Os'])" \
    || echo "$r MISSING"
done
