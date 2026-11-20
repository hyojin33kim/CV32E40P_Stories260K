// Unit test: sram_dp with the XPM URAM model (USE_XPM) vs the behavioural model (sram_beh), same random
// traffic on both ports every cycle; read data compared on the cycles it is valid (port A RLAT, port B RLAT_B).
`timescale 1ns / 1ps
module tb_sram;
  localparam int LINES = 1024, RLAT = 1, RLAT_B = 2, AW = $clog2(LINES) + 4, N = 200000;
  logic clk = 0;
  always #3.333 clk = ~clk;
  logic          a_en, a_we, b_en, b_we;
  logic [3:0]    a_be;
  logic [AW-1:0] a_addr, b_addr;
  logic [31:0]   a_wd, b_wd, a_rx, a_rb;
  logic [127:0]  b_rx, b_rb;
  sram_dp  #(.LINES(LINES), .RLAT(RLAT), .RLAT_B(RLAT_B)) x (.clk_i(clk),
      .a_en_i(a_en), .a_we_i(a_we), .a_be_i(a_be), .a_addr_i(a_addr), .a_wdata_i(a_wd), .a_rdata_o(a_rx),
      .b_en_i(b_en), .b_we_i(b_we), .b_addr_i(b_addr), .b_wdata_i(b_wd), .b_rdata_o(b_rx));
  sram_beh #(.LINES(LINES), .RLAT(RLAT), .RLAT_B(RLAT_B)) r (.clk_i(clk),
      .a_en_i(a_en), .a_we_i(a_we), .a_be_i(a_be), .a_addr_i(a_addr), .a_wdata_i(a_wd), .a_rdata_o(a_rb),
      .b_en_i(b_en), .b_we_i(b_we), .b_addr_i(b_addr), .b_wdata_i(b_wd), .b_rdata_o(b_rb));
  logic [RLAT-1:0]   av = 0;   // port A read issued RLAT cycles ago
  logic [RLAT_B-1:0] bv = 0;
  int errs = 0, ca = 0, cb = 0;
  initial begin
    {a_en, a_we, b_en, b_we} = 0; a_be = 0; a_addr = 0; b_addr = 0; a_wd = 0; b_wd = 0;
    // fill both models identically through port B (word writes), then random traffic
    for (int i = 0; i < LINES * 4; i++) begin
      @(negedge clk); b_en = 1; b_we = 1; b_addr = AW'(4 * i); b_wd = $urandom;
    end
    @(negedge clk); b_en = 0; b_we = 0;
    for (int c = 0; c < N; c++) begin
      @(negedge clk);
      // check read data due this cycle (outputs after the last rising edge)
      if (av[0]) begin ca++; if (a_rx !== a_rb) begin errs++; if (errs < 10) $display("A mismatch c=%0d xpm=%h beh=%h", c, a_rx, a_rb); end end
      if (bv[0]) begin cb++; if (b_rx !== b_rb) begin errs++; if (errs < 10) $display("B mismatch c=%0d xpm=%h beh=%h", c, b_rx, b_rb); end end
      a_en = ($urandom % 3) != 0; a_we = a_en && ($urandom % 3 == 0); a_be = $urandom; a_wd = $urandom;
      a_addr = AW'({$urandom % 64, 2'b00});           // small window: many same-line accesses
      b_en = ($urandom % 3) != 0; b_we = b_en && ($urandom % 4 == 0); b_wd = $urandom;
      b_addr = AW'({$urandom % 64, 2'b00});
      if (a_en && a_we && b_en && b_we && a_addr[AW-1:4] == b_addr[AW-1:4]) b_we = 0;  // no double write
      if (a_en && b_en && (a_we || b_we) && a_addr[AW-1:4] == b_addr[AW-1:4]) begin a_en = 0; end // no read/write collision
      @(posedge clk); #0.5;
      av = RLAT'({a_en && !a_we, av} >> 1);
      bv = RLAT_B'({b_en && !b_we, bv} >> 1);
    end
    $display("SRAM UNIT TEST: %0d port-A reads, %0d port-B reads compared, %0d mismatches", ca, cb, errs);
    $finish;
  end
endmodule
