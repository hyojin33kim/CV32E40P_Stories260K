// P0 of docs/DDR_ARCH_PLAN.md: how fast does the attention read the KV cache when the KV cache is in DDR, for two layouts?
// Stories260K shape: 5 layers, 8 query heads, 4 KV heads (kv_mul 2), head_size 8, kv_dim 32, seq_len 512. Only the access pattern and
// the cycles matter here, the data is whatever the memory holds. Per token and layer the firmware does for each of the 8 query heads
// QK (acc_gemv rows = timesteps, N = head_size) and AV (rows = head dims, columns = timesteps), as gen/firmware_gen.c does.
// Config word at 0x1afff0: bit0 layout (0 = [t][kv_dim] as today, 1 = head-major [kv head][t][head_size]),
//                          bit1 context (0: 128 timesteps, 1: 512), bit2 KV base (0: in the external window = DDR, 1: on-chip SRAM 0x100000..)
// Results at 0x1aff00: 0 cycles of all QK calls, 1 cycles of all AV calls, 2 marker 0x600d600d, 3 number of calls, 4 STATUS err bits seen.
#define G ((volatile unsigned*)0x30000000)
static inline unsigned cyc(void) { unsigned v; __asm__ volatile("csrr %0, mcycle" : "=r"(v) :: "memory"); return v; }
static void gemv(unsigned x, unsigned w, unsigned y, int n, int d, int wstride, int jstride) {
    G[2] = x; G[3] = w; G[4] = y; G[5] = n; G[6] = d; G[7] = wstride; G[9] = jstride;
    G[0] = 1;
    while (G[1] & 1) ;
}
#define Q   0x1a0000u
#define ATT 0x1a1000u
#define OUT 0x1a3000u
void boot(void) {
    unsigned cfg = *(volatile unsigned*)0x1afff0;
    int head = cfg & 1, ctx = (cfg & 2) ? 512 : 128; unsigned kb = (cfg & 4) ? 0x100000u : 0x0u, vb = kb + 0x50000u;
    unsigned calls = 0, errs = 0, qk = 0, av = 0;
    unsigned t0 = cyc();
    for (int l = 0; l < 5; l++)
        for (int h = 0; h < 8; h++) {
            int kvh = h / 2;
            unsigned koff = head ? (unsigned)l * 0x10000u + kvh * (512u * 32u) : (unsigned)l * 0x10000u + kvh * 32u;
            gemv(Q, kb + koff, ATT, 8, ctx, head ? 32 : 128, 4); calls++;
        }
    unsigned t1 = cyc();
    for (int l = 0; l < 5; l++)
        for (int h = 0; h < 8; h++) {
            int kvh = h / 2;
            unsigned voff = head ? (unsigned)l * 0x10000u + kvh * (512u * 32u) : (unsigned)l * 0x10000u + kvh * 32u;
            gemv(ATT, vb + voff, OUT, ctx, 8, 4, head ? 32 : 128); calls++;
        }
    unsigned t2 = cyc();
    errs = (G[1] >> 1) & 1; qk = t1 - t0; av = t2 - t1;
    volatile unsigned *out = (volatile unsigned*)0x1aff00;
    out[0] = qk; out[1] = av; out[2] = 0x600d600d; out[3] = calls; out[4] = errs;
    *(volatile unsigned*)0x20000000 = 1; for (;;);
}
