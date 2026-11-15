#!/usr/bin/env python3
"""Option A: fit the degree-2 polynomial of exp2q (2^r ~ 1 + r*(c1 + c2*r), r in [0, 1/64))
by Lawson-weighted least squares (minimax of the relative error) and print the fixed-point
constants used by opta/exp2q.h: C1, C2 (Q.31) and the 64-entry table T[i] = 2^(i/64) in Q2.30."""
import numpy as np
h = 1 / 64
r = np.linspace(0, h, 20001)
f = 2.0 ** r
A = np.stack([r, r * r], 1); b = f - 1
w = np.ones_like(r) / len(r)
for _ in range(300):
    sw = np.sqrt(w) / f
    c, *_ = np.linalg.lstsq(A * sw[:, None], b * sw, rcond=None)
    e = np.abs((1 + A @ c) - f) / f
    w *= e / e.max() + 1e-15; w /= w.sum()
print(f'c1={c[0]!r} c2={c[1]!r} max rel err poly={e.max():.3e} (2^-24 = {2**-24:.3e})')
C1, C2 = round(c[0] * 2**31), round(c[1] * 2**31)
T = [round(2 ** (i / 64) * 2**30) for i in range(64)]
print(f'C1={C1} C2={C2}')
for k in range(0, 64, 8):
    print('    ' + ', '.join(f'0x{t:08x}u' for t in T[k:k + 8]) + ',')
