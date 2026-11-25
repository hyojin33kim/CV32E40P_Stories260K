#!/bin/bash
# V-A2: build acc/axi_ext_rd.sv standalone for several parameter sets and run the randomized AXI slave test (tb.cpp).
# usage: acc/tb_axi_ext_rd/run.sh [last_seed (default 60)]
#   DUT_DIR=<dir with axi_ext_rd.sv>  test a modified copy (mutation check)     OUT=<build dir name>   CONFIGS="MAXB WT CRED TD;..."
set -u
cd "$(dirname "$0")"
LAST=${1:-60}; DUT_DIR=${DUT_DIR:-..}; O=${OUT:-obj}
CONFIGS=${CONFIGS:-"16 3 48 8;8 1 16 2;4 0 8 2;32 3 48 8;48 5 63 4"}
rc=0; mkdir -p "$O"
IFS=';' read -ra LIST <<< "$CONFIGS"
for cfg in "${LIST[@]}"; do
  set -- $cfg; tag="$1_$2_$3_$4"
  verilator --cc --exe --build -j 4 -O2 -Wno-fatal --top-module axi_ext_rd $DUT_DIR/axi_ext_rd.sv tb.cpp \
    -GMAXB=$1 -GWT=$2 -GCRED=$3 -GTD=$4 -CFLAGS "-DP_MAXB=$1 -DP_CRED=$3 -DP_TD=$4" --Mdir $O/$tag > $O.build_$tag.log 2>&1 || { echo "build failed $tag"; tail -5 $O.build_$tag.log; exit 2; }
  $O/$tag/Vaxi_ext_rd 0 $LAST || rc=1
  $O/$tag/Vaxi_ext_rd 100 $((100 + LAST / 2)) inject || rc=1
done
exit $rc
