// Step ④-b unit test on the SoC RTL: VFU results vs the RISC-V software, bitwise.
// Host-built image (vfu/run_test.py) places at 0x000000 the input vector IN[N] and
// at 0x0C0000 the auxiliary vector AUX[N] (silu gate / softmax lengths), control at
// 0x1afff0 = {N, test}. Tests (all on the same IN):
//   1 exp     : expf(IN[i])                      HW cmd EXP on 512-element chunks
//   2 softmax : softmax over chunks IN[j..j+len) (len from AUX, 1..512, as llama2.c)
//   3 silu    : (v*(1/(1+expf(-v))))*g          HW cmd SILU, g = AUX
//   4 divs    : IN[i] / 0x1.6a09e6p+1f            HW cmd DIVS
//   5 divsoftmax: chunks (len from AUX): IN[i] /= 0x1.6a09e6p+1f, then softmax
// Results: 0x1aff00 = {mismatches, first mismatch index, N, test, cycles sw, cycles hw}
#include <math.h>
#include <string.h>
static inline unsigned cyc(void){unsigned v;__asm__ volatile("csrr %0, mcycle":"=r"(v)::"memory");return v;}

#define IN  ((float*)0x000000)
#define AUX ((float*)0x0C0000)
#define SW  ((float*)0x040000)
#define HW  ((float*)0x080000)

static void vfu(unsigned cmd, float* a, float* b, unsigned n, float s) {
    volatile unsigned *r = (volatile unsigned*)0x30000040;
    union { float f; unsigned u; } c = { s };
    r[2] = (unsigned)a; r[3] = (unsigned)b; r[4] = n; r[5] = c.u;
    r[0] = cmd;
    while (r[1] & 1) ;
}

// software reference: same code as gen/firmware_gen.c (softmax) and the SwiGLU loop
static void softmax(float* x, int size) {
    float max_val = x[0];
    for (int i = 1; i < size; i++) if (x[i] > max_val) max_val = x[i];
    float sum = 0.0f;
    for (int i = 0; i < size; i++) { x[i] = expf(x[i] - max_val); sum += x[i]; }
    for (int i = 0; i < size; i++) x[i] /= sum;
}

void boot(void) {
    volatile unsigned *ctrl = (unsigned*)0x1afff0, *out = (unsigned*)0x1aff00;
    unsigned n = ctrl[0], test = ctrl[1];
    unsigned c0 = cyc();
    // software
    memcpy(SW, IN, n * 4);
    if (test == 1) for (unsigned i = 0; i < n; i++) SW[i] = expf(SW[i]);
    if (test == 2) for (unsigned j = 0; j < n;) {
        unsigned len = ((unsigned*)AUX)[j]; if (len > n - j) len = n - j;
        softmax(SW + j, len); j += len;
    }
    if (test == 3) for (unsigned i = 0; i < n; i++) {
        float val = SW[i];
        val *= (1.0f / (1.0f + expf(-val)));
        val *= AUX[i];
        SW[i] = val;
    }
    if (test == 4) for (unsigned i = 0; i < n; i++) SW[i] /= 0x1.6a09e6p+1f;
    if (test == 5) for (unsigned j = 0; j < n;) {
        unsigned len = ((unsigned*)AUX)[j]; if (len > n - j) len = n - j;
        for (unsigned i = 0; i < len; i++) SW[j + i] /= 0x1.6a09e6p+1f;
        softmax(SW + j, len); j += len;
    }
    unsigned c1 = cyc();
    // hardware
    memcpy(HW, IN, n * 4);
    if (test == 2 || test == 5) for (unsigned j = 0; j < n;) {
        unsigned len = ((unsigned*)AUX)[j]; if (len > n - j) len = n - j;
        if (test == 2) vfu(1, HW + j, 0, len, 0);
        else vfu(5, HW + j, 0, len, 0x1.6a09e6p+1f);
        j += len;
    } else for (unsigned j = 0; j < n; j += 512) {
        unsigned len = n - j < 512 ? n - j : 512;
        if (test == 1) vfu(4, HW + j, 0, len, 0);
        if (test == 3) vfu(2, HW + j, AUX + j, len, 0);
        if (test == 4) vfu(3, HW + j, 0, len, 0x1.6a09e6p+1f);
    }
    unsigned c2 = cyc();
    unsigned bad = 0, first = 0xffffffff;
    for (unsigned i = 0; i < n; i++)
        if (((unsigned*)SW)[i] != ((unsigned*)HW)[i]) { if (!bad) first = i; bad++; }
    out[0] = bad; out[1] = first; out[2] = n; out[3] = test; out[4] = c1 - c0; out[5] = c2 - c1;
    *(volatile unsigned*)0x20000000 = 1; for (;;);
}
