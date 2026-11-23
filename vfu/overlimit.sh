#!/bin/bash
# V-A1: VFU softmax chunk length at and beyond VFU_BUF (rule of the firmware; the RTL has no guard).
# usage: vfu/overlimit.sh [limit (default 512)] [elements per test (default 4096)]
set -u
cd "$(dirname "$0")/.."
L=${1:-512}; N=${2:-4096}
for ln in $L $((L+1)) $((L+8)) $((2*L)); do
  out=$(TEST_ONLY=2,5,6 TEST_LN=$ln TEST_OUT=.scratch/a1/vfu_$ln python3 vfu/run_test.py 1 $N 2>&1)
  echo "chunk length $ln:"
  echo "$out" | grep -E "^\{|^total" | sed "s/'first': .*//" | cut -c1-200 | sed 's/^/   /'
done
