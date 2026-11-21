# ZCU104 board bring-up plan (living document)

Notion copy: https://app.notion.com/p/41f12d20bf0a817d922dce27e2289c95 (the repo file is the source; update both).
Last updated 2026-11-21. Status words: **done** = verified by a command or report in this repo; **planned** = not run yet;
**unknown** = not checked. Update the status table as steps are executed.

## 1. Starting point (done)
- 125 MHz bitstream built in the Windows Vivado GUI (block design `fpga/bd`, Zynq PS + `chip_axi_wrap`):
  WNS +0.320 ns, WHS +0.010 ns (thin), 0 failing endpoints; LUT 55,775, registers 20,344, BRAM 7, URAM 64, DSP 85.
  File `board_wrapper.bit` (19.3 MB). Details: `docs/P1_REPORT.md` section 4.
- The scripted batch route (`fpga/bd/run_board.sh`) is unreliable (Vivado `EXCEPTION_ACCESS_VIOLATION`, 5 of 6 runs).
- **Nothing has been run on a board.** `pynq/run_chip.py` (written 11-18) has never been executed.
- 150 MHz was not tried with the PS (only out-of-context: WNS +0.005 ns).

## 2. Why this run matters
Vivado xsim of the full chip disagreed with Verilator (done cycles 4,347,318 vs 4,501,912), and an FPU-only xsim test
got 671/1402 vectors right (MUL/ADD/I2F wrong); the cause was not found. **The board result decides whether the
hardware matches the Verilator reference.** If the board matches Verilator, the xsim difference was probably a
modelling issue; if it matches xsim, the synthesized FPU or the RTL has a real problem (not excluded).

## 3. Procedure (small to large; do not skip ahead)
| step | what | pass criterion | status |
|---|---|---|---|
| 0 | PC prep: rename `board_wrapper.bit` -> `board.bit` (keep `board.hwh`, same base name); build the reference dump with the Verilator chip sim; copy files; record SHA256 | files and checksums listed | planned |
| 1 | Boot the board (PYNQ), `Overlay("board.bit")`; `ol.ip_dict` shows the chip; base 0xA000_0000 (64 MiB range from the block design); PL clock 125 MHz | loads without error | planned |
| 2 | AXI path only (`CTRL=0`): write/read back patterns in SRAM and imem | read-back equals written | planned |
| 3 | Run the 16-token image: `python3 run_chip.py board.bit image.bin dump_sim.bin` (root) | `DONE_V` equal to sim, `CYCLES` equal to sim, 2 MiB dump byte-identical | planned |
| 4 | Run the 512-token image (about 4.5 M cycles, about 36 ms at 125 MHz: estimate) | same three criteria | planned |
| 5 | Record cycles, wall time, match; update `PROGRESS.md`, `docs/P1_REPORT.md`, this file; push | docs updated | planned |

### Step 0 commands (PC, repo root)
```
TOP=soc_chip ./build_sim.sh          # if obj_chip/Vsoc_chip is missing
obj_chip/Vsoc_chip gen/out_16_O2u_opta_accfull_d2_L0_G1/image.bin /tmp/dump.bin    # note the DONE cycles it prints
cp <fpga work>/board_proj/board.runs/impl_1/board_wrapper.bit board.bit
cp <fpga work>/board_proj/board.gen/sources_1/bd/board/hw_handoff/board.hwh board.hwh
sha256sum board.bit board.hwh gen/out_16_O2u_opta_accfull_d2_L0_G1/image.bin /tmp/dump.bin
```
Copy to the board: `board.bit`, `board.hwh`, `pynq/run_chip.py`, `image.bin`, `dump.bin` (as `dump_sim.bin`).
(The `.hwh` found earlier was older than the `.bit` (09:08 vs 19:33); confirm it comes from the same block design.)

## 4. Register map the script uses (`acc/chip_axi_top.sv`)
SRAM 2 MiB at 0x000_0000, imem 16 KB at 0x100_0000, CTRL 0x200_0000 (bit0 RUN; 0 = core in reset, memories
accessible), STATUS 0x200_0004 (bit0 DONE), DONE_V 0x200_0008, CYCLES 0x200_000C (PL cycles from RUN to DONE).

## 5. If a step fails
- Step 1: `.bit`/`.hwh` name mismatch or PYNQ version incompatibility are the usual causes; `run_chip.py` finds the IP by a
  name containing `chip` (not verified against the block design cell name).
- Step 3 `DONE` timeout: PL clock setting, reset release, imem contents. Cycle count different from the simulation: suspect
  a logic difference before anything else. Dump differs: look at the first differing address and map it to weights / KV /
  results (weights different = load error; results only = computation difference).
- Load and read-back go word by word through Python MMIO (about 0.5 M words each); if too slow, switch to array access.

## 6. Open items (unknown)
- PYNQ image on the board and its version; how the board is reached (SSH, serial, Jupyter).
- Whether the IP name in `ip_dict` matches what the script searches for.
- 150 MHz with the PS; the final PL clock was set by the script, not re-read from the reports.
