#!/usr/bin/env python3
"""Test vectors for the CPU FPU (cv32e40p_fp_wrapper) with IEEE-754 binary32 expected results.
usage: fpu_vectors.py <outdir>   -> vec.hex ("op a b c flags" per line, hex), expect.hex (one result per line), cat.txt (one category per line)

op word = {vec_op, op_mod, op[3:0]} (fpnew_pkg::operation_e): ADD=2 (b+c; op_mod=1 -> SUB, b-c), MUL=3 (a*b), DIV=4 (a/b), SQRT=5 (a),
CMP=8 (a<b with rnd=RTZ), F2I=11 (a, signed), I2F=12 (signed int a).  flags = {int_fmt, src_fmt, dst_fmt, rnd}: 0x400 = {INT32, FP32, FP32, RNE},
0x401 = the same with RTZ (what the firmware's `fcvt.w.s ...,rtz` and `flt.s` send).

Part 1 (first 1402 vectors, unchanged since 11-22): normal-range ADD/MUL/DIV/SQRT/I2F, RNE.  numpy float32 add/mul/div/sqrt are correctly rounded.
Part 2 (V-F3): normal-range SUB, F2I (RTZ), FLT, the operations the firmware uses that part 1 did not cover.
Part 3 (V-F1, categories "edge-*"): all pairs of special operands (+-0, subnormals, min/max normal, +-Inf, quiet and signalling NaN, ...) for
ADD/SUB/MUL/DIV/FLT, and special values for SQRT/I2F/F2I.  Expected values follow the RISC-V F rules: any NaN result is the canonical NaN 0x7fc00000;
fcvt.w.s saturates and maps NaN to 0x7fffffff; flt is 0 when an operand is NaN.  Exception flags are NOT compared (V-F4 in docs/VERIFICATION_PLAN is separate: V-F2)."""
import sys
from pathlib import Path
import numpy as np

out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
rng = np.random.default_rng(1)
f2u = lambda x: int(np.float32(x).view(np.uint32))
u2f = lambda u: np.uint32(u).view(np.float32)
F_RNE, F_RTZ = 0x400, 0x401
rows = []   # (op, a, b, c, flags, expected, category)
def add(op, a=0, b=0, c=0, e=0, cat='', flags=F_RNE): rows.append((op, a, b, c, flags, e, cat))
vals = lambda n: (rng.uniform(-8, 8, n) * 2.0 ** rng.integers(-20, 20, n)).astype(np.float32)

# ---- part 1 (unchanged)
# known cases from the chip trace
x = np.uint32(0x3d1d9db1).view(np.float32); add(3, f2u(x), f2u(x), 0, f2u(np.float32(x) * np.float32(x)), 'MUL')
add(12, 64, 0, 0, f2u(np.float32(64)), 'I2F')
for a, b in zip(vals(300), vals(300)):
    add(3, f2u(a), f2u(b), 0, f2u(np.float32(a) * np.float32(b)), 'MUL')
    add(2, 0, f2u(a), f2u(b), f2u(np.float32(a) + np.float32(b)), 'ADD')
    add(4, f2u(a), f2u(b), 0, f2u(np.float32(a) / np.float32(b)), 'DIV')
    add(5, f2u(abs(a)), 0, 0, f2u(np.sqrt(np.float32(abs(a)))), 'SQRT')
for i in rng.integers(-2**31, 2**31 - 1, 200, dtype=np.int64):
    add(12, int(i) & 0xffffffff, 0, 0, f2u(np.float32(np.int32(i))), 'I2F')
n_part1 = len(rows)

# ---- helpers for parts 2 and 3
rng2 = np.random.default_rng(2)
def canon(r):
    r = np.float32(r)
    return 0x7fc00000 if np.isnan(r) else f2u(r)
def f2i_rtz(xu):
    v = float(u2f(xu))
    if v != v or v >= 2147483648.0: return 0x7fffffff
    if v <= -2147483648.0: return 0x80000000
    return int(v) & 0xffffffff          # int() truncates toward zero
