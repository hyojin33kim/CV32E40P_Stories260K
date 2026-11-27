// V-A3: CPU, GEMV (gemv_acc) and VFU (vfu) active at the same time on the SoC RTL sim. One scenario per run (ctrl word 0x1afff0):
//   1 CPU computes in its own memory while GEMV (int8 mode D) runs         -> GEMV result and CPU result must equal the sequential ones
//   2 CPU computes in its own memory while the VFU runs a softmax           -> same
//   3 VFU is started while GEMV is busy (GEMV and VFU share one memory port; ownership = vfu_busy)   -> the VFU start is refused (VFU STATUS bit1 err),
//     the GEMV finishes with the right result, the VFU data is untouched (before 11-27 the GEMV hung and both results were wrong, E10)
//   4 GEMV is started while the VFU is busy                                  -> serialized by the shared port, characterized
//   5 GEMV start with N = XBUF + 1 (513): refused (GEMV STATUS bit1 err), then a valid start is accepted (err cleared) and the result is right
//   6 VFU start with n = BUF + 1 (513): refused (VFU STATUS bit1 err), then a valid start is accepted (err cleared) and the result is right
// The firmware normally polls busy before starting the next accelerator command; scenarios 3 and 4 break that rule on purpose.
// Before every scenario the firmware measures the durations of a blocking GEMV, VFU softmax and CPU work run (calibration), so that the
// second command of scenarios 3 and 4 starts a third of the way into the first one, and it records whether the first was really busy then.
// Only the accelerators that ran in the scenario are compared with their software reference.
// Results at 0x1aff00 (words), 11 err bits at the end (bit0 gemv, bit1 vfu), 12 err after the refused start (scenarios 5, 6), 13 err after the following valid start,
//   14 words of the VFU data that differ from its input (scenario 3, must be 0): 0 scenario, 1 gemv mismatching words (of 128), 2 vfu (of 512), 3 cpu (of 256), 4 timeouts (bit0 gemv, bit1 vfu),
//   5 overlap evidence (scenarios 1, 2: CPU passes that ended while the accelerator was busy; 3, 4: first accelerator busy when the second
//   was started), 6 cycles of the scenario, 7 gemv, 8 vfu, 9 cpu work calibration cycles, 10 finished marker 0x600d600d.
#include <string.h>
#include <math.h>
static inline unsigned cyc(void) { unsigned v; __asm__ volatile("csrr %0, mcycle" : "=r"(v) :: "memory"); return v; }
#define G ((volatile unsigned*)0x30000000)
#define V ((volatile unsigned*)0x30000040)
#define MAT  ((signed char*)0x000000)
#define XV   ((float*)0x050000)
#define SC   ((float*)0x051000)
#define YSW  ((float*)0x052000)
#define YHW  ((float*)0x053000)
#define VHW  ((float*)0x060000)
#define VSW  ((float*)0x061000)
#define VIN0 ((float*)0x062000)
#define CPUA ((unsigned*)0x070000)
#define CPUB ((unsigned*)0x071000)
#define CPUC ((unsigned*)0x072000)
#define GN 256
#define GD 128
#define VN 512
#define PASSES 6
#define POLL_LIMIT 400000

static unsigned seed = 12345u;
static unsigned rnd(void) { seed = seed * 1664525u + 1013904223u; return seed; }
static float rf(void) { return (float)((int)(rnd() >> 8) - 8388608) / 8388608.0f; }   // [-1, 1)

static void sw_w8(float* y, const float* x, const signed char* wq, const float* sc, int n, int d, int stride) {
    for (int i = 0; i < d; i++) {
        const signed char *wr = wq + i * stride;
        float val = 0.0f;
        for (int j = 0; j < n; j++) val += (float)wr[j] * x[j];
        y[i] = val * sc[i];
    }
}
static void softmax(float* x, int size) {
    float max_val = x[0];
    for (int i = 1; i < size; i++) if (x[i] > max_val) max_val = x[i];
    float sum = 0.0f;
    for (int i = 0; i < size; i++) { x[i] = expf(x[i] - max_val); sum += x[i]; }
    for (int i = 0; i < size; i++) x[i] /= sum;
}
// CPU work in its own memory: reads and writes 256 words per pass; returns the number of passes that ended while *busy_reg was busy
static unsigned work(unsigned* a, int passes, volatile unsigned* busy_reg) {
    unsigned overlapped = 0;
    for (int p = 0; p < passes; p++) {
        for (int i = 0; i < 256; i++) a[i] = a[i] * 3u + a[(i + 1) & 255] + (unsigned)p;
        if (busy_reg && (busy_reg[1] & 1)) overlapped++;
    }
    return overlapped;
}
static void gemv_start(void) {
    G[2] = (unsigned)XV; G[3] = (unsigned)MAT; G[4] = (unsigned)YHW; G[5] = GN; G[6] = GD; G[7] = GN; G[11] = (unsigned)SC;
    G[0] = 3;   // start | int8
}
static void vfu_start(void) {
    V[2] = (unsigned)VHW; V[3] = 0; V[4] = VN; V[5] = 0;
    V[0] = 1;   // softmax
}
static unsigned wait_busy(volatile unsigned* r) {   // returns 1 on timeout
    for (unsigned k = 0; k < POLL_LIMIT; k++) if (!(r[1] & 1)) return 0;
    return 1;
}
static unsigned diff(const unsigned* a, const unsigned* b, int n) { unsigned c = 0; for (int i = 0; i < n; i++) c += a[i] != b[i]; return c; }
static void delay_to(unsigned cycles) { unsigned t = cyc(); while (cyc() - t < cycles) ; }

