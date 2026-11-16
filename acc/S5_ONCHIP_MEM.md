# S5a — CPU instruction/data memory and KV/activation SRAM in RTL (11-15)

Conclusion: `acc/soc_chip.sv` puts the 16 KB instruction memory and the 1 MB on-chip SRAM into RTL around
`soc_top`. Only the DDR weight region and the sim MMIO stay outside. With SRAM read latency 1 and ideal
external memory, the chip sim is **byte- and cycle-identical** to the `soc_top` sim (HOLD, SW baseline,
Option A full offload). With the DDR model, the measured forward cycles and all data are identical; only boot
timing differs (see below).

## Memory map (unchanged addresses)
| Region | Address | Size | In RTL | FPGA resource (intended) |
|---|---|---|---|---|
| imem (code, trap vector) | 0x0100_0000 | 16 KB | `soc_chip` `imem`, 1-cycle read, loader write port | BRAM |
| KV cache | 0x0010_0000 – 0x001A_0000 | 640 KB | `sram_dp` (one 1 MB array) | URAM (`RAM_STYLE "ultra"`) |
| activations, RMS weights copy, prompt/tokens/cycles | 0x001A_0000 – 0x001B_4000 | 80 KB | 〃 | 〃 |
| control: .rodata/.data/.bss, stack | 0x001B_4000 – 0x0020_0000 | 304 KB | 〃 | 〃 |
| weights (model) | 0x0000_0000 – 0x0010_0000 | 1 MB | **external** (`acc_*` line port, `data_*` CPU port) | PS DDR4 via HP port (S5b) |
| sim MMIO (DONE, step log) | 0x2000_0000 | — | external `data_*` | — |

## Structure
- `sram_dp`: 65,536 × 128-bit true dual port with byte enables, registered read (`SRAM_RLAT` 1 or 2).
  Port A = CPU data (32-bit word of the line), port B = accelerators (128-bit line read, 32-bit write).
- CPU data port: SRAM vs external decode. An SRAM grant waits while an external response is pending beyond
  this cycle (and vice versa), so responses stay in order.
- Accelerator port: SRAM lines vs external (DDR) lines in request order. A 256-entry tag FIFO plus fall-through
  data FIFOs (SRAM 32, external 64 lines) return them in order; a granted SRAM read waits for room.
- `scan_cg_en_i = !rst_ni`: the clock gates must be open during reset. With it tied to 0, the CPU FPU divider
  never granted its first request (found in sim: the HOLD run hung at the first `fdiv.s`).
- Simulator (`sim.cpp -DCHIP`, `TOP=soc_chip ./build_sim.sh` → `obj_chip/`): preloads imem/SRAM through
  their public arrays, dumps the SRAM at the end, and drives only the external ports (same DDR model).

## Verification (facts)
| Check | Result |
|---|---|
| HOLD ctx 1/128/512 on `obj_chip` | dumps identical to `base_*.bin` (except the cycle word); cycles 4,501,912 / 7,937,566 / 18,381,795 = `soc_top` D2 |
| SW baseline profile (`chip_gen_O2u_d2`) | cycles = `gen_O2u_d2` exactly, dumps identical |
| Option A full offload profile, ideal (`chip_full_opta_d2`) | cycles 147,875 / 204,175 / 373,168 = `acc_full_opta_d2`, dumps identical |
| Option A full offload, DDR model (`chip_ddr_full_opta_d2`) | measured cycles identical; one stack word differs (a boot-time `mcycle` value, 30,324 vs 30,500) |

The DDR-model difference is expected. The old `sim.cpp` model held the CPU grant low in the cycle a DDR load
returns, which also blocked SRAM accesses. In RTL the SRAM is a separate port, so boot (176 DDR loads in the
RMSNorm-weight copy) is 176 cycles faster. The measured forward window has no CPU DDR loads in full offload.

## Not done / unverified
- **S5b: AXI4 master for the DDR port** (burst coalescing of the accelerator's line stream, CPU single reads).
  Needed for the board (⑤); the external port today is the simple line protocol served by the sim model.
- SRAM/imem initial contents on the board: the loader port writes imem; .rodata/.data in SRAM also need a
  load path (PS via AXI) — not implemented.
- Timing with the 1 MB URAM at read latency 1 → S6 synthesis.

---

# 11-16 update — weights on chip (Decision 11-14 "260K all on-chip"), board top with AXI4-Lite

Correction: the 11-15 plan item "S5b AXI4 master for the DDR weight port" did not follow the Notion
Decision of 11-14 (260K entirely on chip, fp32, no DDR). Following that Decision, the weights move
into the on-chip SRAM. The AXI4 master moves to the 15M scope.

## What changed
| Part | Change |
|---|---|
| `soc_chip` | `WEIGHTS_ONCHIP=1` (default): SRAM = 0x0000_0000 – 0x0020_0000, 2 MiB = weights 1 MiB + KV/activations/control 1 MiB. `=0` keeps the S5a layout (weights through the external port, sim DDR model). |
| `sram_dp` | Synthesis: `xpm_memory_tdpram` (`MEMORY_PRIMITIVE "ultra"`, `WRITE_MODE "no_change"`, 8-bit byte writes). Plain RTL inference fell back to 259 BRAM tiles (Vivado "invalid write mode") and missed 150 MHz by −1.483 ns (9,760 endpoints). Simulation: the same behavioural array as before. |
| imem | `ram_style "block"` and a single read port (CPU fetch or loader). URAM imem missed setup on EN/ADDR (−1.58 ns); two read statements prevented BRAM inference. |
| loader port | `ld_*` on `soc_chip`: word read/write of imem or SRAM while the core is in reset (SRAM shares the CPU's port A). |
| `chip_axi_top` | Board top: AXI4-Lite slave. SRAM window 0x000_0000, imem window 0x100_0000, CTRL.RUN (core reset release), STATUS.DONE (firmware write to 0x2000_0000), DONE value, cycle count. |
| `sim_axi.cpp` | `TOP=chip_axi_top ./build_sim.sh` → `obj_axi/`. Runs the PS flow through AXI4-Lite only: load, run, poll DONE, read the SRAM back, dump. |

## Verification (facts)
| Check | Result |
|---|---|
| HOLD ctx 1/128/512, weights on chip | dumps identical to `base_*.bin` (except cycle word), cycles = soc_top D2 |
| Option A full offload, weights on chip | 147,875 / 204,175 / 373,168 cycles = the ideal-memory references, KV + output identical |
| SW baseline, weights on chip | 3,041,363 / 5,611,118 / 13,425,011 = `gen_O2u_d2` |
| DDR variant (`CHIP_WEIGHTS=ddr`) | Option A + DDR model 168,278 / 224,578 / 393,571 = S5a results |
| Board flow (AXI4-Lite only) vs backdoor preload | 6 runs (HOLD ×3, Option A ×3): whole 2 MiB dump byte-identical. Loading 265K–429K non-zero words takes 0.8–1.3M cycles in sim. |

With the weights on chip there is no DDR latency: the 260K performance is the ideal-memory column
(Option A ctx512 373,168 cycles = 36.0×, E2E 512 133,803,651 cycles = 31.5×).

## Synthesis (in progress, `fpga/run_chip.sh`, top `chip_axi_top`, 150 MHz)
- Synthesis stage: URAM 64 (SRAM 2 MiB), BRAM 7 tiles (imem 4 + exp2 tables 3), DSP 85.
- Synthesis-stage estimate WNS −1.595 ns on CPU fetch address → imem BRAM address (route pending).
