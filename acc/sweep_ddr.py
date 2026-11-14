#!/usr/bin/env python3
"""Memory-model study: DDR parameter sweep (single forward at ctx 1 and 512), every run
checked bit-exact (logits + KV) against the HOLD dump.

usage: acc/sweep_ddr.py <prof tag> [workers]   images from prof/<tag>/ (built by run_prof.py
       with the same firmware flags); SWEEP_SIM = simulator (default obj_soc_ddr16/Vsoc_top)
Grid: SIM_DDR_LAT x SIM_DDR_OUT x SIM_DDR_BURST x SIM_DDR_BW (SIM_DDR_OVH fixed at 4).
"""
import itertools, json, os, struct, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

W = Path(__file__).resolve().parent.parent
TAG = sys.argv[1]
PROF = Path(os.environ.get('PROF_OUT', W / 'prof'))
P = PROF / TAG
O = Path(os.environ.get('SWEEP_OUT', W / 'acc' / 'sweep')) / f'ddr_{TAG}'; O.mkdir(parents=True, exist_ok=True)
SIM = os.environ.get('SWEEP_SIM', str(W / 'obj_soc_ddr16/Vsoc_top'))
base = json.load(open(PROF / 'gen_O2u' / 'summary.json'))          # ideal-memory SW baseline
LATS, OUTS, BURSTS, BWS = (20, 40, 100), (4, 8, 16), (4, 16, 64), (8.0, 12.8, 16.0)

def one(t, lat, out, burst, bw):
    d = O / f'dump_{t}_{lat}_{out}_{burst}_{bw}.bin'
    env = dict(os.environ, SIM_DDR='1', SIM_DDR_LAT=str(lat), SIM_DDR_OUT=str(out),
               SIM_DDR_BURST=str(burst), SIM_DDR_BW=str(bw))
    subprocess.run([SIM, str(P / f'image_{t}.bin'), str(d)], env=env, check=True, capture_output=True)
    m = d.read_bytes(); h = (W / f'base_{t}.bin').read_bytes()
    ok = m[0x1a4a00:0x1a5200] == h[0x1a4a00:0x1a5200] and m[0x100000:0x1a0000] == h[0x100000:0x1a0000]
    cyc = struct.unpack_from('<I', m, 0x1ad000 + 4 * (t - 1))[0]
    d.unlink()
    return dict(ctx=t, lat=lat, out=out, burst=burst, bw=bw, cycles=cyc, bitexact=ok,
                speedup_vs_ideal_sw=base[str(t)]['fw_measured_cycles'] / cyc)

jobs = [(t,) + g for t in (1, 512) for g in itertools.product(LATS, OUTS, BURSTS, BWS)]
with ThreadPoolExecutor(max_workers=int(sys.argv[2]) if len(sys.argv) > 2 else 8) as ex:
    res = list(ex.map(lambda a: one(*a), jobs))
(O / 'sweep.json').write_text(json.dumps(res, indent=1))

out = [f'# DDR sweep `{TAG}` (speedup vs ideal-memory SW baseline; OVH=4)', '']
for t in (1, 512):
    out += [f'## ctx{t}', '', '| latency | outstanding | burst | ' + ' | '.join(f'{b:g} B/cyc' for b in BWS) + ' |',
            '|---:|---:|---:|' + '---:|' * len(BWS)]
    for lat, o, bu in itertools.product(LATS, OUTS, BURSTS):
        cells = []
        for bw in BWS:
            r = next(x for x in res if (x['ctx'], x['lat'], x['out'], x['burst'], x['bw']) == (t, lat, o, bu, bw))
            cells.append(f"{r['cycles']:,} ({r['speedup_vs_ideal_sw']:.2f}x){'' if r['bitexact'] else ' MISMATCH'}")
        out.append(f'| {lat} | {o} | {bu} | ' + ' | '.join(cells) + ' |')
    out.append('')
(O / 'sweep.md').write_text('\n'.join(out) + '\n')
print('\n'.join(out))
print('all bit-exact:', all(r['bitexact'] for r in res), f'({len(res)} runs)')
