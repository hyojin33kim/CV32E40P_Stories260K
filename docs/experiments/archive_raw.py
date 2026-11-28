#!/usr/bin/env python3
"""Copies the raw output of experiments from the untracked scratch folder (.scratch) into docs/experiments/raw (tracked) and rewrites
docs/experiments/raw/INDEX.md. Run it after every experiment (rule R12 in docs/LESSONS_LEARNED.md): .scratch is not in git and is the only
place where most raw numbers exist.
 - commit-message drafts (msg*.txt), build logs (*.log), files over 200 KB and binary files are skipped (large traces and memory dumps are regenerable);
 - a file is copied again when it changed (newer mtime or different size);
 - files outside .scratch worth keeping are listed in EXTRA below (name in raw/ -> producer of the content).
The "what is this" column of INDEX.md comes from DESC (known files); for the rest it shows the first line of the file and says that no description exists.
usage: python3 docs/experiments/archive_raw.py"""
import re
import shutil
import time
from pathlib import Path

W = Path(__file__).resolve().parents[2]
S = W / '.scratch'
R = W / 'docs' / 'experiments' / 'raw'
R.mkdir(parents=True, exist_ok=True)
MAX = 200_000

# exact file name or prefix (ending with *) -> description. Only what is known for sure; everything else is listed without one.
DESC = {
 'fpu_after.out': 'xsim FPU test (1,402 vectors) before the workaround: RTL 671/1402 (MUL 301, I2F 201, ADD 229 wrong), synthesized netlist 1402/1402 (11-22)',
 'fpu_net.out': 'same experiment, netlist run repeated: RTL 671/1402, netlist 1402/1402 (11-22)',
 'fpu_workaround.out': 'xsim FPU test with xsim_workaround.py: RTL 1402/1402, netlist 1402/1402 (11-22)',
 'fpu_xsim_new.out': 'extended FPU vectors (3,896), first xsim run: RTL line is a STALE cached result (1402/3896, meaningless), netlist 3896/3896 (11-23)',
 'fpu_xsim_new2.out': 'extended FPU vectors, stale files removed: xsim RTL 3896/3896, netlist 3896/3896 (11-23)',
 'fpuv_run.out': 'Verilator, extended FPU vectors: single and stream mode x two pipeline configs, all 3896/3896, stream statistics (11-23)',
 'axi_ext_rd_1.out': 'acc/tb_axi_ext_rd/run.sh, six parameter sets (first set list incl. TD=1): five PASS, TD=1 FAIL (11-23)',
 'axi_checks.out': 'acc/tb_axi_ext_rd/checks.sh: constraint probes (TD=1/3/6, MAXB>CRED, CRED=8) and five mutation checks (11-23)',
 'a1_overlimit_512.out': 'GEMV mode D at and beyond the 512-word buffers (build obj_soc): limit cases pass, 7 over-limit cases silently wrong (11-23)',
 'a1_overlimit_1024.out': 'GEMV mode D at and beyond the 1024-word buffers (15M build obj_soc_big, TEST_BIG=1): 2 limit cases pass, 6 over-limit cases wrong, 1025x1025 filtered (cases 0) (11-23)',
 'a1_vfu_overlimit.out': 'VFU softmax/divsoftmax/softmax2 with chunk length 512, 513, 520, 1024 (buffer 512): 512 passes, longer chunks silently wrong (11-23)',
 'fpu_xsim_stream.out': 'xsim FPU test with the stream mode: RTL and netlist, single and stream, all 3896/3896, stream statistics per group (11-24)',
 'xsim_net_license_error.txt': 'the xsim error that stops the post-synthesis full-chip simulation: BASIC license, 107,091 instances > 50,000 allowed (11-24)',
 'exp2_q*': 'exhaustive vfu_exp2 check, one quarter of the 2^32 input patterns per file (RTL vs opta/exp2q.h), with wall time (11-25)',
 'vg7.out': 'V-G7: three full-chip xsim runs (A no patch, B rd_ok only, C FPU table only), MAXCYC=600000: A and C no DONE, B DONE 149,074 cycles dump differs 5,718 bytes (11-25)',
 'vg7_a_unbounded.out': 'first V-G7 run of step A, MAXCYC did not take effect (env var not passed to Windows vivado): ran about 3 h to 85M cycles before it was stopped, no result (11-25)',
 'tb_dm*': 'Debug Module JTAG test (dbg/tb_dm) outputs of successive RTL versions (tb_dm6d = final; tb_dm_mut = mutation check, expected FAIL) (11-26)',
 'chip_dm.out': 'DM build 125 MHz synthesis and implementation summary printed by fpga/run_chip.sh, final RTL (11-26)',
 'axi_checks_d7.out': 'acc/tb_axi_ext_rd/checks.sh after the parameter assertions: mutation checks all FAIL (detected); the constraint probes were empty in this run (the simulation stops before it prints its result line), fixed afterwards (11-27)',
 'boot_walkthrough.out': 'cycle-by-cycle view of the first 8,000 cycles after reset release: fetch addresses mapped to fw.dis, function segments, first data accesses, g_busy rises (11-28)',
 'boot_events.out': 'key events of the whole run from the CPU data-port trace (SIM_TRACE_CPU): .bss clear, stack, DONE (11-28); MMIO accesses are not in this trace',
 'g120_route_summary.txt': 'plain chip_axi_top (no Debug Module) at 120 MHz with the guards and observation registers: routed WNS +0.191 ns, utilization, peak memory 13.1 GB (11-28)',
 'dm120_route_summary.txt': 'chip_axi_top WITH the Debug Module at 120 MHz (guards and observation registers in): routed WNS -3.114 ns (timing fails), worst path trigger match register to imem BRAM address, 8.8 ns of which 7.2 ns is routing (11-28)',
 'npu_perf.out': 'DONE cycles and PERF counters of image_1/128/512 on the board-top simulation, the data of the NPU scaling analysis (11-27)',
 'dm_chip_route_summary.txt': 'RISC-V Debug Module build at 125 MHz: routed timing summary (WNS +0.110 ns), utilization, synthesis LUT/register lines (11-26)',
 'xsim_full_after_tbnet.out': 'full-chip RTL xsim rerun after the tb_chip.sv changes for the netlist: DONE run_cycles=157433, dump equal to Verilator (11-24)',
 'a3_conc.out': 'V-A3: four concurrency scenarios (CPU with GEMV, CPU with VFU, VFU started during GEMV, GEMV started during VFU) (11-24)',
 'net_lint*': 'Verilator lint of the post-synthesis soc_chip netlist with the UNISIM models: successive attempts (deassign, specify, tri-state errors), the last ones ran out of memory (11-24)',
 'net_speed_a.out': 'xsim run of the post-synthesis netlist: wall time and the license error (11-24)',
 'trace_compare.txt': 'Verilator CPU data-port trace of 200k cycles: 20,133 events (11-23)',
 'trace_compare2.txt': 'first xsim-vs-Verilator trace compare: first difference was a store response (Verilator 0 vs xsim x), later shown to be a don\'t care (11-23)',
 'xsim_fix.out': 'full-chip xsim with the FPU workaround only: run was stopped after about 15 h without reaching DONE (11-23)',
 'xsim_full.out': 'full-chip xsim with both workarounds: DONE run_cycles=157433, dump equal to Verilator (sim.cpp 157437) (11-23)',
 'xsim_probe.out': 'run that produced the XSPROBE lines (x_req terms) (11-23)',
 'xsim_vfu.out': 'run that produced the VFU state trace (11-23)',
 'xsim_pc.out': 'run that produced the instruction fetch trace (11-23)',
 'xsim_trace.out': 'xsim trace run of the first 200k cycles (11-23)',
 'sweep_ddr.txt': 'DDR sweep ddr_full_opt (speedup vs ideal-memory SW baseline, OVH=4) (11-14)',
 'vfu_test*': 'VFU unit test output (mismatch counts, software and hardware cycles)',
 'repro_*': 'reproduce.sh output (build, regression, profiles, VFU test)',
 'vt_*': 'VFU unit test output (v3 variants, 11-15)',
 'reproduce_quick*': 'reproduce.sh quick output',
 'w8_*': 'int8 weight (I1) end-to-end run result (JSON, 11-21)',
 'tiled_verify.txt': 'pre-tiled weights (CTRL bit2) GEMV test (11-22)',
 'notrig.txt': 'DDR top run with and without trigger cells (NO_TRIGGERS option), cycle counts (11-22)',
 'chip_ddr*_synth.out': 'Vivado out-of-context synthesis/implementation timing summary of the DDR top (one file per attempt)',
 'chip_on125_synth.out': 'Vivado out-of-context timing summary of the on-chip top at 125 MHz (11-22)',
 'board*.out': 'Vivado log of a PS-connected block design build attempt (Tcl output)',
 'cpu_lat*': 'Vivado timing summary for CPU/FPU latency variants (11-15)',
 'cpu_pipe*': 'Vivado timing summary for CPU/FPU pipeline variants (11-15)',
 'cpu_rt*': 'Vivado timing summary (11-15)',
 'pv*': 'Vivado timing summary of a VFU/SoC variant (11-15)',
 'soc_v2.txt': 'Vivado timing summary of the SoC v2 variant (11-15)',
 'r8*': 'accelerator profile of a single step (JSON, 11-13/14)',
}
EXTRA = {
 'fpfmt_repro.txt': ('FMT lines of the minimal xsim reproduction fpga/xsim/tb_fpfmt.sv (variable index gives exp=7/bias=63 for every format)',
                     Path('/mnt/e/fpga_work/fpu_test/fpfmt.out'), re.compile(r'^FMT')),
 'xsim_hang_window_trace.txt': ('xsim trace of cycles 9900..10300: instruction fetch (IF), VFU state (VFU) and the x_req term probe (XSPROBE); shows x_req=0 while every term is 1',
                                Path('/mnt/e/fpga_work/xsim_fix/trace_xsim.txt'), re.compile(r' (IF|VFU|XSPROBE) ')),
}

