#!/usr/bin/env python3
"""Step ①: continuous generation on CV32E40P RTL vs host llama2.c golden.

usage: [GEN_CFLAGS=...] gen/run_gen.py <steps> [prompt text]   (writes gen/out_<steps>_<tag>/)
GEN_CFLAGS defaults to the step-② SW baseline "-O2 -funroll-loops" (tag O2u);
GEN_CFLAGS="" reproduces the HOLD -Os build (tag Os).
GEN_ACC=1 builds with -DUSE_ACC (FFN GEMV on acc/gemv_acc.sv), GEN_ACC=attn adds
-DUSE_ACC_ATTN (attention QK/AV too), GEN_ACC=all adds -DUSE_ACC_VFU (softmax and
SwiGLU on acc/vfu.sv); all run obj_soc/Vsoc_top;
SIM_ACC_LAT / SIM_ACC_GNT_EVERY set the accelerator memory latency / grant period
(tag <flags>_acc_L<lat>_G<period>). Results must stay bit-exact vs the -Os run.
Pass criteria (agreed 2026-11-13, host<->RISC is tolerance-based):
  per step: logits rel L2 < 1e-5, RISC token == argmax(RISC logits),
            host argmax == RISC argmax (mismatch allowed only on near-tie, reported)
  per pos : KV rel L2 < 1e-5; KV prefix untouched by later steps (checked by layout)
"""
import json, os, struct, subprocess, sys, time
from pathlib import Path
import numpy as np

W = Path(__file__).resolve().parent.parent
G = W / 'gen'
steps = int(sys.argv[1]); text = sys.argv[2] if len(sys.argv) > 2 else 'Once upon a time'
cflags = os.environ.get('GEN_CFLAGS', '-O2 -funroll-loops')
tag = {'-O2 -funroll-loops': 'O2u', '': 'Os'}.get(cflags, cflags.replace(' ', '').replace('-', '_'))
mode = os.environ.get('GEN_ACC', '')
acc = mode in ('1', 'attn', 'all')
name = {'1': 'acc', 'attn': 'accattn', 'all': 'accall'}.get(mode, '')
fwtag = tag + ('_' + name if acc else '')
if acc:
    cflags += ' -DUSE_ACC' + {'1': '', 'attn': ' -DUSE_ACC_ATTN', 'all': ' -DUSE_ACC_ATTN -DUSE_ACC_VFU'}[mode]
    tag += '_' + name + '_L%s_G%s' % (os.environ.get('SIM_ACC_LAT', '0'), os.environ.get('SIM_ACC_GNT_EVERY', '1'))
OUTROOT = Path(os.environ.get('GEN_OUT', G))  # reproduce.sh points this at repro/gen
OUTROOT.mkdir(parents=True, exist_ok=True)
O = OUTROOT / f'out_{steps}_{tag}'; O.mkdir(exist_ok=True)
model, tok = W / 'stories260K.bin', G / 'tok512.bin'
V, L, S, KVD = 512, 5, 512, 32

def run(*a, **k):
    return subprocess.run([str(x) for x in a], check=True, capture_output=True, text=True, **k).stdout

# host tool
hg = O / 'host_gen'  # per-run copy so concurrent runs don't race on the binary
run('cc', '-O2', '-ffp-contract=off', '-w', G / 'host_gen.c', '-lm', '-o', hg)
np_ = int(run(hg, 'encode', model, tok, text, O / 'prompt.u32'))
prompt = np.fromfile(O / 'prompt.u32', dtype='<u4')
assert steps >= np_, 'steps must cover the prompt'

# firmware + image
fw = OUTROOT / f'firmware_gen_{fwtag}'
run('env', 'SRC=gen/firmware_gen.c', f'OUT={fw}', 'TC=/usr', f'CFLAGS_EXTRA={cflags}', W / 'build.sh', cwd=W)
run('python3', W / 'image.py', f'{fw}.elf', O / 'image.bin')
m = bytearray((O / 'image.bin').read_bytes())
m[0x1ae000:0x1ae000 + 4 * np_] = prompt.tobytes()
struct.pack_into('<II', m, 0x1afff0, np_, steps)
(O / 'image.bin').write_bytes(m)

# RTL sim
t0 = time.time()
sim = os.environ.get('GEN_SIM') or W / ('obj_soc/Vsoc_top' if acc else 'obj/Vcv32e40p_top')
log = run(sim, O / 'image.bin', O / 'dump.bin', str(10**11), O / 'steps.bin')
wall = time.time() - t0
(O / 'sim.log').write_text(log)
d = (O / 'dump.bin').read_bytes()
toks = np.frombuffer(d[0x1ae800:0x1ae800 + 4 * steps], dtype='<u4').astype(np.int64)
cyc = np.frombuffer(d[0x1ad000:0x1ad000 + 4 * steps], dtype='<u4').astype(np.int64)
toks.astype('<u4').tofile(O / 'risc_toks.u32')
rec = np.fromfile(O / 'steps.bin', dtype=np.uint8).reshape(-1, 4 + 4 * V)
assert len(rec) == steps
assert (rec[:, :4].copy().view('<u4').ravel() == np.arange(steps)).all()
rl = rec[:, 4:].copy().view('<f4')

