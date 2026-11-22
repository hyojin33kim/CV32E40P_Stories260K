// Board-flow simulation of acc/chip_axi_ddr_top.sv (S5b: weights in DDR, read through an AXI4 master).
// The PS side goes through AXI4-Lite only (imem, SRAM, control); the weight image is placed in the
// simulated DDR directly (the PS would write it through its own DDR path), DDR_BASE is programmed.
//   1. hold the core, write imem (16 KB) and the non-zero words of the 1 MiB SRAM (0x100000..0x1FFFFF)
//   2. DDR_BASE = SIM_DDR_BASE, RUN = 1, poll STATUS.DONE
//   3. read counters, RUN = 0, read the SRAM back; dump = weights (from the DDR array) + SRAM (same layout as sim.cpp)
// usage: obj_axi_ddr/Vchip_axi_ddr_top <image.bin> <dump.bin> [max cycles]
// DDR model (environment): SIM_DDR_LAT (40) cycles from AR to first beat, SIM_DDR_BW (12.8) bytes per cycle
//   sustained, SIM_DDR_OUT (8) outstanding AR, SIM_DDR_BASE (0x40000000).
// Output: "DONE cycles=<CYCLES> ... bursts=<N_BURSTS> lines=<N_LINES>"
#include "Vchip_axi_ddr_top.h"
#include "verilated.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <functional>
#include <iostream>
#include <vector>

static Vchip_axi_ddr_top t;
static unsigned long long cyc = 0;
static double envd(const char* n, double d) { const char* v = getenv(n); return v ? atof(v) : d; }
static const unsigned ddr_lat = (unsigned)envd("SIM_DDR_LAT", 40), ddr_out = (unsigned)envd("SIM_DDR_OUT", 8);
static const double ddr_bw = envd("SIM_DDR_BW", 12.8);
static const unsigned ddr_base = (unsigned)strtoul(getenv("SIM_DDR_BASE") ? getenv("SIM_DDR_BASE") : "0x40000000", 0, 0);
static std::vector<unsigned char> ddr(0x100000, 0);      // weights, DDR_BASE .. +1 MiB

// ---- optional row/bank model (SIM_ROWBANK=1): DDR4 channel timing in tCK units (same rules as ddr/ddr_model.py:
// open page, 4 bank groups x 4 banks, tRCD/tRP/tRAS/tRC/tRTP, tCCD_S/L, tRRD_S/L, tFAW, refresh). SIM_DDR_LAT is then the
// fixed latency (controller, fabric) added on top of the DRAM timing. Env: SIM_DRAM_PAGE (8192), SIM_DRAM_MAP (bgint|rowseq),
// SIM_CORE_MHZ (125), SIM_DRAM_MHZ (1200, tCK clock).
static const bool rb_on = getenv("SIM_ROWBANK") && atoi(getenv("SIM_ROWBANK"));
static const unsigned rb_page = (unsigned)envd("SIM_DRAM_PAGE", 8192);
static const bool rb_bgint = !(getenv("SIM_DRAM_MAP") && !strcmp(getenv("SIM_DRAM_MAP"), "rowseq"));
static const double core_mhz = envd("SIM_CORE_MHZ", 125), dram_mhz = envd("SIM_DRAM_MHZ", 1200);
static const double ratio = dram_mhz / core_mhz;
struct Dram {
    const double tRCD = 17, tRP = 17, tRAS = 39, tRC = 56, tRTP = 9, tCCDS = 4, tCCDL = 6, tRRDS = 4, tRRDL = 6, tFAW = 21,
                 tREFI = 9360, tRFC = 420, tCL = 17, BURST = 4;
    long long open_row[16]; double t_act[16], t_rdy[16], t_pre[16];
    std::deque<double> acts; int last_act_bg = -1; double last_cas = -1e9; int last_bg = -1, n_ref = 0;
    double next_ref = 9360, busy_until = 0;
    unsigned long long hits = 0, misses = 0, accesses = 0;
    Dram() { for (int i = 0; i < 16; i++) { open_row[i] = -1; t_act[i] = -1e9; t_rdy[i] = 0; t_pre[i] = 0; } }
    void map(unsigned long long line, int& bank, long long& row, int& bg) {   // 64 B line number
        unsigned long long ppl = rb_page / 64;
        if (rb_bgint) {
            int b = (int)(line % 4); unsigned long long r = line / 4; r /= ppl;
            int bk = (int)(r % 4); r /= 4; bank = b * 4 + bk; row = (long long)r; bg = b;
        } else {
            unsigned long long pg = line / ppl; bank = (int)(pg % 16); row = (long long)(pg / 16); bg = bank % 4;
        }
    }
    double access(unsigned long long line, double avail) {   // returns the CAS time (tCK) of this 64 B access
        int bank, bg; long long row; map(line, bank, row, bg); accesses++;
        double cas;
        if (open_row[bank] == row) { hits++; cas = std::max(t_rdy[bank], avail); }
        else {
            misses++;
            double pre_done = (open_row[bank] < 0) ? avail : std::max(t_pre[bank], avail) + tRP;
            double act = std::max(std::max(pre_done, t_act[bank] + tRC), avail);
            if (!acts.empty()) act = std::max(act, acts.back() + (last_act_bg == bg ? tRRDL : tRRDS));
            if (acts.size() == 4) act = std::max(act, acts.front() + tFAW);
            if (act >= next_ref) act = std::max(act, next_ref + tRFC);
            acts.push_back(act); if (acts.size() > 4) acts.pop_front(); last_act_bg = bg;
            t_act[bank] = act; open_row[bank] = row; cas = act + tRCD;
        }
        cas = std::max(std::max(cas, last_cas + (bg == last_bg ? tCCDL : tCCDS)), busy_until);
        while (cas >= next_ref) {
            cas = std::max(cas, next_ref + tRFC); next_ref += tREFI; n_ref++;
            for (int i = 0; i < 16; i++) open_row[i] = -1; busy_until = cas;
        }
        last_cas = cas; last_bg = bg;
        t_rdy[bank] = std::max(t_rdy[bank], t_act[bank] + tRCD);
        t_pre[bank] = std::max(t_act[bank] + tRAS, cas + tRTP);
        return cas;
    }
};
static Dram dram;
struct Burst { unsigned addr, len, beat; std::vector<unsigned long long> rdy; };   // rdy[b]: core cycle beat b may be returned
static std::deque<Burst> q;
static double credit = 0;
static unsigned long long ar_n = 0, r_beats = 0, ar_bad = 0;
static bool r_now = false;

