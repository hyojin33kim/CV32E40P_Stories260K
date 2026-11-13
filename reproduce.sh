#!/bin/bash
set -eu
cd "$(dirname "$0")"
# Requires TC pointing to extracted GCC/picolibc usr prefix; Verilator 5.032 in PATH.
./build_sim.sh
cc -O2 -ffp-contract=off reference.c -lm -o reference
./reference
for mode in baseline profile; do
 cp "$mode/firmware.c" firmware.c
 ./build.sh
 python3 image.py
 python3 cases.py
 for t in 1 128 512; do
  prefix=base
  if [ "$mode" = profile ]; then prefix=out; fi
  obj/Vcv32e40p_top "image_$t.bin" "${prefix}_$t.bin" > "${prefix}_$t.log" 2>&1
 done
done
cp baseline/firmware.c firmware.c
./build.sh
python3 image.py
# Existing bench_out.bin records the separate calibration run.
OPENBLAS_NUM_THREADS=1 python3 validate.py
