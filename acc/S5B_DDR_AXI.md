# S5b: weights in DDR through an AXI4 read master (11-21)

Update 11-22: the same top also runs the int8 weights image (see `w8/W8_I1.md`), bit-identical, +7 % cycles in the
DDR model (fp32: +15 %). Timing (OOC, final RTL = int8 mode + request FIFO + registered external flag): **125 MHz
closed, WNS +0.155 ns**, 0 failing, LUT 59,272, URAM 32, DSP 93. **150 MHz not closed**: best WNS -0.001 ns, other
runs -0.263 / -0.832 ns (critical path moves between the CPU branch to imem address path and FPU internals; the
design has no margin at 150 MHz). Two RTL changes came from synthesis: the external-read decision is a per-command
registered flag (`EXT_BELOW`/`m_ext_o` in gemv_acc) and `axi_ext_rd` has a 4-entry request FIFO, so the request
address no longer reaches the grant. `NO_TRIGGERS=1` (fpga/prepare.py, FPGA work copy only) removes the unused debug
triggers; simulation with that core is identical (cycles and the 2 MiB dump) for an fp32 and an int8 image.

Conclusion: the weight region can be served from DDR by a read-only AXI4 master with **bit-identical results**
to the on-chip-weights top (ctx 1/128/512 single steps and an 8-token generation; only timing words differ).
Cost in simulation (DDR model: 40 cycles latency, 12.8 B/cycle): about +14 to +31 % of a step at ctx 512 to ctx 1,
mostly a fixed ~50K cycles per step (weights are streamed once per step). Not run on a board; 150 MHz synthesis
result below. The 125 MHz bitstream (`chip_axi_top`, weights on chip) is untouched.

## What was added
| File | Role |
|---|---|
| `acc/axi_ext_rd.sv` | Read-only AXI4 master (128-bit, INCR). Bridges soc_chip's external accelerator line port and CPU word port. Merges consecutive accelerator lines into bursts (MAXB 16, never across 4 KB), issues after WT idle cycles or when the next request is not the next line, limits requested-but-not-returned lines to CRED (48; soc_chip's external line FIFO holds 64). One AXI ID, R always ready. |
| `acc/chip_axi_ddr_top.sv` | Board top: soc_chip (`WEIGHTS_ONCHIP=0`, SRAM 1 MiB at 0x100000) + `axi_ext_rd` + the AXI4-Lite control slave. Adds registers DDR_BASE (0x200_0010, 4 KB aligned physical address of the weight image), N_BURSTS, N_LINES, STATUS bit1 = bus error. Weights are written to DDR by the PS (not through the slave). CPU reads of 0..0xFFFFF go to DDR; other external accesses (DONE write) stay local; responses are kept in order. |
| `sim_axi_ddr.cpp` | Verilator driver: PS flow through AXI4-Lite, plus an AXI4 memory model (`SIM_DDR_LAT` 40, `SIM_DDR_BW` 12.8 B/cycle, `SIM_DDR_OUT` 8, `SIM_DDR_BASE`). |
| `build_sim.sh` | `TOP=chip_axi_ddr_top ./build_sim.sh` -> `obj_axi_ddr/`; `AXI_MAXB / AXI_WT / AXI_CRED` options. |
| `fpga/prepare.py` | `WITH_DDR=1` adds the two files to the synthesis list (off by default, so the board build is unchanged). |

## Verification (measured)
Option A full offload, `prof/chip_full_opta_d2/image_<ctx>.bin`, board flow (AXI4-Lite load, run, read back), RUN->DONE cycles:
| ctx | on-chip weights | DDR weights | difference | bytes differing in the 2 MiB dump |
|---|---:|---:|---:|---:|
| 1 | 157,433 | 207,376 | +49,943 (+31.7 %) | 6 (timing words only) |
| 128 | 214,253 | 264,196 | +49,943 (+23.3 %) | 6 |
| 512 | 382,966 | 432,909 | +49,943 (+13.0 %) | 8 |
The differing bytes are the per-step cycle record (0x1AD000..), 0x1AFF00 and a stack word (0x1FFF94), all cycle
counters; tokens, KV cache and logits regions are identical. The offset is the same for every context (about 65K
lines = 1 MiB of weights per step, 8,689 bursts, average 7.46 lines per burst, no bus errors, no FIFO overflow).
Of the +49,943 cycles, about 768 CPU word reads at about 41 cycles each (boot-time copies) are an estimated
~31K one-time cost; this split was not measured separately.

