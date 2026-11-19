# CV32E40P × llama2.c Stories260K — bit-exact LLM inference on RISC-V RTL with an FPGA accelerator

A small LLM (llama2.c **Stories260K**) running on a **CV32E40P** (RV32IMFC + FPU) RTL core, then moved step by step
onto hardware accelerators (GEMV engine, vector function unit) **while every result stays bit-identical to the
RISC-V software run**. Target board: **ZCU104** (XCZU7EV). Everything here is verified in simulation and by
Vivado synthesis/implementation; **nothing has been run on a physical board yet**.

한국어: llama2.c Stories260K를 CV32E40P RTL에서 실행하고, 연산을 HW로 옮기면서도 RISC-V 소프트웨어와 bit 단위로
같은 결과를 유지합니다. 상세 기록은 `PROGRESS.md`, 다른 모델(15M 등)에 적용하는 방법은 `docs/PLAYBOOK.md`.

## Status

| | State |
|---|---|
| RTL simulation (Verilator) | verified, all offload levels bit-exact vs the RISC-V software run |
| Vivado synthesis + P&R, 150 MHz, ZCU104 | `chip_axi_top` (CPU + accelerators + on-chip memories + AXI4-Lite) met timing: WNS +0.005 ns, URAM 64, BRAM 7, LUT 24 % |
| Vivado xsim of the full chip, PS integration, board run | **not done / not verified** |

## Results (150 MHz-realizable configuration, simulation cycles)

SW baseline = the same CPU running llama2.c (`-O2 -funroll-loops`, FPU latency 4).

| | SW baseline | all offloaded | + Option A (exp2 softmax/SiLU) |
|---|---:|---:|---:|
| one step, ctx 1 | 3,041,363 | 164,143 (18.5×) | 148,262 (20.5×) |
| one step, ctx 512 | 13,425,011 | 1,454,026 (9.2×) | 373,795 (35.9×) |
| 512-token generation | 4,215,725,794 | 416,300,007 (10.1×) | 133,803,651 (31.5×) |

At 150 MHz that is about 28 s → 0.9 s for 512 tokens. Cycles are simulation results; wall-clock on a board is not measured.
Sources: the "all offloaded" column and the 512-token row are from the `soc_top` simulation; the Option A single-step cycles
are from the chip simulation (on-chip SRAM, slightly more cycles: +0.2–0.3 %).
"Option A" replaces the softmax/SiLU exponent with an integer exp2 and defers the softmax normalization; it defines a
new numeric reference (512 tokens identical to the original, logits rel. L2 ≤ 3.4e-6), and SW, host model and RTL agree
with each other bit for bit.

## Layout

| Path | Content |
|---|---|
| `cv32e40p-master/` | CV32E40P core (vendored, with FPnew), own licenses |
| `acc/` | RTL: `gemv_acc` (MAC lanes), `vfu` + `vfu_lane` + `vfu_exp2` (softmax, SiLU, exp), `soc_top`, `soc_chip` (+ imem, SRAM), `chip_axi_top` (AXI4-Lite board top), `sram_dp` |
| `gen/`, `baseline/`, `firmware.c` | RISC-V firmware (continuous generation, HOLD baseline) and the host golden tool |
| `opta/` | Option A numerics: C model, exhaustive accuracy test, host model generator |
| `prof/`, `vfu/` | zero-overhead profiler, VFU unit test |
| `fpga/` | Vivado scripts and synthesis reports |
| `sim.cpp`, `sim_axi.cpp`, `build_sim.sh` | Verilator drivers and build |
| `reproduce.sh`, `reproduce_check.py` | regression against committed results |
| `docs/` | `PLAYBOOK.md` (stage-by-stage lessons, for the next model), `SIM_GUIDE.md` (how to simulate and view waves) |
| `PROGRESS.md` | index of all stages, results and decisions |

## Quick start (Ubuntu 24.04 / WSL2)

```bash
sudo apt install gcc-riscv64-unknown-elf picolibc-riscv64-unknown-elf python3-numpy gtkwave   # + Verilator 5.038
TOP=soc_top ./build_sim.sh                                   # build the simulator (~5 min)
OPTA=1 GEN_ACC=full python3 gen/run_gen.py 16                # generate 16 steps from "Once upon a time", compare with host
./reproduce.sh quick                                         # regression, ~10 min, expect all items OK
```

Details, options, waveform viewing: [`docs/SIM_GUIDE.md`](docs/SIM_GUIDE.md).

## Verification approach

- host llama2.c ↔ RISC-V: tolerance (logits and KV rel. L2 < 1e-5, token match)
- RISC-V `-Os` ↔ `-O2 -funroll-loops` ↔ accelerator path: **bit-identical** logits, KV and tokens
- accelerators reuse the CPU's FPU module and keep the software's operation order; the exp2 pipeline is checked against
  its C model on all 2³² inputs

## Limitations

- One prompt ("Once upon a time") and greedy decoding were validated; other prompts use the same code but were not checked.
- Stories260K-specific (dim 288 class, 512-entry vocabulary). Larger models need weight streaming from DDR; see `docs/PLAYBOOK.md` §6.
- Timing was measured out-of-context (no PS); the 5 ps margin is expected to need re-checking after the PS is connected.

## Credits and licenses

- [llama2.c](https://github.com/karpathy/llama2.c) (MIT) and its Stories260K model.
- [CV32E40P](https://github.com/openhwgroup/cv32e40p) and [FPnew](https://github.com/pulp-platform/fpnew): Solderpad / Apache licenses,
  see the license files under `cv32e40p-master/`.
- This repository has no license file for its own code yet.
