#!/usr/bin/env python3
"""Step ③: accelerator memory latency / bandwidth sweep (single forward at ctx1 and ctx512).

Uses the images built by `PROF_ACC=1 prof/run_prof.py gen/firmware_gen.c acc_L0_G1`.
SIM_ACC_LAT      : extra cycles before each read response (pipelined, unlimited outstanding)
SIM_ACC_GNT_EVERY: one request granted every P cycles (32-bit port -> 4/P bytes per cycle)
Every run is checked bit-exact (logits + KV) against the HOLD dump.
"""
import json, os, struct, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

W = Path(__file__).resolve().parent.parent
P = W / 'prof' / 'acc_L0_G1'
O = W / 'acc' / 'sweep'; O.mkdir(parents=True, exist_ok=True)
base = json.load(open(W / 'prof' / 'gen_O2u' / 'summary.json'))
LATS, GNTS = (0, 16, 64, 128), (1, 2, 4)

def one(t, lat, gp):
    out = O / f'dump_{t}_L{lat}_G{gp}.bin'
    env = dict(os.environ, SIM_ACC_LAT=str(lat), SIM_ACC_GNT_EVERY=str(gp))
    so = subprocess.run([str(W / 'obj_soc/Vsoc_top'), str(P / f'image_{t}.bin'), str(out)],
                        env=env, check=True, capture_output=True, text=True).stdout
    d = out.read_bytes(); h = (W / f'base_{t}.bin').read_bytes()
    ok = d[0x1a4a00:0x1a5200] == h[0x1a4a00:0x1a5200] and d[0x100000:0x1a0000] == h[0x100000:0x1a0000]
    cyc = struct.unpack_from('<I', d, 0x1ad000 + 4 * (t - 1))[0]
    out.unlink()
    return dict(ctx=t, lat=lat, gnt_every=gp, cycles=cyc, bitexact=ok,
                speedup=base[str(t)]['fw_measured_cycles'] / cyc)

jobs = [(t, l, g) for t in (1, 512) for l in LATS for g in GNTS]
with ThreadPoolExecutor(max_workers=int(sys.argv[1]) if len(sys.argv) > 1 else 8) as ex:
    res = list(ex.map(lambda a: one(*a), jobs))
(O / 'sweep.json').write_text(json.dumps(res, indent=1))
lines = ['| ctx | latency \\ grant period | ' + ' | '.join(f'G={g} ({4 / g:g} B/cyc)' for g in GNTS) + ' |',
         '|---|---|' + '---:|' * len(GNTS)]
for t in (1, 512):
    sw = base[str(t)]['fw_measured_cycles']
    for l in LATS:
        cells = []
        for g in GNTS:
            r = next(x for x in res if x['ctx'] == t and x['lat'] == l and x['gnt_every'] == g)
            cells.append(f"{r['cycles']:,} ({r['speedup']:.2f}x){'' if r['bitexact'] else ' MISMATCH'}")
        lines.append(f'| {t} | L={l} | ' + ' | '.join(cells) + ' |')
    lines.append(f'| {t} | SW baseline | {sw:,} | | |')
(O / 'sweep.md').write_text('\n'.join(lines) + '\n')
print('\n'.join(lines))
print('all bit-exact:', all(r['bitexact'] for r in res))
