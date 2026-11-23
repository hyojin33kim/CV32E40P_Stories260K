# xsim vs Verilator: findings (11-22 .. 11-23)

## Conclusion
The disagreement between Vivado xsim and Verilator was **two xsim evaluation problems, not a hardware defect in the RTL**.
With both worked around (in the xsim work copy only), the full chip runs to DONE in xsim and the **2 MiB memory dump is byte-identical to
Verilator's** (`run_xsim.sh prof/chip_full_opta_d2/image_1.bin`, 157,433 cycles counted by the testbench vs 157,437 by sim.cpp).

| # | symptom in xsim | cause | evidence | workaround (work copy only) |
|---|---|---|---|---|
| 1 | FPU MUL/ADD/I2F wrong (671/1402 vectors right) | xsim returns the wrong value for a **variable-index read** of `fpnew_pkg::FP_ENCODINGS` (a packed array of packed structs): `exp_bits` is 7 for every format, so bias is 63 and the product exponent is off by 64 | minimal repro `fpga/xsim/tb_fpfmt.sv` (constant index and `case` are correct, variable index is wrong); with the patch 1402/1402 RTL and 1402/1402 on the synthesized netlist | `fpga/xsim/xsim_workaround.py`: `fp_width/exp_bits/man_bits/bias` rewritten with constant-index `case` |
| 2 | full chip never reaches DONE: VFU stays in state XS (softmax2) | `acc/vfu.sv` calls the function `rd_ok()` inside continuous assigns (`x_req`, `sum_in`, `max_go`). The function reads `rd_v_q/rd_st_q/rd_elem_q`, which are **not arguments**; xsim did not re-evaluate the assign when only those changed, so `x_req` stayed 0 | probe `XSPROBE` in `tb_chip.sv`: at cycle 10,037 every term of `x_req` is 1, `x_req` is 0, and the same function called from the testbench returns 1 | `xsim_workaround.py`: `rd_ok(S, E)` inlined as `(rd_v_q && rd_st_q == S && rd_elem_q == E)` in the work copy (5 call sites) |

Whether the xsim behaviour in #2 is a simulator bug or allowed by the LRM (an assign is sensitive to function arguments, not to the variables a
function reads) was **not checked against the standard**. Either way the RTL style is fragile; see "Open items".

## What was verified
- Verilator and the synthesized FPU netlist were correct all along (FPU: 1402/1402, netlist and RTL, with the patch).
- CPU data-port trace, xsim vs Verilator: 4,462 events identical up to cycle 9,910 (`fpga/xsim/compare_trace.py`, store responses ignored because
  Verilator's 2-state value 0 and xsim's x are both "don't care"); the first stall is the VFU in state XS.
- Full chip with both workarounds: DONE, dump equal over the whole 2 MiB.

## Retracted
- "The xsim hang is caused by uninitialised SRAM (testbench loads only non-zero words)": the trace difference that suggested it was the
  don't-care store response. The testbench now loads every word anyway (it matches the board flow), but it is not the cause.

## Not verified
- The earlier numbers (cycles 4,347,318 vs 4,501,912, 5,732 bytes different) were **not re-run** with only one of the two patches, so how much each
  patch contributed to that old difference is not separated.
- The synthesized **full-chip** netlist (functional simulation of the post-synthesis netlist) and the **board** were not run. Only the FPU was checked
  on the netlist. "Hardware equals Verilator" is therefore still supported by RTL simulation plus FPU netlist only.
- The 4-cycle difference between 157,433 (testbench) and 157,437 (sim.cpp) is assumed to be the counting convention (sim.cpp subtracts 5 after reset
  in its trace); not checked further.

## How to use
```
fpga/xsim/run_xsim.sh <image.bin> [workdir]          # applies xsim_workaround.py to the work copy (FIXFMT=0 disables it)
TRACE_N=200000 fpga/xsim/run_xsim.sh <image.bin>     # CPU data-port trace -> <workdir>/trace_xsim.txt (+ IF / VFU / APU / XSPROBE lines in 9900..10300)
SIM_TRACE_CPU=200000 obj_chip_trace/Vsoc_chip <image> <dump>   # Verilator side (build: TRACE=1 TOP=soc_chip ./build_sim.sh)
python3 fpga/xsim/compare_trace.py trace_verilator.txt trace_xsim.txt
fpga/xsim/run_fpu_test.sh                            # FPU 1402-vector check; use it as a tool check before trusting an xsim result
```
Before running xsim: nothing else heavy running (Vivado ran out of memory next to a Verilator build), and afterwards check `tasklist.exe` for a left-over
`xsimk.exe` (it holds the project folder).

## Open items
- Decide whether to make `rd_ok` robust in the repository RTL (pass `rd_v_q/rd_st_q/rd_elem_q` as arguments or inline it). No functional change, but it
  needs the quick regression (42 items) and a re-synthesis check, so it was **not done**.
- The same pattern (function reading non-argument variables inside an `assign`) may exist elsewhere; not searched.
- Report the `FP_ENCODINGS` case to the tool vendor if wanted; `tb_fpfmt.sv` is a ready minimal repro.
- Post-synthesis full-chip simulation and the board run (`docs/BOARD_BRINGUP.md`).
