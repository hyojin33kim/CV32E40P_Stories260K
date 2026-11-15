#!/bin/bash
# Build and run the exhaustive vfu_exp2 check (acc/tb_exp2/tb.cpp). Args: [first_hex last_hex]
set -eu
cd "$(dirname "$0")"
verilator --cc --exe --build -j 4 -O3 -Wno-fatal --top-module vfu_exp2 ../vfu_exp2.sv tb.cpp \
  --Mdir obj > build.log 2>&1
./obj/Vvfu_exp2 "$@"
