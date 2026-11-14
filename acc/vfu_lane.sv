// One VFU element engine: computes a single element with its own cv32e40p_fp_wrapper,
// in the exact operation order of the compiled RISC-V software (see vfu.sv).
//   op 0 EXP    : res = expf(a)
//   op 1 SUBEXP : res = expf(a - b)                        (softmax, b = max)
//   op 2 SILU   : res = (a * (1 / (1 + expf(-a)))) * b      (b = gate)
//   op 3 DIV    : res = a / b
// expf = picolibc 1.8.6 newlib/libm/math/sf_exp.c (fdlibm) as linked: bit-pattern range
// checks, k = (int)RTZ(x*invln2 +- 0.5), 5-term polynomial with the negative coefficients
// applied as "a - |P|" (as compiled; identical bits to "a + P"), (x*c)/(2-c), exponent add,
// 2^-100 scaling below k = -125.
module vfu_lane
  import cv32e40p_apu_core_pkg::*;
(
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        start_i,
    input  logic [ 1:0] op_i,
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    output logic        busy_o,
    output logic        done_o,      // one-cycle pulse with res_o
    output logic [31:0] res_o
);
  localparam logic [1:0] O_EXP = 2'd0, O_SUBEXP = 2'd1, O_SILU = 2'd2, O_DIV = 2'd3;
  localparam logic [31:0] ONE = 32'h3f80_0000, TWO = 32'h4000_0000, HALF = 32'h3f00_0000,
      LN2HI = 32'h3f31_7180, LN2LO = 32'h3717_f7d1, INVLN2 = 32'h3fb8_aa3b,
      P1 = 32'h3e2a_aaab, P2N = 32'h3b36_0b61, P3 = 32'h388a_b355, P4N = 32'h35dd_ea0e,
      P5 = 32'h3331_bb4c, TWOM100 = 32'h0d80_0000, POSINF = 32'h7f80_0000;

  typedef enum logic [5:0] {
    IDLE, DONE,
    E_SUB, E_DIV, S_ADD, S_RCP, S_MUL1, S_MUL2,
    X_CLS, X_NAN, X_R1, X_R2A, X_R2B, X_R2C, X_R2D, X_R2E, X_R2F, X_R2G, X_XR, X_TINY,
    X_T, X_A1, X_A2, X_A3, X_A4, X_A5, X_A6, X_A7, X_A8, X_A9, X_C, X_XC,
    X_DEN, X_Q, X_R, X_R2, X_Y, X_SCALE
  } st_e;
  st_e st_q;

  logic [1:0]  op_q;
  logic [31:0] a_q, b_q, v_q, s_q, res_q;
  logic [31:0] ex_q, ey_q, hi_q, lo_q, kf_q, t_q, ac_q, c_q, xc_q, q_q, r_q;
  logic signed [31:0] k_q;
  logic        xsb;
  logic [31:0] hx;
  assign xsb = ex_q[31];
  assign hx  = {1'b0, ex_q[30:0]};

  logic        fp_req, fp_gnt, fp_valid, issued_q, uop, fp_done, fp_mod;
  logic [31:0] fp_res, opa, opb, opc;
  logic [3:0]  fp_op;
  logic [2:0]  fp_rm;
  localparam logic [3:0] OP_ADD = 4'(fpnew_pkg::ADD), OP_MUL = 4'(fpnew_pkg::MUL),
      OP_DIV = 4'(fpnew_pkg::DIV), OP_F2I = 4'(fpnew_pkg::F2I), OP_I2F = 4'(fpnew_pkg::I2F);
  localparam logic [2:0] RNE = 3'(fpnew_pkg::RNE), RTZ = 3'(fpnew_pkg::RTZ);

  // fpnew: ADD/SUB = op[1] +- op[2], MUL/DIV = op[0] */ op[1], F2I/I2F = op[0]
  always_comb begin
    uop = 1'b1; fp_op = OP_ADD; fp_mod = 1'b0; fp_rm = RNE; opa = '0; opb = '0; opc = '0;
    unique case (st_q)
      E_SUB:   begin fp_mod = 1; opb = a_q; opc = b_q; end                  // a - max
      E_DIV:   begin fp_op = OP_DIV; opa = a_q; opb = b_q; end
      S_ADD:   begin opb = ONE; opc = ey_q; end                             // 1 + e
      S_RCP:   begin fp_op = OP_DIV; opa = ONE; opb = s_q; end              // 1 / s
      S_MUL1:  begin fp_op = OP_MUL; opa = v_q; opb = s_q; end              // v * r
      S_MUL2:  begin fp_op = OP_MUL; opa = v_q; opb = b_q; end              // * gate
      X_NAN:   begin opb = ex_q; opc = ex_q; end
      X_R1:    begin fp_mod = 1; opb = ex_q; opc = {xsb, LN2HI[30:0]}; end
      X_R2A:   begin fp_op = OP_MUL; opa = ex_q; opb = INVLN2; end
      X_R2B:   begin opb = t_q; opc = {xsb, HALF[30:0]}; end
      X_R2C:   begin fp_op = OP_F2I; fp_rm = RTZ; opa = t_q; end
      X_R2D:   begin fp_op = OP_I2F; opa = k_q; end
      X_R2E:   begin fp_op = OP_MUL; opa = kf_q; opb = LN2HI; end
      X_R2F:   begin fp_op = OP_MUL; opa = kf_q; opb = LN2LO; end
      X_R2G:   begin fp_mod = 1; opb = ex_q; opc = hi_q; end
      X_XR:    begin fp_mod = 1; opb = hi_q; opc = lo_q; end
      X_TINY:  begin opb = ex_q; opc = ONE; end
      X_T:     begin fp_op = OP_MUL; opa = ex_q; opb = ex_q; end
      X_A1:    begin fp_op = OP_MUL; opa = t_q; opb = P5; end
      X_A2:    begin fp_mod = 1; opb = ac_q; opc = P4N; end
      X_A3:    begin fp_op = OP_MUL; opa = ac_q; opb = t_q; end
      X_A4:    begin opb = ac_q; opc = P3; end
      X_A5:    begin fp_op = OP_MUL; opa = ac_q; opb = t_q; end
      X_A6:    begin fp_mod = 1; opb = ac_q; opc = P2N; end
      X_A7:    begin fp_op = OP_MUL; opa = ac_q; opb = t_q; end
      X_A8:    begin opb = ac_q; opc = P1; end
      X_A9:    begin fp_op = OP_MUL; opa = ac_q; opb = t_q; end
      X_C:     begin fp_mod = 1; opb = ex_q; opc = ac_q; end
      X_XC:    begin fp_op = OP_MUL; opa = ex_q; opb = c_q; end
      X_DEN:   begin fp_mod = 1; opb = (k_q == 0) ? c_q : TWO; opc = (k_q == 0) ? TWO : c_q; end
      X_Q:     begin fp_op = OP_DIV; opa = xc_q; opb = q_q; end
      X_R:     begin fp_mod = 1; opb = (k_q == 0) ? q_q : lo_q; opc = (k_q == 0) ? ex_q : q_q; end
      X_R2:    begin fp_mod = 1; opb = r_q; opc = hi_q; end
      X_Y:     begin fp_mod = 1; opb = ONE; opc = r_q; end
      X_SCALE: begin fp_op = OP_MUL; opa = ey_q; opb = TWOM100; end
      default: uop = 1'b0;
    endcase
  end

  logic [APU_NDSFLAGS_CPU-1:0] fp_flags;
  assign fp_flags = APU_NDSFLAGS_CPU'({2'(fpnew_pkg::INT32), 3'(fpnew_pkg::FP32),
                                       3'(fpnew_pkg::FP32), fp_rm});
  assign fp_req  = uop && !issued_q;
  assign fp_done = uop && fp_valid && (issued_q || fp_gnt);

  cv32e40p_fp_wrapper #(.FPU_ADDMUL_LAT(0), .FPU_OTHERS_LAT(0)) fpu_i (
      .clk_i, .rst_ni,
      .apu_req_i(fp_req), .apu_gnt_o(fp_gnt),
      .apu_operands_i({opc, opb, opa}),
      .apu_op_i(APU_WOP_CPU'({1'b0, fp_mod, fp_op})), .apu_flags_i(fp_flags),
      .apu_rvalid_o(fp_valid), .apu_rdata_o(fp_res), .apu_rflags_o()
  );

  assign busy_o = st_q != IDLE;
  assign done_o = st_q == DONE;
  assign res_o  = res_q;

  // after expf: where the result goes
  st_e after_exp;
  always_comb unique case (op_q)
    O_SILU:  after_exp = S_ADD;
    default: after_exp = DONE;
  endcase

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q <= IDLE; op_q <= '0; issued_q <= 1'b0; k_q <= '0;
      {a_q, b_q, v_q, s_q, res_q, ex_q, ey_q, hi_q, lo_q, kf_q, t_q, ac_q, c_q, xc_q, q_q, r_q} <= '0;
    end else begin
      if (uop) begin
        if (fp_done) issued_q <= 1'b0;
        else if (fp_req && fp_gnt) issued_q <= 1'b1;
      end
      unique case (st_q)
        IDLE: if (start_i) begin
          op_q <= op_i; a_q <= a_i; b_q <= b_i;
          unique case (op_i)
            O_EXP:    begin ex_q <= a_i; st_q <= X_CLS; end
            O_SUBEXP: st_q <= E_SUB;
            O_SILU:   begin v_q <= a_i; ex_q <= a_i ^ 32'h8000_0000; st_q <= X_CLS; end
            default:  st_q <= E_DIV;
          endcase
        end
        DONE: st_q <= IDLE;
        E_SUB:  if (fp_done) begin ex_q <= fp_res; st_q <= X_CLS; end
        E_DIV:  if (fp_done) begin res_q <= fp_res; st_q <= DONE; end
        S_ADD:  if (fp_done) begin s_q <= fp_res; st_q <= S_RCP; end
        S_RCP:  if (fp_done) begin s_q <= fp_res; st_q <= S_MUL1; end
        S_MUL1: if (fp_done) begin v_q <= fp_res; st_q <= S_MUL2; end
        S_MUL2: if (fp_done) begin res_q <= fp_res; st_q <= DONE; end

        // expf(ex_q) -> ey_q (res_q for EXP/SUBEXP), then after_exp
        X_CLS: begin
          if (hx > 32'h7f80_0000) st_q <= X_NAN;
          else if (hx == 32'h7f80_0000) begin
            ey_q <= xsb ? 32'h0 : ex_q; res_q <= xsb ? 32'h0 : ex_q; st_q <= after_exp;
          end else if ($signed(ex_q) > $signed(32'h42b1_7217)) begin
            ey_q <= POSINF; res_q <= POSINF; st_q <= after_exp;
          end else if (xsb && hx > 32'h42cf_f1b5) begin
            ey_q <= 32'h0; res_q <= 32'h0; st_q <= after_exp;
          end else if (hx > 32'h3eb1_7218) st_q <= (hx < 32'h3f85_1592) ? X_R1 : X_R2A;
          else if (hx < 32'h3400_0000) st_q <= X_TINY;
          else begin k_q <= 0; st_q <= X_T; end
        end
        X_NAN, X_TINY, X_SCALE: if (fp_done) begin
          ey_q <= fp_res; res_q <= fp_res; st_q <= after_exp;
        end
        X_R1: if (fp_done) begin
          hi_q <= fp_res; lo_q <= {xsb, LN2LO[30:0]}; k_q <= xsb ? -32'sd1 : 32'sd1; st_q <= X_XR;
        end
        X_R2A: if (fp_done) begin t_q <= fp_res; st_q <= X_R2B; end
        X_R2B: if (fp_done) begin t_q <= fp_res; st_q <= X_R2C; end
        X_R2C: if (fp_done) begin k_q <= fp_res; st_q <= X_R2D; end
        X_R2D: if (fp_done) begin kf_q <= fp_res; st_q <= X_R2E; end
        X_R2E: if (fp_done) begin hi_q <= fp_res; st_q <= X_R2F; end
        X_R2F: if (fp_done) begin lo_q <= fp_res; st_q <= X_R2G; end
        X_R2G: if (fp_done) begin hi_q <= fp_res; st_q <= X_XR; end
        X_XR:  if (fp_done) begin ex_q <= fp_res; st_q <= X_T; end
        X_T:   if (fp_done) begin t_q <= fp_res; st_q <= X_A1; end
        X_A1:  if (fp_done) begin ac_q <= fp_res; st_q <= X_A2; end
        X_A2:  if (fp_done) begin ac_q <= fp_res; st_q <= X_A3; end
        X_A3:  if (fp_done) begin ac_q <= fp_res; st_q <= X_A4; end
        X_A4:  if (fp_done) begin ac_q <= fp_res; st_q <= X_A5; end
        X_A5:  if (fp_done) begin ac_q <= fp_res; st_q <= X_A6; end
        X_A6:  if (fp_done) begin ac_q <= fp_res; st_q <= X_A7; end
        X_A7:  if (fp_done) begin ac_q <= fp_res; st_q <= X_A8; end
        X_A8:  if (fp_done) begin ac_q <= fp_res; st_q <= X_A9; end
        X_A9:  if (fp_done) begin ac_q <= fp_res; st_q <= X_C; end
        X_C:   if (fp_done) begin c_q <= fp_res; st_q <= X_XC; end
        X_XC:  if (fp_done) begin xc_q <= fp_res; st_q <= X_DEN; end
        X_DEN: if (fp_done) begin q_q <= fp_res; st_q <= X_Q; end        // q_q holds den
        X_Q:   if (fp_done) begin q_q <= fp_res; st_q <= X_R; end
        X_R:   if (fp_done) begin r_q <= fp_res; st_q <= (k_q == 0) ? X_Y : X_R2; end
        X_R2:  if (fp_done) begin r_q <= fp_res; st_q <= X_Y; end
        X_Y: if (fp_done) begin
          if (k_q == 0) begin ey_q <= fp_res; res_q <= fp_res; st_q <= after_exp; end
          else if (k_q >= -125) begin
            ey_q <= fp_res + (k_q << 23); res_q <= fp_res + (k_q << 23); st_q <= after_exp;
          end else begin ey_q <= fp_res + ((k_q + 100) << 23); st_q <= X_SCALE; end
        end
        default: st_q <= IDLE;
      endcase
    end
  end
endmodule
