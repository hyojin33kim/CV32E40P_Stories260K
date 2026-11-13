#!/bin/bash
# Step ③/④ E2E generation on the accelerator SoC (memory latency 0, full grant):
#   FFN only (GEN_ACC=1) 64 steps, FFN + attention QK/AV (GEN_ACC=attn) 64 and 512 steps.
# Every run must be bit-exact (512-step logits, KV, tokens) vs gen/out_<N>_Os.
set -u
cd "$(dirname "$0")/.."
GEN_ACC=1 python3 gen/run_gen.py 64 > gen/run_64_acc.txt 2>&1 &
sleep 20
GEN_ACC=attn python3 gen/run_gen.py 64 > gen/run_64_accattn.txt 2>&1 &
sleep 20
GEN_ACC=attn python3 gen/run_gen.py 512 > gen/run_512_accattn.txt 2>&1 &
wait
for r in 64_O2u_acc_L0_G1 64_O2u_accattn_L0_G1 512_O2u_accattn_L0_G1; do
  echo "== $r"
  python3 -c "import json;r=json.load(open('gen/out_${r}/result.json'));print({k:r[k] for k in ('pass','cycles_total','cycles_first','cycles_last','acc','logits_kv_tokens_bitexact_vs_Os','host_free_run_first_divergence')})"
done
