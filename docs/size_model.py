#!/usr/bin/env python3
"""Sizes and first-order throughput of a llama2.c-style model on this tile (used by docs/15M_ADDRESS_MAP.md).
usage: docs/size_model.py [dim hidden layers heads kv_heads vocab seq]   (default: Stories15M, UNCONFIRMED: no model file here)
Everything printed is arithmetic on the config, not a measurement. Throughput lines are rough bounds
(1 MAC/cycle/lane, a fixed DDR share) and ignore CPU work, attention and command overhead."""
import sys

cfg = [288, 768, 6, 6, 6, 32000, 256]
if len(sys.argv) == 8: cfg = [int(x) for x in sys.argv[1:]]
dim, hid, L, H, KVH, V, S = cfg
hs = dim // H; kvd = dim * KVH // H
mats = {'wq': (dim, dim), 'wk': (kvd, dim), 'wv': (kvd, dim), 'wo': (dim, dim), 'w1': (hid, dim), 'w2': (dim, hid), 'w3': (hid, dim)}
MiB = 1 << 20
def stride(n): return (n + 15) // 16 * 16
per_layer = sum(d * n for d, n in mats.values())
params = L * per_layer + V * dim
rows = L * sum(d for d, n in mats.values()) + V
w8_mat = L * sum(d * stride(n) for d, n in mats.values()) + V * stride(dim)
w8_sc = rows * 4
rms = (2 * L + 1) * dim * 4
emb32 = V * dim * 4
kv32 = 2 * L * S * kvd * 4
kv8 = 2 * L * S * kvd + 2 * L * S * KVH * 4          # int8 values + one fp32 scale per head vector
act = (dim * 6 + hid * 2 + H * S + V) * 4              # x, xb, xb2, q, k, v, hb, hb2, att, logits
print(f'config dim={dim} hidden={hid} layers={L} heads={H} kv_heads={KVH} vocab={V} seq={S} head_size={hs} kv_dim={kvd}')
print(f'parameters {params:,} ({params / 1e6:.2f} M); per layer {per_layer:,}')
print(f'fp32 weights (incl. embedding table shared with the classifier) {params * 4 / MiB:.2f} MiB + rms {rms / 1024:.1f} KiB')
print(f'int8 matrices incl. classifier (rows padded to 16 B) {w8_mat / MiB:.2f} MiB; row scales {rows:,} x 4 B = {w8_sc / 1024:.1f} KiB')
print(f'  + fp32 embedding table kept for the lookup {emb32 / MiB:.2f} MiB  -> int8 design total {(w8_mat + w8_sc + rms + emb32) / MiB:.2f} MiB')
print(f'  lookup from the int8 table instead (x = wq * s): total {(w8_mat + w8_sc + rms) / MiB:.2f} MiB')
print(f'KV cache fp32 {kv32 / MiB:.3f} MiB; int8 (+ per-head scales) {kv8 / MiB:.3f} MiB')
print(f'activations / logits buffers (fp32) {act / 1024:.1f} KiB (logits alone {V * 4 / 1024:.0f} KiB)')
print(f'URAM data capacity of XCZU7EV: 96 x 32 KiB = {96 * 32 / 1024:.2f} MiB (72-bit words, 64 data bits used)')
print(f'GEMV buffers: x needs >= {max(dim, hid)} words, y per call <= YBUF rows -> classifier in {-(-V // 1024)} calls of 1024 rows')
print('row length in 16 B lines: ' + ', '.join(f'n={n}: int8 {-(-n // 16)}, fp32 {-(-n // 4)}' for n in sorted({dim, hid})))
macs = params
for lanes in (4, 8, 16):
    comp = macs / lanes
    for name, byt in (('fp32', params * 4), ('int8', w8_mat)):
        for share in (12.8,):
            mem = byt / share
            cyc = max(comp, mem)
            print(f'{lanes:>2} lanes, {name}: compute {comp / 1e6:.2f} M cycles, memory {mem / 1e6:.2f} M cycles (at {share} B/cycle) '
                  f'-> {max(comp, mem) / 1e6:.2f} M cycles/token = {125e6 / cyc:.0f} tok/s at 125 MHz ({"memory" if mem > comp else "compute"} bound)')
