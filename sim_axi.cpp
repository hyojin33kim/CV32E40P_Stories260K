// Board-flow simulation of acc/chip_axi_top.sv (S5, 260K weights on chip): everything the PS
// would do, through the AXI4-Lite slave only, no backdoor preload.
//   1. hold the core (CTRL.RUN = 0), write imem (16 KB) and the SRAM image (2 MiB, non-zero
//      words: the simulated SRAM starts at zero; the board must clear it or write every word)
//   2. CTRL.RUN = 1, poll STATUS.DONE
//   3. CTRL.RUN = 0, read the SRAM back through AXI4-Lite and write the dump (same layout as sim.cpp)
// usage: obj_axi/Vchip_axi_top <image.bin> <dump.bin> [max cycles]
// Output: "DONE cycles=<CYCLES register> axi_cycles=<total sim cycles>"
#include "Vchip_axi_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <vector>

static Vchip_axi_top t;
static unsigned long long cyc = 0;
static void tick() { t.clk_i = 0; t.eval(); t.clk_i = 1; t.eval(); cyc++; }

static void axi_write(unsigned a, unsigned d) {
    t.s_axi_awaddr = a; t.s_axi_awvalid = 1; t.s_axi_wdata = d; t.s_axi_wstrb = 0xf; t.s_axi_wvalid = 1;
    for (;;) { t.clk_i = 0; t.eval(); bool r = t.s_axi_awready; t.clk_i = 1; t.eval(); cyc++; if (r) break; }
    t.s_axi_awvalid = 0; t.s_axi_wvalid = 0; t.s_axi_bready = 1;
    for (;;) { t.clk_i = 0; t.eval(); bool v = t.s_axi_bvalid; t.clk_i = 1; t.eval(); cyc++; if (v) break; }
    t.s_axi_bready = 0;
}
static unsigned axi_read(unsigned a) {
    t.s_axi_araddr = a; t.s_axi_arvalid = 1;
    for (;;) { t.clk_i = 0; t.eval(); bool r = t.s_axi_arready; t.clk_i = 1; t.eval(); cyc++; if (r) break; }
    t.s_axi_arvalid = 0; t.s_axi_rready = 1;
    unsigned d = 0;
    for (;;) { t.clk_i = 0; t.eval(); bool v = t.s_axi_rvalid; d = t.s_axi_rdata; t.clk_i = 1; t.eval(); cyc++; if (v) break; }
    t.s_axi_rready = 0;
    return d;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { std::cerr << "usage: " << argv[0] << " image.bin dump.bin [max cycles]\n"; return 2; }
    std::vector<unsigned char> mem(0x1020000, 0);
    std::ifstream f(argv[1], std::ios::binary); f.read((char*)mem.data(), mem.size());
    unsigned long long maxc = argc > 3 ? strtoull(argv[3], 0, 0) : 100000000ULL;
    auto w32 = [&](unsigned a) { unsigned v; memcpy(&v, &mem[a], 4); return v; };

    t.rst_ni = 0; t.s_axi_awvalid = 0; t.s_axi_wvalid = 0; t.s_axi_bready = 0; t.s_axi_arvalid = 0; t.s_axi_rready = 0;
    for (int i = 0; i < 5; i++) tick();
    t.rst_ni = 1; tick();

    axi_write(0x2000000, 0);                                          // core held
    for (unsigned i = 0; i < 0x4000; i += 4) axi_write(0x1000000 + i, w32(0x1000000 + i));
    unsigned nz = 0;
    for (unsigned a = 0; a < 0x200000; a += 4) { unsigned v = w32(a); if (v) { axi_write(a, v); nz++; } }
    unsigned long long load_cycles = cyc;

    axi_write(0x2000000, 1);                                          // run
    while ((axi_read(0x2000004) & 1) == 0) {
        for (int i = 0; i < 2000; i++) tick();
        if (cyc > maxc) {
            unsigned dr[6]; for (int i = 0; i < 6; i++) dr[i] = axi_read(0x2000040 + 4 * i);
            std::cout << "DBGREGS out=0x" << std::hex << dr[0] << " out_cnt=" << std::dec << dr[1] << " last_pc=0x" << std::hex << dr[2] << std::dec << " fetch_cnt=" << dr[3]
                      << " trap_cnt=" << dr[4] << " trap_pc=0x" << std::hex << dr[5] << std::dec << "\n";
            std::cerr << "TIMEOUT\n"; return 1;
        }
    }
    unsigned run_cycles = axi_read(0x200000C), done_v = axi_read(0x2000008);
    unsigned pf[6]; for (int i = 0; i < 6; i++) pf[i] = axi_read(0x2000020 + 4 * i);
    unsigned dr[6]; for (int i = 0; i < 6; i++) dr[i] = axi_read(0x2000040 + 4 * i);
    axi_write(0x2000000, 0);                                          // hold, then read back
    for (unsigned a = 0; a < 0x200000; a += 4) { unsigned v = axi_read(a); memcpy(&mem[a], &v, 4); }
    std::ofstream out(argv[2], std::ios::binary); out.write((char*)mem.data(), 0x200000);
    std::cout << "DONE cycles=" << run_cycles << " done_value=0x" << std::hex << done_v << std::dec
              << " loaded_words=" << nz << " load_cycles=" << load_cycles << " axi_cycles=" << cyc << "\n";
    std::cout << "PERF gemv_busy=" << pf[0] << " vfu_busy=" << pf[1] << " acc_stall=" << pf[2] << " acc_rd_lines=" << pf[3]
              << " tq_full=" << pf[4] << " eq_max=" << pf[5] << "\n";
    std::cout << "DBGREGS out=0x" << std::hex << dr[0] << " out_cnt=" << std::dec << dr[1] << " last_pc=0x" << std::hex << dr[2] << std::dec << " fetch_cnt=" << dr[3]
              << " trap_cnt=" << dr[4] << " trap_pc=0x" << std::hex << dr[5] << std::dec << "\n";
    return 0;
}
