#!/bin/bash
# Builds and runs the Debug Module test (dbg/tb_dm/tb.cpp) on soc_chip_dm with Verilator.
# usage: dbg/tb_dm/run.sh <image.bin> <reference dump.bin> <workdir> [tb plusargs, e.g. +HALTS=3 +FIRST=20000 +STEP=30000 +VERBOSE=1]
set -eu
W=$(cd "$(dirname "$0")/../.." && pwd); cd "$W"
IMG=$(readlink -f "$1"); REF=$(readlink -f "$2"); WD=$3; shift 3
mkdir -p "$WD"
export DESIGN_RTL_DIR="${DESIGN_RTL_DIR:-$PWD/cv32e40p-master/rtl}"
ACCSRC=("$PWD/acc/gemv_acc.sv" "$PWD/acc/vfu_exp2.sv" "$PWD/acc/vfu_lane.sv" "$PWD/acc/vfu.sv" "$PWD/acc/soc_top.sv")
verilator --cc --exe --build -j 4 -Wno-fatal -Wno-lint -Wno-style -Wno-BLKANDNBLK --top-module soc_chip_dm \
  -GACC_RUN=8 -GCPU_FPU_LAT=4 -GACC_FPU_LAT=4 -GVFU_FPU_LAT=4 -GSRAM_RLAT_B=2 \
  "${ACCSRC[@]}" "$PWD/acc/sram_dp.sv" "$PWD/acc/soc_chip.sv" \
  -f cv32e40p-master/cv32e40p_fpu_manifest.flist -f dbg/dbg_files.f "$PWD/dbg/tb_dm/tb.cpp" --Mdir "$WD/obj" > "$WD/build.log" 2>&1 || { grep -m5 "%Error" "$WD/build.log"; exit 1; }
timeout "${TB_TIMEOUT:-1800}" "$WD/obj/Vsoc_chip_dm" "$IMG" "$REF" "$@"