def describe(name):
    if name in DESC: return DESC[name]
    for k, v in DESC.items():
        if k.endswith('*') and name.startswith(k[:-1]): return v
        if '*' in k and re.fullmatch(k.replace('.', r'\.').replace('*', '.*'), name): return v
    return None

def is_text(p):
    try:
        p.read_text(); return True
    except (UnicodeDecodeError, OSError):
        return False

copied = skipped = 0
files = sorted(p for p in S.glob('*') if p.is_file() and p.suffix in ('.out', '.txt', '.json') and not p.name.startswith('msg')) if S.exists() else []
for p in files:
    if p.stat().st_size > MAX or not is_text(p): skipped += 1; continue
    d = R / p.name
    if not d.exists() or d.stat().st_size != p.stat().st_size or p.stat().st_mtime > d.stat().st_mtime:
        shutil.copy2(p, d); copied += 1
for name, (desc, src, pat) in EXTRA.items():
    if src.exists():
        lines = [l for l in src.read_text(errors='replace').splitlines() if pat.search(l)]
        (R / name).write_text('\n'.join(lines) + '\n'); copied += 1

rows = []
for p in sorted(R.glob('*')):
    if p.name == 'INDEX.md': continue
    first = next((l.strip() for l in p.read_text(errors='replace').splitlines() if l.strip()), '')[:110]
    d = EXTRA[p.name][0] if p.name in EXTRA else describe(p.name)
    rows.append((p.name, time.strftime('%m-%d %H:%M', time.localtime(p.stat().st_mtime)), p.stat().st_size, d, first))
out = ['# Raw experiment outputs', '',
       'Copied from `.scratch` (not tracked by git) by `docs/experiments/archive_raw.py`. The interpretation of each experiment is in `docs/EXPERIMENT_LOG.md`;',
       'this folder only keeps the numbers as they were printed. A file without a description was archived but its meaning was not checked: the',
       'first line is shown instead, do not trust a guess. Files over 200 KB (traces, memory dumps) are not archived because they can be regenerated.', '',
       '| file | saved | bytes | what it is | first line |', '|---|---|---|---|---|']
for n, t, sz, d, f in rows:
    out.append(f'| `{n}` | {t} | {sz} | {d or "(no description recorded)"} | `{f.replace("|", "/")}` |')
(R / 'INDEX.md').write_text('\n'.join(out) + '\n')
print(f'{copied} copied or refreshed, {skipped} skipped (large or binary), {len(rows)} files in {R}')
