// I1 unit test: gemv_acc mode D (int8 weights, per-row fp32 scale) vs the RISC-V software loop, bitwise.
// Host-built image (w8/run_test_w8.py): case table at 0x060000 = {n, d, pattern, seed} x ncases, ncases at 0x1afff0.
// The firmware generates each case's data itself (LCG, deterministic), computes the software reference
//   y[i] = (sum_j (float)wq[i*stride+j] * x[j]) * sc[i]
// and runs the same matmul on the accelerator (CTRL = 3, SC_ADDR), then compares the result words bitwise.
// Patterns: 0 uniform int8 incl. -128, 1 sparse (+-1), 2 extremes {-128,-127,-64,-1,0,1,64,127}, 3 half of the rows zero.
// Row scales: 1/8 zero, 1/8 negative, rest positive; x: random sign/exponent, 1/16 zero.
// The 8 words after y_hw hold a sentinel, checked for overruns.
// Results at 0x1aff00: {mismatches, first case, first row, ncases, cycles sw, cycles hw, sentinel violations, rows}
static inline unsigned cyc(void){unsigned v;__asm__ volatile("csrr %0, mcycle":"=r"(v)::"memory");return v;}

#define MAT ((signed char*)0x000000)
#define XV  ((float*)0x050000)
#define SC  ((float*)0x051000)
#define YSW ((float*)0x052000)
#define YHW ((float*)0x053000)
#define TAB ((volatile unsigned*)0x060000)

static unsigned rng_s;
static unsigned rnd(void) { rng_s = rng_s * 1664525u + 1013904223u; return rng_s >> 8; }
static float fbits(unsigned u) { union { unsigned u; float f; } c = { u }; return c.f; }

static void acc_w8(float* y, float* x, const signed char* wq, const float* sc, int n, int d, int stride) {
    volatile unsigned *r = (volatile unsigned*)0x30000000;
    r[2] = (unsigned)x; r[3] = (unsigned)wq; r[4] = (unsigned)y;
    r[5] = n; r[6] = d; r[7] = stride; r[11] = (unsigned)sc;
    r[0] = 3;
    while (r[1] & 1) ;
}
static void sw_w8(float* y, float* x, const signed char* wq, const float* sc, int n, int d, int stride) {
    for (int i = 0; i < d; i++) {
        const signed char *wr = wq + i * stride;
        float val = 0.0f;
        for (int j = 0; j < n; j++) val += (float)wr[j] * x[j];
        y[i] = val * sc[i];
    }
}

void boot(void) {
    volatile unsigned *out = (unsigned*)0x1aff00;
    unsigned ncases = ((volatile unsigned*)0x1afff0)[0];
    unsigned bad = 0, first_case = 0xffffffff, first_row = 0, sent = 0, rows = 0, csw = 0, chw = 0;
    for (unsigned c = 0; c < ncases; c++) {
        int n = TAB[4 * c], d = TAB[4 * c + 1], pat = TAB[4 * c + 2];
        rng_s = TAB[4 * c + 3];
        int stride = (n + 15) / 16 * 16;
        for (int i = 0; i < d; i++) {
            int zero_row = (pat == 3 && (i & 1));
            for (int j = 0; j < stride; j++) {
                signed char v = 0;
                if (j < n && !zero_row) {
                    unsigned r = rnd();
                    if (pat == 0) v = (signed char)(r & 0xff);
                    else if (pat == 1) v = (r % 10 == 0) ? ((r & 0x100) ? 1 : -1) : 0;
                    else if (pat == 2) { static const signed char e[8] = {-128, -127, -64, -1, 0, 1, 64, 127}; v = e[r & 7]; }
                    else v = (signed char)(r & 0xff);
                }
                MAT[i * stride + j] = v;   // pad bytes (j >= n) stay 0
            }
            unsigned r = rnd();
            unsigned kind = r & 7;
            unsigned mant = rnd() & 0x7fffff, ex = 110 + (rnd() % 30);
            SC[i] = (kind == 0) ? 0.0f : fbits(((kind == 1) ? 0x80000000u : 0u) | (ex << 23) | mant);
        }
        for (int j = 0; j < n; j++) {
            unsigned r = rnd();
            unsigned mant = rnd() & 0x7fffff, ex = 110 + (rnd() % 30);
            XV[j] = ((r & 15) == 0) ? 0.0f : fbits(((r & 0x10) ? 0x80000000u : 0u) | (ex << 23) | mant);
        }
        for (int k = 0; k < 8; k++) ((volatile unsigned*)YHW)[d + k] = 0xDEADBEEFu;
        unsigned t0 = cyc();
        sw_w8(YSW, XV, MAT, SC, n, d, stride);
        unsigned t1 = cyc();
        acc_w8(YHW, XV, MAT, SC, n, d, stride);
        unsigned t2 = cyc();
        csw += t1 - t0; chw += t2 - t1; rows += d;
        for (int i = 0; i < d; i++) {
            if (((volatile unsigned*)YHW)[i] != ((volatile unsigned*)YSW)[i]) {
                if (first_case == 0xffffffff) { first_case = c; first_row = i; }
                bad++;
            }
        }
        for (int k = 0; k < 8; k++) if (((volatile unsigned*)YHW)[d + k] != 0xDEADBEEFu) sent++;
    }
    out[0] = bad; out[1] = first_case; out[2] = first_row; out[3] = ncases;
    out[4] = csw; out[5] = chw; out[6] = sent; out[7] = rows;
    out[8] = 0x600D600Du;   // finished marker
    volatile unsigned *done = (unsigned*)0x20000000;
    *done = 1;
    for (;;) ;
}
