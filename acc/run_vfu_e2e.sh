#!/bin/bash
# Step ④-b E2E: FFN + attention QK/AV (gemv_acc) + softmax/SwiGLU (vfu), 64 and 512 steps.
# Must be bit-exact (logits, KV, tokens) vs gen/out_<N>_Os.
set -u
cd "$(dirname "$0")/.."
GEN_ACC=all python3 gen/run_gen.py 64 > gen/run_64_accall.txt 2>&1 &
sleep 20
GEN_ACC=all python3 gen/run_gen.py 512 > gen/run_512_accall.txt 2>&1 &
wait
for r in 64_O2u_accall_L0_G1 512_O2u_accall_L0_G1; do
  echo "== $r"
  python3 -c "import json;r=json.load(open('gen/out_${r}/result.json'));print({k:r[k] for k in ('pass','cycles_total','cycles_first','cycles_last','acc','logits_kv_tokens_bitexact_vs_Os','host_free_run_first_divergence')})"
done