static void model_pre() {
    t.m_axi_arready = q.size() < ddr_out;
    credit += ddr_bw; if (credit > 32) credit = 32;
    r_now = false; t.m_axi_rvalid = 0; t.m_axi_rlast = 0; t.m_axi_rresp = 0;
    if (!q.empty() && cyc >= q.front().rdy[q.front().beat] && credit >= 16.0) {
        Burst& b = q.front();
        unsigned a = b.addr + 16 * b.beat;
        if (a >= ddr_base && a + 16 <= ddr_base + ddr.size()) {
            memcpy(&t.m_axi_rdata, &ddr[a - ddr_base], 16);
        } else { memset(&t.m_axi_rdata, 0xee, 16); t.m_axi_rresp = 2; ar_bad++; }
        t.m_axi_rvalid = 1; t.m_axi_rlast = (b.beat == b.len);
        r_now = true;
    }
}
static void model_post() {   // after the low-phase eval: signals are settled, handshakes happen at the next edge
    if (t.m_axi_arvalid && t.m_axi_arready) {
        if (t.m_axi_arlen > 255) ar_bad++;
        Burst bu{t.m_axi_araddr, t.m_axi_arlen, 0, {}};
        unsigned long long lastline = ~0ULL; double cas = 0;
        for (unsigned b = 0; b <= bu.len; b++) {
            if (!rb_on) { bu.rdy.push_back(cyc + ddr_lat); continue; }
            unsigned long long line = ((unsigned long long)bu.addr + 16ULL * b) >> 6;
            if (line != lastline) { cas = dram.access(line, (double)cyc * ratio); lastline = line; }
            bu.rdy.push_back((unsigned long long)ceil((cas + dram.tCL) / ratio) + ddr_lat);
        }
        q.push_back(bu); ar_n++;
    }
    if (r_now) {                                     // rready is always 1: the beat is consumed at this edge
        Burst& b = q.front(); credit -= 16.0; r_beats++;
        if (b.beat == b.len) q.pop_front(); else b.beat++;
    }
}
static void step(const std::function<void()>& sample = nullptr) {
    model_pre(); t.clk_i = 0; t.eval();
    if (sample) sample();
    model_post(); t.clk_i = 1; t.eval(); cyc++;
}
static void tick() { step(); }

