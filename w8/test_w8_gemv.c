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

// default layout (n, d <= 512) or -DBIGLAYOUT (n <= 1024, n*d <= 1 MiB: 15M-class shapes, needs ACC_XBUF/ACC_YBUF 1024)
#ifdef BIGLAYOUT
#define MAT ((signed char*)0x000000)
#define XV  ((float*)0x100000)
#define SC  ((float*)0x101000)
#define YSW ((float*)0x102000)
#define YHW ((float*)0x104000)
#define TAB ((volatile unsigned*)0x110000)
#define TMAT ((signed char*)0x200000)
#else
#define MAT ((signed char*)0x000000)
#define XV  ((float*)0x050000)
#define SC  ((float*)0x051000)
#define YSW ((float*)0x052000)
#define YHW ((float*)0x053000)
#define TAB ((volatile unsigned*)0x060000)
#define TMAT ((signed char*)0x080000)
#endif
#ifndef TLL
#define TLL 16   // rows per group of the engine (LANES * FPU latency)
#endif
#ifndef TRUN
#define TRUN 8   // lines per run (ACC_RUN)
#endif

static unsigned rng_s;
static unsigned rnd(void) { rng_s = rng_s * 1664525u + 1013904223u; return rng_s >> 8; }
static float fbits(unsigned u) { union { unsigned u; float f; } c = { u }; return c.f; }

// pre-tiled copy: lines of 16 B in the engine's issue order (group of TLL rows, run of TRUN lines, row, line in run), see w8/pretile.py
static void tile_c(signed char* dst, const signed char* src, int n, int d, int stride) {
    int nch = (n + 15) / 16, idx = 0;
    for (int i0 = 0; i0 < d; i0 += TLL) {
        int na = d - i0 < TLL ? d - i0 : TLL;
        for (int kb = 0; kb < nch; kb += TRUN)
            for (int q = 0; q < na; q++)
                for (int k = kb; k < kb + TRUN && k < nch; k++, idx++)
                    for (int b = 0; b < 16; b++) dst[16 * idx + b] = src[(i0 + q) * stride + 16 * k + b];
    }
}
static void acc_w8t(float* y, float* x, const signed char* wq, const float* sc, int n, int d, int stride) {
    volatile unsigned *r = (volatile unsigned*)0x30000000;
    r[2] = (unsigned)x; r[3] = (unsigned)wq; r[4] = (unsigned)y;
    r[5] = n; r[6] = d; r[7] = stride; r[11] = (unsigned)sc;
    r[0] = 7;   // start | int8 | tiled
    while (r[1] & 1) ;
}
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
    unsigned bad = 0, first_case = 0xffffffff, first_row = 0, sent = 0, rows = 0, csw = 0, chw = 0, badt = 0, cht = 0;
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
        // pre-tiled run: same data, repacked in issue order, must give the same words
        tile_c(TMAT, MAT, n, d, stride);
        for (int k = 0; k < d + 8; k++) ((volatile unsigned*)YHW)[k] = 0xDEADBEEFu;
        unsigned t3 = cyc();
        acc_w8t(YHW, XV, TMAT, SC, n, d, stride);
        cht += cyc() - t3;
        for (int i = 0; i < d; i++) if (((volatile unsigned*)YHW)[i] != ((volatile unsigned*)YSW)[i]) badt++;
        for (int k = 0; k < 8; k++) if (((volatile unsigned*)YHW)[d + k] != 0xDEADBEEFu) sent++;
    }
    out[0] = bad; out[1] = first_case; out[2] = first_row; out[3] = ncases;
    out[4] = csw; out[5] = chw; out[6] = sent; out[7] = rows;
    out[9] = badt; out[10] = cht;
    out[8] = 0x600D600Du;   // finished marker
    volatile unsigned *done = (unsigned*)0x20000000;
    *done = 1;
    for (;;) ;
}
