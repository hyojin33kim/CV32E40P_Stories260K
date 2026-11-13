// CV32E40P (FPU=1) + gemv_acc. Same external CPU ports as cv32e40p_top as used by
// sim.cpp, plus the accelerator's memory master (acc_*), served by the simulator.
// CPU data accesses to 0x3000_0000..0x3000_003F go to the accelerator registers
// (granted immediately, read data returned next cycle); everything else is passed
// to the external data port unchanged.
module soc_top (
    input logic clk_i,
    input logic rst_ni,
    input logic pulp_clock_en_i,
    input logic scan_cg_en_i,
    input logic [31:0] boot_addr_i,
    input logic [31:0] mtvec_addr_i,
    input logic fetch_enable_i,

    output logic        instr_req_o,
    input  logic        instr_gnt_i,
    input  logic        instr_rvalid_i,
    output logic [31:0] instr_addr_o,
    input  logic [31:0] instr_rdata_i,

    output logic        data_req_o,
    input  logic        data_gnt_i,
    input  logic        data_rvalid_i,
    output logic        data_we_o,
    output logic [ 3:0] data_be_o,
    output logic [31:0] data_addr_o,
    output logic [31:0] data_wdata_o,
    input  logic [31:0] data_rdata_i,

    output logic        acc_req_o,
    output logic        acc_we_o,
    output logic [31:0] acc_addr_o,
    output logic [31:0] acc_wdata_o,
    input  logic        acc_gnt_i,
    input  logic        acc_rvalid_i,
    input  logic [31:0] acc_rdata_i
);
  localparam logic [31:0] ACC_BASE = 32'h3000_0000;

  logic        c_req, c_gnt, c_rvalid, c_we;
  logic [ 3:0] c_be;
  logic [31:0] c_addr, c_wdata, c_rdata, s_rdata;
  logic        is_mmio, mmio_rvalid_q;

  cv32e40p_top #(.FPU(1)) cpu_i (
      .clk_i, .rst_ni, .pulp_clock_en_i, .scan_cg_en_i,
      .boot_addr_i, .mtvec_addr_i,
      .dm_halt_addr_i(32'h0), .hart_id_i(32'h0), .dm_exception_addr_i(32'h0),
      .instr_req_o, .instr_gnt_i, .instr_rvalid_i, .instr_addr_o, .instr_rdata_i,
      .data_req_o(c_req), .data_gnt_i(c_gnt), .data_rvalid_i(c_rvalid), .data_we_o(c_we),
      .data_be_o(c_be), .data_addr_o(c_addr), .data_wdata_o(c_wdata), .data_rdata_i(c_rdata),
      .irq_i(32'h0), .irq_ack_o(), .irq_id_o(),
      .debug_req_i(1'b0), .debug_havereset_o(), .debug_running_o(), .debug_halted_o(),
      .fetch_enable_i, .core_sleep_o()
  );

  assign is_mmio      = (c_addr & 32'hFFFF_FFC0) == ACC_BASE;
  assign data_req_o   = c_req && !is_mmio;
  assign data_we_o    = c_we;
  assign data_be_o    = c_be;
  assign data_addr_o  = c_addr;
  assign data_wdata_o = c_wdata;
  assign c_gnt        = is_mmio ? 1'b1 : data_gnt_i;
  assign c_rvalid     = data_rvalid_i || mmio_rvalid_q;
  assign c_rdata      = mmio_rvalid_q ? s_rdata : data_rdata_i;

  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) mmio_rvalid_q <= 1'b0;
    else mmio_rvalid_q <= c_req && is_mmio;

  gemv_acc acc_i (
      .clk_i, .rst_ni,
      .s_req_i(c_req && is_mmio), .s_we_i(c_we), .s_addr_i(c_addr[5:0]),
      .s_wdata_i(c_wdata), .s_rdata_o(s_rdata),
      .m_req_o(acc_req_o), .m_we_o(acc_we_o), .m_addr_o(acc_addr_o), .m_wdata_o(acc_wdata_o),
      .m_gnt_i(acc_gnt_i), .m_rvalid_i(acc_rvalid_i), .m_rdata_i(acc_rdata_i)
  );
endmodule
