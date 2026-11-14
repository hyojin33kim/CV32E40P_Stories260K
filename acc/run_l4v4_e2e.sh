#!/bin/bash
# E2E references on the default SoC build (4 MAC lanes, 4 VFU lanes, tag _l4v4):
# 8 and 64 steps for every offload level, 512 steps for the full offload.
# Every run must be bit-exact (logits, KV, tokens) vs gen/out_<N>_Os.
set -u
cd "$(dirname "$0")/.."
for n in 8 64; do
  for m in 1 attn all full; do GEN_ACC=$m python3 gen/run_gen.py $n > gen/run_${n}_${m}_l4v4.txt 2>&1 & sleep 5; done
  wait
done
GEN_ACC=full python3 gen/run_gen.py 512 > gen/run_512_full_l4v4.txt 2>&1
for r in 8_O2u_acc 8_O2u_accattn 8_O2u_accall 8_O2u_accfull 64_O2u_acc 64_O2u_accattn 64_O2u_accall 64_O2u_accfull 512_O2u_accfull; do
  python3 -c "import json;r=json.load(open('gen/out_${r}_l4v4_L0_G1/result.json'));print('$r',{k:r[k] for k in ('pass','cycles_total','cycles_first','cycles_last','logits_kv_tokens_bitexact_vs_Os','host_free_run_first_divergence')})"
done
