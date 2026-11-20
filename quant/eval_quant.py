#!/usr/bin/env python3
"""Precision gate (P1): accuracy of int8/int4 weights, int8 activations, int8 KV vs the fp32 llama2.c
on Stories260K (host, fake quantization, see quant/make_run_quant.py).

usage: quant/eval_quant.py [steps=512]   -> quant/results/gate_<steps>.json and a table on stdout
Per prompt (greedy free run of the fp32 model, then every config teacher-forced on those tokens):
  nll_delta   mean NLL of the fp32 model's own tokens under the quantized model minus the fp32 NLL
              (the primary metric: language-model quality loss, independent of greedy divergence)
  argmax_agree  fraction of generated positions where the quantized argmax equals the fp32 token
  logit_relL2   mean per-step relative L2 of the logits
  free_match / first_div   free-run greedy token match with fp32 and the first divergence position
Passing criteria are NOT defined here; they are the user's decision (see the report)."""
import json, os, subprocess, sys
from pathlib import Path
import numpy as np

W = Path(__file__).resolve().parent.parent
steps = int(sys.argv[1]) if len(sys.argv) > 1 else 512
O = W / 'quant' / 'results'; O.mkdir(parents=True, exist_ok=True)
model, tok = W / 'stories260K.bin', W / 'gen' / 'tok512.bin'
V = 512
PROMPTS = ['Once upon a time', 'One day, a little girl named Lily', 'The dog and the cat were best friends', 'Tom had a big red ball']
CONFIGS = [  # name, env
    ('fp32 (check)', {}),
    ('W8 g32', dict(QW=8, QG=32)),
    ('W8A8 g32', dict(QW=8, QA=8, QG=32)),
    ('W8A8 g128', dict(QW=8, QA=8, QG=128)),
    ('W8A8 per-row', dict(QW=8, QA=8, QG=256)),      # one scale per row / whole activation vector
    ('W8A8 g32 + KV8', dict(QW=8, QA=8, QKV=8, QG=32)),
    ('W4 g16', dict(QW=4, QG=16)),
    ('W4 g32', dict(QW=4, QG=32)),
    ('W4 g64', dict(QW=4, QG=64)),
    ('W4A8 g32', dict(QW=4, QA=8, QG=32)),
    ('W4A8 g32 + KV8', dict(QW=4, QA=8, QKV=8, QG=32)),
    ('W4 g32 + KV4', dict(QW=4, QKV=4, QG=32)),
]

def run(*a, env=None):
    e = dict(os.environ); e.update({k: str(v) for k, v in (env or {}).items()})
    return subprocess.run([str(x) for x in a], check=True, capture_output=True, text=True, env=e).stdout

subprocess.run(['python3', str(W / 'quant' / 'make_run_quant.py')], check=True)
run('cc', '-O2', '-ffp-contract=off', '-w', '-DQUANT', W / 'gen' / 'host_gen.c', '-lm', '-o', O / 'host_q')
run('cc', '-O2', '-ffp-contract=off', '-w', W / 'gen' / 'host_gen.c', '-lm', '-o', O / 'host_f')

def lsm(x):
    x = x - x.max(1, keepdims=True)
    return x - np.log(np.exp(x).sum(1, keepdims=True))

res = {}
for pi, text in enumerate(PROMPTS):
    P = O / f'p{pi}'; P.mkdir(exist_ok=True)
    npr = int(run(O / 'host_f', 'encode', model, tok, text, P / 'prompt.u32'))
    run(O / 'host_f', 'free', model, P / 'prompt.u32', steps, P / 'free_f.u32')
    ff = np.fromfile(P / 'free_f.u32', dtype='<u4'); g0 = npr - 1
    run(O / 'host_f', 'tf', model, P / 'prompt.u32', P / 'free_f.u32', steps, P / 'tf_f.f32', P / 'kv_f.f32')
    lf = np.fromfile(P / 'tf_f.f32', dtype='<f4').reshape(steps, V).astype(np.float64)
    tgt = ff[g0:].astype(int); idx = np.arange(g0, steps)
    nll_f = -lsm(lf)[idx, tgt].mean()
    for name, env in CONFIGS:
        run(O / 'host_q', 'free', model, P / 'prompt.u32', steps, P / 'free_q.u32', env=env)
        run(O / 'host_q', 'tf', model, P / 'prompt.u32', P / 'free_f.u32', steps, P / 'tf_q.f32', P / 'kv_q.f32', env=env)
        fq = np.fromfile(P / 'free_q.u32', dtype='<u4')
        lq = np.fromfile(P / 'tf_q.f32', dtype='<f4').reshape(steps, V).astype(np.float64)
        div = np.nonzero(fq[g0:] != ff[g0:])[0]
        r = res.setdefault(name, [])
        r.append(dict(prompt=text, nll_f=float(nll_f), nll_q=float(-lsm(lq)[idx, tgt].mean()),
                      argmax_agree=float((lq[idx].argmax(1) == tgt).mean()),
                      logit_relL2=float((np.linalg.norm(lq - lf, axis=1) / np.linalg.norm(lf, axis=1)).mean()),
                      free_match=float((fq[g0:] == ff[g0:]).mean()),
                      first_div=int(div[0]) if len(div) else None, gen_len=int(steps - g0)))
(O / f'gate_{steps}.json').write_text(json.dumps(res, indent=1))
print(f'steps={steps}, {len(PROMPTS)} prompts (mean over prompts; first_div = min)')
print(f'{"config":<18}{"nll_delta":>10}{"argmax":>9}{"logitL2":>10}{"free_match":>11}{"first_div":>10}')
for name, rows in res.items():
    d = np.mean([x['nll_q'] - x['nll_f'] for x in rows])
    fd = [x['first_div'] for x in rows if x['first_div'] is not None]
    print(f'{name:<18}{d:>+10.4f}{np.mean([x["argmax_agree"] for x in rows]):>9.3f}'
          f'{np.mean([x["logit_relL2"] for x in rows]):>10.4f}{np.mean([x["free_match"] for x in rows]):>11.3f}'
          f'{(min(fd) if fd else "none"):>10}')
