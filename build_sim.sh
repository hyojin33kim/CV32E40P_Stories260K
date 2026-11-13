#!/bin/bash
set -eu
cd "$(dirname "$0")"
export DESIGN_RTL_DIR="$PWD/cv32e40p-master/rtl"
VERILATOR=${VERILATOR:-verilator}
"$VERILATOR" --cc --exe --build -j 4 -Wno-fatal -Wno-BLKANDNBLK --top-module cv32e40p_top -GFPU=1 -f cv32e40p-master/cv32e40p_fpu_manifest.flist "$PWD/sim.cpp" --Mdir "$PWD/${MDIR:-obj}" > verilator_build.log 2>&1
