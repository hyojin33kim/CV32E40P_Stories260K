#!/usr/bin/env python3
"""Compare a reproduce.sh run (repro/) with the committed results.

Per item: pass / bit-exact flags must be identical; cycles are reported with their
difference and accepted when |delta| <= 0.01 % (code-layout effects of later firmware
edits, e.g. the 64/512-step references were recorded before the pos0 control was added).
Exit status 1 if any item fails or a committed reference is missing.
"""
import json, sys
from pathlib import Path

W = Path(__file__).resolve().parent
R = W / 'repro'
TOL = 1e-4
rows, bad = [], 0
MODE = sys.argv[1] if len(sys.argv) > 1 else 'quick'
HW = '_d2'  # default configuration D2: FPU latency 4 everywhere, 4 MAC lanes RUN 8 FIFO 256, 4 VFU lanes
EXPECT = [f'prof/O2u{HW}', f'prof/gen_O2u{HW}', f'prof/ddr_full{HW}'] + \
         [f'prof/acc_{t}{HW}' for t in ('ffn', 'attn', 'all', 'full')] + \
         [f'gen/out_8_Os{HW}'] + [f'gen/out_8_O2u_{m}{HW}_L0_G1' for m in ('accattn', 'accall', 'accfull')]
EXPECT += [f'prof/gen_O2u_opta{HW}', f'prof/acc_full_opta{HW}', f'prof/ddr_full_opta{HW}', f'prof/chip_full_opta{HW}',
           f'gen/out_8_Os_opta{HW}', f'gen/out_8_O2u_opta_accfull{HW}_L0_G1']
if MODE in ('standard', 'full'):
    EXPECT += [f'gen/out_64_Os_opta{HW}', f'gen/out_64_O2u_opta{HW}', f'gen/out_64_O2u_opta_accfull{HW}_L0_G1',
               f'gen/out_64_O2u_opta_accfull{HW}_ddr_L0_G1']
    EXPECT += [f'gen/out_64_Os{HW}', f'gen/out_64_O2u{HW}'] + \
              [f'gen/out_64_O2u_{m}{HW}_L0_G1' for m in ('acc', 'accattn', 'accall', 'accfull')] + \
              [f'gen/out_64_O2u_accfull{HW}_ddr_L0_G1']
if MODE == 'full':
    EXPECT += [f'gen/out_512_O2u_opta_accfull{HW}_L0_G1', f'gen/out_512_O2u_opta_accfull{HW}_ddr_L0_G1']
    EXPECT += [f'gen/out_512_Os{HW}', f'gen/out_512_O2u{HW}', f'gen/out_512_O2u_accfull{HW}_L0_G1',
               f'gen/out_512_O2u_accfull{HW}_ddr_L0_G1']
for e in EXPECT:  # a failed background run leaves no result file
    if not ((R / e / 'summary.json').exists() or (R / e / 'result.json').exists()):
        rows.append((e, 'missing (run failed? see repro/*.txt)', False)); bad += 1

def cmp_cycles(a, b):
    d = a - b
    return d, abs(d) <= TOL * b

for f in sorted((R / 'prof').glob('*/summary.json')):
    tag = f.parent.name
    ref = W / 'prof' / tag / 'summary.json'
    if not ref.exists():
        rows.append((f'prof/{tag}', 'no committed reference', False)); bad += 1; continue
    a, b = json.load(open(f)), json.load(open(ref))
    for t in ('1', '128', '512'):
        d, ok = cmp_cycles(a[t]['fw_measured_cycles'], b[t]['fw_measured_cycles'])
        if '_opta' in tag:   # Option A numerics: KV + output region == the SW Option A profile
            sw = R / 'prof' / f'gen_O2u_opta{HW}' / f'dump_{t}.bin'
            x, y = (f.parent / f'dump_{t}.bin').read_bytes(), sw.read_bytes() if sw.exists() else b''
            same = bool(y) and x[0x100000:0x1a0000] == y[0x100000:0x1a0000] and x[0x1a4a00:0x1a5200] == y[0x1a4a00:0x1a5200]
            ok = ok and same
            rows.append((f'prof/{tag} ctx{t}', f"cycles {a[t]['fw_measured_cycles']:,} (delta {d:+,}) "
                         f"bit-exact vs SW Option A {same}", ok))
        else:
            ok = ok and a[t]['logits_kv_bitexact_vs_hold'] is True
            rows.append((f'prof/{tag} ctx{t}', f"cycles {a[t]['fw_measured_cycles']:,} (delta {d:+,}) "
                         f"bit-exact vs HOLD {a[t]['logits_kv_bitexact_vs_hold']}", ok))
        bad += not ok

for f in sorted((R / 'gen').glob('out_*/result.json')):
    name = f.parent.name
    ref = W / 'gen' / name / 'result.json'
    a = json.load(open(f))
    ok = a['pass'] and a.get('logits_kv_tokens_bitexact_vs_Os') is not False
    note = f"pass {a['pass']} bit-exact vs -Os {a.get('logits_kv_tokens_bitexact_vs_Os')} cycles {a['cycles_total']:,}"
    if ref.exists():
        b = json.load(open(ref))
        d, cok = cmp_cycles(a['cycles_total'], b['cycles_total'])
        ok = ok and cok and a['pass'] == b['pass']
        note += f' (delta {d:+,} vs committed)'
    else:
        note += ' (no committed reference)'
    rows.append((f'gen/{name}', note, ok)); bad += not ok

oh = R / 'opta' / 'host_cmp_512' / 'result.json'   # Option A vs llama2.c on the host
if not oh.exists():
    rows.append(('opta host accuracy', 'missing (see repro/opta_host.txt)', False)); bad += 1
else:
    h = json.load(open(oh)); ok = h['free_token_match'] == 1.0 and h['tf_logits_rel_L2_max'] < 1e-5
    rows.append(('opta host accuracy', f"512 tokens match {h['free_token_match']:.3f}, rel L2 max "
                 f"{h['tf_logits_rel_L2_max']:.2e}", ok)); bad += not ok
er = R / 'exp2_rtl.txt'   # vfu_exp2.sv vs opta/exp2q.h
line = [l for l in er.read_text().splitlines() if l.startswith('vfu_exp2:')] if er.exists() else []
ok = bool(line) and line[-1].endswith(' 0 mismatches')
rows.append(('exp2 RTL vs C model', line[-1] if line else 'missing (see repro/exp2_rtl.txt)', ok)); bad += not ok
vt = R / 'vfu' / 'results.json'  # VFU unit test: every element bit-identical
if not vt.exists():
    rows.append(('vfu unit test', 'missing (see repro/vfu_test.txt)', False)); bad += 1
else:
    v = json.load(open(vt)); n = sum(x['n'] for x in v); m = sum(x['mismatches'] for x in v)
    rows.append(('vfu unit test', f'{n:,} elements, {m} mismatches', m == 0)); bad += m != 0

w = max(len(r[0]) for r in rows) if rows else 0
for name, note, ok in rows:
    print(f"{'OK  ' if ok else 'FAIL'} {name:<{w}}  {note}")
print(f'\n{len(rows) - bad}/{len(rows)} OK')
sys.exit(1 if bad else 0)
