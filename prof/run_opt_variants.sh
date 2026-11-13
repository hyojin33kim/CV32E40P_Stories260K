#!/bin/bash
# Step ②: profile result-identical compiler variants of the baseline firmware.
set -u
cd "$(dirname "$0")/.."
python3 prof/run_prof.py baseline/firmware.c baseline > prof/baseline.txt 2>&1 &
for o in O2 O3; do
  PROF_CFLAGS=-$o python3 prof/run_prof.py baseline/firmware.c $o > prof/$o.txt 2>&1 &
done
wait
for v in baseline O2 O3; do
  echo "=== $v"
  grep -E 'forward total|bit-exact|mcycle|text bytes|W_qkv|W_o|FFN|LM head|attn QK|attn AV|softmax|SwiGLU|Traceback|Error' prof/$v.txt | grep -v 'leaf'
done