8-token generation (`gen/out_8_O2u_opta_accfull_d2_L0_G1`): 1,457,596 vs 1,263,796 cycles (+15.3 %), dump identical except timing words.

## AXI master tuning (8-token image, measured)
| CRED | cycles | note |
|---|---:|---|
| 32 | 1,618,148 | in-flight window (512 B) below latency x bandwidth: the bottleneck |
| 48, 56 | 1,457,596 | saturated; MAXB 8 vs 16 and WT 1 vs 3 made no difference |
Sensitivity at CRED 48: latency 20 -> 1,422,916; latency 80 -> 1,844,084 (+26.5 %); bandwidth 16 -> 1,420,132;
bandwidth 8 -> 1,837,220. For latency x bandwidth above about 768 B the window limits throughput; the limit is
soc_chip's 64-line external FIFO (`EQ`), which must grow if the real DDR latency is longer.

## Row/bank DRAM model in the AXI memory model (11-22, measured)
`sim_axi_ddr.cpp` has an optional DDR4 channel model (`SIM_ROWBANK=1`; rules of `ddr/ddr_model.py`: open page, 4 bank
groups x 4 banks, tRCD/tRP/tRAS/tRC/tRTP, tCCD_S/L, tRRD_S/L, tFAW, refresh; `SIM_DRAM_PAGE`, `SIM_DRAM_MAP` = bgint|rowseq,
`SIM_CORE_MHZ` 125, `SIM_DDR_LAT` = fixed latency added on top). Default off: the results above are unchanged.
8-token images, DDR board top (cycles; accelerator stall cycles in the counter):
| | fixed latency 40 | row/bank, bgint, 8 KB | 4 KB | 2 KB | rowseq 8 KB |
|---|---:|---:|---:|---:|---:|
| int8 | 1,343,898 | 1,351,707 (+0.6 %, hit 91.0 %) | 1,351,707 (90.6 %) | 1,351,813 (89.6 %) | 1,352,002 (96.8 %) |
| fp32 | 1,458,156 | 1,486,282 (+1.9 %, hit 96.6 %) | 1,486,329 (96.0 %) | 1,486,329 (94.7 %) | 1,486,761 (98.4 %) |
Fixed latency 20 / 60 on top of the row/bank model: int8 1,315,098 / 1,394,715; fp32 1,438,909 / 1,658,202.
Reading: for one tile streaming its weights the row/bank effects are small (<= 2 %); page size and mapping change the hit rate
but not the cycles, because the run is latency bound and the tile uses about a tenth of the channel. The model has one
master: row conflicts between two tiles sharing a channel (`ddr/ddr_model.py`: 24 % efficiency at 128 B alternation, 91 % at 8 KB)
cannot be seen with it. DRAM timing values are from memory and not checked against a controller.

## Limits and what is not done
- The default DDR model has no row/bank effects (optional `SIM_ROWBANK` model above, single master), no AXI slave stalls. The real HP port / controller behaviour is unknown.
- Weights must be at DDR_BASE + address (0..1 MiB for 260K). The 15M layout (weights about 60 MB) needs a new
  address map: the S5a layout puts the SRAM at 0x100000, which cannot coexist with a larger weight region.
- No prefetch/double buffer beyond the accelerator's own FIFOs; no pre-tiled weight layout; no write path.
- Not tested on hardware; PS side must allocate a contiguous, 4 KB-aligned DDR buffer and write DDR_BASE.
