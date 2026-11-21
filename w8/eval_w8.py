#!/usr/bin/env python3
"""I1 accuracy of the W8 host model (Option A numerics + int8 weights) against the Option A fp32 host model.
usage: w8/eval_w8.py [steps=512]   (4 prompts, teacher forced on the fp32 model's own greedy tokens)
Same metrics as quant/eval_quant.py: nll_delta (mean NLL increase, nats/token), argmax agreement, logits rel L2."""
import subprocess, sys
from pathlib import Path
import numpy as np

W = Path(__file__).resolve().parent.parent
steps = int(sys.argv[1]) if len(sys.argv) > 1 else 512
O = W / 'w8' / 'results'; O.mkdir(parents=True, exist_ok=True)
model, tok, V = W / 'stories260K.bin', W / 'gen' / 'tok512.bin', 512
PROMPTS = ['Once upon a time', 'One day, a little girl named Lily', 'The dog and the cat were best friends', 'Tom had a big red ball']

def run(*a):
    return subprocess.run([str(x) for x in a], check=True, capture_output=True, text=True).stdout

subprocess.run(['python3', str(W / 'w8' / 'make_run_w8.py'), str(W / 'run.c'), str(W / 'w8' / 'run_w8.c')], check=True, capture_output=True)
subprocess.run(['python3', str(W / 'w8' / 'make_run_w8.py'), str(W / 'opta' / 'run_opta.c'), str(W / 'w8' / 'run_opta_w8.c')], check=True, capture_output=True)
cc = ['cc', '-O2', '-ffp-contract=off', '-w', '-I', W / 'opta']
run(*cc, '-DOPTA', W / 'gen' / 'host_gen.c', '-lm', '-o', O / 'host_f')
run(*cc, '-DOPTA', '-DW8', W / 'gen' / 'host_gen.c', '-lm', '-o', O / 'host_q')

def lsm(x):
    x = x - x.max(1, keepdims=True)
    return x - np.log(np.exp(x).sum(1, keepdims=True))

rows = []
for pi, text in enumerate(PROMPTS):
    P = O / f'p{pi}'; P.mkdir(exist_ok=True)
    npr = int(run(O / 'host_f', 'encode', model, tok, text, P / 'prompt.u32'))
    run(O / 'host_f', 'free', model, P / 'prompt.u32', steps, P / 'free_f.u32')
    ff = np.fromfile(P / 'free_f.u32', dtype='<u4'); g0 = npr - 1
    run(O / 'host_f', 'tf', model, P / 'prompt.u32', P / 'free_f.u32', steps, P / 'tf_f.f32', P / 'kv_f.f32')
    run(O / 'host_q', 'tf', model, P / 'prompt.u32', P / 'free_f.u32', steps, P / 'tf_q.f32', P / 'kv_q.f32')
    lf = np.fromfile(P / 'tf_f.f32', dtype='<f4').reshape(steps, V).astype(np.float64)
    lq = np.fromfile(P / 'tf_q.f32', dtype='<f4').reshape(steps, V).astype(np.float64)
    tgt = ff[g0:].astype(int); idx = np.arange(g0, steps)
    rows.append((-lsm(lq)[idx, tgt].mean() + lsm(lf)[idx, tgt].mean(), (lq[idx].argmax(1) == tgt).mean(),
                 (np.linalg.norm(lq - lf, axis=1) / np.linalg.norm(lf, axis=1)).mean()))
r = np.array(rows)
print(f'W8 (per-row int8 weights) on Option A, {len(PROMPTS)} prompts x {steps} steps')
print(f'  nll_delta {r[:,0].mean():+.4f} (per prompt {np.round(r[:,0], 4).tolist()})')
print(f'  argmax agreement {r[:,1].mean():.3f}   logits rel L2 {r[:,2].mean():.4f}')
