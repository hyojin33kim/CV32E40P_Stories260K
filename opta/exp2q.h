// Option A (S3, 11-15): exp2q(y) = 2^y for an fp32 y, integer-only and bit-defined, shared
// by the host model, the RISC-V firmware and the VFU exp2 pipeline (acc/vfu_exp2.sv).
//   1. |y| -> A = round_half_up(|y| * 2^23) (from the fp32 bits); u = sign ? -A : A  (Q8.23)
//      |y| < 2^-23 (incl. +-0, denormals) -> 1.0 ; |y| >= 128 -> +inf (y > 0) / +0 (y < 0)
//   2. n = u >> 23 (arithmetic), f = u & 0x7fffff ; i = f >> 17 (6 bits), r = f & 0x1ffff
//   3. Q = ((r*C1) >> 22) + ((C2*((r*r) >> 17)) >> 28) [r*r 34 bit]     2^(r/2^23) - 1 in units of 2^-32
//   4. M = T[i] + ((T[i]*Q) >> 32)                            Q2.30, T[i] = 2^(i/64)
//   5. m = (M + 64) >> 7 (round half up to 24 bits); m == 2^24 -> m = 2^23, n += 1
//   6. e = n + 127: e >= 255 -> +inf, e <= 0 -> +0 (no denormals), else e<<23 | (m & 0x7fffff)
// Constants from opta/fit_exp2q.py (polynomial max rel err 8.2e-9). Accuracy of the whole
// function: opta/test_exp2q.c (exhaustive over every fp32 input).
#ifndef EXP2Q_H
#define EXP2Q_H
#include <stdint.h>

#define EXP2Q_C1 1488509675u   // round(0.6931413316480365 * 2^31)
#define EXP2Q_C2 518481354u    // round(0.2414366945983792 * 2^31)
static const uint32_t exp2q_T[64] = {
    0x40000000u, 0x40b268fau, 0x4166c34cu, 0x421d1462u, 0x42d561b4u, 0x438fb0cbu, 0x444c0740u, 0x450a6abbu,
    0x45cae0f2u, 0x468d6faeu, 0x47521cc6u, 0x4818ee22u, 0x48e1e9bau, 0x49ad1598u, 0x4a7a77d4u, 0x4b4a169cu,
    0x4c1bf829u, 0x4cf022cau, 0x4dc69cddu, 0x4e9f6cd4u, 0x4f7a9930u, 0x50582888u, 0x51382182u, 0x521a8ad7u,
    0x52ff6b55u, 0x53e6c9dau, 0x54d0ad5au, 0x55bd1cdbu, 0x56ac1f75u, 0x579dbc57u, 0x5891fac1u, 0x5988e209u,
    0x5a82799au, 0x5b7ec8f2u, 0x5c7dd7a4u, 0x5d7fad59u, 0x5e8451d0u, 0x5f8bccdbu, 0x60962665u, 0x61a3666du,
    0x62b39509u, 0x63c6ba64u, 0x64dcdec3u, 0x65f60a7fu, 0x6712460bu, 0x683199edu, 0x69540ec9u, 0x6a79ad56u,
    0x6ba27e65u, 0x6cce8ae1u, 0x6dfddbccu, 0x6f307a41u, 0x70666f76u, 0x719fc4b9u, 0x72dc8374u, 0x741cb528u,
    0x75606374u, 0x76a7980fu, 0x77f25cceu, 0x7940bb9eu, 0x7a92be8bu, 0x7be86fbau, 0x7d41d96eu, 0x7e9f0606u,
};

static inline uint32_t exp2q_bits(uint32_t y) {
    uint32_t s = y >> 31, E = (y >> 23) & 0xff, sig = (y & 0x7fffffu) | 0x800000u;
    if (E < 127 - 24) return 0x3f800000u;                 // |y| < 2^-24 -> 1.0 (A rounds to 0)
    if (E >= 134) return s ? 0u : 0x7f800000u;            // |y| >= 128 (and inf/NaN)
    uint32_t A = E >= 127 ? sig << (E - 127) : ((sig >> (126 - E)) + 1u) >> 1;   // E in [103, 133]
    int32_t u = s ? -(int32_t)A : (int32_t)A;
    int32_t n = u >> 23;                                  // arithmetic shift (floor)
    uint32_t f = (uint32_t)u & 0x7fffffu, i = f >> 17, r = f & 0x1ffffu;
    uint32_t Q = (uint32_t)(((uint64_t)r * EXP2Q_C1) >> 22) +
                 (uint32_t)(((uint64_t)EXP2Q_C2 * (uint32_t)(((uint64_t)r * r) >> 17)) >> 28);  // r*r: 34 bits
    uint32_t T = exp2q_T[i];
    uint32_t M = T + (uint32_t)(((uint64_t)T * Q) >> 32);
    uint32_t m = (M + 64u) >> 7;
    if (m >> 24) { m = 0x800000u; n += 1; }
    int32_t e = n + 127;
    if (e >= 255) return 0x7f800000u;
    if (e <= 0) return 0u;
    return ((uint32_t)e << 23) | (m & 0x7fffffu);
}
static inline float exp2q(float y) {
    union { float f; uint32_t u; } a = { y }, b;
    b.u = exp2q_bits(a.u);
    return b.f;
}
// K = fp32(log2(e) / sqrt(8)): attention scores s -> y = (s - max) * K
#define OPTA_K 0x1.0527dcp-1f
// -log2(e): SiLU argument x -> y = x * OPTA_NLOG2E, sigmoid = 1 / (1 + 2^y)
#define OPTA_NLOG2E -0x1.715476p+0f
#endif
