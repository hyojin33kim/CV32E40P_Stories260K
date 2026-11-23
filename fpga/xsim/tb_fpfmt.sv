// xsim check of the fpnew_pkg format table construct: a packed array of packed structs built from an assignment pattern,
// read with a variable index inside a function. Expected exp_bits per format (FP32, FP64, FP16, FP8, FP16ALT) = 8, 11, 5, 5, 8.
`timescale 1ns / 1ps
package pk;
  typedef struct packed {
    int unsigned exp_bits;
    int unsigned man_bits;
  } enc_t;
  // A: exactly as in fpnew_pkg
  localparam enc_t [0:4] A = '{'{8, 23}, '{11, 52}, '{5, 10}, '{5, 2}, '{8, 7}};
  // B: the same table as one concatenation of 32-bit constants
  localparam enc_t [0:4] B = {{32'd8, 32'd23}, {32'd11, 32'd52}, {32'd5, 32'd10}, {32'd5, 32'd2}, {32'd8, 32'd7}};
  // C: a function with a case statement
  function automatic int unsigned expC(logic [2:0] f);
    case (f) 3'd0: return 8; 3'd1: return 11; 3'd2: return 5; 3'd3: return 5; default: return 8; endcase
  endfunction
  function automatic int unsigned expA(logic [2:0] f); return A[f].exp_bits; endfunction
  function automatic int unsigned expB(logic [2:0] f); return B[f].exp_bits; endfunction
  function automatic int unsigned manA(logic [2:0] f); return A[f].man_bits; endfunction
  function automatic int unsigned biasA(logic [2:0] f); return unsigned'(2**(A[f].exp_bits - 1) - 1); endfunction
endpackage
module tb_fpfmt;
  initial begin
    for (int f = 0; f < 5; f++)
      $display("FMT f=%0d  A(var idx) exp=%0d man=%0d bias=%0d | B exp=%0d | C exp=%0d | expected exp %0d",
               f, pk::expA(f[2:0]), pk::manA(f[2:0]), pk::biasA(f[2:0]), pk::expB(f[2:0]), pk::expC(f[2:0]), (f == 1) ? 11 : (f == 2 || f == 3) ? 5 : 8);
    $display("FMT const idx: A[0].exp=%0d A[1].exp=%0d A[2].exp=%0d A[3].exp=%0d A[4].exp=%0d  raw A=%h", pk::A[0].exp_bits, pk::A[1].exp_bits, pk::A[2].exp_bits, pk::A[3].exp_bits, pk::A[4].exp_bits, pk::A);
    $display("FMT const idx: B[0].exp=%0d B[1].exp=%0d  raw B=%h", pk::B[0].exp_bits, pk::B[1].exp_bits, pk::B);
  end
endmodule
