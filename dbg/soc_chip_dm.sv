// soc_chip with the RISC-V Debug Module (docs/DEBUG_MODULE.md): soc_chip (DM_EN = 1) + dm_obi_top + dmi_jtag from dbg/riscv-dbg.
// Same ports as soc_chip, without the dm_* bus (internal), plus the JTAG pins and the always-on reset of the Debug Module.
// JTAG: dmi_jtag_tap.sv gives a real TAP on tck/tms/tdi/tdo (simulation); dmi_bscane_tap.sv replaces it with the BSCANE2 primitives of the FPGA
// (the pins are then unused: tie tck/tms/tdi to 0, trst_ni to 1, leave tdo open). Put exactly one of the two files in the file list.
module soc_chip_dm #(
    parameter int    ACC_LANES   = 4,
    parameter int    VFU_LANES   = 4,
    parameter int    ACC_RUN     = 8,
    parameter int    ACC_FDEPTH  = 256,
    parameter int    CPU_FPU_LAT = 4,
    parameter int    ACC_FPU_LAT = 4,
    parameter int    VFU_FPU_LAT = 4,
    parameter int    SRAM_RLAT   = 1,
    parameter int    SRAM_RLAT_B = 2,
    parameter int    SRAM_CASCADE = 0,
    parameter bit    SRAM_BREG = 1'b1,
    parameter bit    SRAM_AREG = 1'b0,
    parameter bit    WEIGHTS_ONCHIP = 1'b1,
    parameter string IMEM_INIT   = "",
    parameter logic [31:0] DM_BASE = 32'h1A11_0000,
    parameter logic [31:0] JTAG_IDCODE = 32'h0000_0DB3
) (
    input logic clk_i,
    input logic rst_ni,                 // core reset (the board top holds it low until RUN)
    input logic dm_rst_ni,              // always-on reset of the Debug Module (system reset)
    input logic fetch_enable_i,

    input  logic        ld_req_i,
    input  logic        ld_we_i,
    input  logic [31:0] ld_addr_i,
    input  logic [31:0] ld_wdata_i,
    output logic [31:0] ld_rdata_o,
    output logic        ld_rvalid_o,

    output logic        data_req_o,
    input  logic        data_gnt_i,
    input  logic        data_rvalid_i,
    output logic        data_we_o,
    output logic [ 3:0] data_be_o,
    output logic [31:0] data_addr_o,
    output logic [31:0] data_wdata_o,
    input  logic [31:0] data_rdata_i,

    output logic         acc_req_o,
    output logic         acc_we_o,
    output logic [ 31:0] acc_addr_o,
    output logic [ 31:0] acc_wdata_o,
    input  logic         acc_gnt_i,
    input  logic         acc_rvalid_i,
    input  logic [127:0] acc_rdata_i,

    output logic        dbg_instr_req_o,
    output logic [31:0] dbg_instr_addr_o,
    output logic        dbg_data_req_o,
    output logic        dbg_data_we_o,
    output logic [31:0] dbg_data_addr_o,
    output logic [31:0] perf_gemv_busy_o,
    output logic [31:0] perf_vfu_busy_o,
    output logic [31:0] perf_acc_stall_o,
    output logic [31:0] perf_acc_rd_o,
    output logic [31:0] perf_tq_full_o,
    output logic [31:0] perf_eq_max_o,

    input  logic        jtag_tck_i,
    input  logic        jtag_tms_i,
    input  logic        jtag_trst_ni,
    input  logic        jtag_tdi_i,
    output logic        jtag_tdo_o,
    output logic        ndmreset_o,     // non-debug-module reset request: the board top resets the core and the accelerators with it
    output logic        debug_halted_o
);
  logic        dm_debug_req;
  logic        sl_req, sl_we;
  logic [31:0] sl_addr, sl_wdata, sl_rdata;
  logic [ 3:0] sl_be;

  soc_chip #(.ACC_LANES(ACC_LANES), .VFU_LANES(VFU_LANES), .ACC_RUN(ACC_RUN), .ACC_FDEPTH(ACC_FDEPTH),
             .CPU_FPU_LAT(CPU_FPU_LAT), .ACC_FPU_LAT(ACC_FPU_LAT), .VFU_FPU_LAT(VFU_FPU_LAT),
             .SRAM_RLAT(SRAM_RLAT), .SRAM_RLAT_B(SRAM_RLAT_B), .SRAM_CASCADE(SRAM_CASCADE), .SRAM_BREG(SRAM_BREG), .SRAM_AREG(SRAM_AREG),
             .WEIGHTS_ONCHIP(WEIGHTS_ONCHIP), .IMEM_INIT(IMEM_INIT), .DM_EN(1'b1), .DM_BASE(DM_BASE)) chip_i (
      .clk_i, .rst_ni, .fetch_enable_i,
      .ld_req_i, .ld_we_i, .ld_addr_i, .ld_wdata_i, .ld_rdata_o, .ld_rvalid_o,
      .data_req_o, .data_gnt_i, .data_rvalid_i, .data_we_o, .data_be_o, .data_addr_o, .data_wdata_o, .data_rdata_i,
      .acc_req_o, .acc_we_o, .acc_addr_o, .acc_wdata_o, .acc_gnt_i, .acc_rvalid_i, .acc_rdata_i,
      .dbg_instr_req_o, .dbg_instr_addr_o, .dbg_data_req_o, .dbg_data_we_o, .dbg_data_addr_o,
      .perf_gemv_busy_o, .perf_vfu_busy_o, .perf_acc_stall_o, .perf_acc_rd_o, .perf_tq_full_o, .perf_eq_max_o,
      .dm_debug_req_i(dm_debug_req), .dm_slave_req_o(sl_req), .dm_slave_we_o(sl_we), .dm_slave_addr_o(sl_addr),
      .dm_slave_be_o(sl_be), .dm_slave_wdata_o(sl_wdata), .dm_slave_rdata_i(sl_rdata), .debug_halted_o);

  // system bus access of the Debug Module: not connected to a memory; every access ends with a bus error (sberror), so a debugger that
  // tries it falls back to the program buffer instead of waiting for a response that never comes
  logic        sba_req, sba_rv_q;
  always_ff @(posedge clk_i or negedge dm_rst_ni)
    if (!dm_rst_ni) sba_rv_q <= 1'b0; else sba_rv_q <= sba_req;

  localparam dm::hartinfo_t HARTINFO = '{zero1: '0, nscratch: 4'd2, zero0: '0, dataaccess: 1'b1, datasize: dm::DataCount, dataaddr: dm::DataAddr};
  dm::dmi_req_t  dmi_req;
  dm::dmi_resp_t dmi_resp;
  logic dmi_req_valid, dmi_req_ready, dmi_resp_valid, dmi_resp_ready, dmi_rst_n, dm_active, tdo_oe;
  logic [0:0] dbg_req_v;
  logic sl_rvalid_unused;

  dm_obi_top #(.IdWidth(1), .NrHarts(1), .BusWidth(32), .DmBaseAddress(DM_BASE)) i_dm (
      .clk_i, .rst_ni(dm_rst_ni), .testmode_i(1'b0),
      .ndmreset_o, .dmactive_o(dm_active), .debug_req_o(dbg_req_v),
      .unavailable_i(!rst_ni), .hartinfo_i(HARTINFO),
      .slave_req_i(sl_req), .slave_gnt_o(), .slave_we_i(sl_we), .slave_addr_i(sl_addr), .slave_be_i(sl_be), .slave_wdata_i(sl_wdata),
      .slave_aid_i(1'b0), .slave_rvalid_o(sl_rvalid_unused), .slave_rdata_o(sl_rdata), .slave_rid_o(),
      .master_req_o(sba_req), .master_addr_o(), .master_we_o(), .master_wdata_o(), .master_be_o(),
      .master_gnt_i(1'b1), .master_rvalid_i(sba_rv_q), .master_err_i(1'b1), .master_other_err_i(1'b0), .master_rdata_i('0),
      .dmi_rst_ni(dmi_rst_n), .dmi_req_valid_i(dmi_req_valid), .dmi_req_ready_o(dmi_req_ready), .dmi_req_i(dmi_req),
      .dmi_resp_valid_o(dmi_resp_valid), .dmi_resp_ready_i(dmi_resp_ready), .dmi_resp_o(dmi_resp));
  assign dm_debug_req = dbg_req_v[0];

  dmi_jtag #(.IdcodeValue(JTAG_IDCODE)) i_dmi_jtag (
      .clk_i, .rst_ni(dm_rst_ni), .testmode_i(1'b0), .dmi_rst_no(dmi_rst_n),
      .dmi_req_o(dmi_req), .dmi_req_valid_o(dmi_req_valid), .dmi_req_ready_i(dmi_req_ready),
      .dmi_resp_i(dmi_resp), .dmi_resp_ready_o(dmi_resp_ready), .dmi_resp_valid_i(dmi_resp_valid),
      .tck_i(jtag_tck_i), .tms_i(jtag_tms_i), .trst_ni(jtag_trst_ni), .td_i(jtag_tdi_i), .td_o(jtag_tdo_o), .tdo_oe_o(tdo_oe));
endmodule
