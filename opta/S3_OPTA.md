# S3 — Option A: exp2q softmax / SiLU, deferred normalization (11-15)

Conclusion: Option A replaces the attention softmax and SiLU exponent with an integer exp2 (`exp2q`).
At ctx512 the softmax drops from 1,129,964 to 64,283 cycles, and the full-offload step from
1,454,026 to 373,168 cycles (D2; **36.0×** the D2 SW baseline). The new numerics are a new reference:
host model, RISC SW and HW are bit-exact with each other, and the model stays within the existing
host tolerance of the original llama2.c (512 tokens identical, logits rel L2 ≤ 3.4e-6).

## Definition (reference numerics, `opta/exp2q.h`, `opta/softmax2.h`)
1. Scores `s_t = q·k_t` (no ÷√8); `m = max s_t`; `y_t = (s_t − m) · K`, K = fp32(log2e/√8) = `0x1.0527dcp-1`
2. `p_t = exp2q(y_t)`: |y| → Q8.23 (round half up), n = ⌊u⌋, 6-bit index into T[i] = 2^(i/64) (Q2.30),
   degree-2 polynomial on the remaining 17 bits (C1, C2 from `opta/fit_exp2q.py`), round half up to 24 bits;
   underflow → +0 (no denormals), |y| ≥ 128 → +inf / +0
3. `sum = (S0 + S1) + (S2 + S3)`, `S_k` = sum of p_t with t ≡ k (mod 4), each in t order from +0.0
4. AV on the unnormalized p (GEMV, unchanged), then `xb[i] /= sum` for the head's 8 outputs
5. SiLU: `x · (1 / (1 + exp2q(x · fp32(−log2e))))`, then × gate (same order as before)

## Verification (facts)
| Check | Result |
|---|---|
| exp2q accuracy, every fp32 input (`opta/test_exp2q.c`) | 2.25e9 finite results: max 1.34 ulp, 94.4% correctly rounded, 0 over 2 ulp; 1.0e9 underflow inputs → 0 |
| `acc/vfu_exp2.sv` vs C model, all 2^32 inputs (`acc/tb_exp2/run.sh`) | 4,294,967,296 inputs, 0 mismatches |
| Host Option A vs original llama2.c, 512 steps (`opta/compare_host.py`) | free-run tokens 512/512 identical; teacher-forced logits rel L2 max 3.4e-6 (mean 4.1e-7), argmax 0 mismatches; KV rel L2 2.0e-7 |
| RISC SW Option A vs host Option A, 8 steps (-Os, -O2) | logits / KV bit-exact every step |
| VFU unit test, 2 seeds × 16,384 elements × 7 commands (incl. softmax2 sums, silu2, regression of 1–5) | 229,376 elements, 0 mismatches |
| Full offload single step vs SW Option A (ctx 1/128/512, ideal and DDR) | KV + output region identical |
| E2E (`acc/run_refs_opta.sh`) | see below |

## Hardware
- `acc/vfu_exp2.sv`: 5-stage pipeline, 1 element/cycle (decode → r·C1, r² → C2·r², table → T·Q → round/pack).
- VFU cmd 6 softmax2: max during load; stream fsub → fmul → exp2 at 1 element/cycle with credit-limited issue
  (32-entry adder queue); one pipelined adder rotates over the 4 partial sums (result forwarded when FPU_LAT > 0,
  the same technique as the GEMV row interleave); 3 final adds; p stored back; sum at MMIO 0x1C.
- VFU cmd 7 silu2: lane op SILU2 (fmul, exp2q, then the existing 1+e / reciprocal / ×x / ×gate chain).
- Commands 1–5 unchanged.

## Single-step profile, D2 (cycles; bit-exact vs SW Option A)
| ctx | full offload (original numerics) | **full offload Option A** | softmax region | SwiGLU | +DDR model | vs D2 SW baseline (original) | vs D2 SW Option A |
|---|---|---|---|---|---|---|---|
| 1 | 164,143 | **147,875** | 3,602 → 3,083 | 35,208 → 12,895 | 168,278 | 20.6× | 20.0× |
| 128 | 482,555 | **204,175** | 281,414 → 18,203 | | 224,578 | 27.5× | 23.3× |
| 512 | 1,454,026 | **373,168** | 1,129,964 → 64,283 | | 393,571 | 36.0× | 27.2× |

D2 SW Option A: 2,960,330 / 4,747,806 / 10,143,044 cycles. The integer exp2q is also cheaper on the CPU than picolibc expf.

## E2E (D2, prompt "Once upon a time", greedy; total cycles over all steps)
| run | 64 steps | 512 steps | 512 steps @150 MHz | bit-exact |
|---|---:|---:|---:|---|
| SW baseline, original numerics (`O2u_d2`) | 235,632,942 | 4,215,725,794 | 28.1 s (18 tok/s) | vs -Os ✔ |
| full offload, original numerics | 15,784,236 (14.9×) | 416,300,007 (10.1×) | 2.78 s | vs -Os ✔ |
| 〃 + DDR model | 17,090,028 (13.8×) | 426,746,343 (9.9×) | 2.84 s | vs -Os ✔ |
| SW Option A (`O2u_opta_d2`) | 217,872,855 | (not run) | | vs -Os Option A ✔ |
| **full offload Option A** | **10,409,428 (22.6×)** | **133,803,651 (31.5×)** | **0.89 s (574 tok/s)** | 64: vs -Os Option A ✔; 512: vs host Option A model, 512/512 steps and KV bit-exact |
| 〃 + DDR model | 11,715,220 (20.1×) | 144,249,987 (29.2×) | 0.96 s | same as above |

Ratios are against the SW baseline with the original numerics (the CPU-only llama2.c). All runs pass the host
criterion; the Option A runs match the host Option A model bit for bit (logits rel L2 0.0).

## FPGA (ZCU104, 150 MHz, D2, DISTRIBUTED) — `fpga/reports_opta_soc/`, `fpga/P6_FPGA_SYNTH.md`
| | route WNS | LUT | FF | BRAM tile | DSP |
|---|---:|---:|---:|---:|---:|
| v2 (before Option A) | +0.025 ns | 49,286 (21.4%) | 16,818 | 0.5 | 39 |
| v2 + Option A, EXPLORE flow | **+0.136 ns** (0 failing) | 54,545 (23.7%) | 18,716 | 3 | 85 |

The first Option A implementation (default flow) missed by −0.137 ns. The path ran from the CPU store address
through the MMIO decode into the VFU `disp_q` clear at command start. That clear is redundant and was removed,
with no change in behavior or cycles. The remaining CPU-FPU path closed with the EXPLORE implementation flow.

## Unverified / what reverses this
- The decision that the new numerics are acceptable rests on one prompt, 512 greedy steps and the existing
  tolerance (rel L2 < 1e-5). A larger model (15M) or sampling could expose the 1.34-ulp exp error. Re-run
  `opta/compare_host.py` there.
