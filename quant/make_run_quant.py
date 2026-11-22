#!/usr/bin/env python3
"""Precision gate (P1): generate quant/run_quant.c = llama2.c run.c with fake quantization.
Everything stays fp32 arithmetic on dequantized values, so this measures the accuracy of the
quantized *numbers* (integer MAC accumulation is exact, so a real int lane differs only by the
order of the per-group scale multiply, which is far below the quantization error).

Runtime switches (environment variables, read once):
  QW=<bits>   weight bits for every matmul weight incl. wcls (0 = fp32), symmetric, per (row, group)
  QA=<bits>   activation bits for the matmul input vector (0 = off), symmetric, per group
  QKV=<bits>  KV cache bits (0 = off), symmetric, per head vector (head_size values)
  QG=<n>      group size along the input dimension (default 32)
Not quantized: embedding lookup, rmsnorm weights, RoPE, softmax, SiLU, attention math (fp32).
Every replaced snippet must occur exactly once in run.c."""
from pathlib import Path

W = Path(__file__).resolve().parent.parent
t = (W / 'run.c').read_text()

HELP = r'''
#include <stdlib.h>
static int Q_W = -1, Q_A, Q_KV, Q_G;
static void q_init(void) {
    if (Q_W >= 0) return;
    const char *e;
    Q_W = (e = getenv("QW")) ? atoi(e) : 0; Q_A = (e = getenv("QA")) ? atoi(e) : 0;
    Q_KV = (e = getenv("QKV")) ? atoi(e) : 0; Q_G = (e = getenv("QG")) ? atoi(e) : 32;
}
// symmetric round-to-nearest fake quantization of n values sharing one scale
static void q_group(float *dst, const float *src, int n, int bits) {
    float qmax = (float)((1 << (bits - 1)) - 1), m = 0.0f;
    for (int i = 0; i < n; i++) { float a = fabsf(src[i]); if (a > m) m = a; }
    if (m == 0.0f) { for (int i = 0; i < n; i++) dst[i] = 0.0f; return; }
    float s = m / qmax;
    for (int i = 0; i < n; i++) {
        float q = roundf(src[i] / s);
        if (q > qmax) q = qmax; if (q < -qmax) q = -qmax;
        dst[i] = q * s;
    }
}
static void q_vec(float *dst, const float *src, int n, int bits, int g) {
    for (int j = 0; j < n; j += g) q_group(dst + j, src + j, (n - j < g) ? n - j : g, bits);
}
'''

REPL = [
    ('#include <math.h>\n', '#include <math.h>\n' + HELP),
    ('''void matmul(float* xout, float* x, float* w, int n, int d) {
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
''', '''void matmul(float* xout, float* x, float* w, int n, int d) {
    // W (d,n) @ x (n,) -> xout (d,)   [quant: fake-quantized weights/activations]
    q_init();
    float xq[2048], wq[2048];
    if (Q_A) q_vec(xq, x, n, Q_A, Q_G); else memcpy(xq, x, n * sizeof(float));
    for (int i = 0; i < d; i++) {
        const float *wr = w + (size_t)i * n;
        if (Q_W) { q_vec(wq, wr, n, Q_W, Q_G); wr = wq; }
        float val = 0.0f;
        for (int j = 0; j < n; j++) val += wr[j] * xq[j];
        xout[i] = val;
    }
}
'''),
    ('''        // multihead attention. iterate over all heads
''', '''        if (Q_KV) {   // quantize the new K and V rows (per head vector) as they enter the cache
            for (int hh = 0; hh < kv_dim; hh += head_size) {
                q_group(s->k + hh, s->k + hh, head_size, Q_KV);
                q_group(s->v + hh, s->v + hh, head_size, Q_KV);
            }
        }
        // multihead attention. iterate over all heads
'''),
]
for old, new in REPL:
    assert t.count(old) == 1, old[:60]
    t = t.replace(old, new)
(W / 'quant' / 'run_quant.c').write_text(t)
print('quant/run_quant.c written')
