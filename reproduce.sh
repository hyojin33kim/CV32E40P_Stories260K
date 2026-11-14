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
# The accelerator results are checked on the default SoC build (gemv_acc 4 MAC lanes,
# vfu 4 lanes, tag _l4v4). Earlier single-lane results stay in the repo as history
# (prof/acc_*_L0_G1, gen/out_*_acc*_L0_G1 without _l4v4) and are not re-checked.
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
for sim in obj/Vcv32e40p_top obj_soc/Vsoc_top; do
  for t in 1 128 512; do
    "$sim" "$R/hold/image_$t.bin" "$R/hold/dump_$t.bin" > "$R/hold/$(basename $sim)_$t.log" 2>&1
    cmp -s "$R/hold/dump_$t.bin" "base_$t.bin" && echo "OK   $(basename $sim) ctx$t HOLD dump byte-identical" \
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
PROF_CFLAGS="$F" python3 prof/run_prof.py baseline/firmware.c O2u > "$R/prof_O2u.txt" 2>&1 &
PROF_CFLAGS="$F" python3 prof/run_prof.py gen/firmware_gen.c gen_O2u > "$R/prof_gen_O2u.txt" 2>&1 &
PROF_CFLAGS="$F" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_ffn_l4v4 > "$R/prof_ffn.txt" 2>&1 &
PROF_CFLAGS="$F -DUSE_ACC_ATTN" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_attn_l4v4 > "$R/prof_attn.txt" 2>&1 &
PROF_CFLAGS="$F -DUSE_ACC_ATTN -DUSE_ACC_VFU" PROF_ACC=1 python3 prof/run_prof.py gen/firmware_gen.c acc_all_l4v4 > "$R/prof_all.txt" 2>&1 &
PROF_CFLAGS="$F -DUSE_ACC_ATTN -DUSE_ACC_VFU -DUSE_ACC_MM -DUSE_ACC_VFU_DIV" PROF_ACC=1 \
  python3 prof/run_prof.py gen/firmware_gen.c acc_full_l4v4 > "$R/prof_full.txt" 2>&1 &
wait

step "VFU unit test (expf / softmax / SiLU / divide / divide+softmax vs RISC-V software, bitwise)"
case "$MODE" in quick) VS=1; VN=4096;; standard) VS=1; VN=65536;; full) VS=4; VN=65536;; esac
python3 vfu/run_test.py $VS $VN > "$R/vfu_test.txt" 2>&1 || true
tail -1 "$R/vfu_test.txt"

step "E2E generation, 8 steps (-Os reference first, then the offload levels)"
GEN_CFLAGS="" python3 gen/run_gen.py 8 > "$R/gen_8_Os.txt" 2>&1
for m in attn all full; do GEN_ACC=$m python3 gen/run_gen.py 8 > "$R/gen_8_$m.txt" 2>&1 & done
wait

if [ "$MODE" != quick ]; then
  step "E2E generation, 64 steps"
  GEN_CFLAGS="" python3 gen/run_gen.py 64 > "$R/gen_64_Os.txt" 2>&1
  python3 gen/run_gen.py 64 > "$R/gen_64_O2u.txt" 2>&1 &
  for m in 1 attn all full; do GEN_ACC=$m python3 gen/run_gen.py 64 > "$R/gen_64_$m.txt" 2>&1 & done
  wait
fi

if [ "$MODE" = full ]; then
  step "E2E generation, 512 steps (hours) and memory sweep"
  GEN_CFLAGS="" python3 gen/run_gen.py 512 > "$R/gen_512_Os.txt" 2>&1
  python3 gen/run_gen.py 512 > "$R/gen_512_O2u.txt" 2>&1 &
  GEN_ACC=full python3 gen/run_gen.py 512 > "$R/gen_512_full.txt" 2>&1 &
  python3 acc/sweep_mem.py acc_full_l4v4 2 > "$R/sweep.txt" 2>&1 &
  wait
fi

step "compare with committed results"
python3 reproduce_check.py "$MODE"
