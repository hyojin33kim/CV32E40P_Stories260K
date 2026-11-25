#!/bin/bash
# V-A1: GEMV mode D at and beyond the buffer limits (n <= XBUF, d <= YBUF are rules of the firmware; the RTL has no guard).
# Runs w8/run_test_w8.py one case at a time and prints the verdict, mismatch count and finish marker of each.
# usage: w8/overlimit.sh [sim (default obj_soc/Vsoc_top, 512-word buffers)] [limit (default 512)]
#   15M build: TEST_BIG=1 w8/overlimit.sh obj_soc_big/Vsoc_top 1024
set -u
cd "$(dirname "$0")/.."
SIM=${1:-obj_soc/Vsoc_top}; L=${2:-512}
echo "simulator $SIM, XBUF=YBUF=$L"
for c in "${L}x8" "8x${L}" "$((L+1))x8" "$((L+8))x8" "$((2*L))x4" "8x$((L+1))" "8x$((L+8))" "4x$((2*L))" "$((L+1))x$((L+1))"; do
  out=$(TEST_SIM=$SIM TEST_CASES=$c TEST_OUT=.scratch/a1/$SIM/$c TEST_MAXCYC=300000000 python3 w8/run_test_w8.py 1 0 4000000 2>&1)
  v=$(echo "$out" | tail -1)
  m=$(echo "$out" | grep -o "mismatching output words [0-9]* (row-major) / [0-9]* (pre-tiled), sentinel violations [0-9]*, finished marker 0x[0-9a-f]*" | head -1)
  e=$(echo "$out" | grep -o "simulator exit code [0-9-]*" | head -1)
  k=$(echo "$out" | grep -o "^cases [0-9]*" | head -1)
  echo "case $c ($k): $v | $m $e"   # "cases 0" = the size filter of run_test_w8.py dropped the case (n*d > 1 MiB): no verdict
done
