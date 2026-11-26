# RISC-V Debug Module and JTAG (added 2026-11-26)

Status words as in docs/VERIFICATION_PLAN.md: **done** = run here and the result is in this file; **not run** = not checked.

## What it is
The CV32E40P core supports execution-based debug (RISC-V Debug Spec 0.13.2, one trigger; cores docs `cv32e40p-master/docs/source/debug.rst`). A Debug Module (DM)
and a Debug Transport Module (DTM, JTAG) are needed to use it. They come from `pulp-platform/riscv-dbg` (`dbg/`, versions in `dbg/VENDOR.md`).

```
 JTAG (4 pins, or the BSCANE2 primitives of the FPGA JTAG chain)
   │
 dmi_jtag (TAP + DTM, TCK -> clk_i clock crossing)            dbg/riscv-dbg/src/dmi_jtag*.sv, dmi_cdc.sv
   │ DMI
 dm_obi_top (dm_top: dm_csrs, dm_mem = debug ROM + program buffer + data regs, dm_sba)
   │ slave port (32 bit, response one cycle after the request)        │ debug_req_o
   ▼                                                                    ▼
 soc_chip (DM_EN = 1): region DM_BASE .. +4 KiB on the core's        core debug_req_i  (halt request)
   instruction port (debug ROM / program buffer fetch) and data       dm_halt_addr_i = DM_BASE + 0x800
   port (data registers, flags)                                       dm_exception_addr_i = DM_BASE + 0x810
```
- `acc/soc_chip.sv`: parameter `DM_EN` (default 0: nothing changes, no debug files needed) and the plain bus ports `dm_*`; `DM_BASE` default `0x1A11_0000`
  (unused in the address map: SRAM 0..2 MiB, imem 0x0100_0000, MMIO 0x2000_0000 and 0x3000_0000).
