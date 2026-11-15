#!/usr/bin/env python3
"""S3: accuracy of the Option A numerics against the original llama2.c (host, both fp32).

usage: opta/compare_host.py [steps=512] [prompt]   -> opta/host_cmp_<steps>/result.json
  - free run (greedy) of both models: first token divergence, token match rate
  - teacher-forced on the original model's tokens: per-step logits rel L2 and argmax agreement,
    KV-cache rel L2 at the end (shows how far the numerics move, independent of divergence)
"""
import json, os, subprocess, sys
from pathlib import Path
import numpy as np

W = Path(__file__).resolve().parent.parent
steps = int(sys.argv[1]) if len(sys.argv) > 1 else 512
text = sys.argv[2] if len(sys.argv) > 2 else 'Once upon a time'
O = Path(os.environ.get('OPTA_OUT', W / 'opta')) / f'host_cmp_{steps}'; O.mkdir(parents=True, exist_ok=True)
model, tok = W / 'stories260K.bin', W / 'gen' / 'tok512.bin'
V = 512

def run(*a):
    return subprocess.run([str(x) for x in a], check=True, capture_output=True, text=True).stdout

for name, d in (('orig', []), ('opta', ['-DOPTA'])):
    run('cc', '-O2', '-ffp-contract=off', '-w', *d, W / 'gen' / 'host_gen.c', '-lm', '-o', O / f'host_{name}')
np_ = int(run(O / 'host_orig', 'encode', model, tok, text, O / 'prompt.u32'))
for name in ('orig', 'opta'):
    run(O / f'host_{name}', 'free', model, O / 'prompt.u32', steps, O / f'free_{name}.u32')
fo, fa = (np.fromfile(O / f'free_{n}.u32', dtype='<u4') for n in ('orig', 'opta'))
for name in ('orig', 'opta'):   # both teacher-forced on the original model's tokens
    run(O / f'host_{name}', 'tf', model, O / 'prompt.u32', O / 'free_orig.u32', steps,
        O / f'tf_logits_{name}.f32', O / f'tf_kv_{name}.f32')
lo, la = (np.fromfile(O / f'tf_logits_{n}.f32', dtype='<f4').reshape(steps, V) for n in ('orig', 'opta'))
ko, ka = (np.fromfile(O / f'tf_kv_{n}.f32', dtype='<f4') for n in ('orig', 'opta'))
rel = np.linalg.norm(la - lo, axis=1) / np.linalg.norm(lo, axis=1)
top2 = np.sort(lo, axis=1)[:, -2:]; margin = top2[:, 1] - top2[:, 0]
amm = np.nonzero(la.argmax(1) != lo.argmax(1))[0]
gen_from = np_ - 1
div = np.nonzero(fo[gen_from:] != fa[gen_from:])[0]
res = dict(steps=steps, prompt=text, n_prompt=np_,
           free_first_divergence=(int(div[0] + gen_from) if len(div) else None),
           free_token_match=float((fo[gen_from:] == fa[gen_from:]).mean()),
           tf_logits_rel_L2_max=float(rel.max()), tf_logits_rel_L2_mean=float(rel.mean()),
           tf_argmax_mismatch=[dict(pos=int(p), orig_margin=float(margin[p])) for p in amm],
           tf_kv_rel_L2=float(np.linalg.norm(ka - ko) / np.linalg.norm(ko)))
(O / 'result.json').write_text(json.dumps(res, indent=2))
print(json.dumps(res, indent=2))
print('orig:', run(O / 'host_orig', 'decode', model, tok, O / 'prompt.u32', O / 'free_orig.u32', steps).strip()[:300])
print('opta:', run(O / 'host_opta', 'decode', model, tok, O / 'prompt.u32', O / 'free_opta.u32', steps).strip()[:300])
