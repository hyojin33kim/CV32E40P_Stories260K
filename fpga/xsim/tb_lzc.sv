// xsim check of common_cells lzc (leading zero count, MODE 1) for the widths fpnew uses: 51 (fma_multi lower sum), 32 (cast_multi),
// plus 2, 8, 16, 76. A vector with its most significant 1 at index i must give cnt = WIDTH-1-i; all zero must give empty.
`timescale 1ns / 1ps
module tb_lzc;
  localparam int NW = 6;
  localparam int WS[NW] = '{2, 8, 16, 32, 51, 76};
  int mism[NW];
  int total[NW];
  for (genvar g = 0; g < NW; g++) begin : gw
    localparam int W  = WS[g];
    localparam int CW = (W > 1) ? $clog2(W) : 1;
    logic [W-1:0]  in;
    logic [CW-1:0] cnt;
    logic          empty;
    lzc #(.WIDTH(W), .MODE(1'b1)) dut (.in_i(in), .cnt_o(cnt), .empty_o(empty));
    initial begin
      mism[g] = 0; total[g] = 0;
      #1;
      in = '0; #1; total[g]++; if (!empty) mism[g]++;
      for (int i = 0; i < W; i++) begin
        for (int r = 0; r < 8; r++) begin
          in = '0; in[i] = 1'b1;
          for (int b = 0; b < i; b++) in[b] = $urandom_range(0, 1);
          #1; total[g]++;
          if (empty || cnt !== CW'(W - 1 - i)) begin
            mism[g]++;
            if (mism[g] <= 3) $display("LZC W=%0d bad: msb index %0d -> cnt %0d empty %0b (expected %0d)", W, i, cnt, empty, W - 1 - i);
          end
        end
      end
      $display("LZC W=%0d mismatches=%0d of %0d", W, mism[g], total[g]);
    end
  end
endmodule
