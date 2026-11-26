// Verilator test of the Debug Module on soc_chip_dm (dbg/soc_chip_dm.sv): a JTAG master written as bit-banging (TCK/TMS/TDI/TDO pins of the real
// TAP, dmi_jtag_tap.sv), the same loader protocol as fpga/xsim/net_verilator/net_sim.cpp, and a firmware image that runs to DONE.
//   1. load imem and SRAM through the loader port, release the core
//   2. JTAG: IDCODE, DTMCS, activate the Debug Module (dmcontrol.dmactive)
//   3. at several points of the run: halt request, wait for allhalted, read dpc/dcsr/x2 and a write-read-restore check of x5, resume, wait for allresumeack
//   4. run to DONE, read the SRAM back, compare with the reference dump (words that differ are listed: cycle counters differ after a halt)
//   +EBREAK=1: the instruction c.lui t0,0x6 at 0x0100_0088 (executed once at boot) is replaced by c.ebreak; the core is halted at reset, dcsr.ebreakm is set,
//   the hit is checked (cause 1, dpc), the replaced instruction is emulated through the debugger (t0 = 0x6000, dpc + 2) and the run continues.
// usage: <sim> <image.bin> <ref_dump.bin> [+HALTS=n] [+FIRST=cycles] [+STEP=cycles] [+VERBOSE=1] [+EBREAK=1] [+EXTRA=0]
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include "Vsoc_chip_dm.h"
#include "verilated.h"

static const int SRAM_WORDS = 524288, IMEM_WORDS = 4096;
static const uint32_t IMEM_BASE = 0x01000000u, DONE_ADDR = 0x20000000u;
static Vsoc_chip_dm* t;
static bool done = false, rvalid_next = false, verbose = false;
static long run_cycles = 0, fails = 0;

static void tick() {
  t->clk_i = 0; t->eval();
  bool req = t->data_req_o, we = t->data_we_o; uint32_t addr = t->data_addr_o;
  rvalid_next = req && t->rst_ni;
  if (t->rst_ni && req && we && addr == DONE_ADDR) done = true;
  t->clk_i = 1; t->eval();
  t->data_rvalid_i = rvalid_next;
  t->clk_i = 0; t->eval();
  if (t->rst_ni) run_cycles++;
}
static void ld_write(uint32_t a, uint32_t d) {
  t->ld_req_i = 1; t->ld_we_i = 1; t->ld_addr_i = a; t->ld_wdata_i = d; tick();
  t->ld_req_i = 0; t->ld_we_i = 0; tick();
}
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else if (verbose) { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)

// ---------------------------------------------------------------- JTAG bit-banging: one TCK period = 4 system clocks; TDO is read after the falling edge
static int jt(int tms, int tdi) {
  t->jtag_tms_i = tms; t->jtag_tdi_i = tdi; t->jtag_tck_i = 0;
  tick(); tick();
  int tdo = t->jtag_tdo_o;
  t->jtag_tck_i = 1;
  tick(); tick();
  t->jtag_tck_i = 0;
  return tdo;
}
static void tap_reset() { for (int i = 0; i < 6; i++) jt(1, 0); jt(0, 0); }       // Test-Logic-Reset, then Run-Test/Idle
static void shift_ir(unsigned v) {
  jt(1, 0); jt(1, 0); jt(0, 0); jt(0, 0);
  for (int i = 0; i < 5; i++) jt(i == 4, (v >> i) & 1);
  jt(1, 0); jt(0, 0);
}
static uint64_t shift_dr(uint64_t v, int n) {
  uint64_t out = 0;
  jt(1, 0); jt(0, 0); jt(0, 0);
  for (int i = 0; i < n; i++) out |= (uint64_t)jt(i == n - 1, (v >> i) & 1) << i;
  jt(1, 0); jt(0, 0);
  return out;
}
static void idle(int n) { for (int i = 0; i < n; i++) jt(0, 0); }
// DMI access: 7-bit address, 32-bit data, 2-bit op (1 read, 2 write); the result of a request comes with the next scan
static bool dmi(int op, unsigned addr, uint32_t data, uint32_t* rd) {
  for (int attempt = 0; attempt < 4; attempt++) {
    shift_ir(0x11);
    shift_dr(((uint64_t)addr << 34) | ((uint64_t)data << 2) | op, 41);
    idle(10 + 40 * attempt);
    uint64_t r = shift_dr(0, 41);
    int st = r & 3;
    if (st == 0) { if (rd) *rd = (uint32_t)(r >> 2); return true; }
    if (st == 3) { shift_ir(0x10); shift_dr(1u << 16, 32); continue; }           // busy: dmireset and retry with more idle cycles
    return false;
  }
  return false;
}
static uint32_t rd(unsigned a) { uint32_t v = 0; if (!dmi(1, a, 0, &v)) { fails++; printf("FAIL: DMI read 0x%02x\n", a); } return v; }
static void wr(unsigned a, uint32_t v) { if (!dmi(2, a, v, nullptr)) { fails++; printf("FAIL: DMI write 0x%02x\n", a); } }

