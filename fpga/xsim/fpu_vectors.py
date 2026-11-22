#!/usr/bin/env python3
"""Test vectors for the CPU FPU (cv32e40p_fp_wrapper) with IEEE-754 binary32 expected results from numpy.
usage: fpu_vectors.py <outdir>   -> vec.hex ("op a b c" per line, hex), expect.hex (one result per line)
Ops (fpnew_pkg::operation_e): ADD=2 (b+c), MUL=3 (a*b), DIV=4 (a/b), SQRT=5 (a), I2F=12 (signed int a).
Normal-range operands, RNE: numpy float32 add/mul/div/sqrt are correctly rounded, so the expected values are exact.
Includes the operations seen wrong in the chip xsim run (0x3d1d9db1^2, I2F 64)."""
import sys
from pathlib import Path
import numpy as np

out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
rng = np.random.default_rng(1)
f2u = lambda x: int(np.float32(x).view(np.uint32))
rows = []
def add(op, a=0, b=0, c=0, e=0): rows.append((op, a, b, c, e))
vals = lambda n: (rng.uniform(-8, 8, n) * 2.0 ** rng.integers(-20, 20, n)).astype(np.float32)
# known cases from the chip trace
x = np.uint32(0x3d1d9db1).view(np.float32); add(3, f2u(x), f2u(x), 0, f2u(np.float32(x) * np.float32(x)))
add(12, 64, 0, 0, f2u(np.float32(64)))
for a, b in zip(vals(300), vals(300)):
    add(3, f2u(a), f2u(b), 0, f2u(np.float32(a) * np.float32(b)))
    add(2, 0, f2u(a), f2u(b), f2u(np.float32(a) + np.float32(b)))
    add(4, f2u(a), f2u(b), 0, f2u(np.float32(a) / np.float32(b)))
    add(5, f2u(abs(a)), 0, 0, f2u(np.sqrt(np.float32(abs(a)))))
for i in rng.integers(-2**31, 2**31 - 1, 200, dtype=np.int64):
    add(12, int(i) & 0xffffffff, 0, 0, f2u(np.float32(np.int32(i))))
(out / 'vec.hex').write_text(''.join(f'{op:02x} {a:08x} {b:08x} {c:08x}\n' for op, a, b, c, _ in rows))
(out / 'expect.hex').write_text(''.join(f'{e:08x}\n' for *_, e in rows))
print(len(rows), 'vectors ->', out)
