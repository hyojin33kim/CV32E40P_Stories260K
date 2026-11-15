#!/bin/bash
# Build the Verilator simulator.
#   default            : cv32e40p_top (FPU=1)          -> obj/Vcv32e40p_top
#   TOP=soc_top        : CPU + gemv_acc + vfu (acc/*.sv) -> obj_soc/Vsoc_top
#   MDIR=<dir>         : output directory override
#   LOG=<file>         : Verilator log (default verilator_build[_soc].log)
#   ACC_LANES=<n>      : gemv_acc MAC lanes for TOP=soc_top (default 4)
#   VFU_LANES=<n>      : vfu element engines for TOP=soc_top (default 4)
#   ACC_RUN=<n>        : gemv_acc mode-A lines per lane run (default 16; 1 = pre-11-14 order)
#   ACC_FDEPTH=<n>     : gemv_acc words per lane FIFO, power of two (default 256; was 128)
set -eu
cd "$(dirname "$0")"
export DESIGN_RTL_DIR="$PWD/cv32e40p-master/rtl"
VERILATOR=${VERILATOR:-verilator}
TOP=${TOP:-cv32e40p_top}
if [ "$TOP" = soc_top ]; then
  EXTRA=(-CFLAGS -DSOC -GACC_LANES=${ACC_LANES:-4} -GVFU_LANES=${VFU_LANES:-4} -GACC_RUN=${ACC_RUN:-16} -GACC_FDEPTH=${ACC_FDEPTH:-256} "$PWD/acc/gemv_acc.sv" "$PWD/acc/vfu_lane.sv" "$PWD/acc/vfu.sv" "$PWD/acc/soc_top.sv")
  MDIR=${MDIR:-obj_soc}; LOG=${LOG:-verilator_build_soc.log}
else
  EXTRA=(-GFPU=1)
  MDIR=${MDIR:-obj}; LOG=${LOG:-verilator_build.log}
fi
"$VERILATOR" --cc --exe --build -j 4 -Wno-fatal -Wno-BLKANDNBLK --top-module "$TOP" "${EXTRA[@]}" -f cv32e40p-master/cv32e40p_fpu_manifest.flist "$PWD/sim.cpp" --Mdir "$PWD/$MDIR" > "$LOG" 2>&1
