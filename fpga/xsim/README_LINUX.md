# Running the Vivado xsim flow on a native Linux machine

The scripts were written for WSL with the Windows Vivado (`~/bin/vivado` starts `vivado.bat` through `cmd.exe`, work dirs under `/mnt/e`).
Changed 11-26 so that they also run with a Linux Vivado: `VIVADO` (command, default `~/bin/vivado` if it exists, else `vivado` on PATH) and
`FPGA_WORK` (parent of the default work dirs, default `/mnt/e/fpga_work`). Checked only on the WSL setup (a 3000-cycle run of `run_xsim.sh` after the
change); a native Linux run has not been done.

## What to bring
| item | how |
|---|---|
| repo | `git clone` then `git checkout verification-followup` (or the merged main) |
| images | not in git. Copy `prof/chip_full_opta_d2/image_1.bin` (16.9 MB; also `image_128.bin`, `image_512.bin`), or regenerate with the riscv toolchain (`reproduce.sh`) |
| Vivado | version used: 2026.1. Another version may behave differently (see below) |
| Verilator 5.x + g++ | only for the reference simulation `obj_chip/Vsoc_chip` that `run_xsim.sh` compares with: `TOP=soc_chip ./build_sim.sh` |
| python3 | the scripts patch a work copy of the RTL with Python |

Put the work dir on a local disk: `export FPGA_WORK=/data/fpga_work` (the flow copies the RTL and writes the Vivado project there).

## Order (rule: trust a full-chip xsim result only after the FPU test passed, plan section 7)
1. `export VIVADO=$(which vivado); export FPGA_WORK=/data/fpga_work`
2. FPU test: `fpga/xsim/run_fpu_test.sh` (no mode argument: it runs the RTL, then synthesizes the FPU wrapper out of context and simulates that small netlist, single and stream mode; 3,896 vectors, expected 3896/3896 in all four; the synthesis step needs the Vivado synthesis license/features and some minutes)
3. Full chip: `fpga/xsim/run_xsim.sh prof/chip_full_opta_d2/image_1.bin` (about 3 to 4 minutes on the WSL host; expected `TB DONE run_cycles=157433`
   and `xsim dump == Verilator`). Add `XSIM_PLUS="MAXCYC=600000"` as a safety limit for any new setup, and a `timeout` (rule R13).
4. Look at the cycle count and the dump line first; if the run does not reach DONE within about 2x the expected cycles, stop it.

## What can differ on a new machine
- **The two xsim evaluation problems** (`docs/XSIM_VS_VERILATOR.md`, E13) were seen with Vivado 2026.1 on the WSL host. A different Vivado version may not have
  them, or the workarounds in `xsim_workaround.py` may not apply (the script stops with an error if its text patterns are not found). To see
  which case it is, run the variants of experiment E13: `FIXFMT=0` (no patch), `XW=rd`, `XW=fmt`, each with `XSIM_PLUS="MAXCYC=600000"`.
- **The license decides D4.** The BASIC license of the WSL host stops the post-synthesis simulation (50,000 instances, the netlist has 107,091). If the
  Linux machine has a full xsim license, `fpga/xsim/run_xsim_net.sh <image.bin>` runs the synthesized netlist directly, with the plusarg file mechanism,
  and the Verilator conversion kit (`net_verilator/`) is not needed. The netlist is `netlist_net.v` (45 MB, in the handoff tarball made by
  `net_verilator/pack_handoff.sh`, or recreate it: `PIPE_DIST=1 fpga/prepare.py <dir>; cd <dir>; vivado -mode batch -source synth.tcl -tclargs soc_chip 8.0 0 net NETLIST`).
  `run_xsim_net.sh` expects the netlist and the work files in the work dir (read its header). That script has not run to completion on any machine.
- The plusargs (`MAXCYC`, `TRACE_N`, ...) go through `plusargs.txt` in the work dir, not through environment variables, so they work the same on Linux.
- `tasklist.exe` (used in the notes to find leftover `vivado.exe`/`xsimk.exe`) does not exist on Linux: use `pgrep -a 'vivado|xsimk'`.
- Scripts that still need the WSL layout and are not part of the xsim flow: `fpga/run_chip.sh`, `run_soc_v2.sh`, `run_cpu_*.sh` (synthesis runs; they call `~/bin/vivado` and
  `/mnt/e` directly). Change them the same way if you need synthesis there.
