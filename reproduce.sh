#!/bin/bash
# Reproduce the project's results from a clean checkout and compare them with the
# committed values. Nothing tracked by git is overwritten: all outputs go to repro/.
#
#   ./reproduce.sh            quick    (~8 min)  build, HOLD regression, reference C,
#                                                 single-step profiles, VFU unit test (20K),
#                                                 8-step E2E
#   ./reproduce.sh standard   (~30 min) quick + VFU unit test (328K) + 64-step E2E
#   ./reproduce.sh full       (hours)   standard + VFU unit test (1.3M) + 512-step E2E + sweep
#
# Results are checked on the default configuration D2 (FPGA-real, 11-15; tag _d2): CPU,
# accelerator and VFU FPU latency 4, gemv_acc 4 MAC lanes RUN 8 FIFO 256, vfu 4 lanes, with
# the ideal memory and with the DDR/SRAM memory model (SIM_DDR=1, default parameters).
# Earlier results stay in the repo as history and are not re-checked: D1 ideal (all FPU
# latency 0, RUN 16; tags without _d2, accelerator _l4v4r16), _l4v4, _L0_G1 without lanes.
# The HOLD regression compares the whole dump except the firmware cycle word (0x1aff00),
# which depends on the FPU latency.
# Option A numerics (S3, OPTA=1: exp2q softmax/SiLU, deferred normalization) are checked as a
# second set (tags _opta), including the chip sim (S5a: imem + 1 MB SRAM in RTL, obj_chip).
#
# Requires (Ubuntu 24.04): gcc-riscv64-unknown-elf picolibc-riscv64-unknown-elf
# verilator (5.038 used) python3-numpy gcc. Override the RISC-V prefix with TC=<prefix>.
set -eu
cd "$(dirname "$0")"
MODE=${1:-quick}
case "$MODE" in quick|standard|full) ;; *) echo "usage: $0 [quick|standard|full]"; exit 2;; esac
R=$PWD/repro
rm -rf "$R"; mkdir -p "$R/hold" "$R/ref"
export GEN_OUT=$R/gen PROF_OUT=$R/prof SWEEP_OUT=$R/sweep TEST_OUT=$R/vfu
F="-O2 -funroll-loops"
step() { echo; echo "=== $*"; }

step "build simulators (CPU, CPU profiler, CPU + accelerator SoC)"
LOG=$R/build_cpu.log ./build_sim.sh
LOG=$R/build_prof.log MDIR=obj_prof ./build_sim.sh
LOG=$R/build_soc.log TOP=soc_top ./build_sim.sh
LOG=$R/build_chip.log TOP=soc_chip ./build_sim.sh
HW=_d2

step "G0: HOLD regression (stored HOLD ELF, ctx 1/128/512) on CPU sim and SoC sim"
python3 image.py firmware.elf "$R/hold/image.bin"
python3 - "$R/hold" <<'EOF'
import struct, sys
from pathlib import Path
o = Path(sys.argv[1]); base = (o / 'image.bin').read_bytes()
for t in (1, 128, 512):  # same injection as cases.py
    m = bytearray(base); kv = Path(f'kv_{t}.bin').read_bytes()
    for l in range(5):
        for j in range(2):
            m[0x100000 + l * 0x20000 + j * 0x10000:0x110000 + l * 0x20000 + j * 0x10000] = \
                kv[j * 327680 + l * 65536:j * 327680 + (l + 1) * 65536]
    struct.pack_into('I', m, 0x1afff0, t - 1)
    (o / f'image_{t}.bin').write_bytes(m)
EOF
for sim in obj/Vcv32e40p_top obj_soc/Vsoc_top obj_chip/Vsoc_chip; do
  for t in 1 128 512; do
    "$sim" "$R/hold/image_$t.bin" "$R/hold/dump_$t.bin" > "$R/hold/$(basename $sim)_$t.log" 2>&1
    python3 -c "import sys;a,b=(open(f,'rb').read() for f in sys.argv[1:]);m=lambda x:x[:0x1aff00]+x[0x1aff04:];sys.exit(m(a)!=m(b))" \
        "$R/hold/dump_$t.bin" "base_$t.bin" \
      && echo "OK   $(basename $sim) ctx$t HOLD dump byte-identical (except cycle word)" \
      || { echo "FAIL $(basename $sim) ctx$t HOLD dump differs"; exit 1; }
  done
done

step "host reference C (ref/kv golden files)"
cp reference.c run.c stories260K.bin "$R/ref/"
(cd "$R/ref" && cc -O2 -ffp-contract=off -w reference.c -lm -o reference && ./reference)
for f in ref_1 ref_128 ref_512 kv_1 kv_128 kv_512 after_kv_1 after_kv_128 after_kv_512; do
  cmp -s "$R/ref/$f.bin" "$f.bin" && echo "OK   $f.bin" || { echo "FAIL $f.bin"; exit 1; }
done

