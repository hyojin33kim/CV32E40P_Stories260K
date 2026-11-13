#!/bin/bash
# Build the Verilator simulator.
#   default            : cv32e40p_top (FPU=1)          -> obj/Vcv32e40p_top
#   TOP=soc_top        : CPU + gemv_acc (acc/*.sv)      -> obj_soc/Vsoc_top
#   MDIR=<dir>         : output directory override
set -eu
cd "$(dirname "$0")"
export DESIGN_RTL_DIR="$PWD/cv32e40p-master/rtl"
VERILATOR=${VERILATOR:-verilator}
TOP=${TOP:-cv32e40p_top}
if [ "$TOP" = soc_top ]; then
  EXTRA=(-CFLAGS -DSOC "$PWD/acc/gemv_acc.sv" "$PWD/acc/soc_top.sv")
  MDIR=${MDIR:-obj_soc}; LOG=verilator_build_soc.log
else
  EXTRA=(-GFPU=1)
  MDIR=${MDIR:-obj}; LOG=verilator_build.log
fi
"$VERILATOR" --cc --exe --build -j 4 -Wno-fatal -Wno-BLKANDNBLK --top-module "$TOP" "${EXTRA[@]}" -f cv32e40p-master/cv32e40p_fpu_manifest.flist "$PWD/sim.cpp" --Mdir "$PWD/$MDIR" > "$LOG" 2>&1