static void axi_write(unsigned a, unsigned d) {
    t.s_axi_awaddr = a; t.s_axi_awvalid = 1; t.s_axi_wdata = d; t.s_axi_wstrb = 0xf; t.s_axi_wvalid = 1;
    for (;;) { bool r = false; step([&] { r = t.s_axi_awready; }); if (r) break; }
    t.s_axi_awvalid = 0; t.s_axi_wvalid = 0; t.s_axi_bready = 1;
    for (;;) { bool v = false; step([&] { v = t.s_axi_bvalid; }); if (v) break; }
    t.s_axi_bready = 0;
}
static unsigned axi_read(unsigned a) {
    t.s_axi_araddr = a; t.s_axi_arvalid = 1;
    for (;;) { bool r = false; step([&] { r = t.s_axi_arready; }); if (r) break; }
    t.s_axi_arvalid = 0; t.s_axi_rready = 1;
    unsigned d = 0;
    for (;;) { bool v = false; step([&] { v = t.s_axi_rvalid; d = t.s_axi_rdata; }); if (v) break; }
    t.s_axi_rready = 0;
    return d;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { std::cerr << "usage: " << argv[0] << " image.bin dump.bin [max cycles]\n"; return 2; }
    std::vector<unsigned char> mem(0x1020000, 0);
    std::ifstream f(argv[1], std::ios::binary); f.read((char*)mem.data(), mem.size());
    unsigned long long maxc = argc > 3 ? strtoull(argv[3], 0, 0) : 200000000ULL;
    auto w32 = [&](unsigned a) { unsigned v; memcpy(&v, &mem[a], 4); return v; };
    memcpy(ddr.data(), mem.data(), 0x100000);                      // weights placed in DDR by the "PS"

    t.rst_ni = 0; t.s_axi_awvalid = 0; t.s_axi_wvalid = 0; t.s_axi_bready = 0; t.s_axi_arvalid = 0; t.s_axi_rready = 0;
    t.m_axi_arready = 0; t.m_axi_rvalid = 0;
    for (int i = 0; i < 5; i++) tick();
    t.rst_ni = 1; tick();

    axi_write(0x2000000, 0);                                          // core held
    for (unsigned i = 0; i < 0x4000; i += 4) axi_write(0x1000000 + i, w32(0x1000000 + i));
    unsigned nz = 0;
    for (unsigned a = 0x100000; a < 0x200000; a += 4) { unsigned v = w32(a); if (v) { axi_write(a, v); nz++; } }
    axi_write(0x2000010, ddr_base);
    unsigned long long load_cycles = cyc;

    axi_write(0x2000000, 1);                                          // run
    while ((axi_read(0x2000004) & 1) == 0) {
        for (int i = 0; i < 2000; i++) tick();
        if (cyc > maxc) { std::cerr << "TIMEOUT\n"; return 1; }
    }
    unsigned run_cycles = axi_read(0x200000C), done_v = axi_read(0x2000008), st = axi_read(0x2000004);
    unsigned nb = axi_read(0x2000014), nl = axi_read(0x2000018);
    unsigned pf[6]; for (int i = 0; i < 6; i++) pf[i] = axi_read(0x2000020 + 4 * i);
    axi_write(0x2000000, 0);                                          // hold, then read back the SRAM
    for (unsigned a = 0x100000; a < 0x200000; a += 4) { unsigned v = axi_read(a); memcpy(&mem[a], &v, 4); }
    memcpy(mem.data(), ddr.data(), 0x100000);                         // weights: DDR array (not modified by the chip)
    std::ofstream out(argv[2], std::ios::binary); out.write((char*)mem.data(), 0x200000);
    std::cout << "DONE cycles=" << run_cycles << " done_value=0x" << std::hex << done_v << std::dec
              << " status=0x" << std::hex << st << std::dec << " bursts=" << nb << " lines=" << nl
              << " avg_burst_lines=" << (nb ? (double)nl / nb : 0.0) << " ar=" << ar_n << " r_beats=" << r_beats
              << " bad=" << ar_bad << " loaded_words=" << nz << " axi_cycles=" << cyc << "\n";
    if (rb_on) std::cout << "DRAM accesses=" << dram.accesses << " row_hits=" << dram.hits << " row_misses=" << dram.misses
              << " hit_rate=" << (dram.accesses ? 100.0 * dram.hits / dram.accesses : 0.0) << "% refreshes=" << dram.n_ref
              << " page=" << rb_page << " map=" << (rb_bgint ? "bgint" : "rowseq") << "\n";
    std::cout << "PERF gemv_busy=" << pf[0] << " vfu_busy=" << pf[1] << " acc_stall=" << pf[2] << " acc_rd_lines=" << pf[3]
              << " tq_full=" << pf[4] << " eq_max=" << pf[5] << "\n";
    return 0;
}
