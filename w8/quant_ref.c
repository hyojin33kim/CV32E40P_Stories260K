// Cross-check for w8/quantize.py: the same per-row quantization as the W8 host model (w8/make_run_w8.py),
// applied to every weight matrix of the checkpoint; writes wq (int8) then the fp32 scales per matrix, in
// the order and layout of `w8/quantize.py dump`.
// build: cc -O2 -ffp-contract=off w8/quant_ref.c -lm -o quant_ref ; usage: quant_ref stories260K.bin out.bin
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void quant(const float *w, int n, int d, FILE *fq, float *s_out) {
    for (int i = 0; i < d; i++) {
        const float *wr = w + (size_t)i * n;
        float m = 0.0f;
        for (int j = 0; j < n; j++) { float a = fabsf(wr[j]); if (a > m) m = a; }
        float s = m / 127.0f;
        for (int j = 0; j < n; j++) {
            float q = 0.0f;
            if (s != 0.0f) { q = rintf(wr[j] / s); if (q > 127.0f) q = 127.0f; if (q < -127.0f) q = -127.0f; }
            signed char c = (signed char)q; fwrite(&c, 1, 1, fq);
        }
        s_out[i] = s;
    }
}
int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "rb"); fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    char *b = malloc(sz); fread(b, 1, sz, f); fclose(f);
    const float *fp = (const float *)(b + 28);
    FILE *o = fopen(argv[2], "wb");
    // name, word offset in the checkpoint float array, layers, d, n  (checkpoint order, see quantize.py)
    struct { long off; int lay, d, n; } M[8] = {
        {32768 + 320, 5, 64, 64}, {32768 + 320 + 20480, 5, 32, 64}, {32768 + 320 + 30720, 5, 32, 64},
        {32768 + 320 + 40960, 5, 64, 64}, {32768 + 320 + 61440 + 320, 5, 172, 64},
        {32768 + 320 + 61440 + 320 + 55040, 5, 64, 172}, {32768 + 320 + 61440 + 320 + 110080, 5, 172, 64},
        {0, 1, 512, 64}};
    for (int k = 0; k < 8; k++) {
        float *sc = malloc(sizeof(float) * M[k].lay * M[k].d);
        for (int l = 0; l < M[k].lay; l++)
            quant(fp + M[k].off + (size_t)l * M[k].d * M[k].n, M[k].n, M[k].d, o, sc + (size_t)l * M[k].d);
        fwrite(sc, 4, (size_t)M[k].lay * M[k].d, o);
        free(sc);
    }
    fclose(o);
    return 0;
}
