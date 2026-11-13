#!/usr/bin/env python3
"""Step ②: zero-overhead per-region profile of one forward() at context 1/128/512.

usage: prof/run_prof.py <firmware.c> <tag>   -> prof/<tag>/{prof_<t>.csv, summary.json, table.md}
The firmware is built with -g (code bytes identical to the non -g build; checked
here) and run on the CSR-free sim profiler (SIM_PROF). Each cycle is charged to the
forward()/boot() source line that is the current call site, so callee cycles
(matmul, expf, ...) land on the calling line. Regions below are line ranges of
baseline/firmware.c forward(); a different firmware.c must keep forward() lines.
"""
import csv, json, os, struct, subprocess, sys
from collections import defaultdict
from pathlib import Path

W = Path(__file__).resolve().parent.parent
src, tag = sys.argv[1], sys.argv[2]
O = W / 'prof' / tag; O.mkdir(parents=True, exist_ok=True)
TC = '/usr/bin/riscv64-unknown-elf-'

def sh(*a, **k):
    return subprocess.run([str(x) for x in a], check=True, capture_output=True, text=True, **k).stdout

# build (-g and plain) and require identical code bytes
OPT = os.environ.get('PROF_CFLAGS', '')  # e.g. "-O2" (appended after build.sh's -Os)
for name, extra in (('fw_g', '-g ' + OPT), ('fw', OPT)):
    sh('env', f'SRC={src}', f'OUT=prof/{tag}/{name}', f'CFLAGS_EXTRA={extra}', W / 'build.sh', cwd=W)
txt = [subprocess.run([TC + 'objcopy', '-O', 'binary', '-j', '.text', O / f'{n}.elf', '/dev/stdout'],
                      capture_output=True, check=True).stdout for n in ('fw_g', 'fw')]
assert txt[0] == txt[1], '-g changed code bytes'
elf = O / 'fw_g.elf'

syms = []
for line in sh(TC + 'nm', '-S', elf).splitlines():
    f = line.split()
    if len(f) == 4 and f[2] in 'tT':
        syms.append((int(f[0], 16), int(f[0], 16) + int(f[1], 16), f[3]))
fn = {n: (a, b) for a, b, n in syms}
def leaf(pc):
    for a, b, n in syms:
        if a <= pc < b:
            return 'save/restore' if n.startswith('__riscv_') else n
    return 'other'

REGIONS = [  # (first line, last line, region) in forward()
    (113, 128, 'setup+embed'), (131, 131, 'layer loop'), (134, 134, 'rmsnorm'),
    (137, 139, 'misc'), (142, 144, 'W_qkv'), (147, 160, 'RoPE'),
    (165, 165, 'attn head loop'), (167, 182, 'attn QK'), (185, 185, 'softmax'),
    (188, 200, 'attn AV'), (203, 203, 'W_o'), (206, 208, 'residual'), (211, 211, 'rmsnorm'),
    (215, 216, 'FFN W1/W3'), (219, 226, 'SwiGLU'), (229, 229, 'FFN W2'), (232, 235, 'residual'),
    (238, 238, 'rmsnorm'), (241, 243, 'LM head'),
]

