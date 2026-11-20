# P1 report: precision gate, DDR model, CPU residual, board integration

Date 2026-11-20, branch `worktree-g0-repro`. Status words: **measured** = produced by a command in this repo
today; **model** = output of a first-order model, not validated against hardware; **estimate** = hand calculation.

## 1. Precision gate (measured, host)

`quant/make_run_quant.py` generates `quant/run_quant.c` (llama2.c with fake quantization of the matmul
weights, matmul input activations and the KV cache; fp32 arithmetic on dequantized values, so it measures the
accuracy of the quantized numbers, not of a specific MAC implementation). `quant/eval_quant.py 512` runs 4 prompts
x 512 steps and writes `quant/results/gate_512.json`. The `fp32 (check)` row reproduces the original model exactly
(nll_delta 0, argmax 1.000), which validates the harness.

Primary metric `nll_delta` = mean negative log-likelihood of the fp32 model's own greedy tokens under the quantized
model minus the same under fp32 (nats/token; fp32 itself is 0.49 to 0.52 on these prompts).
`argmax` = fraction of positions where the quantized model picks the fp32 token (teacher forced).

| config | nll_delta | argmax | logit rel L2 | free-run first divergence (min over prompts) |
|---|---:|---:|---:|---:|
| fp32 (check) | +0.0000 | 1.000 | 0.0000 | none |
| W8 g32 | +0.0009 | 0.990 | 0.0076 | 29 |
| W8A8 g32 | +0.0001 | 0.985 | 0.0115 | 29 |
| W8A8 g128 | +0.0032 | 0.980 | 0.0141 | 6 |
| W8A8 per-row (one scale per row) | +0.0022 | 0.983 | 0.0151 | 15 |
| W8A8 g32 + KV8 | +0.0032 | 0.981 | 0.0182 | 33 |
| W4 g16 | +0.1011 | 0.850 | 0.1210 | 3 |
| W4 g32 | +0.1303 | 0.841 | 0.1498 | 1 |
| W4 g64 | +0.1772 | 0.820 | 0.1531 | 4 |
| W4A8 g32 | +0.1314 | 0.843 | 0.1501 | 1 |
| W4A8 g32 + KV8 | +0.1320 | 0.843 | 0.1513 | 1 |
| W4 g32 + KV4 | +0.9993 | 0.572 | 0.2638 | 0 |

Reading (facts from the table, interpretation marked):
- **int8 weights + int8 activations (+ int8 KV) cost at most 0.003 nats/token** with any tested group size, down
  to one scale per row. Interpretation: per-row scale is enough, which simplifies the integer lane (no per-group
  scale multiply inside a row).
- **Plain round-to-nearest int4 costs 0.10 to 0.18 nats/token and agrees with fp32 on only 82 to 85 % of
  positions.** This is a tiny 260K model with no calibration; GPTQ/AWQ-style methods or QAT may close part of
  the gap but were **not tested**.
- **int4 KV is not usable** (+1.0 nats); int8 KV is fine.
- Greedy free-run text diverges from fp32 after tens of tokens even for int8 (greedy decoding amplifies any
  difference), so "same tokens as fp32" cannot be the pass criterion for a quantized path.
- Not covered: the embedding table lookup and wcls quantization interplay (wcls shares the embedding table and
  is quantized here, the lookup is not), other prompts and models, integer-accumulation order effects (exact in
  integer arithmetic), perplexity on a held-out text set.
- **Decision needed from the user:** the pass criterion. Candidate: int8 W/A/KV with per-row scales and
  `nll_delta` <= 0.01 and argmax >= 0.97 against the fp32 reference; bit-exactness is then defined against a
  new quantized software reference (as was done for Option A).

## 2. DDR row/bank model (model)

`ddr/ddr_model.py` (output: `ddr/ddr_model_results.md`). DDR4-2400 17-17-17 channel (19.2 GB/s peak), 16 banks
in 4 bank groups, 8 KB page, open-page policy, in-order issue with a lookahead window, refresh. Timing values are
from memory (JEDEC-typical), **not validated against a controller or board**.

| case | efficiency (model) |
|---|---:|
| 1 sequential stream, bank-group-interleaved mapping | 95.7 % (loss = refresh) |
| 1 sequential stream, page-linear mapping (page of one bank, then next) | 64.1 % (tCCD_L 6 vs tCCD_S 4) |
| 2 masters, alternate every 128 B | 23.9 % |
| 2 masters, alternate every 1 KB | 67.6 % |
| 2 masters, alternate every 4 KB | 86.9 % |
| 2 masters, alternate every 8 KB (= page) | 91.4 % |
| 2 masters, alternate every 16 KB | 93.9 % |
| 2 masters, alternate every 32 KB | 95.1 % |

Findings that survive the model's simplifications (interpretation):
1. **Address mapping matters as much as burst size**: page-linear mapping caps a single stream at 64 %.
2. **Pair sharing with a fine interleave is the worst case**: two streams alternating at 128 B keep re-opening
   rows. The model issues in order, so a reordering (FR-FCFS) controller would do better than the small-quantum
   numbers; the numbers at 128 B to 1 KB are therefore pessimistic, the numbers from 8 KB up are not sensitive to this.
3. **A time-slice quantum of at least one page (8 KB) restores >90 %**, which supports the page-aligned
   alternation idea; the gain from 8 to 16 KB is 2.5 points, and the lookahead window (4 to 64) did not matter.
