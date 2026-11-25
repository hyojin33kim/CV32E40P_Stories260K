// Stand-alone test of acc/axi_ext_rd.sv (V-A2): AXI master protocol and data checks against a randomized AXI4 read slave.
// Slave behaviour per seed: AR ready probability and long stalls, read latency, R beat gaps; optional SLVERR/DECERR on one beat.
// Driver: accelerator line requests (sequential runs crossing 4 KB boundaries, long runs, jumps, repeats, descending) with random gaps,
// interleaved with CPU word reads. Every response is compared with a hash of its address, in order.
// Protocol checks (every cycle): AR address 16 B aligned, burst never crosses 4 KB, arlen+1 <= MAXB, AR stable while arvalid && !arready,
// bursts outstanding <= TD, lines outstanding <= CRED+1 (+1: a CPU read is not credit limited), rready == 1, R beat only when a burst is outstanding.
// usage: Vaxi_ext_rd <first seed> <last seed> [inject]   ("inject": one error beat per seed, checks err_o and recovery after reset)
#include "Vaxi_ext_rd.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <random>
#include <string>
#include <vector>

#ifndef P_MAXB
#define P_MAXB 16
#endif
#ifndef P_CRED
#define P_CRED 48
#endif
#ifndef P_TD
#define P_TD 8
#endif

static Vaxi_ext_rd t;
static const uint32_t BASE = 0x40000000u;
static uint32_t hw(uint32_t line, int k) { uint32_t x = (line * 4u + (uint32_t)k) * 2654435761u; x ^= x >> 15; x *= 2246822519u; x ^= x >> 13; return x; }
static void line_words(uint32_t line, uint32_t w[4]) { for (int k = 0; k < 4; k++) w[k] = hw(line, k); }