- `acc/soc_top.sv`: the core's `debug_req_i`, `dm_halt_addr_i`, `dm_exception_addr_i` and the three status outputs are now ports (the simulators leave them at 0).
- `dbg/soc_chip_dm.sv`: `soc_chip` with `DM_EN = 1` plus `dm_obi_top` and `dmi_jtag`. Ports as `soc_chip` plus the JTAG pins, `dm_rst_ni`, `ndmreset_o`.
- `acc/chip_axi_top.sv`: with `` `DM_BUILD`` defined it instantiates `soc_chip_dm` (JTAG pins tied off for the BSCANE2 variant); the Debug Module sits on the
  system reset `rst_ni` while the core is held in reset until RUN; `ndmreset_o` also resets the core and the accelerators. Without the macro it is the old top.
- `dbg/dbg_files.f`: file list (real TAP `dmi_jtag_tap.sv`); `DM=1 fpga/prepare.py` swaps in `dmi_bscane_tap.sv` for the FPGA, and the synthesis token `DM_BUILD`
  (`fpga/synth.tcl`) defines the macro: `DM=1 PERIOD=8.0 fpga/run_chip.sh <dir> DM_BUILD`.

Timing of the debug-region access (kept off the 125 MHz critical path; the core's instruction address path is already the critical one, through the trigger match):
- Instruction side: `i_gnt` depends only on a register (`dm_busy_i_q`). A fetch in the region is captured at the grant (stage I), the Debug Module sees it one cycle later and answers one
  cycle after that (response at grant + 2); the next fetch waits until that response, so the responses stay in order. The imem read is not gated by the region decode (the value it reads is unused).
- Data side: the region grant is decoded from `d_addr` like the SRAM grant, the access is captured in stage D and is granted only when no other data response is in flight; same-port
  requests wait during the access. The Debug Module takes one request per cycle, data first.
- What the iterations showed (E14): the first version (decode in the grant and in front of the Debug Module) was -1.651 ns at the synthesis stage; registering only the Debug Module request
  (decode still in the instruction grant) routed to WNS -2.579 ns at 125 MHz; making the instruction grant register-only gives WNS +0.110 ns.

System bus access (SBA, reading memory without the core) is **not connected**: every SBA access ends with a bus error, so a debugger falls back to the program buffer
(memory access by the halted core). Reading memory while the core runs is therefore not possible.

## What was checked (Verilator, `dbg/tb_dm`, image_1, done)
`dbg/tb_dm/run.sh <image> <reference dump> <workdir> +HALTS=6 +FIRST=20000 +STEP=22000` drives the TAP pins bit by bit (the test master is in `dbg/tb_dm/tb.cpp`).
- IDCODE 0x00000DB3, DTMCS (version 1, abits 7), `dmcontrol.dmactive`, `dmstatus.version` = 2 (debug spec 0.13).
- 6 halts at run cycles ~25k, 47k, 69k, 91k, 113k, 135k (the core is somewhere else each time: `dpc` values differ): `allhalted`, `dcsr.cause` = 3 (haltreq), `dpc` inside imem,
  `sp` inside the SRAM, `debug_halted_o`; abstract register reads (dpc, dcsr, x2) and a write, read-back and restore of x5; resume with `allresumeack`; `debug_halted_o` cleared.
- The firmware then runs to DONE. The 2 MiB dump differs from the reference dump in exactly 2 words: 0x1aff00 (the firmware cycle word, which `reproduce.sh`
  excludes from its HOLD comparison) and 0x1ad000 (same value in every run; it follows the cycle word, but this file does not prove what it is). Everything else is equal.
- Mutation check: a broken response path for debug data accesses (`dm_rsp_d_q` forced to 0) makes the test fail (register reads and abstract commands fail).
- Default builds (`DM_EN = 0`, no `DM_BUILD`): image_1/128/512 give 157,437 / 214,257 / 382,970 cycles and dumps equal to the reference (`board_kit/dump_sim_*`);
  board top `image_1`: 157,433 cycles, dump equal; with `DM_BUILD` and an idle Debug Module: same 157,433 cycles, dump equal.
- `reproduce.sh quick` after the change: 42/42 OK (11-26, 28 minutes, 0 failures; raw output `docs/experiments/raw/repro_dm.out`).

## Synthesis (Vivado 2026.1, out of context, chip_axi_top, 125 MHz, `DM=1 PERIOD=8.0 fpga/run_chip.sh <dir> DM_BUILD`, done)
Final RTL, routed: WNS +0.110 ns, TNS 0, 0 failing endpoints, WHS +0.012 ns; CLB LUTs 60,456, registers 21,932, BRAM 7, URAM 64, DSP 93; 2 BSCANE2 (summary file:
`docs/experiments/raw/dm_chip_route_summary.txt`). Reference without the Debug Module (plan row V-M1): WNS +0.249 ns, so the Debug Module costs about 0.14 ns of slack in this pair of runs (two
separate place-and-route runs; the run-to-run variation was not measured). At the synthesis stage the debug logic was about 1,200 LUTs (`dmi_jtag` 656, `dm_obi_top` 522 in the first run).
Vivado crashed twice during synthesis of the same RTL (EXCEPTION_ACCESS_VIOLATION, "Start Timing Optimization"), once more in the earlier iteration, while a synthesis-only run and a third
full run were fine; the cause is not known.
The board bitstream `board_release_125_int8` does NOT contain the Debug Module: a new bitstream would be needed (build `chip_axi_top` with `DM_BUILD` and `dmi_bscane_tap.sv`).

## Not checked
- The BSCANE2 variant (`dmi_bscane_tap.sv`) in simulation: Verilator has no BSCANE2; it was only synthesized.
- OpenOCD/GDB on the board: JTAG chain position of the PL, IR codes of USER3/USER4 for ZCU104, and OpenOCD's `riscv` configuration are not known here. No OpenOCD configuration is
  provided because it could not be tested. The USB-JTAG cable cannot be used by Vivado and OpenOCD at the same time.
- Hardware breakpoints (the single trigger, `DEBUG_TRIGGER_EN`; `fpga/prepare.py NO_TRIGGERS=1` removes it), single step, `ebreak`: not exercised by `tb_dm`.
- Halting while an accelerator command runs and comparing intermediate memory: the accelerators keep running while the core is halted; only the final result was compared.
- The board itself (a bitstream with the Debug Module was not built; the routed timing above is from an out-of-context run, as for the existing bitstream's V-M1/V-M2).
- The Debug Module's `dmstatus`, `hartinfo` and the `unavailable` bit while the core is held in reset (RUN = 0) were read in simulation (`dmstatus` 0x000c3082) but not interpreted bit by bit.