4. Not reproduced: the efficiency drop above 16 KB seen in the Hummingbird paper (it comes from splitting one
   command over 4 ports, which this model has no equivalent of).
- The tile's current DDR sim model (`SIM_DDR*` in `sim.cpp`: latency + burst coalescing + bandwidth cap) was not
  changed. One tile at 16 B/cycle uses about 2.4 GB/s, 12 % of a channel, so it is nowhere near DDR-bound; use the
  numbers above when choosing `SIM_DDR_BW` for pair-sharing studies.

## 3. CPU residual work (measured, `prof/chip_full_opta_d2.txt`, Option A chip simulation)

CPU-executed regions per step (cycles; the GEMV/QK/AV/softmax/SwiGLU regions are accelerator time):

| region | ctx 1 | ctx 128 | ctx 512 |
|---|---:|---:|---:|
| rmsnorm (11 calls) | 17,819 (12.0 %) | 17,817 (8.7 %) | 17,810 (4.8 %) |
| RoPE | 14,961 (10.1 %) | 14,961 (7.3 %) | 14,961 (4.0 %) |
| residual (10 adds) | 5,545 (3.7 %) | 5,545 (2.7 %) | 5,545 (1.5 %) |
| loops, setup, misc | 1,279 (0.9 %) | 1,279 (0.6 %) | 1,279 (0.3 %) |
| **CPU residual total** | **39,604 (26.7 %)** | **39,602 (19.3 %)** | **39,595 (10.6 %)** |
| attention path (QK + softmax + AV) | 17,564 (11.8 %) | 74,386 (36.3 %) | 243,106 (65.0 %) |
| forward total | 148,251 | 205,071 | 373,784 |

Estimated gain of moving work into the VFU (estimate, not implemented):
- residual as a VFU `A[i] += B[i]` command: about 250 cycles per add (64 words loaded twice, stored once, 40 cycles
  command overhead) instead of about 550, so about -2.5K cycles per step.
- rmsnorm: the sum of squares must stay a sequential sum to remain bit-identical with the software, which bounds it
  at about 350 cycles (fadd latency 4 + 1 per element, 64 elements) against about 700 on the CPU; the scalar
  1/sqrt stays on the CPU. About -9K cycles per step. A 4-way partial-sum version (like Option A's softmax) would be
  faster but defines yet another numeric reference.
- RoPE is a pair-wise cross operation (outputs need both elements of a pair plus a cos/sin table); it does not fit the
  VFU's per-element lane structure without a pair mode or pre-permuted weights. Up to -13K cycles per step.
- **Upper bound of rmsnorm + residual offload: -11.5K cycles = 7.8 % at ctx 1, 5.6 % at ctx 128, 3.1 % at ctx 512.**
  Including RoPE: 16 %, 11 %, 6.6 %.
- Recommendation (judgement): **do not implement these VFU commands now.** The gain is small at long context, where
  the attention path (65 % at ctx 512) dominates, and the VFU is already the largest logic block (45 % of tile LUT).
  If the target is long context, spend the effort on attention throughput (QK/softmax/AV); if the target is a
  wider model range, the right step is a programmable VFU, not more fixed commands. This recommendation flips if
  the target workload is mostly short-context chat (ctx <= 128), where the residual is about 19 to 27 %.

## 4. Board integration (P1-1): blocked, no bitstream (measured attempts)

`fpga/bd/run_board.sh 125` builds the ZCU104 block design (Zynq PS + `chip_axi_wrap`, PL clock 125 MHz).
- **Passes:** block design creation, address assignment, `validate_bd_design`, PL0 clock = 125.000 MHz.
- **Fixed on the way:** (1) `registers.svh` must be a project header for the module-reference elaboration;
  (2) `launch_runs -jobs 4` and `-jobs 2` fail with "system resources" errors (zynq IP synthesis);
  (3) a Tcl comment on the same line as a command broke the script.
- **Not solved:** Vivado crashes with `EXCEPTION_ACCESS_VIOLATION` (hs_err_pid*.log) during the synthesis of the
  `chip` module, 5 of 6 attempts with the same RTL and configuration (one out-of-context run at 19:29 completed;
  later out-of-context runs at 20:43, 22:51 (twice) and the global top-level synthesis at 22:57 crashed, the last one
  while sorting areas). The parent Vivado does not notice the dead child and waits indefinitely (a 2 h hang).
  The same RTL (`chip_axi_top`) synthesizes and routes reliably through `fpga/run_chip.sh` (batch `synth_design`),
  so the cause is in the project-run flow or the host environment, not in the RTL. Windows host memory was not
  the limit (about 5.7 of 16 GB free at the last crash). Root cause not found.
- **Result: no `board.bit`, no timing with the PS, nothing run on a board.** The 150 MHz OOC result (WNS +0.005 ns)
  is unchanged and still the only timing evidence.
- `fpga/bd/build_board.tcl` now uses global synthesis (`synth_checkpoint_mode None`) and one job; it is untested to
  completion.
- Options (not tried): build the block design interactively in the Vivado GUI on the host (`run_board.sh 125 <dir> gui`
  opens it), or synthesize the module through the reliable batch flow and import the checkpoint, or retry on another
  machine. A board run additionally needs the PYNQ image and `pynq/run_chip.py`, neither of which has been exercised.