void boot(void) {
    volatile unsigned *ctrl = (unsigned*)0x1afff0, *out = (unsigned*)0x1aff00;
    unsigned sc = ctrl[0], to = 0, evid = 0, c0, c1, gc, vc, wc;
    for (int i = 0; i < GN * GD; i++) MAT[i] = (signed char)(rnd() >> 24);
    for (int j = 0; j < GN; j++) XV[j] = rf();
    for (int i = 0; i < GD; i++) SC[i] = rf() * 0.01f;
    for (int i = 0; i < VN; i++) VIN0[i] = rf() * 6.0f;
    for (int i = 0; i < 256; i++) CPUA[i] = CPUB[i] = CPUC[i] = rnd();
    // references: sequential and without any accelerator
    sw_w8(YSW, XV, MAT, SC, GN, GD, GN);
    memcpy(VSW, VIN0, VN * 4); softmax(VSW, VN);
    work(CPUB, PASSES, 0);
    // calibration: blocking runs
    c0 = cyc(); gemv_start(); wait_busy(G); gc = cyc() - c0;
    memcpy(VHW, VIN0, VN * 4);
    c0 = cyc(); vfu_start(); wait_busy(V); vc = cyc() - c0;
    c0 = cyc(); work(CPUC, PASSES, 0); wc = cyc() - c0;
    for (int i = 0; i < GD; i++) YHW[i] = 0.0f;
    memcpy(VHW, VIN0, VN * 4);
    unsigned ran_g = sc != 2 && sc != 6, ran_v = sc != 1 && sc != 3 && sc != 5, e1 = 0, e2 = 0;
    c0 = cyc();
    if (sc == 1) { gemv_start(); evid = work(CPUA, PASSES, G); to |= wait_busy(G); }
    else if (sc == 2) { vfu_start(); evid = work(CPUA, PASSES, V); to |= wait_busy(V) << 1; }
    else if (sc == 3) { gemv_start(); delay_to(gc / 3); evid = G[1] & 1; vfu_start(); to |= wait_busy(G); to |= wait_busy(V) << 1; work(CPUA, PASSES, 0); }
    else if (sc == 4) { vfu_start(); delay_to(vc / 3); evid = V[1] & 1; gemv_start(); to |= wait_busy(V) << 1; to |= wait_busy(G); work(CPUA, PASSES, 0); }
    else if (sc == 5) { G[2] = (unsigned)XV; G[3] = (unsigned)MAT; G[4] = (unsigned)YHW; G[5] = 513; G[6] = GD; G[7] = GN; G[11] = (unsigned)SC; G[0] = 3;
                        e1 = (G[1] >> 1) & 1; to |= wait_busy(G); gemv_start(); to |= wait_busy(G); e2 = (G[1] >> 1) & 1; evid = 1; work(CPUA, PASSES, 0); }
    else if (sc == 6) { V[2] = (unsigned)VHW; V[3] = 0; V[4] = 513; V[5] = 0; V[0] = 1;
                        e1 = (V[1] >> 1) & 1; to |= wait_busy(V) << 1; vfu_start(); to |= wait_busy(V) << 1; e2 = (V[1] >> 1) & 1; evid = 1; work(CPUA, PASSES, 0); }
    c1 = cyc();
    unsigned errs = ((G[1] >> 1) & 1) | (((V[1] >> 1) & 1) << 1);
    out[0] = sc;
    out[1] = ran_g ? diff((const unsigned*)YHW, (const unsigned*)YSW, GD) : 0;
    out[2] = ran_v ? diff((const unsigned*)VHW, (const unsigned*)VSW, VN) : 0;
    out[3] = diff(CPUA, CPUB, 256);
    out[4] = to; out[5] = evid; out[6] = c1 - c0; out[7] = gc; out[8] = vc; out[9] = wc;
    out[10] = 0x600d600d;
    out[11] = errs; out[12] = e1; out[13] = e2; out[14] = (sc == 3) ? diff((const unsigned*)VHW, (const unsigned*)VIN0, VN) : 0;
    *(volatile unsigned*)0x20000000 = 1; for (;;);
}
