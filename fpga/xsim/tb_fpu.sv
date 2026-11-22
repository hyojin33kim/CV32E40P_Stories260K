// FPU-only test: cv32e40p_fp_wrapper (CPU FPU, FPU_ADDMUL_LAT / FPU_OTHERS_LAT 4) on vec.hex, one
// operation at a time (req until gnt, wait rvalid), results to fpu_out.hex. With NETLIST defined the
// DUT is the post-synthesis functional netlist (parameters fixed at synthesis).
`timescale 1ns / 1ps
module tb_fpu;
  logic clk = 0, rst_n = 0;
  always #3.333 clk = ~clk;
  logic        req = 0, gnt, rvalid;
  logic [2:0][31:0] opnd = '0;
  logic [5:0]  op = 0;
  logic [14:0] flags = 15'h400;             // {INT32, FP32, FP32, RNE} as the CPU sends them
  logic [31:0] rdata;
  logic [4:0]  rflags;
`ifdef NETLIST
  cv32e40p_fp_wrapper dut (
`else
  cv32e40p_fp_wrapper #(.FPU_ADDMUL_LAT(4), .FPU_OTHERS_LAT(4)) dut (
`endif
`ifdef NETLIST   // the netlist splits the packed operand array into escaped-name ports
      .\apu_operands_i[0] (opnd[0]), .\apu_operands_i[1] (opnd[1]), .\apu_operands_i[2] (opnd[2]),
      .clk_i(clk), .rst_ni(rst_n), .apu_req_i(req), .apu_gnt_o(gnt),
`else
      .clk_i(clk), .rst_ni(rst_n), .apu_req_i(req), .apu_gnt_o(gnt), .apu_operands_i(opnd),
`endif
      .apu_op_i(op), .apu_flags_i(flags), .apu_rvalid_o(rvalid), .apu_rdata_o(rdata), .apu_rflags_o(rflags));
  integer fi, fo, n, k;
  logic [31:0] o, a, b, c;
  initial begin
    fi = $fopen("vec.hex", "r"); fo = $fopen("fpu_out.hex", "w");
    repeat (5) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);
    n = 0;
    while ($fscanf(fi, "%h %h %h %h\n", o, a, b, c) == 4) begin
      @(negedge clk); op = o[5:0]; opnd[0] = a; opnd[1] = b; opnd[2] = c; req = 1;
      do @(posedge clk); while (!gnt);
      #0.1 req = 0;
      k = 0;
      while (!rvalid) begin @(posedge clk); #0.1; if (++k > 200) $fatal(1, "no rvalid, vector %0d", n); end
      $fdisplay(fo, "%08h", rdata);
      n++;
      @(posedge clk);
    end
    $fclose(fo);
    $display("TB_FPU %0d vectors done", n);
    $finish;
  end
endmodule
