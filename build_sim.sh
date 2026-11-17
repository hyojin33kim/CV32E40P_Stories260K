#!/bin/bash
# Build the Verilator simulator.
#   default            : cv32e40p_top (FPU=1)          -> obj/Vcv32e40p_top
#   TOP=soc_top        : CPU + gemv_acc + vfu (acc/*.sv) -> obj_soc/Vsoc_top
#   TOP=soc_chip       : soc_top + imem + SRAM in RTL (S5)        -> obj_chip/Vsoc_chip
#   TOP=chip_axi_top   : board top, AXI4-Lite loading (sim_axi.cpp) -> obj_axi/Vchip_axi_top
#                        SRAM_RLAT=<1|2> SRAM read latency (default 1)
#                        CHIP_WEIGHTS=onchip (default, weights in the 2 MiB SRAM) | ddr (S5a layout,
#                        weights through the external port and the sim DDR model)
#   CFG=d2 (default)   : FPGA-real configuration (synthesized at 150 MHz on ZCU104):
#                        CPU/ACC/VFU FPU latency 4, ACC_RUN 8
#   CFG=d1             : ideal / legacy (all FPU latency 0, ACC_RUN 16; not FPGA-realizable)
#                        -> default directories get a _d1 suffix (obj_d1, obj_soc_d1, ...)
#   MDIR=<dir>         : output directory override
#   LOG=<file>         : Verilator log (default verilator_build[_soc].log)
#   ACC_LANES=<n>      : gemv_acc MAC lanes for TOP=soc_top (default 4)
#   VFU_LANES=<n>      : vfu element engines for TOP=soc_top (default 4)
#   ACC_RUN=<n>        : gemv_acc mode-A lines per lane run (CFG default; 1 = pre-11-14 order)
#   ACC_FDEPTH=<n>     : gemv_acc words per lane FIFO, power of two (default 256; was 128)
#   CPU_FPU_LAT / ACC_FPU_LAT / VFU_FPU_LAT=<n> : FPU pipeline registers (CFG default)
set -eu
cd "$(dirname "$0")"
export DESIGN_RTL_DIR="$PWD/cv32e40p-master/rtl"
VERILATOR=${VERILATOR:-verilator}
TOP=${TOP:-cv32e40p_top}
CFG=${CFG:-d2}
case "$CFG" in
  d2) L=4; RUN=8;  SUF=;;
  d1) L=0; RUN=16; SUF=_d1;;
  *) echo "CFG must be d1 or d2"; exit 2;;
esac
CPU_FPU_LAT=${CPU_FPU_LAT:-$L}; ACC_FPU_LAT=${ACC_FPU_LAT:-$L}; VFU_FPU_LAT=${VFU_FPU_LAT:-$L}
ACC_RUN=${ACC_RUN:-$RUN}
ACCSRC=("$PWD/acc/gemv_acc.sv" "$PWD/acc/vfu_exp2.sv" "$PWD/acc/vfu_lane.sv" "$PWD/acc/vfu.sv" "$PWD/acc/soc_top.sv")
case "${CHIP_WEIGHTS:-onchip}" in
  onchip) WOPT=(-GWEIGHTS_ONCHIP=1 -CFLAGS -DCHIP_SRAM_BASE=0x0u -CFLAGS -DCHIP_SRAM_LINES=131072u);;
  ddr)    WOPT=(-GWEIGHTS_ONCHIP=0 -CFLAGS -DCHIP_SRAM_BASE=0x100000u -CFLAGS -DCHIP_SRAM_LINES=65536u);;
  *) echo "CHIP_WEIGHTS must be onchip or ddr"; exit 2;;
esac
if [ "$TOP" = chip_axi_top ]; then   # board flow (S5): AXI4-Lite loading, sim_axi.cpp, weights on chip
  "$VERILATOR" --cc --exe --build -j 4 -Wno-fatal -Wno-BLKANDNBLK --top-module chip_axi_top -GACC_LANES=${ACC_LANES:-4} -GVFU_LANES=${VFU_LANES:-4} -GACC_RUN=$ACC_RUN -GACC_FDEPTH=${ACC_FDEPTH:-256} -GCPU_FPU_LAT=$CPU_FPU_LAT -GACC_FPU_LAT=$ACC_FPU_LAT -GVFU_FPU_LAT=$VFU_FPU_LAT -GSRAM_RLAT=${SRAM_RLAT:-1} -GSRAM_RLAT_B=${SRAM_RLAT_B:-2} "${ACCSRC[@]}" "$PWD/acc/sram_dp.sv" "$PWD/acc/soc_chip.sv" "$PWD/acc/chip_axi_top.sv" -f cv32e40p-master/cv32e40p_fpu_manifest.flist "$PWD/sim_axi.cpp" --Mdir "$PWD/${MDIR:-obj_axi$SUF}" > "${LOG:-verilator_build_axi.log}" 2>&1
  exit
elif [ "$TOP" = soc_chip ]; then
  EXTRA=(-CFLAGS -DSOC -CFLAGS -DCHIP -GACC_LANES=${ACC_LANES:-4} -GVFU_LANES=${VFU_LANES:-4} -GACC_RUN=$ACC_RUN -GACC_FDEPTH=${ACC_FDEPTH:-256} -GCPU_FPU_LAT=$CPU_FPU_LAT -GACC_FPU_LAT=$ACC_FPU_LAT -GVFU_FPU_LAT=$VFU_FPU_LAT -GSRAM_RLAT=${SRAM_RLAT:-1} -GSRAM_RLAT_B=${SRAM_RLAT_B:-2} "${WOPT[@]}" "${ACCSRC[@]}" "$PWD/acc/sram_dp.sv" "$PWD/acc/soc_chip.sv")
  MDIR=${MDIR:-obj_chip$SUF}; LOG=${LOG:-verilator_build_chip.log}
elif [ "$TOP" = soc_top ]; then
  EXTRA=(-CFLAGS -DSOC -GACC_LANES=${ACC_LANES:-4} -GVFU_LANES=${VFU_LANES:-4} -GACC_RUN=$ACC_RUN -GACC_FDEPTH=${ACC_FDEPTH:-256} -GCPU_FPU_LAT=$CPU_FPU_LAT -GACC_FPU_LAT=$ACC_FPU_LAT -GVFU_FPU_LAT=$VFU_FPU_LAT "$PWD/acc/gemv_acc.sv" "$PWD/acc/vfu_exp2.sv" "$PWD/acc/vfu_lane.sv" "$PWD/acc/vfu.sv" "$PWD/acc/soc_top.sv")
  MDIR=${MDIR:-obj_soc$SUF}; LOG=${LOG:-verilator_build_soc.log}
else
  EXTRA=(-GFPU=1 -GFPU_ADDMUL_LAT=$CPU_FPU_LAT -GFPU_OTHERS_LAT=$CPU_FPU_LAT)
  MDIR=${MDIR:-obj$SUF}; LOG=${LOG:-verilator_build.log}
fi
"$VERILATOR" --cc --exe --build -j 4 -Wno-fatal -Wno-BLKANDNBLK --top-module "$TOP" "${EXTRA[@]}" -f cv32e40p-master/cv32e40p_fpu_manifest.flist "$PWD/sim.cpp" --Mdir "$PWD/$MDIR" > "$LOG" 2>&1
