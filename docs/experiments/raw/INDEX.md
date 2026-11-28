# Raw experiment outputs

Copied from `.scratch` (not tracked by git) by `docs/experiments/archive_raw.py`. The interpretation of each experiment is in `docs/EXPERIMENT_LOG.md`;
this folder only keeps the numbers as they were printed. A file without a description was archived but its meaning was not checked: the
first line is shown instead, do not trust a guess. Files over 200 KB (traces, memory dumps) are not archived because they can be regenerated.

| file | saved | bytes | what it is | first line |
|---|---|---|---|---|
| `a1_overlimit_1024.out` | 11-23 23:54 | 1330 | GEMV mode D at and beyond the 1024-word buffers (15M build obj_soc_big, TEST_BIG=1): 2 limit cases pass, 6 over-limit cases wrong, 1025x1025 filtered (cases 0) (11-23) | `simulator obj_soc_big/Vsoc_top, XBUF=YBUF=1024` |
| `a1_overlimit_512.out` | 11-23 23:28 | 1231 | GEMV mode D at and beyond the 512-word buffers (build obj_soc): limit cases pass, 7 over-limit cases silently wrong (11-23) | `simulator obj_soc/Vsoc_top, XBUF=YBUF=512` |
| `a1_vfu_overlimit.out` | 11-23 23:34 | 1670 | VFU softmax/divsoftmax/softmax2 with chunk length 512, 513, 520, 1024 (buffer 512): 512 passes, longer chunks silently wrong (11-23) | `chunk length 512:` |
| `a3_conc.out` | 11-24 23:13 | 1011 | V-A3: four concurrency scenarios (CPU with GEMV, CPU with VFU, VFU started during GEMV, GEMV started during VFU) (11-24) | `scenario 1: finished=True gemv mismatches 0/128, vfu mismatches 0/512, cpu mismatches 0/256, timeouts gemv=0 v` |
| `axi_checks.out` | 11-23 21:59 | 3155 | acc/tb_axi_ext_rd/checks.sh: constraint probes (TD=1/3/6, MAXB>CRED, CRED=8) and five mutation checks (11-23) | `== constraint probes (expected: the unsupported sets fail)` |
| `axi_checks_d7.out` | 11-27 21:06 | 1468 | acc/tb_axi_ext_rd/checks.sh after the parameter assertions: mutation checks all FAIL (detected); the constraint probes were empty in this run (the simulation stops before it prints its result line), fixed afterwards (11-27) | `== constraint probes (expected: the unsupported sets fail)` |
| `axi_ext_rd_1.out` | 11-23 21:58 | 4590 | acc/tb_axi_ext_rd/run.sh, six parameter sets (first set list incl. TD=1): five PASS, TD=1 FAIL (11-23) | `AXI_EXT_RD MAXB=16 CRED=48 TD=8 seeds 0..20: PASS / acc lines 107914, cpu words 6562, bursts 24788, beats 1144` |
| `board125.out` | 11-20 22:58 | 293 | Vivado log of a PS-connected block design build attempt (Tcl output) | `# if {$bp ne ""} { set_property board_part $bp [current_project]; puts "BOARD_PART $bp" } else { puts "BOARD_P` |
| `board125_final.out` | 11-22 13:37 | 293 | Vivado log of a PS-connected block design build attempt (Tcl output) | `# if {$bp ne ""} { set_property board_part $bp [current_project]; puts "BOARD_PART $bp" } else { puts "BOARD_P` |
| `board125_inproc.out` | 11-22 13:39 | 322 | Vivado log of a PS-connected block design build attempt (Tcl output) | `# if {$bp ne ""} { set_property board_part $bp [current_project]; puts "BOARD_PART $bp" } else { puts "BOARD_P` |
| `board_gui2.out` | 11-22 21:25 | 293 | Vivado log of a PS-connected block design build attempt (Tcl output) | `# if {$bp ne ""} { set_property board_part $bp [current_project]; puts "BOARD_PART $bp" } else { puts "BOARD_P` |
| `boot_events.out` | 11-28 00:25 | 727 | key events of the whole run from the CPU data-port trace (SIM_TRACE_CPU): .bss clear, stack, DONE (11-28); MMIO accesses are not in this trace | `data-port events in the trace: 10067; .bss clear loop: 39 stores` |
| `boot_walkthrough.out` | 11-28 00:34 | 7283 | cycle-by-cycle view of the first 8,000 cycles after reset release: fetch addresses mapped to fw.dis, function segments, first data accesses, g_busy rises (11-28) | `reset released at time 10 (cycle 0); the clock period is 2 time units` |
| `build_axi_ddr.out` | 11-28 15:05 | 0 | (no description recorded) | `` |
| `chip_ddr2_synth.out` | 11-21 21:41 | 1571 | Vivado out-of-context synthesis/implementation timing summary of the DDR top (one file per attempt) | `66 files, include dirs ['rtl/include', 'rtl/vendor/pulp_platform_common_cells/include'] -> /mnt/e/fpga_work/ch` |
| `chip_ddr3_synth.out` | 11-21 22:33 | 1571 | Vivado out-of-context synthesis/implementation timing summary of the DDR top (one file per attempt) | `66 files, include dirs ['rtl/include', 'rtl/vendor/pulp_platform_common_cells/include'] -> /mnt/e/fpga_work/ch` |
| `chip_ddr4_synth.out` | 11-21 23:26 | 1571 | Vivado out-of-context synthesis/implementation timing summary of the DDR top (one file per attempt) | `66 files, include dirs ['rtl/include', 'rtl/vendor/pulp_platform_common_cells/include'] -> /mnt/e/fpga_work/ch` |
| `chip_ddr5_synth.out` | 11-22 00:31 | 1571 | Vivado out-of-context synthesis/implementation timing summary of the DDR top (one file per attempt) | `66 files, include dirs ['rtl/include', 'rtl/vendor/pulp_platform_common_cells/include'] -> /mnt/e/fpga_work/ch` |
| `chip_ddr6_synth.out` | 11-22 11:33 | 1571 | Vivado out-of-context synthesis/implementation timing summary of the DDR top (one file per attempt) | `66 files, include dirs ['rtl/include', 'rtl/vendor/pulp_platform_common_cells/include'] -> /mnt/e/fpga_work/ch` |
| `chip_ddr7_synth.out` | 11-22 12:07 | 1571 | Vivado out-of-context synthesis/implementation timing summary of the DDR top (one file per attempt) | `66 files, include dirs ['rtl/include', 'rtl/vendor/pulp_platform_common_cells/include'] -> /mnt/e/fpga_work/ch` |
| `chip_ddr_synth.out` | 11-21 21:06 | 1570 | Vivado out-of-context synthesis/implementation timing summary of the DDR top (one file per attempt) | `66 files, include dirs ['rtl/include', 'rtl/vendor/pulp_platform_common_cells/include'] -> /mnt/e/fpga_work/ch` |
| `chip_dm.out` | 11-26 23:06 | 1597 | DM build 125 MHz synthesis and implementation summary printed by fpga/run_chip.sh, final RTL (11-26) | `84 files, include dirs ['rtl/include', 'rtl/vendor/pulp_platform_common_cells/include', 'dbg/common_cells/incl` |
| `chip_dm120.out` | 11-28 11:08 | 1600 | (no description recorded) | `84 files, include dirs ['rtl/include', 'rtl/vendor/pulp_platform_common_cells/include', 'dbg/common_cells/incl` |
| `chip_dm120b.out` | 11-28 12:40 | 1601 | (no description recorded) | `84 files, include dirs ['rtl/include', 'rtl/vendor/pulp_platform_common_cells/include', 'dbg/common_cells/incl` |
| `chip_g120.out` | 11-28 10:27 | 1571 | (no description recorded) | `64 files, include dirs ['rtl/include', 'rtl/vendor/pulp_platform_common_cells/include'] -> /mnt/e/fpga_work/ch` |
| `chip_g120b.out` | 11-28 13:26 | 1572 | (no description recorded) | `64 files, include dirs ['rtl/include', 'rtl/vendor/pulp_platform_common_cells/include'] -> /mnt/e/fpga_work/ch` |
| `chip_on125_synth.out` | 11-22 12:33 | 1572 | Vivado out-of-context timing summary of the on-chip top at 125 MHz (11-22) | `64 files, include dirs ['rtl/include', 'rtl/vendor/pulp_platform_common_cells/include'] -> /mnt/e/fpga_work/ch` |
| `cpu_lat.txt` | 11-15 10:27 | 1769 | Vivado timing summary for CPU/FPU latency variants (11-15) | `60 files, include dirs ['rtl/include', 'rtl/vendor/pulp_platform_common_cells/include'] -> /mnt/e/fpga_work/cv` |
| `cpu_lat2.txt` | 11-15 10:54 | 1778 | Vivado timing summary for CPU/FPU latency variants (11-15) | `60 files, include dirs ['rtl/include', 'rtl/vendor/pulp_platform_common_cells/include'] -> /mnt/e/fpga_work/cv` |
| `cpu_pipe.txt` | 11-15 12:25 | 2025 | Vivado timing summary for CPU/FPU pipeline variants (11-15) | `== cpu_grt3` |
| `cpu_pipe2.txt` | 11-15 12:45 | 1383 | Vivado timing summary for CPU/FPU pipeline variants (11-15) | `== DISTRIBUTED addmul 4 others 6` |
| `cpu_rt.txt` | 11-15 11:45 | 1121 | Vivado timing summary (11-15) | `60 files, include dirs ['rtl/include', 'rtl/vendor/pulp_platform_common_cells/include'] -> /mnt/e/fpga_work/cv` |
| `dm120_route_summary.txt` | 11-28 11:26 | 2853 | chip_axi_top WITH the Debug Module at 120 MHz (guards and observation registers in): routed WNS -3.114 ns (timing fails), worst path trigger match register to imem BRAM address, 8.8 ns of which 7.2 ns is routing (11-28) | `Vivado 2026.1, out of context, chip_axi_top WITH the Debug Module (DM=1 DM_BUILD), 120 MHz (8.333 ns), fpga/ru` |
| `dm120b_route_summary.txt` | 11-28 13:39 | 3063 | chip_axi_top WITH the Debug Module at 120 MHz after the E17 fixes (clock gate pass-through, imem port select by rst_ni, real JTAG TAP): routed WNS +0.752 ns, timing met (11-28) | `Vivado 2026.1, out of context, chip_axi_top WITH the Debug Module (DM=1 DM_BUILD, real JTAG TAP on pins), 120 ` |
| `dm_chip_route_summary.txt` | 11-26 23:08 | 1840 | RISC-V Debug Module build at 125 MHz: routed timing summary (WNS +0.110 ns), utilization, synthesis LUT/register lines (11-26) | `Vivado 2026.1, out of context, chip_axi_top, 125 MHz (8.0 ns), DM=1 fpga/run_chip.sh DM_BUILD, final RTL (v3),` |
| `dm_sim.out` | 11-28 12:17 | 1211 | (no description recorded) | `loaded` |
| `dm_sim_e17.out` | 11-28 14:09 | 1211 | dbg/tb_dm after the E17 RTL changes: PASSED, 0 check failures (11-28) | `loaded` |
| `drv_rtl.out` | 11-26 13:39 | 423 | (no description recorded) | `NS running 100000 cycles, 2 s, 60569 cycles/s` |
| `exp2_q1.out` | 11-24 23:26 | 188 | exhaustive vfu_exp2 check, one quarter of the 2^32 input patterns per file (RTL vs opta/exp2q.h), with wall time (11-25) | `268435456 checked` |
| `exp2_q2.out` | 11-25 10:36 | 188 | exhaustive vfu_exp2 check, one quarter of the 2^32 input patterns per file (RTL vs opta/exp2q.h), with wall time (11-25) | `268435456 checked` |
| `exp2_q3.out` | 11-25 10:36 | 188 | exhaustive vfu_exp2 check, one quarter of the 2^32 input patterns per file (RTL vs opta/exp2q.h), with wall time (11-25) | `268435456 checked` |
| `exp2_q4.out` | 11-25 10:36 | 188 | exhaustive vfu_exp2 check, one quarter of the 2^32 input patterns per file (RTL vs opta/exp2q.h), with wall time (11-25) | `268435456 checked` |
| `fpfmt_repro.txt` | 11-28 21:59 | 672 | FMT lines of the minimal xsim reproduction fpga/xsim/tb_fpfmt.sv (variable index gives exp=7/bias=63 for every format) | `FMT f=0  A(var idx) exp=7 man=7 bias=63 / B exp=7 / C exp=8 / expected exp 8` |
| `fpu_after.out` | 11-22 21:01 | 339 | xsim FPU test (1,402 vectors) before the workaround: RTL 671/1402 (MUL 301, I2F 201, ADD 229 wrong), synthesized netlist 1402/1402 (11-22) | `1402 vectors -> /mnt/e/fpga_work/fpu_test` |
| `fpu_net.out` | 11-22 20:58 | 313 | same experiment, netlist run repeated: RTL 671/1402, netlist 1402/1402 (11-22) | `1402 vectors -> /mnt/e/fpga_work/fpu_test` |
| `fpu_workaround.out` | 11-22 21:17 | 221 | xsim FPU test with xsim_workaround.py: RTL 1402/1402, netlist 1402/1402 (11-22) | `1402 vectors -> /mnt/e/fpga_work/fpu_test` |
| `fpu_xsim_new.out` | 11-23 21:35 | 3681 | extended FPU vectors (3,896), first xsim run: RTL line is a STALE cached result (1402/3896, meaningless), netlist 3896/3896 (11-23) | `already patched /mnt/e/fpga_work/fpu_test/rtl/vendor/pulp_platform_fpnew/src/fpnew_pkg.sv` |
| `fpu_xsim_new2.out` | 11-23 21:37 | 425 | extended FPU vectors, stale files removed: xsim RTL 3896/3896, netlist 3896/3896 (11-23) | `already patched /mnt/e/fpga_work/fpu_test/rtl/vendor/pulp_platform_fpnew/src/fpnew_pkg.sv` |
| `fpu_xsim_stream.out` | 11-24 22:28 | 1103 | xsim FPU test with the stream mode: RTL and netlist, single and stream, all 3896/3896, stream statistics per group (11-24) | `already patched /mnt/e/fpga_work/fpu_test/rtl/vendor/pulp_platform_fpnew/src/fpnew_pkg.sv` |
| `fpuv_run.out` | 11-23 21:25 | 1012 | Verilator, extended FPU vectors: single and stream mode x two pipeline configs, all 3896/3896, stream statistics (11-23) | `FPU_VERILATOR 3896 vectors done` |
| `g120_route_summary.txt` | 11-28 10:29 | 2120 | plain chip_axi_top (no Debug Module) at 120 MHz with the guards and observation registers: routed WNS +0.191 ns, utilization, peak memory 13.1 GB (11-28) | `Vivado 2026.1, out of context, chip_axi_top without the Debug Module, 120 MHz (8.333 ns), fpga/run_chip.sh, RT` |
| `g120b_route_summary.txt` | 11-28 13:39 | 2980 | chip_axi_top without the Debug Module at 120 MHz after the E17 fixes: routed WNS +0.673 ns, timing met (11-28) | `Vivado 2026.1, out of context, chip_axi_top without the Debug Module, 120 MHz (8.333 ns), after E17 (clock gat` |
| `kvddr_p0.out` | 11-28 21:58 | 1220 | acc/tb_kvddr/run_test.py: attention QK/AV reads of a KV cache in DDR, layout [t][kv_dim] vs head-major, ctx 128 and 512, plus on-chip reference: ctx 512 268,536 vs 183,496 vs 169,176 cycles (11-28) | `DDR model: latency 40, 12.8 B/cycle` |
| `net_lint.out` | 11-24 22:52 | 2640 | Verilator lint of the post-synthesis soc_chip netlist with the UNISIM models: successive attempts (deassign, specify, tri-state errors), the last ones ran out of memory (11-24) | `%Error-BADVLTPRAGMA: /home/hyojinkim/work/3_Company_PJT/CSO/Server/LLM/CV32E40P_Stories260K/.claude/worktrees/` |
| `net_lint2.out` | 11-24 22:54 | 770 | Verilator lint of the post-synthesis soc_chip netlist with the UNISIM models: successive attempts (deassign, specify, tri-state errors), the last ones ran out of memory (11-24) | `%Error-BADVLTPRAGMA: /home/hyojinkim/work/3_Company_PJT/CSO/Server/LLM/CV32E40P_Stories260K/.claude/worktrees/` |
| `net_lint3.out` | 11-24 22:54 | 31248 | Verilator lint of the post-synthesis soc_chip netlist with the UNISIM models: successive attempts (deassign, specify, tri-state errors), the last ones ran out of memory (11-24) | `%Warning-TIMESCALEMOD: /home/hyojinkim/work/3_Company_PJT/CSO/Server/LLM/CV32E40P_Stories260K/.claude/worktree` |
| `net_lint5.out` | 11-24 22:56 | 667 | Verilator lint of the post-synthesis soc_chip netlist with the UNISIM models: successive attempts (deassign, specify, tri-state errors), the last ones ran out of memory (11-24) | `%Warning-TIMESCALEMOD: /home/hyojinkim/work/3_Company_PJT/CSO/Server/LLM/CV32E40P_Stories260K/.claude/worktree` |
| `net_speed_a.out` | 11-24 22:48 | 1222 | xsim run of the post-synthesis netlist: wall time and the license error (11-24) | `wall time 211 s (vivado project creation, elaboration and simulation)` |
| `notrig.txt` | 11-22 00:41 | 624 | DDR top run with and without trigger cells (NO_TRIGGERS option), cycle counts (11-22) | `build exit=0` |
| `npu_perf.out` | 11-27 21:01 | 715 | DONE cycles and PERF counters of image_1/128/512 on the board-top simulation, the data of the NPU scaling analysis (11-27) | `== image_1 (ctx 1), board-top simulation obj_axi, 11-27` |
| `pv2a.txt` | 11-15 12:51 | 1781 | Vivado timing summary of a VFU/SoC variant (11-15) | `/ region / ctx1 cycles (%) / ctx128 cycles (%) / ctx512 cycles (%) / ctx512 reads W/KV/act (words) /` |
| `pv2b.txt` | 11-15 12:51 | 1788 | Vivado timing summary of a VFU/SoC variant (11-15) | `/ region / ctx1 cycles (%) / ctx128 cycles (%) / ctx512 cycles (%) / ctx512 reads W/KV/act (words) /` |
| `pv2c.txt` | 11-15 12:53 | 1783 | Vivado timing summary of a VFU/SoC variant (11-15) | `/ region / ctx1 cycles (%) / ctx128 cycles (%) / ctx512 cycles (%) / ctx512 reads W/KV/act (words) /` |
| `pv2d.txt` | 11-15 12:53 | 1783 | Vivado timing summary of a VFU/SoC variant (11-15) | `/ region / ctx1 cycles (%) / ctx128 cycles (%) / ctx512 cycles (%) / ctx512 reads W/KV/act (words) /` |
| `pv3_v3a.txt` | 11-15 12:57 | 1781 | Vivado timing summary of a VFU/SoC variant (11-15) | `/ region / ctx1 cycles (%) / ctx128 cycles (%) / ctx512 cycles (%) / ctx512 reads W/KV/act (words) /` |
| `pv3_v3b.txt` | 11-15 12:57 | 1787 | Vivado timing summary of a VFU/SoC variant (11-15) | `/ region / ctx1 cycles (%) / ctx128 cycles (%) / ctx512 cycles (%) / ctx512 reads W/KV/act (words) /` |
| `r8all.txt` | 11-14 08:50 | 801 | accelerator profile of a single step (JSON, 11-13/14) | `{` |
| `r8attn.txt` | 11-13 23:58 | 787 | accelerator profile of a single step (JSON, 11-13/14) | `{` |
| `r8attn2.txt` | 11-14 08:52 | 787 | accelerator profile of a single step (JSON, 11-13/14) | `{` |
| `repro_d7.out` | 11-27 21:01 | 5513 | reproduce.sh output (build, regression, profiles, VFU test) | `=== build simulators (CPU, CPU profiler, CPU + accelerator SoC)` |
| `repro_dbgprobe.out` | 11-26 17:01 | 5513 | reproduce.sh output (build, regression, profiles, VFU test) | `=== build simulators (CPU, CPU profiler, CPU + accelerator SoC)` |
| `repro_dm.out` | 11-26 23:36 | 5513 | reproduce.sh output (build, regression, profiles, VFU test) | `=== build simulators (CPU, CPU profiler, CPU + accelerator SoC)` |
| `repro_e17.out` | 11-28 14:09 | 5513 | reproduce.sh quick after the E17 RTL changes: 42/42 OK, cycles +0 (11-28) | `=== build simulators (CPU, CPU profiler, CPU + accelerator SoC)` |
| `repro_g.out` | 11-28 12:16 | 5513 | reproduce.sh output (build, regression, profiles, VFU test) | `=== build simulators (CPU, CPU profiler, CPU + accelerator SoC)` |
| `repro_quick.txt` | 11-14 08:02 | 2111 | reproduce.sh output (build, regression, profiles, VFU test) | `=== build simulators (CPU, CPU profiler, CPU+accelerator SoC)` |
| `repro_quick2.txt` | 11-14 08:27 | 2111 | reproduce.sh output (build, regression, profiles, VFU test) | `=== build simulators (CPU, CPU profiler, CPU+accelerator SoC)` |
| `repro_quick3.txt` | 11-14 19:30 | 3098 | reproduce.sh output (build, regression, profiles, VFU test) | `=== build simulators (CPU, CPU profiler, CPU + accelerator SoC)` |
| `repro_quick4.txt` | 11-15 10:10 | 3440 | reproduce.sh output (build, regression, profiles, VFU test) | `=== build simulators (CPU, CPU profiler, CPU + accelerator SoC)` |
| `repro_standard.txt` | 11-14 11:11 | 3841 | reproduce.sh output (build, regression, profiles, VFU test) | `=== build simulators (CPU, CPU profiler, CPU + accelerator SoC)` |
| `reproduce_quick.out` | 11-21 21:59 | 5513 | reproduce.sh quick output | `=== build simulators (CPU, CPU profiler, CPU + accelerator SoC)` |
| `reproduce_quick2.out` | 11-22 13:04 | 5513 | reproduce.sh quick output | `=== build simulators (CPU, CPU profiler, CPU + accelerator SoC)` |
| `reproduce_quick3.out` | 11-22 20:54 | 5513 | reproduce.sh quick output | `=== build simulators (CPU, CPU profiler, CPU + accelerator SoC)` |
| `reproduce_quick4_final.out` | 11-25 12:15 | 5558 | reproduce.sh quick output | `=== build simulators (CPU, CPU profiler, CPU + accelerator SoC)` |
| `reproduce_quick5_merged.out` | 11-25 12:50 | 5558 | reproduce.sh quick output | `=== build simulators (CPU, CPU profiler, CPU + accelerator SoC)` |
| `soc_v2.txt` | 11-15 13:18 | 1482 | Vivado timing summary of the SoC v2 variant (11-15) | `60 files, include dirs ['rtl/include', 'rtl/vendor/pulp_platform_common_cells/include'] -> /mnt/e/fpga_work/so` |
| `sweep_ddr.txt` | 11-14 18:51 | 4168 | DDR sweep ddr_full_opt (speedup vs ideal-memory SW baseline, OVH=4) (11-14) | `# DDR sweep `ddr_full_opt` (speedup vs ideal-memory SW baseline; OVH=4)` |
| `sweep_dm_7.0.out` | 11-28 14:51 | 1602 | (no description recorded) | `84 files, include dirs ['rtl/include', 'rtl/vendor/pulp_platform_common_cells/include', 'dbg/common_cells/incl` |
| `tb_dm.out` | 11-26 20:26 | 1138 | Debug Module JTAG test (dbg/tb_dm) outputs of successive RTL versions (tb_dm6d = final; tb_dm_mut = mutation check, expected FAIL) (11-26) | `loaded` |
| `tb_dm6.out` | 11-26 20:27 | 824 | Debug Module JTAG test (dbg/tb_dm) outputs of successive RTL versions (tb_dm6d = final; tb_dm_mut = mutation check, expected FAIL) (11-26) | `loaded` |
| `tb_dm6b.out` | 11-26 20:46 | 824 | Debug Module JTAG test (dbg/tb_dm) outputs of successive RTL versions (tb_dm6d = final; tb_dm_mut = mutation check, expected FAIL) (11-26) | `loaded` |
| `tb_dm6c.out` | 11-26 20:55 | 824 | Debug Module JTAG test (dbg/tb_dm) outputs of successive RTL versions (tb_dm6d = final; tb_dm_mut = mutation check, expected FAIL) (11-26) | `loaded` |
| `tb_dm6d.out` | 11-26 21:36 | 824 | Debug Module JTAG test (dbg/tb_dm) outputs of successive RTL versions (tb_dm6d = final; tb_dm_mut = mutation check, expected FAIL) (11-26) | `loaded` |
| `tb_dm_bp.out` | 11-26 23:45 | 927 | Debug Module JTAG test (dbg/tb_dm) outputs of successive RTL versions (tb_dm6d = final; tb_dm_mut = mutation check, expected FAIL) (11-26) | `loaded` |
| `tb_dm_eb.out` | 11-26 23:45 | 873 | Debug Module JTAG test (dbg/tb_dm) outputs of successive RTL versions (tb_dm6d = final; tb_dm_mut = mutation check, expected FAIL) (11-26) | `loaded` |
| `tb_dm_mut.out` | 11-26 20:29 | 1356 | Debug Module JTAG test (dbg/tb_dm) outputs of successive RTL versions (tb_dm6d = final; tb_dm_mut = mutation check, expected FAIL) (11-26) | `loaded` |
| `tb_dm_step.out` | 11-26 23:42 | 838 | Debug Module JTAG test (dbg/tb_dm) outputs of successive RTL versions (tb_dm6d = final; tb_dm_mut = mutation check, expected FAIL) (11-26) | `loaded` |
| `tiled_verify.txt` | 11-22 20:54 | 738 | pre-tiled weights (CTRL bit2) GEMV test (11-22) | `soc_top build exit=0` |
| `trace_compare.txt` | 11-23 12:32 | 160 | Verilator CPU data-port trace of 200k cycles: 20,133 events (11-23) | `trace build exit=0` |
| `trace_compare2.txt` | 11-23 12:45 | 198 | first xsim-vs-Verilator trace compare: first difference was a store response (Verilator 0 vs xsim x), later shown to be a don't care (11-23) | `4562 .scratch/trv/trace_xsim.txt` |
| `vfu_test_big.txt` | 11-14 08:47 | 1671 | VFU unit test output (mismatch counts, software and hardware cycles) | `{'test': 'exp', 'seed': 0, 'n': 65536, 'mismatches': 0, 'sw_cycles': 9261117, 'hw_cycles': 4111332}` |
| `vfu_test_l4.txt` | 11-14 10:39 | 2103 | VFU unit test output (mismatch counts, software and hardware cycles) | `{'test': 'exp', 'seed': 0, 'n': 65536, 'mismatches': 0, 'sw_cycles': 9269325, 'hw_cycles': 2972919}` |
| `vg7.out` | 11-25 16:44 | 1738 | V-G7: three full-chip xsim runs (A no patch, B rd_ok only, C FPU table only), MAXCYC=600000: A and C no DONE, B DONE 149,074 cycles dump differs 5,718 bytes (11-25) | `== A no workaround  start 16:33:48` |
| `vg7_a_unbounded.out` | 11-25 16:07 | 31876 | first V-G7 run of step A, MAXCYC did not take effect (env var not passed to Windows vivado): ran about 3 h to 85M cycles before it was stopped, no result (11-25) | `INFO: [Common 17-3922] A valid Vivado Design Suite BASIC license has been detected. Your current license is ac` |
| `vt_v3a.txt` | 11-15 12:57 | 534 | VFU unit test output (v3 variants, 11-15) | `{'test': 'exp', 'seed': 0, 'n': 4096, 'mismatches': 0, 'sw_cycles': 650897, 'hw_cycles': 192087}` |
| `vt_v3b.txt` | 11-15 12:57 | 534 | VFU unit test output (v3 variants, 11-15) | `{'test': 'exp', 'seed': 0, 'n': 4096, 'mismatches': 0, 'sw_cycles': 650897, 'hw_cycles': 264381}` |
| `w8_acc.out` | 11-21 21:27 | 828 | int8 weight (I1) end-to-end run result (JSON, 11-21) | `{` |
| `w8_acc64.out` | 11-21 21:16 | 1144 | int8 weight (I1) end-to-end run result (JSON, 11-21) | `{` |
| `w8_os.out` | 11-21 20:53 | 675 | int8 weight (I1) end-to-end run result (JSON, 11-21) | `{` |
| `xsim_fix.out` | 11-23 12:32 | 1767 | full-chip xsim with the FPU workaround only: run was stopped after about 15 h without reaching DONE (11-23) | `FIXCLK: 15 always blocks reclocked to forever_cpuclk` |
| `xsim_full.out` | 11-23 13:58 | 828 | full-chip xsim with both workarounds: DONE run_cycles=157433, dump equal to Verilator (sim.cpp 157437) (11-23) | `FIXCLK: 15 always blocks reclocked to forever_cpuclk` |
| `xsim_full_after_tbnet.out` | 11-24 23:18 | 828 | full-chip RTL xsim rerun after the tb_chip.sv changes for the netlist: DONE run_cycles=157433, dump equal to Verilator (11-24) | `FIXCLK: 15 always blocks reclocked to forever_cpuclk` |
| `xsim_hang_window_trace.txt` | 11-28 21:59 | 20146 | xsim trace of cycles 9900..10300: instruction fetch (IF), VFU state (VFU) and the x_req term probe (XSPROBE); shows x_req=0 while every term is 1 | `9909 IF a=01000ec8` |
| `xsim_net_license_error.txt` | 11-24 23:13 | 300 | the xsim error that stops the post-synthesis full-chip simulation: BASIC license, 107,091 instances > 50,000 allowed (11-24) | `ERROR: The current Vivado Simulator license tier you have, BASIC, does not meet the requirement to run the num` |
| `xsim_pc.out` | 11-23 12:48 | 185 | run that produced the instruction fetch trace (11-23) | `FIXCLK: 15 always blocks reclocked to forever_cpuclk` |
| `xsim_probe.out` | 11-23 13:48 | 185 | run that produced the XSPROBE lines (x_req terms) (11-23) | `FIXCLK: 15 always blocks reclocked to forever_cpuclk` |
| `xsim_trace.out` | 11-23 12:45 | 185 | xsim trace run of the first 200k cycles (11-23) | `FIXCLK: 15 always blocks reclocked to forever_cpuclk` |
| `xsim_vfu.out` | 11-23 13:42 | 185 | run that produced the VFU state trace (11-23) | `FIXCLK: 15 always blocks reclocked to forever_cpuclk` |