enum { DMCONTROL = 0x10, DMSTATUS = 0x11, ABSTRACTCS = 0x16, COMMAND = 0x17, DATA0 = 0x04 };
static bool wait_status(uint32_t mask, uint32_t want, int max_polls) {
  for (int i = 0; i < max_polls; i++) if ((rd(DMSTATUS) & mask) == want) return true;
  return false;
}
// abstract "access register": regno 0x1000+n = x(n), 0x7b0 dcsr, 0x7b1 dpc
static uint32_t reg_read(unsigned regno) {
  wr(COMMAND, 0x00220000u | regno);
  for (int i = 0; i < 50; i++) { uint32_t cs = rd(ABSTRACTCS); if (!(cs & 0x1000)) { CHECK(((cs >> 8) & 7) == 0, "abstract read 0x%x cmderr=%u", regno, (cs >> 8) & 7); break; } }
  return rd(DATA0);
}
static void reg_write(unsigned regno, uint32_t v) {
  wr(DATA0, v);
  wr(COMMAND, 0x00230000u | regno);                                             // transfer + write
  for (int i = 0; i < 50; i++) { uint32_t cs = rd(ABSTRACTCS); if (!(cs & 0x1000)) { CHECK(((cs >> 8) & 7) == 0, "abstract write 0x%x cmderr=%u", regno, (cs >> 8) & 7); break; } }
}
static long arg(int argc, char** argv, const char* key, long def) {
  size_t n = strlen(key);
  for (int i = 3; i < argc; i++) if (!strncmp(argv[i], key, n)) return atol(argv[i] + n);
  return def;
}

