# Post-synthesis full-chip simulation in Verilator (D4, V-S1)

Why: xsim (BASIC license: 50,000 instances, the netlist has 107,091) and the 7.9 GB WSL host (Verilator conversion >6.5 GB, not finished) could
not run the synthesized `soc_chip` netlist. This folder runs it in Verilator on a Linux server with enough memory. No Vivado is needed there.

## Files
| file | what |
|---|---|
| `pack_handoff.sh` | run where Vivado output exists: makes `handoff_d4.tar.gz` (netlist 45 MB, UNISIM sources of the 25 primitive types, image, reference dump, SHA256SUMS) |
| `run_net_vl.sh` | run on the server: checks, prep, build (peak memory logged), speed probe, full run, dump compare, `result.txt` |
| `prep.py` | netlist + UNISIM sources -> Verilator inputs (own models for FDRE/FDSE/FDCE/FDPE/SRL16E, `specify` blocks and `!== 1'bz` tests removed, constant `glbl`) |
| `net_sim.cpp` | port-level driver, same protocol as `fpga/xsim/tb_chip.sv` (load through the loader port, run to DONE, read back) |
| `test_driver_rtl.sh` | checks the driver on the RTL `soc_chip` first |

## Steps
1. Here (done once, 2026-11-26): `fpga/xsim/net_verilator/pack_handoff.sh` -> `/mnt/e/fpga_work/chip_net/handoff_d4.tar.gz` (5 MB).
2. Copy that file to the server and `git checkout verification-followup` (or the merged main) there. Needs Verilator (tested 5.038), g++, make, python3.
3. `mkdir -p /data/d4 && tar -C /data/d4 -xzf handoff_d4.tar.gz && fpga/xsim/net_verilator/run_net_vl.sh /data/d4/h`
4. Send back `<workdir>/result.txt`, `build.time`, `build.mem` (peak RSS samples, MB) and `steps.log`; they go into the experiment log as E14.

## What was checked here, and what was not
- Checked: the driver on the RTL `soc_chip` gives `run_cycles=157433` (same as xsim `tb_chip.sv`) and a 2 MiB dump equal to `obj_chip/Vsoc_chip`;
  the same Verilator options as in `run_net_vl.sh` (`--no-timing --x-initial 0 --x-assign 0 --output-split ... -O1`) give the same dump on the RTL;
  `pack_handoff.sh`, the bundle checksums, `prep.py` on the packed UNISIM sources and the script's checks (DRYRUN=1) run.
- NOT checked: the Verilator conversion and C++ build of the netlist itself (this host runs out of memory), so memory, wall time, and whether the
  UNISIM models behave like the vendor simulation in Verilator are unknown. The speed probe and the first lines of `run.log` show it early.
  The netlist FPU test in Verilator was never run either: only xsim ran the netlist FPU (3,896/3,896). If the full dump differs, the first suspects
  are the own flip-flop models in `prim_models.v` and the constant `glbl` (GSR = 0).
- Expected values: DONE at about 157,433 cycles on this image, dump equal to `ref_dump.bin`. The netlist FPU stream test showed one cycle longer
  latency than the RTL in xsim (E09, hypothesis: testbench sampling), so a cycle count off by a few is not by itself a failure; the dump is the criterion.
- Run limits: `BUILD_TIMEOUT` 6 h, `RUN_TIMEOUT` 12 h (env). Check `steps.log` and the `NS running` lines in `run.log` after the first minutes (R13).
- The UNISIM sources are copyrighted by the vendor and come from a Vivado installation; check that your license allows copying them to the server.
