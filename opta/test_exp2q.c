// Exhaustive accuracy of exp2q (opta/exp2q.h) over every fp32 input bit pattern:
// error in ulp of the result vs exp2l(y) rounded to nearest fp32 (reference denormals and
// y in the flush range are counted separately), plus the constants K and -log2(e).
// usage: cc -O2 -fopenmp opta/test_exp2q.c -lm -o test_exp2q && ./test_exp2q
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "exp2q.h"

static float bf(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
static uint32_t fb(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }

int main(void) {
    printf("K: OPTA_K=%a fp32(log2e/sqrt8)=%a  NLOG2E=%a fp32(-log2e)=%a\n", (double)OPTA_K,
           (double)(float)(1.4426950408889634074L / sqrtl(8.0L)), (double)OPTA_NLOG2E,
           (double)(float)(-1.4426950408889634074L));
    long long hist[8] = {0}, flush = 0, nonfinite_bad = 0, n = 0;
    double maxulp = 0; uint32_t worst = 0;
#pragma omp parallel for reduction(+:hist[:8],flush,nonfinite_bad,n) reduction(max:maxulp) schedule(dynamic, 1 << 16)
    for (long long k = 0; k < (1LL << 32); k++) {
        uint32_t y = (uint32_t)k;
        if (((y >> 23) & 0xff) == 0xff) continue;               // inf/NaN inputs: not used
        float yf = bf(y);
        long double ref = exp2l((long double)yf);
        float got = exp2q(yf);
        if (ref < 0x1p-126L) { flush++; if (got != 0.0f && fabsf(got) > 0x1p-126f) nonfinite_bad++; continue; }
        if (ref >= 0x1p128L) { if (!isinf(got)) nonfinite_bad++; continue; }
        float rf = (float)ref;
        if (isinf(rf)) { if (!isinf(got)) nonfinite_bad++; continue; }
        long double ulp = ldexpl(1.0L, ilogbl(ref) - 23);
        double e = (double)(fabsl((long double)got - ref) / ulp);
        int b = (fb(got) == fb(rf)) ? 0 : (e <= 1.0 ? 1 : (e <= 2.0 ? 2 : 3));
        hist[b]++; n++;
        if (e > maxulp) { maxulp = e; }
    }
    // worst case search (serial, cheap second pass not needed: report max)
    printf("finite results checked: %lld\n", n);
    printf("  == correctly rounded fp32 : %lld (%.4f%%)\n", hist[0], 100.0 * hist[0] / n);
    printf("  other, err <= 1 ulp       : %lld\n", hist[1]);
    printf("  1 < err <= 2 ulp          : %lld\n", hist[2]);
    printf("  err > 2 ulp               : %lld\n", hist[3]);
    printf("  max error                 : %.4f ulp\n", maxulp);
    printf("flush range (ref < 2^-126, result 0 by definition): %lld, bad: %lld\n", flush, nonfinite_bad);
    (void)worst;
    return hist[3] != 0 || nonfinite_bad != 0;
}
