# ILA probes for the ZCU104 board build (prepared 2026-11-26, not built, not run on a board)

Why: the board top `acc/chip_axi_top.sv` used to leave the chip's observation outputs (`dbg_instr_*`, `dbg_data_*`) unconnected, so nothing
inside the running core could be seen except the six performance counters. Use this only if a board run fails and the dump compare and the counters
(docs/BOARD_BRINGUP.md section 5) do not locate the problem. The first board runs (V-B1..B3) use the existing bitstream.

## What changed (RTL)
`chip_axi_top` has a new parameter `DBG_PROBE` (default 0). With 0 nothing changes. With 1, ten nets get `(* mark_debug = "true" *)`:

| net | meaning |
|---|---|
| `g_dbg.pr_ireq`, `pr_iaddr[31:0]` | CPU instruction fetch request and address (the PC being fetched) |
| `g_dbg.pr_dreq`, `pr_dwe`, `pr_daddr[31:0]` | CPU data port: request, write enable, address (a write to 0x2000_0000 is DONE) |
| `g_dbg.pr_areq`, `pr_awe`, `pr_aaddr[31:0]` | accelerator memory port (GEMV and VFU share it) |
| `g_dbg.pr_run`, `pr_done` | RUN and DONE of the control registers |

Only addresses and strobes are probed, no data buses (width and BRAM use). Add `pr_*` for `d_wdata`/`a_wdata` if a data value is needed.

## What was checked here
- Verilator, `chip_axi_top` board-flow simulation, image_1: with the default (`DBG_PROBE=0`) and with `-GDBG_PROBE=1` (`VXARGS="-GDBG_PROBE=1" TOP=chip_axi_top ./build_sim.sh`)
  the DONE cycles are 157,433 and the 2 MiB dump equals the reference dump (`board_kit/dump_sim_1.bin`) in both builds.
- With `--public-flat-rw` the model has 0 probe nets for `DBG_PROBE=0` and 10 for `DBG_PROBE=1`.
- `./reproduce.sh quick` after this change: 42/42 OK (11-26, `docs/experiments/raw/repro_dbgprobe.out`).
- NOT checked: Vivado synthesis, timing (the current routed WNS is only +0.100 ns, WHS +0.008 ns), BRAM use of the ILA, ILA operation on the board.
  The steps below are the usual Vivado flow written from general knowledge; they were not run on this project.

## Steps (Windows Vivado GUI, as for the existing bitstream)
1. In the block design the chip is an RTL module reference of `chip_axi_top`: set its parameter `DBG_PROBE` to 1 (customize the module reference, or the
   `-generic`/`CONFIG` equivalent of the build) and regenerate the output products.
2. Run synthesis. Open the synthesized design, Tools > Set Up Debug: the ten `pr_*` nets are listed (marked debug). Choose the clock `clk_i`
   (125 MHz), sample depth (start with 2048 or 4096; the run is about 157,000 cycles for image_1, so a trigger is needed), no advanced trigger at first.
3. Implement, check WNS/WHS in the routed report (they must stay >= 0), write the bitstream. The `.hwh` changes too: rebuild `board_kit`
   (`pynq/pack_board_kit.sh`) and record the commit and checksums.
4. On the board: program or load the bitstream, open the Vivado Hardware Manager on the same USB-JTAG. Set the trigger first (examples: `pr_daddr == 0x2000_0000`
   and `pr_dwe` = DONE write; `pr_iaddr == <PC of a function from fw.dis>` to see what runs before it; `pr_run` rising edge for the start), arm the ILA, then start the run from
   Python (`run_chip.py`). Vivado and OpenOCD cannot share the JTAG cable at the same time.
5. Compare the captured fetch addresses with the Verilator instruction fetch trace (`tb_chip.sv` `IF` lines or `sim.cpp` `SIM_TRACE_CPU`) for the same image.

## Limits
The ILA holds a few thousand samples: it shows a window around a trigger, not the whole run. Probing adds routing and BRAM; if timing fails, reduce the probes
(for example only `pr_iaddr` and `pr_done`). The ILA is not a debugger: it cannot stop the core or read registers (that needs a Debug Module, see the plan, D6).