int main(int argc, char** argv) {
  if (argc < 3) { fprintf(stderr, "usage: %s image.bin ref_dump.bin [+HALTS=n] [+FIRST=c] [+STEP=c] [+VERBOSE=1]\n", argv[0]); return 2; }
  long halts = arg(argc, argv, "+HALTS=", 3), first = arg(argc, argv, "+FIRST=", 20000), step = arg(argc, argv, "+STEP=", 30000);
  verbose = arg(argc, argv, "+VERBOSE=", 0);
  FILE* f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 2; }
  std::vector<uint8_t> img(IMEM_BASE + IMEM_WORDS * 4);
  if (fread(img.data(), 1, img.size(), f) != img.size()) { fprintf(stderr, "short image\n"); return 2; }
  fclose(f);
  std::vector<uint32_t> ref(SRAM_WORDS);
  f = fopen(argv[2], "rb"); if (!f) { perror(argv[2]); return 2; }
  if (fread(ref.data(), 4, SRAM_WORDS, f) != (size_t)SRAM_WORDS) { fprintf(stderr, "short reference\n"); return 2; }
  fclose(f);
  bool ebreak_mode = arg(argc, argv, "+EBREAK=", 0);
  if (ebreak_mode) { img[IMEM_BASE + 0x88] = 0x02; img[IMEM_BASE + 0x89] = 0x90; }   // c.ebreak = 0x9002 (little endian)
  auto word = [&](size_t off) { uint32_t w; memcpy(&w, &img[off], 4); return w; };

  Verilated::commandArgs(argc, argv);
  t = new Vsoc_chip_dm;
  t->clk_i = 0; t->rst_ni = 0; t->dm_rst_ni = 0; t->fetch_enable_i = 1;
  t->ld_req_i = 0; t->ld_we_i = 0; t->ld_addr_i = 0; t->ld_wdata_i = 0;
  t->data_gnt_i = 1; t->data_rvalid_i = 0; t->data_rdata_i = 0;
  t->acc_gnt_i = 1; t->acc_rvalid_i = 0; for (int i = 0; i < 4; i++) t->acc_rdata_i[i] = 0;
  t->jtag_tck_i = 0; t->jtag_tms_i = 0; t->jtag_trst_ni = 0; t->jtag_tdi_i = 0;
  for (int i = 0; i < 10; i++) tick();
  t->dm_rst_ni = 1; t->jtag_trst_ni = 1;
  for (int i = 0; i < 10; i++) tick();
  for (int i = 0; i < IMEM_WORDS; i++) ld_write(IMEM_BASE + 4 * i, word(IMEM_BASE + 4 * i));
  for (int i = 0; i < SRAM_WORDS; i++) ld_write(4 * (uint32_t)i, word(4 * (size_t)i));
  printf("loaded\n"); fflush(stdout);

  // ---- JTAG basics (the core is still in reset: the Debug Module and the TAP are on the always-on reset)
  tap_reset();
  shift_ir(0x01);
  uint32_t idc = (uint32_t)shift_dr(0, 32);
  CHECK(idc == 0x00000DB3u, "IDCODE 0x%08x (want 0x00000db3)", idc);
  shift_ir(0x10);
  uint32_t dtmcs = (uint32_t)shift_dr(0, 32);
  CHECK((dtmcs & 0xf) == 1 && ((dtmcs >> 4) & 0x3f) == 7, "DTMCS 0x%08x (version 1, abits 7)", dtmcs);
  wr(DMCONTROL, 0x00000001);                                                    // dmactive
  uint32_t dmc = rd(DMCONTROL);
  CHECK((dmc & 1) == 1, "dmcontrol after activate 0x%08x", dmc);
  uint32_t st0 = rd(DMSTATUS);
  CHECK((st0 & 0xf) == 2, "dmstatus.version = %u (want 2: debug spec 0.13)", st0 & 0xf);
  printf("dmstatus (core in reset) = 0x%08x\n", st0);

  // ---- release the core and run, with halt/resume cycles
  if (ebreak_mode) wr(DMCONTROL, 0x80000001);                                   // haltreq while the core is still in reset
  t->rst_ni = 1;
  if (ebreak_mode) {
    bool hr = wait_status(0x300, 0x300, 400);
    CHECK(hr, "ebreak test: core halted right after reset release");
    wr(DMCONTROL, 0x00000001);
    uint32_t dpc0 = reg_read(0x7b1), dcsr = reg_read(0x7b0);
    CHECK(dpc0 == 0x01000080u, "dpc after reset halt = 0x%08x (boot address 0x01000080)", dpc0);
    reg_write(0x7b0, dcsr | (1u << 15));                                         // ebreakm
    wr(DMCONTROL, 0x40000001);
    CHECK(wait_status(0x20000, 0x20000, 200), "ebreak test: resume acknowledged");
    wr(DMCONTROL, 0x00000001);
    bool hit = wait_status(0x300, 0x300, 400);
    CHECK(hit, "ebreak test: halted again at the ebreak");
    if (hit) {
      uint32_t c2 = reg_read(0x7b0), d2 = reg_read(0x7b1);
      printf("ebreak hit: dpc=0x%08x dcsr cause %u\n", d2, (c2 >> 6) & 7);
      CHECK(((c2 >> 6) & 7) == 1, "ebreak: dcsr.cause = %u (1 = ebreak)", (c2 >> 6) & 7);
      CHECK(d2 == 0x01000088u, "ebreak: dpc 0x%08x == address of the ebreak 0x01000088", d2);
      reg_write(0x1005, 0x6000);                                                 // emulate the replaced instruction c.lui t0,0x6
      reg_write(0x7b1, d2 + 2);
      reg_write(0x7b0, c2 & ~(1u << 15));
      wr(DMCONTROL, 0x40000001);
      CHECK(wait_status(0x20000, 0x20000, 200), "ebreak test: final resume acknowledged");
      wr(DMCONTROL, 0x00000001);
    }
  }
  for (long h = 0; h < halts && !done; h++) {
    long target = first + h * step;
    while (!done && run_cycles < target) tick();
    if (done) break;
    wr(DMCONTROL, 0x80000001);                                                  // haltreq
    bool halted = wait_status(0x300, 0x300, 200);                               // anyhalted, allhalted
    CHECK(halted, "halt %ld: allhalted", h);
    if (!halted) break;
    wr(DMCONTROL, 0x00000001);
    uint32_t dpc = reg_read(0x7b1), dcsr = reg_read(0x7b0), sp = reg_read(0x1002);
    printf("halt %ld at run cycle ~%ld: dpc=0x%08x dcsr=0x%08x (cause %u) sp=0x%08x halted_o=%d\n", h, run_cycles, dpc, dcsr, (dcsr >> 6) & 7, sp, (int)t->debug_halted_o);
    CHECK((dpc & ~0x3fffu) == IMEM_BASE, "dpc 0x%08x inside imem", dpc);
    CHECK(((dcsr >> 6) & 7) == 3, "dcsr.cause = %u (3 = haltreq)", (dcsr >> 6) & 7);
    CHECK(sp < 0x00200000u && (sp & 3) == 0, "sp 0x%08x inside the SRAM", sp);
    CHECK(t->debug_halted_o == 1, "debug_halted_o");
    uint32_t old = reg_read(0x1005);                                            // x5: write, read back, restore
    reg_write(0x1005, 0x12345678u);
    uint32_t back = reg_read(0x1005);
    CHECK(back == 0x12345678u, "x5 write/read 0x%08x", back);
    reg_write(0x1005, old);
    CHECK(reg_read(0x1005) == old, "x5 restored");
    // the other cores of the SoC keep running while the CPU is halted: nothing to check here beyond the final result
    wr(DMCONTROL, 0x40000001);                                                  // resumereq
    bool res = wait_status(0x20000, 0x20000, 200);                              // allresumeack
    CHECK(res, "resume %ld: allresumeack", h);
    wr(DMCONTROL, 0x00000001);
    CHECK(!t->debug_halted_o, "debug_halted_o cleared after resume");
  }
  // ---- single step and hardware breakpoint (trigger) at one more halt
  if (arg(argc, argv, "+EXTRA=", 1) && !done) {
    long target = first + halts * step;
    while (!done && run_cycles < target) tick();
    if (!done) {
      wr(DMCONTROL, 0x80000001);
      bool h = wait_status(0x300, 0x300, 200);
      CHECK(h, "extra halt: allhalted");
      if (h) {
        wr(DMCONTROL, 0x00000001);
        uint32_t dcsr0 = reg_read(0x7b0), dpc_first = reg_read(0x7b1);
        // single step: dcsr.step = bit 2; every resume executes one instruction and halts again with cause 4
        reg_write(0x7b0, dcsr0 | 4);
        uint32_t prev = dpc_first;
        uint32_t vis[8]; int nvis = 0; vis[nvis++] = dpc_first;
        for (int k = 0; k < 4; k++) {
          wr(DMCONTROL, 0x40000001);
          bool ack = wait_status(0x20000, 0x20000, 200);
          wr(DMCONTROL, 0x00000001);
          bool hh = ack && wait_status(0x300, 0x300, 200);
          CHECK(hh, "step %d: resume acknowledged and halted again", k);
          if (!hh) break;
          uint32_t dcsr = reg_read(0x7b0), dpc = reg_read(0x7b1);
          printf("step %d: dpc 0x%08x -> 0x%08x, dcsr cause %u\n", k, prev, dpc, (dcsr >> 6) & 7);
          CHECK(((dcsr >> 6) & 7) == 4, "step %d: dcsr.cause = %u (4 = step)", k, (dcsr >> 6) & 7);
          CHECK((dpc & ~0x3fffu) == IMEM_BASE && dpc != prev, "step %d: dpc moved to 0x%08x", k, dpc);
          prev = dpc; vis[nvis++] = dpc;
        }
        reg_write(0x7b0, dcsr0 & ~4u);
        // hardware breakpoint: trigger 0, match control (type 2), execute, machine mode, action 1 = enter debug mode, at the current pc
        uint32_t P = reg_read(0x7b1);
        reg_write(0x7a0, 0);
        reg_write(0x7a2, P);
        reg_write(0x7a1, 0x28001044u);
        uint32_t td1 = reg_read(0x7a1);
        printf("trigger: tdata1 reads 0x%08x, address 0x%08x\n", td1, P);
        CHECK((td1 >> 28) == 2, "tdata1.type = %u (2 = match control)", td1 >> 28);
        wr(DMCONTROL, 0x40000001);
        bool ack = wait_status(0x20000, 0x20000, 200);
        wr(DMCONTROL, 0x00000001);
        bool hit = ack && wait_status(0x300, 0x300, 400);
        CHECK(hit, "trigger: halted again after resume");
        if (hit) {
          uint32_t dcsr = reg_read(0x7b0), dpc = reg_read(0x7b1);
          printf("trigger hit: dpc=0x%08x dcsr cause %u\n", dpc, (dcsr >> 6) & 7);
          CHECK(((dcsr >> 6) & 7) == 2, "trigger: dcsr.cause = %u (2 = trigger)", (dcsr >> 6) & 7);
          CHECK(dpc == P, "trigger: dpc 0x%08x == breakpoint address 0x%08x", dpc, P);
        }
        // breakpoint at an address that is reached by running: another pc of the loop seen during the single steps
        uint32_t A = 0;
        for (int k = 0; k < nvis; k++) if (vis[k] != P) { A = vis[k]; break; }
        CHECK(A != 0, "second breakpoint: an address different from 0x%08x was seen", P);
        if (A) {
          reg_write(0x7a2, A);
          wr(DMCONTROL, 0x40000001);
          bool a2 = wait_status(0x20000, 0x20000, 200);
          wr(DMCONTROL, 0x00000001);
          bool h2 = a2 && wait_status(0x300, 0x300, 400);
          CHECK(h2, "second breakpoint: halted after running to 0x%08x", A);
          if (h2) {
            uint32_t c3 = reg_read(0x7b0), d3 = reg_read(0x7b1);
            printf("second breakpoint: dpc=0x%08x (set 0x%08x, resumed from 0x%08x) dcsr cause %u\n", d3, A, P, (c3 >> 6) & 7);
            CHECK(((c3 >> 6) & 7) == 2 && d3 == A, "second breakpoint: cause %u dpc 0x%08x", (c3 >> 6) & 7, d3);
          }
        }
        reg_write(0x7a1, 0x28000040u);                                         // execute bit off: trigger disabled
        wr(DMCONTROL, 0x40000001);
        CHECK(wait_status(0x20000, 0x20000, 200), "final resume acknowledged");
        wr(DMCONTROL, 0x00000001);
      }
    }
  }
  long guard = 0;
  while (!done && guard < 3000000) { tick(); guard++; }
  CHECK(done, "firmware reached DONE (run_cycles=%ld)", run_cycles);
  printf("DONE run_cycles=%ld (ticks include JTAG time)\n", run_cycles);

  // ---- read back and compare
  t->rst_ni = 0;
  for (int i = 0; i < 5; i++) tick();
  t->ld_req_i = 1; t->ld_we_i = 0;
  long diffs = 0; std::vector<uint32_t> dumpv(SRAM_WORDS);
  for (int i = 0; i < SRAM_WORDS; i++) {
    t->ld_addr_i = 4 * (uint32_t)i;
    t->clk_i = 0; t->eval(); t->clk_i = 1; t->eval();
    if (!t->ld_rvalid_o) { printf("FAIL: loader read %d no rvalid\n", i); return 1; }
    dumpv[i] = t->ld_rdata_o;
    t->clk_i = 0; t->eval();
  }
  for (int i = 0; i < SRAM_WORDS; i++) if (dumpv[i] != ref[i]) { if (diffs < 12) printf("  word 0x%06x: got 0x%08x ref 0x%08x\n", 4 * i, dumpv[i], ref[i]); diffs++; }
  printf("dump differs from the reference in %ld words\n", diffs);
  printf("%s: %ld check failure(s)\n", fails ? "FAILED" : "PASSED", fails);
  delete t;
  return fails ? 1 : 0;
}
