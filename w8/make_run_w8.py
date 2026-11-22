#!/usr/bin/env python3
"""I1 (int8 weights, per-row scale, fp32 activations and MAC): generate the W8 host model.
usage: w8/make_run_w8.py <src run.c | opta/run_opta.c> <dst>

Numeric definition of matmul under W8 (the reference for the RISC-V firmware and the GEMV engine):
  for each output row i of W (d rows, n columns):
      m = max_j |W[i][j]|                      (fp32)
      s = m / 127.0f                          (fp32 division; s = 0 if m = 0)
      wq[j] = clamp(rintf(W[i][j] / s), -127, 127)   (round to nearest even; 0 if s = 0)
      acc = 0.0f; for j in order: acc = acc + (float)wq[j] * x[j]     (one fmul then one fadd, no FMA)
      y[i] = acc * s                          (one fmul)
(float)wq is exact, so the integer weights and the per-row fp32 scales are plain data: the offline
quantizer (w8/quantize.py, numpy float32) must produce the same wq and s as this function; the
check is w8/check_quant.sh. Only matmul() changes (weight matmuls incl. the classifier); attention
QK/AV, the KV cache, rmsnorm, RoPE, softmax and SiLU stay fp32 and untouched; the embedding lookup
reads the fp32 table. Every replaced snippet must occur exactly once in the source."""
import sys
from pathlib import Path

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
t = src.read_text()
OLD = '''void matmul(float* xout, float* x, float* w, int n, int d) {
    // W (d,n) @ x (n,) -> xout (d,)
    // by far the most amount of time is spent inside this little function
    int i;
    #pragma omp parallel for private(i)
    for (i = 0; i < d; i++) {
        float val = 0.0f;
        for (int j = 0; j < n; j++) {
            val += w[i * n + j] * x[j];
        }
        xout[i] = val;
    }
}
'''
NEW = '''void matmul(float* xout, float* x, float* w, int n, int d) {
    // W (d,n) @ x (n,) -> xout (d,)   [W8: int8 weights, one scale per row, see w8/make_run_w8.py]
    for (int i = 0; i < d; i++) {
        const float *wr = w + (size_t)i * n;
        float m = 0.0f;
        for (int j = 0; j < n; j++) { float a = fabsf(wr[j]); if (a > m) m = a; }
        float s = m / 127.0f;
        float val = 0.0f;
        for (int j = 0; j < n; j++) {
            float q = 0.0f;
            if (s != 0.0f) { q = rintf(wr[j] / s); if (q > 127.0f) q = 127.0f; if (q < -127.0f) q = -127.0f; }
            val += q * x[j];
        }
        xout[i] = val * s;
    }
}
'''
assert t.count(OLD) == 1
dst.write_text(t.replace(OLD, NEW))
print(f'{dst} written')