step "single-step profiles: SW baseline, then each offload level on the accelerator"
PROF_CFLAGS="$F" python3 prof/run_prof.py baseline/firmware.c O2u$HW > "$R/prof_O2u.txt" 2>&1 &
PROF_CFLAGS="$F" python3 prof/run_prof.py gen/firmware_gen.c gen_O2u$HW > "$R/prof_gen_O2u.txt" 2>&1 &
FULL="$F -DUSE_ACC_ATTN -DUSE_ACC_VFU -DUSE_ACC_MM -DUSE_ACC_VFU_DIV -DRMS_SRAM -DEMB_WORDS"
PROF_CFLAGS="$F" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_ffn$HW > "$R/prof_ffn.txt" 2>&1 &
PROF_CFLAGS="$F -DUSE_ACC_ATTN" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_attn$HW > "$R/prof_attn.txt" 2>&1 &
PROF_CFLAGS="$F -DUSE_ACC_ATTN -DUSE_ACC_VFU" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_all$HW > "$R/prof_all.txt" 2>&1 &
PROF_CFLAGS="$FULL" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_full$HW > "$R/prof_full.txt" 2>&1 &
SIM_DDR=1 PROF_CFLAGS="$FULL" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c ddr_full$HW > "$R/prof_ddr_full.txt" 2>&1 &
wait
FA="$F -DOPTA"; FULLA="$FULL -DOPTA"
PROF_CFLAGS="$FA" python3 prof/run_prof.py gen/firmware_gen.c gen_O2u_opta$HW > "$R/prof_gen_opta.txt" 2>&1 &
PROF_CFLAGS="$FULLA" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_full_opta$HW > "$R/prof_full_opta.txt" 2>&1 &
SIM_DDR=1 PROF_CFLAGS="$FULLA" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c ddr_full_opta$HW > "$R/prof_ddr_full_opta.txt" 2>&1 &
PROF_SIM=$PWD/obj_chip/Vsoc_chip PROF_CFLAGS="$FULLA" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c chip_full_opta$HW > "$R/prof_chip_full_opta.txt" 2>&1 &
wait

step "Option A: host accuracy vs llama2.c (512 steps), exp2 RTL vs C model"
OPTA_OUT=$R/opta python3 opta/compare_host.py 512 > "$R/opta_host.txt" 2>&1 || true
case "$MODE" in
  full) E2LO=0; E2HI=ffffffff;;
  *)    E2LO=bf000000; E2HI=c0ffffff;;     # [-8, -0.5]: the softmax argument range, 2^25 x 2 inputs
esac
acc/tb_exp2/run.sh $E2LO $E2HI > "$R/exp2_rtl.txt" 2>&1 || true
tail -1 "$R/exp2_rtl.txt"
if [ "$MODE" = full ]; then
  cc -O2 -fopenmp opta/test_exp2q.c -lm -o "$R/test_exp2q" && "$R/test_exp2q" > "$R/exp2_accuracy.txt" 2>&1 || true
  tail -3 "$R/exp2_accuracy.txt"
fi

step "VFU unit test (expf / softmax / SiLU / divide / divide+softmax vs RISC-V software, bitwise)"
case "$MODE" in quick) VS=1; VN=4096;; standard) VS=1; VN=65536;; full) VS=4; VN=65536;; esac
python3 vfu/run_test.py $VS $VN > "$R/vfu_test.txt" 2>&1 || true
tail -1 "$R/vfu_test.txt"

step "E2E generation, 8 steps (-Os reference first, then the offload levels)"
GEN_CFLAGS="" python3 gen/run_gen.py 8 > "$R/gen_8_Os.txt" 2>&1
for m in attn all full; do GEN_ACC=$m python3 gen/run_gen.py 8 > "$R/gen_8_$m.txt" 2>&1 & done
OPTA=1 GEN_CFLAGS="" python3 gen/run_gen.py 8 > "$R/gen_8_Os_opta.txt" 2>&1
wait
OPTA=1 GEN_ACC=full python3 gen/run_gen.py 8 > "$R/gen_8_full_opta.txt" 2>&1

if [ "$MODE" != quick ]; then
  step "E2E generation, 64 steps"
  GEN_CFLAGS="" python3 gen/run_gen.py 64 > "$R/gen_64_Os.txt" 2>&1
  python3 gen/run_gen.py 64 > "$R/gen_64_O2u.txt" 2>&1 &
  for m in 1 attn all full; do GEN_ACC=$m python3 gen/run_gen.py 64 > "$R/gen_64_$m.txt" 2>&1 & done
  SIM_DDR=1 GEN_HW=${HW}_ddr GEN_ACC=full python3 gen/run_gen.py 64 > "$R/gen_64_full_ddr.txt" 2>&1 &
  OPTA=1 GEN_CFLAGS="" python3 gen/run_gen.py 64 > "$R/gen_64_Os_opta.txt" 2>&1 &
  wait
  OPTA=1 python3 gen/run_gen.py 64 > "$R/gen_64_O2u_opta.txt" 2>&1 &
  OPTA=1 GEN_ACC=full python3 gen/run_gen.py 64 > "$R/gen_64_full_opta.txt" 2>&1 &
  OPTA=1 SIM_DDR=1 GEN_HW=${HW}_ddr GEN_ACC=full python3 gen/run_gen.py 64 > "$R/gen_64_full_opta_ddr.txt" 2>&1 &
  wait
fi

if [ "$MODE" = full ]; then
  step "E2E generation, 512 steps (hours) and memory sweep"
  GEN_CFLAGS="" python3 gen/run_gen.py 512 > "$R/gen_512_Os.txt" 2>&1
  python3 gen/run_gen.py 512 > "$R/gen_512_O2u.txt" 2>&1 &
  GEN_ACC=full python3 gen/run_gen.py 512 > "$R/gen_512_full.txt" 2>&1 &
  SIM_DDR=1 GEN_HW=${HW}_ddr GEN_ACC=full python3 gen/run_gen.py 512 > "$R/gen_512_full_ddr.txt" 2>&1 &
  OPTA=1 GEN_ACC=full python3 gen/run_gen.py 512 > "$R/gen_512_full_opta.txt" 2>&1 &
  OPTA=1 SIM_DDR=1 GEN_HW=${HW}_ddr GEN_ACC=full python3 gen/run_gen.py 512 > "$R/gen_512_full_opta_ddr.txt" 2>&1 &
  wait
fi

step "compare with committed results"
python3 reproduce_check.py "$MODE"
