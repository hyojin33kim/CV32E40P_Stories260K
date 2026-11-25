# 15M-class model on this tile: sizes, address map, buffers, FIFOs, pre-tiling (design, 11-22)

Status words: **measured** = a command in this repository produced it; **computed** = arithmetic on the config
(`docs/size_model.py`); **proposal** = design choice not yet implemented; **unknown** = not checked.
The Stories15M config used here (dim 288, hidden 768, 6 layers, 6 heads, 6 KV heads, vocab 32,000, seq 256) is **unconfirmed**:
no model file is in this repository (PLAYBOOK gate 15-0). Nothing here was run on a board or on a real 15M model.

## 1. Sizes (computed, `python3 docs/size_model.py`)
| Item | Size |
|---|---:|
| Parameters | 15,187,968 (15.19 M; per layer 995,328) |
| fp32 weights (embedding table shared with the classifier) | 57.94 MiB + RMS weights 14.6 KiB |
| int8 matrices incl. classifier (rows padded to 16 B) | 14.48 MiB |
| int8 row scales (49,856 rows x 4 B) | 194.8 KiB |
| fp32 embedding table, if kept for the lookup | 35.16 MiB (int8 design would total 49.85 MiB: no saving) |
| int8 design with the lookup done from the int8 table (x = wq * s) | **14.69 MiB** |
| KV cache fp32 / int8 + per-head scales | 3.375 MiB / 0.914 MiB |
| Activations and logits buffers (fp32) | 143.8 KiB (logits alone 125 KiB) |
| URAM data capacity of XCZU7EV | 96 x 32 KiB = 3.00 MiB |
Check against the 260K model: the script gives int8 0.25 MiB + 13.7 KiB scales and KV 0.625 MiB, equal to the measured layout.
Row length: n = 288 -> 18 lines (int8) / 72 (fp32); n = 768 -> 48 / 192.

## 2. Consequences that drive the design
1. **KV fp32 (3.375 MiB) does not fit the on-chip URAM (3.0 MiB)**, so KV is int8 or fp16 on chip (int8 KV measured +0.003 nats
   together with W8A8 on the 260K model; not measured on 15M), or it goes to DDR.
2. **KV in DDR needs a write path.** `axi_ext_rd` is read-only; the CPU writes the new K and V rows and the accelerator reads them back.
   An AXI write master is not designed. This is the main reason to keep KV on chip.
3. **The int8 design only saves memory if the embedding lookup uses the int8 table** (x = wq * s: one more fmul per element on the CPU,
   a new numeric definition, accuracy not measured). With a separate fp32 table the int8 design is 49.85 MiB (fp32: 57.94 MiB).
4. **Buffers:** the engine's x buffer must hold n up to 768 and y at most the rows of one call; the classifier (32,000 rows) is
   issued in 32 calls of up to 1024 rows. The engine and VFU were built with 1024-word buffers (`ACC_XBUF`, `ACC_YBUF`, `VFU_BUF`)
   and verified on 15M-class shapes (section 6).

## 3. Address map (proposal)
CPU view; MMIO (0x3000_0000 gemv, 0x3000_0040 vfu) and the sim DONE address (0x2000_0000) are unchanged.
| Region | Option I: int8 weights (recommended) | Option II: fp32 weights |
|---|---|---|
| External weight window (DDR, read only) | 0x0000_0000 .. 0x00FF_FFFF (16 MiB; needs 14.69 MiB + RMS) | 0x0000_0000 .. 0x03FF_FFFF (64 MiB; needs 57.94 MiB) |
| imem | 0x0100_0000 (unchanged) | must move above the window, e.g. 0x0800_0000 |
| SRAM (KV, activations, control, stack) | 0x0200_0000, 2 MiB (KV int8 0.91 + act 0.14 + control about 0.3 = about 1.4 MiB) | e.g. 0x1000_0000, 2 MiB |
| KV precision | int8 (or fp16) | int8 or fp16 (fp32 does not fit) |
RTL support today: `EXT_BELOW` (soc_top, gemv_acc) is a parameter; `chip_axi_ddr_top` compares the CPU address with 0x0010_0000 and
`soc_chip` derives `SRAM_BASE` from `WEIGHTS_ONCHIP`; the AXI4-Lite SRAM window is 0x010_0000..0x01F_FFFF; imem is fixed at 0x0100_0000
and the boot address at 0x0100_0080. **Not done:** make SRAM_BASE and the external limit module parameters, widen the AXI4-Lite SRAM window,
and make `link.ld`, `image.py` and `firmware_gen.c` (many absolute 0x1xxxxx addresses) layout-driven. That is the firmware port of PLAYBOOK gate 15-3.

