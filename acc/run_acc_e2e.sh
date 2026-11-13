#!/bin/bash
# Step ③: E2E generation with the FFN GEMV accelerator (memory latency 0, full grant),
# 64 and 512 steps; must be bit-exact vs gen/out_<N>_Os.
set -u
cd "$(dirname "$0")/.."
GEN_ACC=1 python3 gen/run_gen.py 64 > gen/run_64_acc.txt 2>&1 &
sleep 20
GEN_ACC=1 python3 gen/run_gen.py 512 > gen/run_512_acc.txt 2>&1 &
wait
for n in 64 512; do
  echo "== $n steps"
  python3 -c "import json;r=json.load(open('gen/out_${n}_O2u_acc_L0_G1/result.json'));print({k:r[k] for k in ('pass','cycles_total','cycles_first','cycles_last','acc','logits_kv_tokens_bitexact_vs_Os','host_free_run_first_divergence')})"
done
