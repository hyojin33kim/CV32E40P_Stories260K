// Option A (S3) attention softmax without normalization, shared by the host model
// (opta/run_opta.c) and the firmware (gen/firmware_gen.c -DOPTA); the VFU command 6 must be
// bit-exact with it.
//   x[t] = raw score q.k (no /sqrt(head_size): folded into OPTA_K = log2(e)/sqrt(8))
//   m = max x[t];  p[t] = exp2q((x[t] - m) * OPTA_K)  (fp32 sub, fp32 mul, exp2q)
//   sum = (S0 + S1) + (S2 + S3),  S_k = +0.0 + p[k] + p[k+4] + ...   (t order within S_k)
// Returns sum; x[] keeps the unnormalized p. The caller divides the 8 AV outputs by sum
// (deferred normalization) instead of dividing every p.
#ifndef SOFTMAX2_H
#define SOFTMAX2_H
#include "exp2q.h"
static float softmax2(float* x, int size) {
    float max_val = x[0];
    for (int i = 1; i < size; i++)
        if (x[i] > max_val) max_val = x[i];
    float s[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    for (int i = 0; i < size; i++) {
        float p = exp2q((x[i] - max_val) * OPTA_K);
        x[i] = p;
        s[i & 3] += p;
    }
    return (s[0] + s[1]) + (s[2] + s[3]);
}
#endif