def i2f(u):
    return f2u(np.float32(np.int32(((u + 2**31) % 2**32) - 2**31)))
def flt(au, bu):
    return 1 if np.float32(u2f(au)) < np.float32(u2f(bu)) else 0

# ---- part 2: normal-range SUB, F2I (RTZ), FLT
v2 = lambda n: (rng2.uniform(-8, 8, n) * 2.0 ** rng2.integers(-20, 20, n)).astype(np.float32)
for a, b in zip(v2(300), v2(300)):
    add(0x12, 0, f2u(a), f2u(b), f2u(np.float32(a) - np.float32(b)), 'SUB')
for a in (rng2.uniform(-8, 8, 300) * 2.0 ** rng2.integers(-3, 28, 300)).astype(np.float32):
    add(11, f2u(a), 0, 0, f2i_rtz(f2u(a)), 'F2I', F_RTZ)
for a, b in zip(v2(100), v2(100)):                     # random pairs
    add(8, f2u(a), f2u(b), 0, flt(f2u(a), f2u(b)), 'FLT', F_RTZ)
for a in v2(100):                                      # equal operands
    add(8, f2u(a), f2u(a), 0, 0, 'FLT', F_RTZ)
for a in v2(100):                                      # neighbouring values, both orders
    nb = np.nextafter(a, np.float32(np.inf))
    add(8, f2u(a), f2u(nb), 0, 1, 'FLT', F_RTZ)
    add(8, f2u(nb), f2u(a), 0, 0, 'FLT', F_RTZ)
n_part2 = len(rows)

# ---- part 3: special values
SP = [0x00000000, 0x80000000, 0x00000001, 0x80000001, 0x007fffff, 0x00800000, 0x3f000000, 0x3f800000, 0xbf800000, 0x40000000,
      0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000, 0x7fc00000, 0xffc00001, 0x7f800001]
with np.errstate(all='ignore'):
    for p in SP:
        for q in SP:
            a, b = u2f(p), u2f(q)
            add(2, 0, p, q, canon(a + b), 'edge-ADD')
            add(0x12, 0, p, q, canon(a - b), 'edge-SUB')
            add(3, p, q, 0, canon(a * b), 'edge-MUL')
            add(4, p, q, 0, canon(a / b), 'edge-DIV')
            add(8, p, q, 0, flt(p, q), 'edge-FLT', F_RTZ)
    for p in SP:
        add(5, p, 0, 0, canon(np.sqrt(u2f(p))), 'edge-SQRT')
for i in (0, 1, 0xffffffff, 0x7fffffff, 0x80000000, 0x01000001, 0x01000003, 0xfeffffff, 0x7fffff80, 0x7fffffc0, 0x00ffffff, 0x80000001, 0xfffffff0):
    add(12, i, 0, 0, i2f(i), 'edge-I2F')
for p in (0x00000000, 0x80000000, 0x3f000000, 0x3fc00000, 0xbfc00000, 0x3f7fffff, 0xbf7fffff, 0x4effffff, 0x4f000000, 0xcf000000, 0xcf000001,
          0x7f800000, 0xff800000, 0x7fc00000, 0x7f800001, 0x00000001, 0x80000001, 0x3f800000, 0xbf800000):
    add(11, p, 0, 0, f2i_rtz(p), 'edge-F2I', F_RTZ)

(out / 'vec.hex').write_text(''.join(f'{op:02x} {a:08x} {b:08x} {c:08x} {fl:04x}\n' for op, a, b, c, fl, _, _ in rows))
(out / 'expect.hex').write_text(''.join(f'{e:08x}\n' for *_, e, _ in rows))
(out / 'cat.txt').write_text(''.join(f'{cat}\n' for *_, cat in rows))
print(len(rows), 'vectors ->', out, f'(part 1: {n_part1}, part 2: {n_part2 - n_part1}, part 3: {len(rows) - n_part2})')
