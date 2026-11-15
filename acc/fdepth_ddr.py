#!/usr/bin/env python3
"""Memory-model study: gemv_acc lane FIFO depth vs DDR latency (ACC_RUN=16 builds).
Uses prof/ddr_full_opt images; every run checked bit-exact against the HOLD dump.
usage: acc/fdepth_ddr.py   -> acc/sweep/fdepth_ddr/{fdepth.json,fdepth.md}"""
import json, os, struct, subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

W = Path(__file__).resolve().parent.parent
P = W / 'prof' / 'ddr_full_opt'
O = W / 'acc' / 'sweep' / 'fdepth_ddr'; O.mkdir(parents=True, exist_ok=True)
SIMS = {128: 'obj_soc_ddr16', 256: 'obj_soc_r16f256', 512: 'obj_soc_r16f512'}
CONDS = [(40, 12.8), (100, 16.0), (100, 12.8)]          # (latency, B/cycle); burst 16, out 8
base = json.load(open(W / 'prof' / 'gen_O2u' / 'summary.json'))

def one(fd, t, lat, bw):
    d = O / f'dump_{fd}_{t}_{lat}_{bw}.bin'
    env = dict(os.environ, SIM_DDR='1', SIM_DDR_LAT=str(lat), SIM_DDR_BW=str(bw))
    subprocess.run([str(W / SIMS[fd] / 'Vsoc_top'), str(P / f'image_{t}.bin'), str(d)],
                   env=env, check=True, capture_output=True)
    m = d.read_bytes(); h = (W / f'base_{t}.bin').read_bytes(); d.unlink()
    ok = m[0x1a4a00:0x1a5200] == h[0x1a4a00:0x1a5200] and m[0x100000:0x1a0000] == h[0x100000:0x1a0000]
    cyc = struct.unpack_from('<I', m, 0x1ad000 + 4 * (t - 1))[0]
    return dict(fdepth=fd, ctx=t, lat=lat, bw=bw, cycles=cyc, bitexact=ok,
                speedup=base[str(t)]['fw_measured_cycles'] / cyc)

jobs = [(fd, t, l, b) for fd in SIMS for t in (1, 512) for l, b in CONDS]
with ThreadPoolExecutor(8) as ex:
    res = list(ex.map(lambda a: one(*a), jobs))
(O / 'fdepth.json').write_text(json.dumps(res, indent=1))
lines = ['| ctx | DDR (latency, B/cycle) | ' + ' | '.join(f'FDEPTH {fd}' for fd in SIMS) + ' |',
         '|---|---|' + '---:|' * len(SIMS)]
for t in (1, 512):
    for l, b in CONDS:
        cells = []
        for fd in SIMS:
            r = next(x for x in res if (x['fdepth'], x['ctx'], x['lat'], x['bw']) == (fd, t, l, b))
            cells.append(f"{r['cycles']:,} ({r['speedup']:.2f}x){'' if r['bitexact'] else ' MISMATCH'}")
        lines.append(f'| {t} | L{l}, {b:g} | ' + ' | '.join(cells) + ' |')
(O / 'fdepth.md').write_text('\n'.join(lines) + '\n')
print('\n'.join(lines))
print('all bit-exact:', all(r['bitexact'] for r in res))
