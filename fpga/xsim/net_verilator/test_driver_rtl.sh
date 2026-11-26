#!/bin/bash
# Checks the driver net_sim.cpp on the RTL soc_chip (same ports as the netlist top) before it is used on the netlist:
# the dump must equal obj_chip/Vsoc_chip's dump and run_cycles must equal the xsim/tb_chip.sv value (157,433 for prof/chip_full_opta_d2/image_1.bin).
# usage: fpga/xsim/net_verilator/test_driver_rtl.sh <image.bin> [workdir]
set -eu
W=$(cd "$(dirname "$0")/../../.." && pwd); cd "$W"
IMG=$(readlink -f "$1"); WD=${2:-$W/.scratch/drv_rtl}; mkdir -p "$WD"
export DESIGN_RTL_DIR="${DESIGN_RTL_DIR:-$PWD/cv32e40p-master/rtl}"
ACCSRC=("$PWD/acc/gemv_acc.sv" "$PWD/acc/vfu_exp2.sv" "$PWD/acc/vfu_lane.sv" "$PWD/acc/vfu.sv" "$PWD/acc/soc_top.sv")
verilator --cc --exe --build -j 4 -Wno-fatal -Wno-BLKANDNBLK --top-module soc_chip \
  -CFLAGS -DRTL_TOP -CFLAGS -DVNAME=Vsoc_chip \
  -GACC_LANES=4 -GVFU_LANES=4 -GACC_RUN=8 -GACC_FDEPTH=256 -GCPU_FPU_LAT=4 -GACC_FPU_LAT=4 -GVFU_FPU_LAT=4 -GSRAM_RLAT=1 -GSRAM_RLAT_B=2 -GSRAM_AREG=0 \
  -GWEIGHTS_ONCHIP=1 "${ACCSRC[@]}" "$PWD/acc/sram_dp.sv" "$PWD/acc/soc_chip.sv" \
  -f cv32e40p-master/cv32e40p_fpu_manifest.flist "$PWD/fpga/xsim/net_verilator/net_sim.cpp" --Mdir "$WD/obj" > "$WD/build.log" 2>&1
"$WD/obj/Vsoc_chip" "$IMG" "$WD/drv_dump.bin" +PROGRESS=50000 | tee "$WD/run.log" | tail -4
obj_chip/Vsoc_chip "$IMG" "$WD/ref_dump.bin" > "$WD/ref.log" 2>&1
grep DONE "$WD/ref.log" | head -1
cmp -s "$WD/drv_dump.bin" "$WD/ref_dump.bin" && echo "driver dump == Verilator chip dump (2 MiB)" || echo "driver dump DIFF: $(cmp -l "$WD/drv_dump.bin" "$WD/ref_dump.bin" | wc -l) bytes"
