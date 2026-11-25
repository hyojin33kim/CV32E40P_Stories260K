// Verilator version of fpga/xsim/tb_fpu.sv: cv32e40p_fp_wrapper (FPU latency 4) on vec.hex, one operation at a time
// (request until grant, wait for rvalid), results to fpu_out.hex. usage: Vcv32e40p_fp_wrapper vec.hex fpu_out.hex [stream]
// vec.hex lines: "op a b c flags". With "stream" the vectors of one operation group (ADDMUL / DIVSQRT / NONCOMP / CONV; each group returns in order)
// are requested back to back (a new request every cycle the FPU grants) and the results are collected in order as they come out (V-F4).
#include "Vcv32e40p_fp_wrapper.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <algorithm>
#include <string>
static Vcv32e40p_fp_wrapper t;
static void tick() { t.clk_i = 0; t.eval(); t.clk_i = 1; t.eval(); }
static int group_of(unsigned op) { unsigned o = op & 0xf; return o <= 3 ? 0 : o <= 5 ? 1 : o <= 9 ? 2 : 3; }
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    FILE* fi = fopen(argv[1], "r"); FILE* fo = fopen(argv[2], "w");
    bool stream = argc > 3 && std::string(argv[3]) == "stream";
    if (!fi || !fo) { fprintf(stderr, "files\n"); return 2; }
    t.rst_ni = 0; t.apu_req_i = 0; t.apu_flags_i = 0x400; t.apu_op_i = 0;
    for (int i = 0; i < 5; i++) tick();
    t.rst_ni = 1; for (int i = 0; i < 3; i++) tick();
    struct V { unsigned o, a, b, c, f; };
    std::vector<V> vs; unsigned o, a, b, c, f;
    while (fscanf(fi, "%x %x %x %x %x\n", &o, &a, &b, &c, &f) == 5) vs.push_back({o, a, b, c, f});
    int n = 0;
    if (!stream) {
        for (auto& v : vs) {
            t.apu_op_i = v.o & 0x3f; t.apu_flags_i = v.f; t.apu_operands_i[0] = v.a; t.apu_operands_i[1] = v.b; t.apu_operands_i[2] = v.c; t.apu_req_i = 1;
            int k = 0;
            for (;;) { t.clk_i = 0; t.eval(); bool g = t.apu_gnt_o; t.clk_i = 1; t.eval(); if (g) break; if (++k > 200) { fprintf(stderr, "no gnt %d\n", n); return 1; } }
            t.apu_req_i = 0; k = 0;
            while (!t.apu_rvalid_o) { tick(); if (++k > 200) { fprintf(stderr, "no rvalid, vector %d\n", n); return 1; } }
            fprintf(fo, "%08x\n", (unsigned)t.apu_rdata_o);
            n++; tick();
        }
        fclose(fo); printf("FPU_VERILATOR %d vectors done\n", n);
        return 0;
    }
    // stream mode: per group, in vector order; results are stored at the original vector index
    std::vector<unsigned> res(vs.size(), 0); long total_cycles = 0; int max_out = 0, extra = 0; bool ok = true;
    const char* gname[4] = {"ADDMUL", "DIVSQRT", "NONCOMP", "CONV"};
    for (int g = 0; g < 4; g++) {
        std::vector<int> idx; for (size_t i = 0; i < vs.size(); i++) if (group_of(vs[i].o) == g) idx.push_back((int)i);
        if (idx.empty()) continue;
        size_t iss = 0, col = 0; long cyc = 0; int mo = 0;
        while (col < idx.size()) {
            if (iss < idx.size()) { auto& v = vs[idx[iss]]; t.apu_op_i = v.o & 0x3f; t.apu_flags_i = v.f; t.apu_operands_i[0] = v.a; t.apu_operands_i[1] = v.b; t.apu_operands_i[2] = v.c; t.apu_req_i = 1; }
            else t.apu_req_i = 0;
            t.clk_i = 0; t.eval(); bool gnt = t.apu_gnt_o && t.apu_req_i;
            t.clk_i = 1; t.eval(); cyc++;
            if (gnt) iss++;
            if (t.apu_rvalid_o) { if (col >= iss) { fprintf(stderr, "stream %s: result without request\n", gname[g]); ok = false; col = idx.size(); break; } res[idx[col++]] = (unsigned)t.apu_rdata_o; }
            if ((int)(iss - col) > mo) mo = (int)(iss - col);
            if (cyc > 200 + 50 * (long)idx.size()) { fprintf(stderr, "stream %s: timeout (issued %zu, collected %zu of %zu)\n", gname[g], iss, col, idx.size()); ok = false; break; }
        }
        t.apu_req_i = 0; for (int k = 0; k < 20; k++) { tick(); if (t.apu_rvalid_o) extra++; }
        printf("stream %-7s %5zu ops, %6ld cycles (%.2f cycles/op), max in flight %d\n", gname[g], idx.size(), cyc, (double)cyc / idx.size(), mo);
        total_cycles += cyc; max_out = std::max(max_out, mo);
    }
    for (auto r : res) fprintf(fo, "%08x\n", r);
    fclose(fo);
    printf("FPU_VERILATOR_STREAM %zu vectors, %ld cycles, max in flight %d, unexpected extra results %d%s\n", vs.size(), total_cycles, max_out, extra, ok ? "" : " (ERROR)");
    return ok && extra == 0 ? 0 : 1;
}
