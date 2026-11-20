// Vivado xsim testbench for soc_chip with the synthesized memory models (XPM URAM, UNISIM BUFGCE):
// the board flow through the loader port, no backdoor.
//   1. core in reset: write imem (16 KB) and the SRAM image (2 MiB, non-zero words) via ld_*
//   2. release reset, run until the firmware writes 0x2000_0000 (DONE) on the external data port
//   3. core in reset again: read the whole SRAM back via ld_* and write it as a hex dump
// Files (from fpga/xsim/run_xsim.sh): imem.hex (4096 words), sram.hex (524288 words), out: dump.hex.
// Output line: "TB DONE run_cycles=<cycles from reset release to DONE>".
`timescale 1ns / 1ps
module tb_chip;
  localparam int SRAM_WORDS = 524288, IMEM_WORDS = 4096;
  logic clk = 1'b0, rst_n = 1'b0;
  always #3.333 clk = ~clk;                       // 150 MHz (period only matters for waveforms)

  logic        ld_req = 0, ld_we = 0, ld_rvalid;
  logic [31:0] ld_addr = 0, ld_wdata = 0, ld_rdata;
  logic        d_req, d_we, d_rvalid = 0;
  logic [ 3:0] d_be;
  logic [31:0] d_addr, d_wdata;
  logic        a_req, a_we;
  logic [31:0] a_addr, a_wdata;

  soc_chip dut (
      .clk_i(clk), .rst_ni(rst_n), .fetch_enable_i(1'b1),
      .ld_req_i(ld_req), .ld_we_i(ld_we), .ld_addr_i(ld_addr), .ld_wdata_i(ld_wdata),
      .ld_rdata_o(ld_rdata), .ld_rvalid_o(ld_rvalid),
      .data_req_o(d_req), .data_gnt_i(1'b1), .data_rvalid_i(d_rvalid), .data_we_o(d_we),
      .data_be_o(d_be), .data_addr_o(d_addr), .data_wdata_o(d_wdata), .data_rdata_i(32'h0),
      .acc_req_o(a_req), .acc_we_o(a_we), .acc_addr_o(a_addr), .acc_wdata_o(a_wdata),
      .acc_gnt_i(1'b1), .acc_rvalid_i(1'b0), .acc_rdata_i(128'h0),
      .dbg_instr_req_o(), .dbg_instr_addr_o(), .dbg_data_req_o(), .dbg_data_we_o(), .dbg_data_addr_o());

  // external data port: answered next cycle; a write to 0x2000_0000 is DONE
  logic done = 0;
  always_ff @(posedge clk) begin
    d_rvalid <= d_req && rst_n;
    if (rst_n && d_req && d_we && d_addr == 32'h2000_0000) done <= 1'b1;
  end

  logic [31:0] imem_img[IMEM_WORDS];
  logic [31:0] sram_img[SRAM_WORDS];
  logic [31:0] dump[SRAM_WORDS];
  longint run_cycles = 0;
  integer fd, nz, tf, trace_n;

  task automatic ld_write(input logic [31:0] a, input logic [31:0] d);
    @(negedge clk); ld_req = 1; ld_we = 1; ld_addr = a; ld_wdata = d;
    @(negedge clk); ld_req = 0; ld_we = 0;
  endtask

  initial begin
    $readmemh("imem.hex", imem_img);
    $readmemh("sram.hex", sram_img);
    repeat (10) @(posedge clk);
    for (int i = 0; i < IMEM_WORDS; i++) ld_write(32'h0100_0000 + 4 * i, imem_img[i]);
    nz = 0;
    for (int i = 0; i < SRAM_WORDS; i++) if (sram_img[i] != 0) begin ld_write(4 * i, sram_img[i]); nz++; end
    $display("TB loaded imem %0d words, sram %0d non-zero words at %0t", IMEM_WORDS, nz, $time);
    if (!$value$plusargs("TRACE_N=%d", trace_n)) trace_n = 0;
    if (trace_n > 0) tf = $fopen("trace_xsim.txt", "w");
    @(negedge clk); rst_n = 1;
    while (!done) begin
      // CPU data port trace (signals sampled just before the rising edge), same format as sim.cpp SIM_TRACE_CPU
      if (trace_n > 0 && run_cycles < trace_n) begin
        if (dut.d_req && dut.d_gnt) $fdisplay(tf, "%0d REQ we=%0d be=%h a=%08h wd=%08h", run_cycles, dut.d_we, dut.d_be, dut.d_addr, dut.d_wdata);
        if (dut.d_rvalid) $fdisplay(tf, "%0d RSP rd=%08h", run_cycles, dut.d_rdata);
      end
      // FPU (APU) interface for cycles 4100..4200 of the trace window
      if (trace_n > 0 && run_cycles >= 4100 && run_cycles < 4200)
        $fdisplay(tf, "%0d APU req=%0d gnt=%0d op=%h a=%h b=%h c=%h | rv=%0d rd=%h", run_cycles,
          dut.soc_i.cpu_i.apu_req, dut.soc_i.cpu_i.apu_gnt, dut.soc_i.cpu_i.apu_op,
          dut.soc_i.cpu_i.apu_operands[0], dut.soc_i.cpu_i.apu_operands[1], dut.soc_i.cpu_i.apu_operands[2],
          dut.soc_i.cpu_i.apu_rvalid, dut.soc_i.cpu_i.apu_rdata);
      if (trace_n > 0 && run_cycles == trace_n) begin $fclose(tf); $display("TB TRACE written, stopping"); $finish; end
      @(posedge clk); run_cycles++; @(negedge clk);
      if (run_cycles % 500000 == 0) $display("TB running %0d", run_cycles);
    end
    $display("TB DONE run_cycles=%0d", run_cycles);
    @(negedge clk); rst_n = 0;
    repeat (5) @(posedge clk);
    // read back: request at a falling edge, captured at the next rising edge (port A latency 1),
    // data and ld_rvalid valid right after that edge
    for (int i = 0; i < SRAM_WORDS; i++) begin
      @(negedge clk); ld_req = 1; ld_we = 0; ld_addr = 4 * i;
      @(posedge clk); #1;
      if (!ld_rvalid) $fatal(1, "loader read %0d: no rvalid", i);
      dump[i] = ld_rdata;
    end
    @(negedge clk); ld_req = 0;
    fd = $fopen("dump.hex", "w");
    for (int i = 0; i < SRAM_WORDS; i++) $fdisplay(fd, "%08h", dump[i]);
    $fclose(fd);
    $display("TB WROTE dump.hex");
    $finish;
  end
endmodule
