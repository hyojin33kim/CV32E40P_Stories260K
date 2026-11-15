#!/usr/bin/env python3
"""Per-stage time profile: one forward step at ctx 1 / 128 / 512, cycles per region for each
development stage, plus time at an assumed clock.

usage: prof/stage_profile.py [MHz=150]  -> prints markdown (also written to prof/STAGE_PROFILE.md)
Data: prof/<tag>/summary.json written by prof/run_prof.py (zero-overhead sim profiler).
"""
import json, sys
from pathlib import Path

W = Path(__file__).resolve().parent.parent
MHZ = float(sys.argv[1]) if len(sys.argv) > 1 else 150.0
STAGES = [  # (label, summary path)
    ('HOLD -Os', 'prof/baseline/summary.json'),
    ('② SW baseline', 'prof/gen_O2u/summary.json'),
    ('③ FFN', 'prof/acc_ffn_l4v4r16/summary.json'),
    ('④-a +QK/AV', 'prof/acc_attn_l4v4r16/summary.json'),
    ('④-b +VFU', 'prof/acc_all_l4v4r16/summary.json'),
    ('all GEMV+lanes+fused', 'prof/acc_full_l4v4r16/summary.json'),
    ('+DDR model', 'prof/ddr_full_l4v4r16/summary.json'),
    ('v2 FPU lat 4 (sim)', '.scratch/pv3/v3b/summary.json'),
]
GROUPS = [  # (group, regions)
    ('Weight GEMV (QKV, O, FFN, LM head)', ['W_qkv', 'W_o', 'FFN W1/W3', 'FFN W2', 'LM head']),
    ('Attention QK (+ ÷√8)', ['attn QK']),
    ('softmax', ['softmax']),
    ('Attention AV', ['attn AV']),
    ('SwiGLU', ['SwiGLU']),
    ('CPU rest (rmsnorm, RoPE, residual, loops, embed)',
     ['rmsnorm', 'RoPE', 'residual', 'attn head loop', 'layer loop', 'setup+embed', 'misc']),
]
data = []
for label, path in STAGES:
    f = W / path
    if f.exists():
        data.append((label, json.load(open(f))))
out = [f'# Per-stage time profile (one forward step, cycles; time at {MHZ:g} MHz)', '',
       'Source: `prof/<tag>/summary.json` (zero-overhead sim profiler). bit-exact vs HOLD in every stage.',
       'Stages after ④-b use the default SoC build (4 MAC lanes RUN 16 FIFO 256, 4 VFU lanes); "v2 FPU',
       'lat 4" is the FPGA-oriented RTL with pipelined accelerator FPUs (CPU FPU still latency 0).', '']
for t in ('1', '128', '512'):
    out += [f'## ctx{t}', '', '| region | ' + ' | '.join(l for l, _ in data) + ' |',
            '|---|' + '---:|' * len(data)]
    for g, regs in GROUPS:
        cells = []
        for _, d in data:
            r = d[t]['regions']; tot = d[t]['profiled_forward_cycles']
            c = sum(r.get(x, {}).get('cycles', 0) for x in regs)
            cells.append(f'{c:,} ({100 * c / tot:.0f}%)')
        out.append(f'| {g} | ' + ' | '.join(cells) + ' |')
    tots = [d[t]['fw_measured_cycles'] for _, d in data]
    base = data[1][1][t]['fw_measured_cycles']
    out.append('| **total cycles** | ' + ' | '.join(f'**{c:,}**' for c in tots) + ' |')
    out.append(f'| time @ {MHZ:g} MHz (ms) | ' + ' | '.join(f'{c / MHZ / 1e3:.2f}' for c in tots) + ' |')
    out.append('| vs ② SW baseline | ' + ' | '.join(f'{base / c:.2f}×' for c in tots) + ' |')
    out.append('')
text = '\n'.join(out) + '\n'
(W / 'prof' / 'STAGE_PROFILE.md').write_text(text)
print(text)
