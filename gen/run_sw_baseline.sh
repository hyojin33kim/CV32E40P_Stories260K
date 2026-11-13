#!/bin/bash
# Step ① with the step-② SW baseline flags (-O2 -funroll-loops): 64 and 512 steps.
# Requires gen/out_<N>_Os from the -Os run for the bit-exact cross-check
# (GEN_CFLAGS="" gen/run_gen.py <N> produces it).
# Output: gen/out_<N>_O2u/result.json, gen/run_<N>_O2u.txt
set -u
cd "$(dirname "$0")/.."
python3 gen/run_gen.py 64 > gen/run_64_O2u.txt 2>&1 &
sleep 20   # let the 64-step build finish before the 512-step build starts
python3 gen/run_gen.py 512 > gen/run_512_O2u.txt 2>&1 &
wait
for n in 64 512; do
  echo "== $n steps"
  python3 -c "import json;r=json.load(open('gen/out_${n}_O2u/result.json'));print({k:r[k] for k in ('pass','cycles_total','text_bytes','logits_kv_tokens_bitexact_vs_Os','host_free_run_first_divergence')})"
done