# host golden
run(hg, 'tf', model, O / 'prompt.u32', O / 'risc_toks.u32', steps, O / 'host_logits.f32', O / 'host_kv.f32')
run(hg, 'free', model, O / 'prompt.u32', steps, O / 'host_free.u32')
hl = np.fromfile(O / 'host_logits.f32', dtype='<f4').reshape(steps, V)
hkv = np.fromfile(O / 'host_kv.f32', dtype='<f4').reshape(2, L, S, KVD)
rkv = np.stack([np.stack([np.frombuffer(d[0x100000 + l * 0x20000 + j * 0x10000:0x110000 + l * 0x20000 + j * 0x10000],
                dtype='<f4').reshape(S, KVD) for l in range(L)]) for j in range(2)])
free = np.fromfile(O / 'host_free.u32', dtype='<u4').astype(np.int64)

rel = np.linalg.norm(rl - hl, axis=1) / np.linalg.norm(hl, axis=1)
ra, ha = rl.argmax(1), hl.argmax(1)
top2 = np.sort(hl, axis=1)[:, -2:]; margin = top2[:, 1] - top2[:, 0]
kv_rel = np.array([np.linalg.norm(rkv[:, :, p] - hkv[:, :, p]) / np.linalg.norm(hkv[:, :, p]) for p in range(steps)])
kv_bitexact = int(sum((rkv[:, :, p] == hkv[:, :, p]).all() for p in range(steps)))
logit_bitexact = int((rl == hl).all(axis=1).sum())
untouched = bool((rkv[:, :, steps:] == 0).all()) if steps < S else True
gen_from = np_ - 1
div = np.nonzero(free[gen_from:] != toks[gen_from:])[0]
argmax_mm = np.nonzero(ra != ha)[0]

# RISC-SW numerics must not depend on compiler flags: compare with the -Os run if present
ref = OUTROOT / f'out_{steps}_Os' if (OUTROOT / f'out_{steps}_Os' / 'steps.bin').exists() else G / f'out_{steps}_Os'
if tag != 'Os' and (ref / 'steps.bin').exists() and (ref / 'dump.bin').exists():
    rd = (ref / 'dump.bin').read_bytes()
    bitexact_vs_Os = bool((O / 'steps.bin').read_bytes() == (ref / 'steps.bin').read_bytes()
                          and d[0x100000:0x1a0000] == rd[0x100000:0x1a0000] and d[0x1ae800:0x1aec00] == rd[0x1ae800:0x1aec00])
else:
    bitexact_vs_Os = None
text_bytes = int([l for l in run('/usr/bin/riscv64-unknown-elf-size', '-A', f'{fw}.elf').splitlines()
                  if l.startswith('.text')][0].split()[1])
acc_line = [l for l in log.splitlines() if l.startswith('ACC ')]
res = dict(
    acc=acc_line[0] if acc_line else None,
    cflags=cflags, text_bytes=text_bytes, logits_kv_tokens_bitexact_vs_Os=bitexact_vs_Os,
    steps=steps, prompt=text, n_prompt=np_, sim_wall_s=round(wall, 1),
    cycles_total=int(cyc.sum()), cycles_first=int(cyc[0]), cycles_last=int(cyc[-1]),
    logits_rel_L2_max=float(rel.max()), logits_bitexact_steps=logit_bitexact,
    risc_token_is_own_argmax=bool((toks == ra).all()),
    argmax_mismatch_steps=[dict(pos=int(p), host_margin=float(margin[p])) for p in argmax_mm],
    min_host_top2_margin=float(margin.min()),
    kv_rel_L2_max=float(kv_rel.max()), kv_bitexact_positions=kv_bitexact, kv_beyond_steps_zero=untouched,
    host_free_run_first_divergence=(int(div[0] + gen_from) if len(div) else None),
)
res['pass'] = bool(rel.max() < 1e-5 and kv_rel.max() < 1e-5 and res['risc_token_is_own_argmax'] and untouched
                   and all(x['host_margin'] < 1e-4 for x in res['argmax_mismatch_steps'])
                   and bitexact_vs_Os is not False)
np.save(O / 'cycles.npy', cyc)
(O / 'result.json').write_text(json.dumps(res, indent=2))
print(json.dumps(res, indent=2))
print('RISC text :', run(hg, 'decode', model, tok, O / 'prompt.u32', O / 'risc_toks.u32', steps).strip())
print('host free :', run(hg, 'decode', model, tok, O / 'prompt.u32', O / 'host_free.u32', steps).strip())
