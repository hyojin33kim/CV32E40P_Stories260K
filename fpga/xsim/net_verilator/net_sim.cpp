// Port-level driver of the full-chip simulation in Verilator (D4, V-S1), same protocol as fpga/xsim/tb_chip.sv and the board flow:
//   1. core in reset: write imem (4096 words at 0x0100_0000) and every SRAM word (524288 words, zeros included) through the loader port
//   2. release reset, run until the firmware writes 0x2000_0000 on the external data port (DONE)
//   3. core in reset again: read the whole SRAM back through the loader port and write it as a 2 MiB binary
// It touches only ports, no internal signal, so it drives the post-synthesis netlist (top net_top) and the RTL soc_chip alike.
// Build with  -CFLAGS -DVNAME=Vnet_top   (RTL check: -CFLAGS -DVNAME=Vsoc_chip -CFLAGS -DRTL_TOP).
// usage: <sim> <image.bin> <dump.bin> [+MAXCYC=n] [+LOADMAX=words] [+PROGRESS=cycles]
//   MAXCYC: stop after n run cycles (speed measurement, no dump). LOADMAX: load only that many SRAM words (speed measurement).
// Progress lines carry the wall time so a stuck or slow run is visible at once (rule R13).
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>
#include "verilated.h"
#define STR2(x) #x
#define STR(x) STR2(x)
#define HDR(n) STR(n.h)
#include HDR(VNAME)
#define VTOP VNAME

static const int SRAM_WORDS = 524288, IMEM_WORDS = 4096;
static const uint32_t IMEM_BASE = 0x01000000u, DONE_ADDR = 0x20000000u;
static VTOP* t;
static uint64_t ticks = 0;
static double now() { timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec * 1e-9; }

// One clock period. Inputs are set while clk is low (as the testbench does at negedge); the external data port is answered one cycle
// after the request, like tb_chip.sv: d_rvalid <= d_req && rst_n at every rising edge, done set on a write to DONE_ADDR.
static bool done = false, rvalid_next = false;
static void tick() {
  t->clk_i = 0; t->eval();
  bool req = t->data_req_o, we = t->data_we_o;
  uint32_t addr = t->data_addr_o;
  bool rst = t->rst_ni;
  rvalid_next = req && rst;
  if (rst && req && we && addr == DONE_ADDR) done = true;
  t->clk_i = 1; t->eval();
  t->data_rvalid_i = rvalid_next;
  t->clk_i = 0; t->eval();
  ticks++;
}

static void ld_write(uint32_t a, uint32_t d) {
  t->ld_req_i = 1; t->ld_we_i = 1; t->ld_addr_i = a; t->ld_wdata_i = d; tick();
  t->ld_req_i = 0; t->ld_we_i = 0; tick();
}

static long arg(int argc, char** argv, const char* key, long def) {
  size_t n = strlen(key);
  for (int i = 3; i < argc; i++) if (!strncmp(argv[i], key, n)) return atol(argv[i] + n);
  return def;
}

int main(int argc, char** argv) {
  if (argc < 3) { fprintf(stderr, "usage: %s image.bin dump.bin [+MAXCYC=n] [+LOADMAX=n] [+PROGRESS=n]\n", argv[0]); return 2; }
  long maxcyc = arg(argc, argv, "+MAXCYC=", 0), loadmax = arg(argc, argv, "+LOADMAX=", 0), progress = arg(argc, argv, "+PROGRESS=", 20000);
  FILE* f = fopen(argv[1], "rb");
  if (!f) { perror(argv[1]); return 2; }
  std::vector<uint8_t> img(IMEM_BASE + IMEM_WORDS * 4);
  size_t got = fread(img.data(), 1, img.size(), f);
  fclose(f);
  if (got != img.size()) { fprintf(stderr, "image %s: %zu bytes, expected %zu\n", argv[1], got, img.size()); return 2; }
  auto word = [&](size_t byte_off) { uint32_t w; memcpy(&w, &img[byte_off], 4); return w; };

  Verilated::commandArgs(argc, argv);
  t = new VTOP;
  t->clk_i = 0; t->rst_ni = 0; t->fetch_enable_i = 1;
  t->ld_req_i = 0; t->ld_we_i = 0; t->ld_addr_i = 0; t->ld_wdata_i = 0;
  t->data_gnt_i = 1; t->data_rvalid_i = 0; t->data_rdata_i = 0;
#ifdef RTL_TOP   // the netlist wrapper net_top ties these inside; the RTL soc_chip has them as ports
  t->acc_gnt_i = 1; t->acc_rvalid_i = 0;
  for (int i = 0; i < 4; i++) t->acc_rdata_i[i] = 0;
#endif
  double t0 = now();
  for (int i = 0; i < 10; i++) tick();

  for (int i = 0; i < IMEM_WORDS; i++) ld_write(IMEM_BASE + 4 * i, word(IMEM_BASE + 4 * i));
  int nload = loadmax > 0 ? (int)loadmax : SRAM_WORDS;
  long nz = 0;
  for (int i = 0; i < nload; i++) {
    uint32_t w = word(4 * (size_t)i);
    ld_write(4 * (uint32_t)i, w); if (w) nz++;
    if (progress && (i % 65536) == 65535) printf("NS loading %d/%d words, %.0f s, %.0f ticks/s\n", i + 1, nload, now() - t0, ticks / (now() - t0)), fflush(stdout);
  }
  printf("NS loaded imem %d words, sram %d words (%ld non-zero) after %.1f s, %llu ticks (%.0f ticks/s)\n", IMEM_WORDS, nload, nz, now() - t0,
         (unsigned long long)ticks, ticks / (now() - t0));
  fflush(stdout);

  double t1 = now();
  t->rst_ni = 1;
  long run_cycles = 0;
  while (!done) {
    if (maxcyc > 0 && run_cycles >= maxcyc) {
      printf("NS MAXCYC reached run_cycles=%ld, %.1f s, %.0f cycles/s (no dump)\n", run_cycles, now() - t1, run_cycles / (now() - t1)); return 0;
    }
    tick(); run_cycles++;
    if (progress && run_cycles % progress == 0) printf("NS running %ld cycles, %.0f s, %.0f cycles/s\n", run_cycles, now() - t1, run_cycles / (now() - t1)), fflush(stdout);
  }
  printf("NS DONE run_cycles=%ld, %.1f s\n", run_cycles, now() - t1);
  fflush(stdout);
  if (loadmax > 0) { printf("NS LOADMAX set: no dump\n"); return 0; }

  t->rst_ni = 0;
  for (int i = 0; i < 5; i++) tick();
  std::vector<uint32_t> dump(SRAM_WORDS);
  t->ld_req_i = 1; t->ld_we_i = 0;
  for (int i = 0; i < SRAM_WORDS; i++) {   // request while clk low, captured at the rising edge, data valid right after it
    t->ld_addr_i = 4 * (uint32_t)i;
    t->clk_i = 0; t->eval();
    t->clk_i = 1; t->eval();
    if (!t->ld_rvalid_o) { fprintf(stderr, "NS loader read %d: no rvalid\n", i); return 1; }
    dump[i] = t->ld_rdata_o;
    t->clk_i = 0; t->eval();
  }
  FILE* o = fopen(argv[2], "wb");
  fwrite(dump.data(), 4, SRAM_WORDS, o);
  fclose(o);
  printf("NS WROTE %s (%d bytes), total %.1f s\n", argv[2], SRAM_WORDS * 4, now() - t0);
  delete t;
  return 0;
}
