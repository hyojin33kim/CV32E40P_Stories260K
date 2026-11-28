# Debug Module and JTAG transport (vendored 2026-11-26)

| directory | upstream | commit | files taken |
|---|---|---|---|
| `riscv-dbg/` | https://github.com/pulp-platform/riscv-dbg | `643607e` (Merge pull request #206) | `src/` dm_pkg, dm_csrs, dm_mem, dm_sba, dm_top, dm_obi_top, dmi_cdc, dmi_jtag, dmi_jtag_tap, dmi_bscane_tap; `debug_rom/` debug_rom, debug_rom_one_scratch; LICENSE, LICENSE.SiFive |
| `tech_cells_generic/` | https://github.com/pulp-platform/tech_cells_generic | shallow clone of the default branch on the same day (commit not recorded; record it when updating) | `src/rtl/tc_clk.sv` (needs tc_clk_inverter and tc_clk_mux2 only) |

Unmodified copies. Not taken: testbenches, sva, docs, the C debug ROM sources. The `common_cells` modules these files use (`cdc_2phase`, `fifo_v3`, `sync`, ...)
are already in `cv32e40p-master/rtl/vendor/pulp_platform_common_cells/src`.

`dmi_jtag_tap.sv` (real TAP on JTAG pins, for simulation) and `dmi_bscane_tap.sv` (Xilinx `BSCANE2`, USER3 and USER4 chains of the FPGA's own JTAG chain; not used since 11-28, E17: FPGA-only)
define the same module name and are pin compatible: put exactly one of them in a file list. Licenses: Solderpad Hardware License (see the LICENSE files).
