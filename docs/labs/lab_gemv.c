// Lab 5: the same matrix times vector on the CPU (software loop) and on the GEMV accelerator, compared bit by bit.
// This is the C code that the project's firmware (gen/firmware_gen.c, acc_gemv) uses to call the hardware: write 7 MMIO registers, start, poll busy.
// Results at 0x1aff00: [0] words that differ (expected 0), [1] STATUS err bit after the run (expected 0), [2] y_hw[0] bits, [3] y_sw[0] bits, [4] 0x600d600d when finished.
// With --ctrl 513 the program asks the accelerator for N = 513 (> XBUF 512): the start is refused, STATUS bit1 (err) is set and y_hw stays unwritten.
#define N 8
#define D 4
#define OUT ((volatile unsigned*)0x20000010)
#define RES ((volatile unsigned*)0x1aff00)
#define G   ((volatile unsigned*)0x30000000)      // gemv_acc registers (acc/gemv_acc.sv)
static float *W  = (float*)0x050000;              // D rows of N floats, 16-byte aligned
static float *X  = (float*)0x051000;
static float *YH = (float*)0x052000;
static float *YS = (float*)0x053000;
void boot(void) {
    unsigned ctrl = *(volatile unsigned*)0x1afff0;
    unsigned n = ctrl ? ctrl : N;                   // --ctrl 513 demonstrates the refusal
    for (int i = 0; i < D; i++) for (int j = 0; j < N; j++) W[i * N + j] = 0.5f * (i + 1) + 0.25f * j;
    for (int j = 0; j < N; j++) X[j] = 1.0f / (float)(j + 1);
    for (int i = 0; i < D; i++) { float s = 0.0f; for (int j = 0; j < N; j++) s += W[i * N + j] * X[j]; YS[i] = s; YH[i] = 0.0f; }
    G[2] = (unsigned)X; G[3] = (unsigned)W; G[4] = (unsigned)YH;
    G[5] = n; G[6] = D; G[7] = N * 4; G[9] = 4;      // N, D, row stride in bytes, element stride in bytes
    G[0] = 1;                                         // start
    while (G[1] & 1) ;                                // poll busy (STATUS bit0)
    unsigned bad = 0;
    for (int i = 0; i < D; i++) { union { float f; unsigned u; } a = { YH[i] }, b = { YS[i] }; bad += a.u != b.u; }
    RES[0] = bad; RES[1] = (G[1] >> 1) & 1;
    { union { float f; unsigned u; } a = { YH[0] }, b = { YS[0] }; RES[2] = a.u; RES[3] = b.u; }
    RES[4] = 0x600d600d;
    *OUT = bad;
    *(volatile unsigned*)0x20000000 = 1;
    for (;;) ;
}
