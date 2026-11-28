// Lab 2/3: a float dot product, compiled by gcc for RV32IMFC. Read the assembly (docs/labs: prog.dis) and compare with how you would write it by hand.
// Expected: a . b = 1.5*0.5 + 2*1 + 3*2 + 4*0.25 = 9.75, bit pattern 0x411c0000, written to the output channel.
#define OUT ((volatile unsigned*)0x20000010)
static float dot(const float *a, const float *b, int n) {
    float s = 0.0f;
    for (int i = 0; i < n; i++) s += a[i] * b[i];
    return s;
}
void boot(void) {
    float a[4] = {1.5f, 2.0f, 3.0f, 4.0f}, b[4] = {0.5f, 1.0f, 2.0f, 0.25f};
    union { float f; unsigned u; } r;
    r.f = dot(a, b, 4);
    *OUT = r.u;
    *(volatile unsigned*)0x20000000 = 1;   // DONE
    for (;;) ;
}
