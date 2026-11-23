// Verilator version of fpga/xsim/tb_fpu.sv: cv32e40p_fp_wrapper (FPU latency 4) on vec.hex, one operation at a time
// (request until grant, wait for rvalid), results to fpu_out.hex. usage: Vcv32e40p_fp_wrapper vec.hex fpu_out.hex
#include "Vcv32e40p_fp_wrapper.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
static Vcv32e40p_fp_wrapper t;
static void tick() { t.clk_i = 0; t.eval(); t.clk_i = 1; t.eval(); }
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    FILE* fi = fopen(argv[1], "r"); FILE* fo = fopen(argv[2], "w");
    if (!fi || !fo) { fprintf(stderr, "files\n"); return 2; }
    t.rst_ni = 0; t.apu_req_i = 0; t.apu_flags_i = 0x400; t.apu_op_i = 0;
    for (int i = 0; i < 5; i++) tick();
    t.rst_ni = 1; for (int i = 0; i < 3; i++) tick();
    unsigned o, a, b, c; int n = 0;
    while (fscanf(fi, "%x %x %x %x\n", &o, &a, &b, &c) == 4) {
        t.apu_op_i = o & 0x3f; t.apu_operands_i[0] = a; t.apu_operands_i[1] = b; t.apu_operands_i[2] = c; t.apu_req_i = 1;
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
