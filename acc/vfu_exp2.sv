// Option A (S3) exp2q pipeline: res = 2^y for an fp32 y, bit-exact with opta/exp2q.h
// (integer only: Q8.23 argument, 64-entry 2^(i/64) table, degree-2 polynomial, round half up).
// Fully pipelined: one input per cycle, result LAT = 5 cycles after the input (valid_o).
//   S0 decode   A = round(|y| * 2^23), u = +-A, n = u >>> 23, i = f[22:17], r = f[16:0]
//   S1          r*C1 >> 22, (r*r) >> 17
//   S2          Q = (r*C1 >> 22) + (C2*rr >> 28), T = table[i]
//   S3          M = T + (T*Q >> 32)
//   S4          m = (M + 64) >> 7 (carry -> n+1), e = n + 127, pack (+inf / +0 outside)
module vfu_exp2 (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        valid_i,
    input  logic [31:0] y_i,
    output logic        valid_o,
    output logic [31:0] res_o
);
  localparam logic [31:0] C1 = 32'd1488509675, C2 = 32'd518481354;
  localparam logic [31:0] ONE = 32'h3f80_0000, PINF = 32'h7f80_0000;
  logic [31:0] T_ROM[64];
  assign T_ROM = '{
    32'h40000000, 32'h40b268fa, 32'h4166c34c, 32'h421d1462, 32'h42d561b4, 32'h438fb0cb, 32'h444c0740, 32'h450a6abb,
    32'h45cae0f2, 32'h468d6fae, 32'h47521cc6, 32'h4818ee22, 32'h48e1e9ba, 32'h49ad1598, 32'h4a7a77d4, 32'h4b4a169c,
    32'h4c1bf829, 32'h4cf022ca, 32'h4dc69cdd, 32'h4e9f6cd4, 32'h4f7a9930, 32'h50582888, 32'h51382182, 32'h521a8ad7,
    32'h52ff6b55, 32'h53e6c9da, 32'h54d0ad5a, 32'h55bd1cdb, 32'h56ac1f75, 32'h579dbc57, 32'h5891fac1, 32'h5988e209,
    32'h5a82799a, 32'h5b7ec8f2, 32'h5c7dd7a4, 32'h5d7fad59, 32'h5e8451d0, 32'h5f8bccdb, 32'h60962665, 32'h61a3666d,
    32'h62b39509, 32'h63c6ba64, 32'h64dcdec3, 32'h65f60a7f, 32'h6712460b, 32'h683199ed, 32'h69540ec9, 32'h6a79ad56,
    32'h6ba27e65, 32'h6cce8ae1, 32'h6dfddbcc, 32'h6f307a41, 32'h70666f76, 32'h719fc4b9, 32'h72dc8374, 32'h741cb528,
    32'h75606374, 32'h76a7980f, 32'h77f25cce, 32'h7940bb9e, 32'h7a92be8b, 32'h7be86fba, 32'h7d41d96e, 32'h7e9f0606};

  // ---------------------------------------------------------------- S0: decode (comb) -> regs
  logic        s, spec;
  logic [ 7:0] E;
  logic [23:0] sig;
  logic [31:0] A, specv;
  logic signed [31:0] u;
  always_comb begin
    s = y_i[31]; E = y_i[30:23]; sig = {1'b1, y_i[22:0]};
    spec = 1'b0; specv = '0; A = '0;
    if (E < 8'd103) begin spec = 1'b1; specv = ONE; end            // |y| < 2^-24 -> 1.0
    else if (E >= 8'd134) begin spec = 1'b1; specv = s ? 32'h0 : PINF; end
    else if (E >= 8'd127) A = 32'(sig) << (E - 8'd127);
    else A = ((32'(sig) >> (8'd126 - E)) + 32'd1) >> 1;
    u = s ? -$signed(A) : $signed(A);
  end
  logic        v1, sp1;
  logic [31:0] spv1;
  logic signed [8:0] n1;
  logic [ 5:0] i1;
  logic [16:0] r1;
  // ---------------------------------------------------------------- S1
  logic        v2, sp2;
  logic [31:0] spv2;
  logic signed [8:0] n2;
  logic [ 5:0] i2;
  logic [25:0] q1_2;    // r*C1 >> 22 (< 2^26)
  logic [16:0] rr2;     // r*r >> 17
  // ---------------------------------------------------------------- S2
  logic        v3, sp3;
  logic [31:0] spv3, t3;
  logic signed [8:0] n3;
  logic [26:0] q3;
  // ---------------------------------------------------------------- S3
  logic        v4, sp4;
  logic [31:0] spv4, m4;
  logic signed [8:0] n4;

  logic [47:0] p_rc1;
  logic [33:0] p_rr;
  logic [46:0] p_c2;
  logic [58:0] p_tq;
  assign p_rc1 = 48'(r1) * 48'(C1[30:0]);
  assign p_rr  = 34'(r1) * 34'(r1);
  assign p_c2  = 47'(C2[29:0]) * 47'(rr2);
  assign p_tq  = 59'(t3) * 59'(q3);

  // S4 (comb on S3 regs)
  logic [24:0] m24;
  logic signed [9:0] e4;
  logic [31:0] res4;
  always_comb begin
    m24 = 25'((33'(m4) + 33'd64) >> 7);
    e4  = $signed({n4[8], n4}) + 10'sd127;
    if (m24[24]) begin m24 = 25'h80_0000; e4 = e4 + 10'sd1; end
    if (sp4) res4 = spv4;
    else if (e4 >= 10'sd255) res4 = PINF;
    else if (e4 <= 10'sd0) res4 = 32'h0;
    else res4 = {1'b0, e4[7:0], m24[22:0]};
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      {v1, v2, v3, v4, valid_o} <= '0;
    end else begin
      v1 <= valid_i; v2 <= v1; v3 <= v2; v4 <= v3; valid_o <= v4;
    end
  end
  always_ff @(posedge clk_i) begin
    // S0 -> S1 regs
    sp1 <= spec; spv1 <= specv; n1 <= 9'(u >>> 23); i1 <= 6'(u[22:17]); r1 <= u[16:0];
    // S1 -> S2
    sp2 <= sp1; spv2 <= spv1; n2 <= n1; i2 <= i1;
    q1_2 <= 26'(p_rc1 >> 22); rr2 <= 17'(p_rr >> 17);
    // S2 -> S3
    sp3 <= sp2; spv3 <= spv2; n3 <= n2; t3 <= T_ROM[i2];
    q3 <= 27'(q1_2) + 27'(p_c2 >> 28);
    // S3 -> S4
    sp4 <= sp3; spv4 <= spv3; n4 <= n3;
    m4 <= t3 + 32'(p_tq >> 32);
    // S4 -> out
    res_o <= res4;
  end
endmodule