image = O / 'image.bin'
sh('python3', W / 'image.py', O / 'fw.elf', image)
base = image.read_bytes()
summary = {}
for t in (1, 128, 512):
    m = bytearray(base); kv = (W / f'kv_{t}.bin').read_bytes()  # same injection as cases.py
    for l in range(5):
        for j in range(2):
            m[0x100000 + l * 0x20000 + j * 0x10000:0x110000 + l * 0x20000 + j * 0x10000] = \
                kv[j * 327680 + l * 65536:j * 327680 + (l + 1) * 65536]
    struct.pack_into('I', m, 0x1afff0, t - 1)
    img = O / f'image_{t}.bin'; img.write_bytes(m)
    env = dict(os.environ, SIM_PROF=str(O / f'prof_{t}.csv'),
               SIM_PROF_SITES='%x-%x,%x-%x' % (*fn['forward'], *fn['boot']))
    subprocess.run([str(W / 'obj_prof/Vcv32e40p_top'), str(img), str(O / f'dump_{t}.bin')],
                   env=env, check=True, capture_output=True)
    dump = (O / f'dump_{t}.bin').read_bytes(); hold = (W / f'base_{t}.bin').read_bytes()
    fw_cycles = struct.unpack_from('I', dump, 0x1aff00)[0]
    bitexact = dump[0x1a4a00:0x1a5200] == hold[0x1a4a00:0x1a5200] and dump[0x100000:0x1a0000] == hold[0x100000:0x1a0000]
    rows = list(csv.DictReader(open(O / f'prof_{t}.csv')))
    sites = sorted({int(r['site'], 16) for r in rows} - {0})
    # -a -i: per address, the inline chain innermost-first; the last frame is the
    # line in the enclosing (non-inlined) function, i.e. the forward() call site.
    a2l = sh(TC + 'addr2line', '-a', '-i', '-e', elf, *[hex(s) for s in sites]).splitlines()
    def lineno(x):
        n = x.split()[0].rsplit(':', 1)[1]
        return int(n) if n.isdigit() else -1
    line_of, cur = {}, None
    for x in a2l:
        if x.startswith('0x'): cur = int(x, 16)
        else: line_of[cur] = lineno(x)
    def region(site):
        if site == 0: return 'reset'
        if not (fn['forward'][0] <= site < fn['forward'][1]): return 'boot/argmax'
        ln = line_of[site]
        for a, b, r in REGIONS:
            if a <= ln <= b: return r
        return f'forward:{ln}'
    reg = defaultdict(lambda: defaultdict(int)); lf = defaultdict(lambda: defaultdict(int))
    for r in rows:
        s = int(r['site'], 16); g = region(s)
        for k, v in r.items():
            if k not in ('site', 'pc'): reg[g][k] += int(v)
        lf[g][leaf(int(r['pc'], 16))] += int(r['cycles'])
    fwd = sum(v['cycles'] for g, v in reg.items() if g not in ('reset', 'boot/argmax'))
    summary[t] = dict(fw_measured_cycles=fw_cycles, logits_kv_bitexact_vs_hold=bitexact, profiled_forward_cycles=fwd,
                      regions={g: dict(v) for g, v in reg.items()}, leaf_cycles={g: dict(v) for g, v in lf.items()})

tb = int([l for l in sh(TC + 'size', '-A', O / 'fw.elf').splitlines() if l.startswith('.text')][0].split()[1])
(O / 'summary.json').write_text(json.dumps(dict(summary, text_bytes=tb), indent=1))

# markdown table: cycles share + data reads (words) per region
order = ['W_qkv', 'W_o', 'FFN W1/W3', 'FFN W2', 'LM head', 'attn QK', 'softmax', 'attn AV', 'SwiGLU',
         'rmsnorm', 'RoPE', 'residual', 'attn head loop', 'layer loop', 'setup+embed', 'misc']
out = ['| region | ' + ' | '.join(f'ctx{t} cycles (%)' for t in summary) + ' | ctx512 reads W/KV/act (words) |',
       '|---|' + '---:|' * (len(summary) + 1)]
for g in order + sorted({g for s in summary.values() for g in s['regions']} - set(order) - {'reset', 'boot/argmax'}):
    cells = []
    for t, s in summary.items():
        c = s['regions'].get(g, {}).get('cycles', 0)
        cells.append(f"{c:,} ({100 * c / s['profiled_forward_cycles']:.1f}%)")
    r5 = summary[512]['regions'].get(g, {})
    out.append(f'| {g} | ' + ' | '.join(cells) +
               f" | {r5.get('rd_w', 0):,} / {r5.get('rd_kv', 0):,} / {r5.get('rd_act', 0):,} |")
out.append('| **forward total (profiled)** | ' + ' | '.join(f"{s['profiled_forward_cycles']:,}" for s in summary.values()) + ' | |')
out.append('| logits+KV bit-exact vs HOLD | ' + ' | '.join(str(s['logits_kv_bitexact_vs_hold']) for s in summary.values()) + ' | |')
out.append(f'| .text bytes | {tb} | | | |')
out.append('| firmware mcycle window | ' + ' | '.join(f"{s['fw_measured_cycles']:,}" for s in summary.values()) + ' | |')
(O / 'table.md').write_text('\n'.join(out) + '\n')
print('\n'.join(out))
for t, s in summary.items():
    print(f'ctx{t} leaf cycles in softmax:', s['leaf_cycles'].get('softmax'), ' SwiGLU:', s['leaf_cycles'].get('SwiGLU'))
