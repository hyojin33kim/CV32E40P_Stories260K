// Exhaustive check of acc/vfu_exp2.sv against the C model opta/exp2q.h: every 32-bit input
// pattern (inf/NaN inputs included; the model defines them too), one input per cycle.
// usage: acc/tb_exp2/run.sh [first_hex last_hex]   (default: all 2^32)
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include "Vvfu_exp2.h"
#include "../../opta/exp2q.h"

int main(int argc, char** argv) {
    uint64_t lo = argc > 2 ? strtoull(argv[1], 0, 16) : 0, hi = argc > 2 ? strtoull(argv[2], 0, 16) : 0xffffffffull;
    Vvfu_exp2 t;
    t.clk_i = 0; t.rst_ni = 0; t.valid_i = 0; t.eval(); t.rst_ni = 1; t.eval();
    const int LAT = 5;
    uint32_t pipe[8]; uint64_t n_in = 0, n_out = 0, bad = 0;
    for (uint64_t k = lo; n_out < hi - lo + 1; ) {
        bool in = k <= hi;
        t.valid_i = in; t.y_i = (uint32_t)k;
        if (in) { pipe[n_in % 8] = (uint32_t)k; n_in++; k++; }
        t.clk_i = 1; t.eval(); t.clk_i = 0; t.eval();
        if (t.valid_o) {
            uint32_t y = pipe[n_out % 8], want = exp2q_bits(y);
            if (t.res_o != want) { if (bad < 10) printf("MISMATCH y=%08x rtl=%08x model=%08x\n", y, t.res_o, want); bad++; }
            n_out++;
        }
        if (n_in - n_out > LAT + 1) { printf("latency error\n"); return 2; }
        if ((n_out & 0x0fffffff) == 0 && n_out) { printf("  %llu checked\n", (unsigned long long)n_out); fflush(stdout); }
    }
    printf("vfu_exp2: %llu inputs [%08llx..%08llx], %llu mismatches\n", (unsigned long long)n_out,
           (unsigned long long)lo, (unsigned long long)hi, (unsigned long long)bad);
    return bad != 0;
}