struct Burst { uint32_t addr; int len; long ready; int sent; };
static int fails = 0;
#define FAIL(...) do { if (fails < 12) { printf("  FAIL: "); printf(__VA_ARGS__); printf("\n"); } fails++; } while (0)

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int s0 = atoi(argv[1]), s1 = atoi(argv[2]); bool inject = argc > 3 && !strcmp(argv[3], "inject");
    long tot_acc = 0, tot_cpu = 0, tot_beats = 0, tot_cycles = 0; int tot_bursts = 0, max_len = 0, max_tdo = 0, max_lo = 0, cross_splits = 0;
    for (int seed = s0; seed <= s1; seed++) {
        std::mt19937 rng(seed * 7919u + 13u);
        auto rnd = [&](int n) { return (int)(rng() % (unsigned)n); };
        auto chance = [&](double p) { return (rng() & 0xffffff) < p * 16777216.0; };
        // ---- per-seed behaviour
        const double par_opts[3] = {1.0, 0.5, 0.1}, pr_opts[3] = {1.0, 0.5, 0.2}, preq_opts[3] = {1.0, 0.5, 0.1};
        const int lat_lo[3] = {0, 10, 50}, lat_hi[3] = {3, 40, 200};
        double p_ar = par_opts[seed % 3], p_r = pr_opts[(seed / 3) % 3], p_req = preq_opts[(seed / 9) % 3];
        int li = (seed / 27) % 3; bool ar_stall = (seed % 5) == 4;
        // ---- request plan
        std::vector<uint32_t> plan;
        int nseg = 40 + rnd(40);
        for (int sgi = 0; sgi < nseg; sgi++) {
            int kind = rnd(6); uint32_t start = (uint32_t)rnd(1 << 18);
            if (kind == 0) { start = 256u * (1 + rnd(900)) - (uint32_t)rnd(24); int n = 1 + rnd(40); for (int i = 0; i < n; i++) plan.push_back(start + i); }          // across a 4 KB boundary
            else if (kind == 1) { start = 256u * rnd(900); int n = 100 + rnd(700); for (int i = 0; i < n; i++) plan.push_back(start + i); }                      // long run, several boundaries
            else if (kind == 2) { int n = 1 + rnd(3); for (int i = 0; i < n; i++) plan.push_back(start + (uint32_t)rnd(1000)); }                                 // jumps
            else if (kind == 3) { int n = 2 + rnd(4); for (int i = 0; i < n; i++) plan.push_back(start); }                                                       // same line repeated
            else if (kind == 4) { int n = 2 + rnd(30); start += (uint32_t)n; for (int i = 0; i < n; i++) plan.push_back(start - i); }                           // descending
            else { start = 256u * (1 + rnd(900)) - 1; plan.push_back(start); plan.push_back(start + 1); plan.push_back(start + 2); }                             // exactly at the boundary
        }
        // ---- DUT reset
        t.rst_ni = 0; t.acc_req_i = 0; t.cpu_req_i = 0; t.m_arready_i = 0; t.m_rvalid_i = 0; t.m_rlast_i = 0; t.m_rresp_i = 0; t.base_i = BASE;
        for (int i = 0; i < 5; i++) { t.clk_i = 0; t.eval(); t.clk_i = 1; t.eval(); }
        t.rst_ni = 1;
        // ---- state
        std::deque<Burst> bursts; std::deque<std::pair<uint32_t, int>> exp_acc, exp_cpu;   // expected (line, -) / (line, word)
        size_t next_req = 0; int cpu_left = 200 + rnd(200); bool cpu_wait = false; uint32_t cpu_addr_req = 0;
        long cycle = 0, last_prog = 0, beat_no = 0; int stall_left = 0; bool prev_arvalid = false; uint32_t prev_addr = 0; int prev_len = 0;
        long inj_beat = inject ? (long)(20 + rnd(400)) : -1; int inj_code = rnd(2) ? 2 : 3; bool inj_done = false; long inj_cycle = -1;
        long acc_got = 0, cpu_got = 0; int bursts_seen = 0; uint32_t lines_req = 0, lines_exp_total = 0; (void)lines_exp_total;
        long lines_out = 0; bool done = false; int drain = 0; long seed_fails0 = fails;
        bool cur_valid = false; uint32_t cur_line = 0;
        while (true) {
            // ---- drive inputs for this cycle
            // accelerator request: hold until granted
            if (!cur_valid && next_req < plan.size() && chance(p_req)) { cur_valid = true; cur_line = plan[next_req]; }
            t.acc_req_i = cur_valid; t.acc_addr_i = cur_line * 16u;
            // CPU request
            if (!cpu_wait && cpu_left > 0 && chance(0.02)) { cpu_wait = true; cpu_addr_req = ((uint32_t)rnd(1 << 18) * 16u) + 4u * rnd(4); }
            t.cpu_req_i = cpu_wait; t.cpu_addr_i = cpu_addr_req;
            // slave: ar ready
            if (stall_left > 0) stall_left--; else if (ar_stall && chance(0.01)) stall_left = 30 + rnd(40);
            bool arready = stall_left == 0 && chance(p_ar);
            t.m_arready_i = arready;
            // slave: R beat
            bool rv = false; uint32_t beat_line = 0; int rresp = 0; bool rlast = false;
            if (!bursts.empty() && cycle >= bursts.front().ready && chance(p_r)) {
                Burst& b = bursts.front(); rv = true; beat_line = (b.addr - BASE) / 16 + (uint32_t)b.sent; rlast = b.sent == b.len;
                if (beat_no == inj_beat && inject) { rresp = inj_code; inj_done = true; inj_cycle = cycle; }
            }
            t.m_rvalid_i = rv; t.m_rlast_i = rlast; t.m_rresp_i = rresp;
            uint32_t w[4] = {0xdeadbeef, 0xdeadbeef, 0xdeadbeef, 0xdeadbeef}; if (rv && rresp == 0) line_words(beat_line, w);
            for (int k = 0; k < 4; k++) t.m_rdata_i[k] = w[k];
            t.clk_i = 0; t.eval();
            // ---- sample (before the edge)
            bool acc_gnt = t.acc_gnt_o, cpu_gnt = t.cpu_gnt_o, arvalid = t.m_arvalid_o; uint32_t araddr = t.m_araddr_o; int arlen = t.m_arlen_o;
            if (!t.m_rready_o) FAIL("seed %d cyc %ld: rready low", seed, cycle);
            if (arvalid) {
                if (araddr & 0xf) FAIL("seed %d cyc %ld: araddr %08x not 16 B aligned", seed, cycle, araddr);
                if (((araddr & 0xfff) + (uint32_t)(arlen + 1) * 16u) > 0x1000u) FAIL("seed %d cyc %ld: burst %08x len %d crosses 4 KB", seed, cycle, araddr, arlen + 1);
                if (arlen + 1 > P_MAXB) FAIL("seed %d cyc %ld: burst of %d lines > MAXB %d", seed, cycle, arlen + 1, P_MAXB);
                if (araddr < BASE) FAIL("seed %d cyc %ld: araddr %08x below base", seed, cycle, araddr);
            }
            if (prev_arvalid && !arvalid) FAIL("seed %d cyc %ld: arvalid dropped without arready", seed, cycle);
            if (prev_arvalid && arvalid && (araddr != prev_addr || arlen != prev_len)) FAIL("seed %d cyc %ld: AR changed while waiting for arready", seed, cycle);
            bool acc_rv = t.acc_rvalid_o, cpu_rv = t.cpu_rvalid_o; uint32_t accw[4], cpuw = t.cpu_rdata_o;
            for (int k = 0; k < 4; k++) accw[k] = t.acc_rdata_o[k];
            if (acc_rv && cpu_rv) FAIL("seed %d cyc %ld: acc and cpu rvalid together", seed, cycle);
            if (rv && !(acc_rv || cpu_rv)) FAIL("seed %d cyc %ld: R beat consumed by nobody", seed, cycle);
            // ---- edge
            t.clk_i = 1; t.eval(); cycle++;
            // ---- bookkeeping after the edge
            prev_arvalid = arvalid && !arready; prev_addr = araddr; prev_len = arlen;
            if (t.acc_req_i && acc_gnt) { cur_valid = false; next_req++; lines_req++; exp_acc.push_back({plan[next_req - 1], 0}); last_prog = cycle; }
            if (t.cpu_req_i && cpu_gnt) { cpu_wait = false; cpu_left--; exp_cpu.push_back({cpu_addr_req >> 4, (int)((cpu_addr_req >> 2) & 3)}); last_prog = cycle; }
            if (arvalid && arready) {
                Burst b; b.addr = araddr; b.len = arlen; b.sent = 0; b.ready = cycle + lat_lo[li] + rnd(lat_hi[li] - lat_lo[li] + 1);
                bursts.push_back(b); bursts_seen++; lines_out += arlen + 1; last_prog = cycle;
                if (arlen + 1 > max_len) max_len = arlen + 1;
                if ((int)bursts.size() > P_TD) FAIL("seed %d cyc %ld: %zu bursts outstanding > TD %d", seed, cycle, bursts.size(), P_TD);
                if ((int)bursts.size() > max_tdo) max_tdo = (int)bursts.size();
                if (lines_out > P_CRED + 1) FAIL("seed %d cyc %ld: %ld lines outstanding > CRED+1 %d", seed, cycle, lines_out, P_CRED + 1);
                if (lines_out > max_lo) max_lo = (int)lines_out;
            }
            if (rv) {
                Burst& b = bursts.front(); b.sent++; beat_no++; tot_beats++; lines_out--; last_prog = cycle;
                if (b.sent == b.len + 1) bursts.pop_front();
                if (acc_rv) {
                    if (exp_acc.empty()) FAIL("seed %d cyc %ld: unexpected acc response", seed, cycle);
                    else {
                        uint32_t eline = exp_acc.front().first; exp_acc.pop_front(); acc_got++;
                        if (rresp == 0) { uint32_t ew[4]; line_words(eline, ew); if (memcmp(ew, accw, 16)) FAIL("seed %d cyc %ld: acc data of line %u wrong (got %08x, expected %08x)", seed, cycle, eline, accw[0], ew[0]); }
                    }
                } else if (cpu_rv) {
                    if (exp_cpu.empty()) FAIL("seed %d cyc %ld: unexpected cpu response", seed, cycle);
                    else {
                        auto e = exp_cpu.front(); exp_cpu.pop_front(); cpu_got++;
                        if (rresp == 0 && cpuw != hw(e.first, e.second)) FAIL("seed %d cyc %ld: cpu word of line %u word %d wrong (got %08x, expected %08x)", seed, cycle, e.first, e.second, cpuw, hw(e.first, e.second));
                    }
                }
            }
            if (inject && inj_done && cycle >= inj_cycle + 3 && !t.err_o) { FAIL("seed %d: err_o not set after an error response (injected at cycle %ld)", seed, inj_cycle); inj_done = false; }
            if (!inject && t.err_o) { FAIL("seed %d cyc %ld: err_o set without an error response", seed, cycle); }
            // ---- completion / deadlock
            if (next_req == plan.size() && cpu_left == 0 && !cpu_wait && exp_acc.empty() && exp_cpu.empty() && bursts.empty()) { if (++drain > 100) { done = true; break; } }
            if (cycle - last_prog > 20000) { FAIL("seed %d: no progress for 20000 cycles (issued %zu/%zu, answered %ld, bursts %zu) - deadlock", seed, next_req, plan.size(), acc_got, bursts.size()); break; }
            if (cycle > 4000000) { FAIL("seed %d: cycle limit", seed); break; }
        }
        // ---- end of seed checks
        if (done) {
            if (t.n_lines_o != lines_req) FAIL("seed %d: n_lines %u != accelerator lines requested %u", seed, (unsigned)t.n_lines_o, lines_req);
            if (inject && !inj_done && inj_cycle < 0) printf("  note: seed %d finished before the error beat (beat %ld)\n", seed, inj_beat);
            if (inject && inj_cycle >= 0 && !t.err_o) FAIL("seed %d: err_o cleared without reset", seed);
            tot_acc += acc_got; tot_cpu += cpu_got; tot_bursts += bursts_seen;
            // lines merged into bursts vs the 4 KB split count (informational)
            (void)cross_splits;
        }
        tot_cycles += cycle;
        if (inject) {   // recovery: reset clears err_o
            t.rst_ni = 0; for (int i = 0; i < 3; i++) { t.clk_i = 0; t.eval(); t.clk_i = 1; t.eval(); } t.rst_ni = 1; t.clk_i = 0; t.eval();
            if (t.err_o) FAIL("seed %d: err_o still set after reset", seed);
        }
        if (fails == seed_fails0 && !done) FAIL("seed %d: did not finish", seed);
    }
    printf("AXI_EXT_RD MAXB=%d CRED=%d TD=%d seeds %d..%d%s: %s | acc lines %ld, cpu words %ld, bursts %d, beats %ld, cycles %ld | longest burst %d lines, max bursts outstanding %d, max lines outstanding %d\n",
           P_MAXB, P_CRED, P_TD, s0, s1, inject ? " inject" : "", fails ? "FAIL" : "PASS", tot_acc, tot_cpu, tot_bursts, tot_beats, tot_cycles, max_len, max_tdo, max_lo);
    return fails ? 1 : 0;
}
