#!/usr/bin/env python3
"""I1 unit test: gemv_acc mode D (int8 weights + per-row scale) vs the software loop on the SoC RTL sim, bitwise.

usage: w8/run_test_w8.py [seed=1] [extra_random=60] [mac_budget=1500000]
       (TEST_SIM overrides obj_soc/Vsoc_top; the sim is built by TOP=soc_top ./build_sim.sh)
Cases: an edge grid of (n, d) with n not a multiple of 16 / 4, d not a multiple of 4 or of the 16-row group, plus a few large
cases (n or d = 512, FIFO and ybuf limits) and seeded random sizes; the four weight patterns rotate over the cases.
Sizes are limited by a total multiply-accumulate budget so the simulation stays at about 10 minutes."""
import os, struct, subprocess, sys
from pathlib import Path
import numpy as np

W = Path(__file__).resolve().parent.parent
O = Path(os.environ.get('TEST_OUT', W / 'w8' / 'out')); O.mkdir(parents=True, exist_ok=True)
SIM = os.environ.get('TEST_SIM', str(W / 'obj_soc/Vsoc_top'))
seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
extra = int(sys.argv[2]) if len(sys.argv) > 2 else 60
budget = int(sys.argv[3]) if len(sys.argv) > 3 else 1500000
rng = np.random.default_rng(seed)
BIG = os.environ.get('TEST_BIG') == '1'   # 15M-class shapes: needs a sim built with ACC_XBUF=ACC_YBUF=1024 (TEST_SIM=obj_soc_big/Vsoc_top)
TAB_ADDR = 0x110000 if BIG else 0x060000

if BIG:   # Stories15M-like: dim 288, hidden 768, classifier chunks of up to 1024 rows
    cases = [(288, 288), (288, 768), (768, 288), (288, 1024), (768, 1024), (288, 1000), (768, 768), (288, 17), (768, 33), (1024, 64),
             (287, 289), (769, 513), (1000, 100), (288, 1), (1, 1024), (768, 1), (576, 768), (96, 1024)]
    for _ in range(extra):
        cases.append((int(rng.integers(1, 1025)), int(rng.integers(1, 1025))))
else:
    NE = [1, 2, 3, 4, 5, 7, 15, 16, 17, 31, 32, 33, 63, 64, 65, 100, 171, 172, 173, 255, 256, 257, 511, 512]
    DE = [1, 2, 3, 4, 5, 8, 15, 16, 17, 31, 33, 64, 100, 172, 255, 256, 511, 512]
    cases = [(n, d) for n in NE for d in DE if n * d <= 12000]            # edge grid
    cases += [(512, 512), (512, 64), (64, 512), (172, 512), (512, 33), (1, 512), (512, 1)]  # large / degenerate
    for _ in range(extra):
        cases.append((int(rng.integers(1, 513)), int(rng.integers(1, 513))))
# keep within the MAC budget (grid and large cases first, then random)
sel, tot = [], 0
for n, d in cases:
    if tot + n * d > budget or n * d > 1048576: continue
    sel.append((n, d)); tot += n * d
cases = sel

subprocess.run(['env', 'SRC=' + os.environ.get('TEST_SRC', 'w8/test_w8_gemv.c'), f'OUT={O}/test_w8', 'CFLAGS_EXTRA=-O2 -funroll-loops' + (' -DBIGLAYOUT' if BIG else ''), str(W / 'build.sh')],
               cwd=W, check=True, capture_output=True)
elf = (O / 'test_w8.elf').read_bytes()
phoff = struct.unpack_from('<I', elf, 28)[0]; sz, num = struct.unpack_from('<HH', elf, 42)
m = bytearray(0x1020000)
for i in range(num):
    typ, off, va, pa, fs, ms, fl, al = struct.unpack_from('<8I', elf, phoff + i * sz)
    if typ == 1: m[pa:pa + fs] = elf[off:off + fs]
for c, (n, d) in enumerate(cases):
    struct.pack_into('<4I', m, TAB_ADDR + 16 * c, n, d, c % 4, int(rng.integers(1, 2 ** 31)))
struct.pack_into('<I', m, 0x1afff0, len(cases))
img, dump = O / 'img.bin', O / 'dump.bin'
img.write_bytes(m)
subprocess.run([SIM, str(img), str(dump), str(10 ** 10)], check=True, capture_output=True)
d = dump.read_bytes()
bad, fc, fr, nc, csw, chw, sent, rows, marker, badt, cht = struct.unpack_from('<11I', d, 0x1aff00)
print(f'cases {nc}, rows {rows}, total MAC {tot:,}, sw cycles {csw:,}, hw cycles {chw:,}')
print(f'mismatching output words {bad} (row-major) / {badt} (pre-tiled), sentinel violations {sent}, finished marker {hex(marker)}; accelerator cycles row-major {chw:,}, pre-tiled {cht:,}')
if bad:
    print(f'first mismatch: case {fc} (n={cases[fc][0]}, d={cases[fc][1]}, pattern {fc % 4}), row {fr}')
ok = marker == 0x600D600D and bad == 0 and badt == 0 and sent == 0 and nc == len(cases)
print('PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
