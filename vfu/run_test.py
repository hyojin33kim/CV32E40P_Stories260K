#!/usr/bin/env python3
"""Step ④-b unit test: VFU (acc/vfu.sv) vs RISC-V software on the SoC RTL sim, bitwise.

usage: vfu/run_test.py [seeds=4] [n=65536]     (TEST_SIM overrides obj_soc/Vsoc_top)
       env: TEST_ONLY=2,5,6 (tests to run), TEST_LN=<n> (softmax chunk length), TEST_OUT
Runs tests exp/softmax/silu/divs for each seed in parallel; prints mismatches per run.
exp inputs: every sf_exp threshold +-64 ulp (both signs), specials (+-0, +-inf, NaN,
+-FLT_MAX, subnormals), the k<-125 / subnormal-result range, |x|<2^-23, uniform ranges,
softmax-like [-40,0], and raw random bit patterns.
"""
import json, os, struct, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import numpy as np

W = Path(__file__).resolve().parent.parent
O = Path(os.environ.get('TEST_OUT', W / 'vfu' / 'out')); O.mkdir(parents=True, exist_ok=True)
SIM = os.environ.get('TEST_SIM', str(W / 'obj_soc/Vsoc_top'))
SEEDS = int(sys.argv[1]) if len(sys.argv) > 1 else 4
N = int(sys.argv[2]) if len(sys.argv) > 2 else 65536
TESTS = {1: 'exp', 2: 'softmax', 3: 'silu', 4: 'divs', 5: 'divsoftmax', 6: 'softmax2', 7: 'silu2'}
if os.environ.get('TEST_ONLY'): TESTS = {int(k): TESTS[int(k)] for k in os.environ['TEST_ONLY'].split(',')}

def f2u(a): return np.asarray(a, dtype='<f4').view('<u4')
def u2f(a): return np.asarray(a, dtype='<u4').view('<f4')

def exp_inputs(rng):
    th = [0x42b17217, 0x42cff1b5, 0x3eb17218, 0x3f851592, 0x34000000, 0x7f800000,
          0x42b17218, 0x42aeac50, 0x3f800000, 0x00800000]
    b = [t + d for t in th for d in range(-64, 65) if 0 <= t + d < 0x80000000]
    b = b + [x | 0x80000000 for x in b]
    spec = [0, 0x80000000, 0x7f800000, 0xff800000, 0x7fc00000, 0x7f800001, 0xffc00000,
            0x7f7fffff, 0xff7fffff, 0x00000001, 0x80000001, 0x007fffff, 0x807fffff]
    parts = [np.array(b + spec, dtype=np.uint32),
             f2u(rng.uniform(-104.0, -85.0, 8192).astype(np.float32)),   # k<-125, subnormal results
             f2u(rng.uniform(-110.0, 90.0, 8192).astype(np.float32)),
             f2u(rng.uniform(-40.0, 0.0, 8192).astype(np.float32)),      # softmax-like
             f2u((rng.uniform(-1, 1, 2048) * 2.0 ** -23).astype(np.float32)),
             f2u(rng.uniform(-1.5, 1.5, 4096).astype(np.float32))]        # around +-ln2 ranges
    x = np.concatenate(parts)
    rest = max(0, N - len(x))
    return np.concatenate([x, rng.integers(0, 2 ** 32, rest, dtype=np.uint64).astype(np.uint32)])[:N]

def inputs(test, rng):
    aux = np.zeros(N, dtype=np.uint32)
    if test == 1:
        x = exp_inputs(rng)
    elif test in (2, 5, 6):  # softmax chunks with llama2.c-like scores, ties and +-0
        x = f2u(rng.normal(0, 3, N).astype(np.float32) * rng.choice([1, 4, 0.01], N).astype(np.float32))
        x[rng.integers(0, N, N // 64)] = 0x80000000
        x[rng.integers(0, N, N // 64)] = 0
        j = 0
        while j < N:
            ln = int(os.environ['TEST_LN']) if os.environ.get('TEST_LN') else int(rng.choice([1, 2, 8, 512, int(rng.integers(1, 513))]))   # TEST_LN=<n>: fixed chunk length (V-A1: at and beyond VFU_BUF)
            aux[j] = ln; j += ln
    elif test in (3, 7):  # silu: values seen in hb, gate in hb2
        x = f2u(rng.normal(0, 4, N).astype(np.float32))
        x[:len(exp_inputs(rng)[:4096])] = exp_inputs(rng)[:4096] ^ 0x80000000  # exp corner cases via -val
        aux = f2u(rng.normal(0, 2, N).astype(np.float32))
    else:
        x = np.concatenate([f2u(rng.normal(0, 5, N // 2).astype(np.float32)),
                            rng.integers(0, 2 ** 32, N - N // 2, dtype=np.uint64).astype(np.uint32)])
    return x.astype(np.uint32), aux.astype(np.uint32)

def build():
    subprocess.run(['env', 'SRC=vfu/test_vfu.c', f'OUT={O}/test_vfu', 'CFLAGS_EXTRA=-O2 -funroll-loops',
                    str(W / 'build.sh')], cwd=W, check=True, capture_output=True)
    elf = (O / 'test_vfu.elf').read_bytes(); segs = []
    phoff = struct.unpack_from('<I', elf, 28)[0]; sz, num = struct.unpack_from('<HH', elf, 42)
    for i in range(num):
        typ, off, va, pa, fs, ms, fl, al = struct.unpack_from('<8I', elf, phoff + i * sz)
        if typ == 1: segs.append((pa, elf[off:off + fs]))
    return segs

def one(segs, test, seed):
    rng = np.random.default_rng(1000 * seed + test)
    x, aux = inputs(test, rng)
    m = bytearray(0x1020000)
    for pa, data in segs: m[pa:pa + len(data)] = data
    m[0x000000:0x000000 + 4 * N] = x.tobytes(); m[0x0C0000:0x0C0000 + 4 * N] = aux.tobytes()
    struct.pack_into('<II', m, 0x1afff0, N, test)
    img = O / f'img_{test}_{seed}.bin'; dump = O / f'dump_{test}_{seed}.bin'
    img.write_bytes(m)
    subprocess.run([SIM, str(img), str(dump), str(10 ** 10)], check=True, capture_output=True)
    d = dump.read_bytes()
    bad, first, n, t, csw, chw, sbad = struct.unpack_from('<7I', d, 0x1aff00)
    res = dict(test=TESTS[test], seed=seed, n=n, mismatches=bad, sw_cycles=csw, hw_cycles=chw)
    if test == 6:   # softmax2: per-chunk sums returned by the VFU (SUM register) vs software
        res['sum_mismatches'] = sbad; res['mismatches'] += sbad
    if bad:
        res['first'] = dict(index=first, input=hex(int(x[first])), sw=hex(struct.unpack_from('<I', d, 0x040000 + 4 * first)[0]),
                            hw=hex(struct.unpack_from('<I', d, 0x080000 + 4 * first)[0]))
    img.unlink(); dump.unlink()
    return res

segs = build()
jobs = [(t, s) for s in range(SEEDS) for t in TESTS]
with ThreadPoolExecutor(max_workers=min(10, len(jobs))) as ex:
    results = list(ex.map(lambda a: one(segs, *a), jobs))
(O / 'results.json').write_text(json.dumps(results, indent=1))
for r in results:
    print(r)
tot = sum(r['n'] for r in results); bad = sum(r['mismatches'] for r in results)
print(f'total {tot:,} elements, mismatches {bad}')
sys.exit(1 if bad else 0)
