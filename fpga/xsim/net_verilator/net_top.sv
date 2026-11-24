// Top of the post-synthesis netlist simulation in the cycle simulator (D4): the UNISIM models read the global set/reset via the hierarchical
// name glbl.GSR, so glbl must be an instance above the netlist. Ports are those of soc_chip (netlist).
module net_top (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         fetch_enable_i,
    input  logic         ld_req_i,
    input  logic         ld_we_i,
    input  logic [31:0]  ld_addr_i,
    input  logic [31:0]  ld_wdata_i,
    output logic [31:0]  ld_rdata_o,
    output logic         ld_rvalid_o,
    output logic         data_req_o,
    input  logic         data_gnt_i,
    input  logic         data_rvalid_i,
    output logic         data_we_o,
    output logic [3:0]   data_be_o,
    output logic [31:0]  data_addr_o,
    output logic [31:0]  data_wdata_o,
    input  logic [31:0]  data_rdata_i
);
  glbl glbl ();
  logic         acc_req_o, acc_we_o, dbg_instr_req_o, dbg_data_req_o, dbg_data_we_o;
  logic [31:0]  acc_addr_o, acc_wdata_o, dbg_instr_addr_o, dbg_data_addr_o;
  logic [31:0]  perf_gemv_busy_o, perf_vfu_busy_o, perf_acc_stall_o, perf_acc_rd_o, perf_tq_full_o, perf_eq_max_o;
  soc_chip dut (
      .clk_i, .rst_ni, .fetch_enable_i,
      .ld_req_i, .ld_we_i, .ld_addr_i, .ld_wdata_i, .ld_rdata_o, .ld_rvalid_o,
      .data_req_o, .data_gnt_i, .data_rvalid_i, .data_we_o, .data_be_o, .data_addr_o, .data_wdata_o, .data_rdata_i,
      .acc_req_o, .acc_we_o, .acc_addr_o, .acc_wdata_o, .acc_gnt_i(1'b1), .acc_rvalid_i(1'b0), .acc_rdata_i(128'h0),
      .dbg_instr_req_o, .dbg_instr_addr_o, .dbg_data_req_o, .dbg_data_we_o, .dbg_data_addr_o,
      .perf_gemv_busy_o, .perf_vfu_busy_o, .perf_acc_stall_o, .perf_acc_rd_o, .perf_tq_full_o, .perf_eq_max_o);
endmodule