## 4. External line FIFO and in-flight limit
Measured counters (8-token images, DDR top, latency 40): `eq_max` = 0 for fp32 and int8, `tq_full` = 0. The 64-line external FIFO of
`soc_chip` is never used beyond bypass, so enlarging it is not needed. The in-flight limit `CRED` (48 lines) is the constraint:
needed in flight = latency x consumption rate = 40 cycles x 16 B = 640 B = 40 lines (fits); at latency 80 it needs 80 lines and measured
cycles rise by 26 % (`acc/S5B_DDR_AXI.md`). If the real DDR latency is longer, raise `CRED` and `EQ` together (EQ >= CRED + margin).
The real latency of the board's HP port is unknown.

## 5. Pre-tiling (implemented, simulation-verified)
Problem (computed, `python3 w8/pretile.py`): the engine reads (group of 16 rows, run of 8 lines, row, line), so with row-major weights
consecutive reads are only the 8 lines of one row segment. Merged bursts average 6.0 to 8.0 lines (about 100 to 130 B) for 15M shapes.
Pre-tiled weights stored in this issue order make the whole (rows of a group) x (run) block contiguous:
| Matrix | lines | row-major bursts (avg) | pre-tiled, MAXB 16 | MAXB 64 | MAXB 256 (4 KB) |
|---|---:|---:|---:|---:|---:|
| 15M Wq/Wo int8 | 5,184 | 862 (6.0) | 324 (16.0) | 81 (64.0) | 21 (246.9) |
| 15M W1/W3 int8 | 13,824 | 2,298 (6.0) | 864 (16.0) | 216 (64.0) | 54 (256.0) |
| 15M W2 int8 | 13,824 | 1,728 (8.0) | 864 (16.0) | 216 (64.0) | 54 (256.0) |
| 15M classifier chunk (1024 rows) int8 | 18,432 | 3,064 (6.0) | 1,152 (16.0) | 288 (64.0) | 72 (256.0) |
| 15M W1/W3 fp32 | 55,296 | 6,888 (8.0) | 3,456 (16.0) | 864 (64.0) | 216 (256.0) |
Implementation: `gemv_acc` CTRL bit2 (tiled): modes A and D read line i at W_ADDR + 16 * i (W_STRIDE ignored); packer `w8/pretile.py`
(`fetch_order`, `tile`). The packed order depends on the engine (rows per group LL = LANES x FPU latency = 16, RUN = 8): an image is tied to that configuration.
Verification (measured): unit test with every case also run pre-tiled and compared with the software reference: 355 cases (n, d <= 512) and
14 cases of 15M-class shapes (buffers 1024): 0 mismatching words in both layouts; the C packer in the firmware, `w8/pretile.py` and the RTL address
counter agree. `reproduce.sh quick` 42/42. Accelerator cycles are equal to the row-major run (338,105 vs 338,105; 400,930 vs 400,925), as expected for on-chip memory.
**Not measured:** the effect on the DDR top (needs `AXI_MAXB` 64 or 256 and an image packed by `pretile.py`); the model-wide packer is not integrated into the image builder; fp32 mode A tiled
is not unit-tested (same address logic as mode D, not tested separately).

## 6. Verification status of the 15M-related changes (measured)
| Check | Result |
|---|---|
| int8 GEMV on 15M-class shapes, buffers 1024 (n 288/768/1024, d 288/768/1000/1024, random sizes) | 14 cases, 5,921 rows, 1,487,327 MAC: 0 mismatches, 0 sentinel violations |
| same, pre-tiled | 0 mismatches |
| default buffers (512) unchanged | `reproduce.sh quick` 42/42 OK |
| VFU with buffer 1024 | built only; not unit-tested at length 768 |
| throughput of a 15M model | bounds only, section 7 |

## 7. Throughput bounds (computed, ignore CPU work, attention and command overhead)
At 125 MHz, 12.8 B/cycle DDR share, 1 MAC/cycle/lane: 4 lanes fp32 4.75 M cycles/token (memory bound, 26 tok/s); 4 lanes int8 3.80 M (compute bound, 33 tok/s);
8 lanes int8 1.90 M (66 tok/s); 16 lanes int8 1.19 M (memory bound, 105 tok/s). CPU work (RoPE, rmsnorm, argmax over 32,000 logits) is not included and
was 10 to 27 % of a 260K step; it needs its own profile on 15M.

## 8. Decisions needed from the user
1. Target model confirmed as Stories15M and the model file (SHA256, config).
2. Embedding lookup from the int8 table (new numeric definition) or a separate fp32 table (no memory saving).
3. KV: int8 or fp16 on chip (recommended) vs DDR (needs a write path).
4. Option I (int8, 16 MiB window, imem unchanged) vs Option II (fp32, 64 MiB, relocation).
5. Lanes: 4 (33 tok/s bound) or more; area and DDR share decide.
