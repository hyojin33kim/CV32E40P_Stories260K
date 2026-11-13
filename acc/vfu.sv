// Vector function unit, step ④-b: softmax, SiLU*gate, divide-by-scalar and expf,
// bit-exact with the RISC-V software (llama2.c run.c + picolibc 1.8.6 expf).
//
// All arithmetic goes through one cv32e40p_fp_wrapper (the CV32E40P FPU module, incl.
// the iterative divider and int<->float conversion), one operation at a time, in the
// exact operation order of the compiled software:
//   expf  : newlib/libm/math/sf_exp.c (fdlibm, __OBSOLETE_MATH_FLOAT path) as linked;
//           range checks on the bit pattern, k = (int)(x*invln2 + +-0.5) with RTZ,
//           5-term polynomial, (x*c)/(2-c), exponent add, 2^-100 scaling below k=-125.
//           Negative coefficients are applied as "a - |P|" exactly as compiled
//           (identical to "a + P" in IEEE arithmetic).
//   softmax(x,n): max by '>' scan from x[0]; x[i]=expf(x[i]-max); sum+=x[i] from +0;
//                 x[i]/=sum.
//   silu(h,g,n) : h[i] = (h[i] * (1/(1+expf(-h[i])))) * g[i]
//   divs(x,n,c) : x[i] /= c
//   exp(x,n)    : x[i] = expf(x[i])            (unit test command)
// '>' for the max scan is an integer compare of the IEEE bit patterns (inputs are
// finite; +0 and -0 compare equal), equivalent to flt.s for non-NaN values.
//
// MMIO (byte offsets from the slave base):
//   0x00 CMD (W: 1 softmax, 2 silu, 3 divs, 4 exp -> starts)  0x04 STATUS (R: bit0 busy)
//   0x08 A_ADDR  0x0C B_ADDR (silu gate)  0x10 N (<= BUF)  0x14 SCALAR (divs divisor bits)
//   0x18 LAST_CYCLES (R)
// Memory master: same OBI-like protocol as gemv_acc (in-order read responses, writes
// complete on grant). Sequence: load A (and B) -> compute in buffers -> store A.
module vfu
  import cv32e40p_apu_core_pkg::*;
#(
    parameter int BUF = 512
) (
    input logic clk_i,
    input logic rst_ni,

    input  logic        s_req_i,
    input  logic        s_we_i,
    input  logic [ 5:0] s_addr_i,
    input  logic [31:0] s_wdata_i,
    output logic [31:0] s_rdata_o,

    output logic        m_req_o,
    output logic        m_we_o,
    output logic [31:0] m_addr_o,
    output logic [31:0] m_wdata_o,
    input  logic        m_gnt_i,
    input  logic        m_rvalid_i,
    input  logic [31:0] m_rdata_i,

    output logic busy_o
);
  localparam int AW = $clog2(BUF);
  localparam logic [2:0] C_SOFTMAX = 3'd1, C_SILU = 3'd2, C_DIVS = 3'd3, C_EXP = 3'd4;

  // fdlibm sf_exp constants (bit patterns as in the source comments)
  localparam logic [31:0] ONE = 32'h3f80_0000, TWO = 32'h4000_0000, HALF = 32'h3f00_0000,
      LN2HI = 32'h3f31_7180, LN2LO = 32'h3717_f7d1, INVLN2 = 32'h3fb8_aa3b,
      P1 = 32'h3e2a_aaab, P2N = 32'h3b36_0b61, P3 = 32'h388a_b355, P4N = 32'h35dd_ea0e,
      P5 = 32'h3331_bb4c, TWOM100 = 32'h0d80_0000, POSINF = 32'h7f80_0000;

  typedef enum logic [5:0] {
    IDLE, LOAD, ELEM, STORE,
    SM_SUB, SM_SUM, SM_DIV,                       // softmax
    SL_ADD, SL_RCP, SL_MUL1, SL_MUL2,             // silu
    DV_DIV,                                       // divs
    X_CLS, X_NAN, X_R1, X_R2A, X_R2B, X_R2C, X_R2D, X_R2E, X_R2F, X_R2G, X_XR, X_TINY,
    X_T, X_A1, X_A2, X_A3, X_A4, X_A5, X_A6, X_A7, X_A8, X_A9, X_C, X_XC,
    X_DEN, X_Q, X_R, X_R2, X_Y, X_SCALE, X_RET
  } st_e;
  st_e st_q, ret_q;

  logic [2:0]  cmd_q;
  logic [31:0] a_addr_q, b_addr_q, n_q, scalar_q, cyc_q;
  logic [31:0] abuf[BUF];
  logic [31:0] bbuf[BUF];
  logic [31:0] iss_q, rsp_q, idx_q, st_cnt_q;
  logic        pass2_q;                          // softmax normalise pass
  logic [31:0] max_q, sum_q, v_q;               // softmax max/sum, silu value

  // expf working registers
  logic [31:0] ex_q, ey_q, hi_q, lo_q, kf_q, t_q, a_q, c_q, xc_q, q_q, r_q;
  logic signed [31:0] k_q;
  logic        xsb;
  logic [31:0] hx;
  assign xsb = ex_q[31];
  assign hx  = {1'b0, ex_q[30:0]};

  // ---------------------------------------------------------------- FPU interface
  logic        fp_req, fp_gnt, fp_valid, issued_q;
  logic [31:0] fp_res;
  logic [3:0]  fp_op;
  logic        fp_mod;
  logic [2:0]  fp_rm;
  logic [31:0] opa, opb, opc;
  logic        uop;                              // current state issues an FP op

  localparam logic [3:0] OP_ADD = 4'(fpnew_pkg::ADD), OP_MUL = 4'(fpnew_pkg::MUL),
      OP_DIV = 4'(fpnew_pkg::DIV), OP_F2I = 4'(fpnew_pkg::F2I), OP_I2F = 4'(fpnew_pkg::I2F);
  localparam logic [2:0] RNE = 3'(fpnew_pkg::RNE), RTZ = 3'(fpnew_pkg::RTZ);

  // op/operands per micro state (fpnew: ADD/SUB = op[1] +- op[2], MUL/DIV = op[0] */ op[1],
  // F2I/I2F = op[0])
  always_comb begin
    uop = 1'b1; fp_op = OP_ADD; fp_mod = 1'b0; fp_rm = RNE; opa = '0; opb = '0; opc = '0;
    unique case (st_q)
      SM_SUB:  begin fp_mod = 1; opb = abuf[idx_q[AW-1:0]]; opc = max_q; end   // x - max
      SM_SUM:  begin opb = sum_q; opc = ey_q; end                               // sum + e
      SM_DIV:  begin fp_op = OP_DIV; opa = abuf[idx_q[AW-1:0]]; opb = sum_q; end
      SL_ADD:  begin opb = ONE; opc = ey_q; end                                 // 1 + e
      SL_RCP:  begin fp_op = OP_DIV; opa = ONE; opb = c_q; end                  // 1 / s
      SL_MUL1: begin fp_op = OP_MUL; opa = v_q; opb = c_q; end                  // v * r
      SL_MUL2: begin fp_op = OP_MUL; opa = v_q; opb = bbuf[idx_q[AW-1:0]]; end  // * gate
      DV_DIV:  begin fp_op = OP_DIV; opa = abuf[idx_q[AW-1:0]]; opb = scalar_q; end
      X_NAN:   begin opb = ex_q; opc = ex_q; end                                // x + x
      X_R1:    begin fp_mod = 1; opb = ex_q; opc = {xsb, LN2HI[30:0]}; end      // x - ln2HI[xsb]
      X_R2A:   begin fp_op = OP_MUL; opa = ex_q; opb = INVLN2; end
      X_R2B:   begin opb = t_q; opc = {xsb, HALF[30:0]}; end                    // + halF[xsb]
      X_R2C:   begin fp_op = OP_F2I; fp_rm = RTZ; opa = t_q; end                // (int)
      X_R2D:   begin fp_op = OP_I2F; opa = k_q; end                             // (float)k
      X_R2E:   begin fp_op = OP_MUL; opa = kf_q; opb = LN2HI; end               // t*ln2HI[0]
      X_R2F:   begin fp_op = OP_MUL; opa = kf_q; opb = LN2LO; end               // lo
      X_R2G:   begin fp_mod = 1; opb = ex_q; opc = hi_q; end                    // hi = x - t*ln2HI
      X_XR:    begin fp_mod = 1; opb = hi_q; opc = lo_q; end                    // x = hi - lo
      X_TINY:  begin opb = ex_q; opc = ONE; end                                 // x + one
      X_T:     begin fp_op = OP_MUL; opa = ex_q; opb = ex_q; end                // t = x*x
      X_A1:    begin fp_op = OP_MUL; opa = t_q; opb = P5; end
      X_A2:    begin fp_mod = 1; opb = a_q; opc = P4N; end
      X_A3:    begin fp_op = OP_MUL; opa = a_q; opb = t_q; end
      X_A4:    begin opb = a_q; opc = P3; end
      X_A5:    begin fp_op = OP_MUL; opa = a_q; opb = t_q; end
      X_A6:    begin fp_mod = 1; opb = a_q; opc = P2N; end
      X_A7:    begin fp_op = OP_MUL; opa = a_q; opb = t_q; end
      X_A8:    begin opb = a_q; opc = P1; end
      X_A9:    begin fp_op = OP_MUL; opa = a_q; opb = t_q; end
      X_C:     begin fp_mod = 1; opb = ex_q; opc = a_q; end                     // c = x - a
      X_XC:    begin fp_op = OP_MUL; opa = ex_q; opb = c_q; end                 // x*c
      X_DEN:   begin fp_mod = 1; opb = (k_q == 0) ? c_q : TWO; opc = (k_q == 0) ? TWO : c_q; end
      X_Q:     begin fp_op = OP_DIV; opa = xc_q; opb = q_q; end                 // xc / den
      X_R:     begin fp_mod = 1; opb = (k_q == 0) ? q_q : lo_q; opc = (k_q == 0) ? ex_q : q_q; end
      X_R2:    begin fp_mod = 1; opb = r_q; opc = hi_q; end                     // (lo-q) - hi
      X_Y:     begin fp_mod = 1; opb = ONE; opc = r_q; end                      // one - r
      X_SCALE: begin fp_op = OP_MUL; opa = ey_q; opb = TWOM100; end
      default: uop = 1'b0;
    endcase
  end

  localparam logic [APU_WOP_CPU-1:0] VEC0 = '0;
  logic [APU_NDSFLAGS_CPU-1:0] fp_flags;
  assign fp_flags = APU_NDSFLAGS_CPU'({2'(fpnew_pkg::INT32), 3'(fpnew_pkg::FP32),
                                       3'(fpnew_pkg::FP32), fp_rm});
  assign fp_req = uop && !issued_q;

  cv32e40p_fp_wrapper #(.FPU_ADDMUL_LAT(0), .FPU_OTHERS_LAT(0)) fpu_i (
      .clk_i, .rst_ni,
      .apu_req_i(fp_req), .apu_gnt_o(fp_gnt),
      .apu_operands_i({opc, opb, opa}),
      .apu_op_i(APU_WOP_CPU'({1'b0, fp_mod, fp_op})), .apu_flags_i(fp_flags),
      .apu_rvalid_o(fp_valid), .apu_rdata_o(fp_res), .apu_rflags_o()
  );
  logic fp_done;  // result of the current micro state available this cycle
  assign fp_done = uop && fp_valid && (issued_q || fp_gnt);

  // ---------------------------------------------------------------- master port
  logic [31:0] n_load;
  assign n_load = (cmd_q == C_SILU) ? 2 * n_q : n_q;
  always_comb begin
    m_req_o = 1'b0; m_we_o = 1'b0; m_addr_o = '0; m_wdata_o = '0;
    if (st_q == LOAD && iss_q < n_load) begin
      m_req_o  = 1'b1;
      m_addr_o = (iss_q < n_q) ? a_addr_q + (iss_q << 2) : b_addr_q + ((iss_q - n_q) << 2);
    end else if (st_q == STORE && st_cnt_q < n_q) begin
      m_req_o = 1'b1; m_we_o = 1'b1;
      m_addr_o = a_addr_q + (st_cnt_q << 2); m_wdata_o = abuf[st_cnt_q[AW-1:0]];
    end
  end
  assign busy_o = st_q != IDLE;

  // IEEE '>' for finite values (+0 == -0)
  function automatic logic fgt(logic [31:0] a, logic [31:0] b);
    if (a[30:0] == 0 && b[30:0] == 0) return 1'b0;
    if (a[31] != b[31]) return !a[31];
    return a[31] ? (a[30:0] < b[30:0]) : (a[30:0] > b[30:0]);
  endfunction

  always_ff @(posedge clk_i) begin
    unique case (s_addr_i[5:2])
      4'h1: s_rdata_o <= {31'b0, busy_o};
      4'h2: s_rdata_o <= a_addr_q;
      4'h3: s_rdata_o <= b_addr_q;
      4'h4: s_rdata_o <= n_q;
      4'h5: s_rdata_o <= scalar_q;
      4'h6: s_rdata_o <= cyc_q;
      default: s_rdata_o <= '0;
    endcase
  end

  // ---------------------------------------------------------------- sequencer
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q <= IDLE; ret_q <= IDLE; cmd_q <= '0; issued_q <= 1'b0; pass2_q <= 1'b0;
      {a_addr_q, b_addr_q, n_q, scalar_q, cyc_q, iss_q, rsp_q, idx_q, st_cnt_q} <= '0;
      {max_q, sum_q, v_q, ex_q, ey_q, hi_q, lo_q, kf_q, t_q, a_q, c_q, xc_q, q_q, r_q} <= '0;
      k_q <= '0;
    end else begin
      if (s_req_i && s_we_i && st_q == IDLE) begin
        unique case (s_addr_i[5:2])
          4'h0: if (s_wdata_i[2:0] != 0) begin
            cmd_q <= s_wdata_i[2:0]; st_q <= LOAD; cyc_q <= '0;
            {iss_q, rsp_q, idx_q, st_cnt_q} <= '0; pass2_q <= 1'b0; sum_q <= '0;
          end
          4'h2: a_addr_q <= s_wdata_i;
          4'h3: b_addr_q <= s_wdata_i;
          4'h4: n_q      <= s_wdata_i;
          4'h5: scalar_q <= s_wdata_i;
          default: ;
        endcase
      end
      if (st_q != IDLE) cyc_q <= cyc_q + 1;

      // FPU handshake: hold the request until granted, then wait for the result
      if (uop) begin
        if (fp_done) issued_q <= 1'b0;
        else if (fp_req && fp_gnt) issued_q <= 1'b1;
      end

      unique case (st_q)
        IDLE: ;
        LOAD: begin
          if (m_req_o && m_gnt_i) iss_q <= iss_q + 1;
          if (m_rvalid_i) begin
            if (rsp_q < n_q) begin
              abuf[rsp_q[AW-1:0]] <= m_rdata_i;
              if (rsp_q == 0 || fgt(m_rdata_i, max_q)) max_q <= m_rdata_i;
            end else bbuf[(rsp_q - n_q) & (BUF - 1)] <= m_rdata_i;
            rsp_q <= rsp_q + 1;
            if (rsp_q + 1 == n_load) st_q <= ELEM;
          end
        end
        // per-element dispatch
        ELEM: begin
          if (idx_q == n_q) begin
            if (cmd_q == C_SOFTMAX && !pass2_q) begin
              pass2_q <= 1'b1; idx_q <= '0;
            end else st_q <= STORE;
          end else unique case (cmd_q)
            C_SOFTMAX: st_q <= pass2_q ? SM_DIV : SM_SUB;
            C_SILU: begin
              v_q <= abuf[idx_q[AW-1:0]];
              ex_q <= abuf[idx_q[AW-1:0]] ^ 32'h8000_0000;  // -val (exact sign flip)
              ret_q <= SL_ADD; st_q <= X_CLS;
            end
            C_DIVS: st_q <= DV_DIV;
            C_EXP: begin ex_q <= abuf[idx_q[AW-1:0]]; ret_q <= X_RET; st_q <= X_CLS; end
            default: st_q <= STORE;
          endcase
        end
        SM_SUB: if (fp_done) begin ex_q <= fp_res; ret_q <= SM_SUM; st_q <= X_CLS; end
        SM_SUM: if (fp_done) begin
          sum_q <= fp_res; abuf[idx_q[AW-1:0]] <= ey_q; idx_q <= idx_q + 1; st_q <= ELEM;
        end
        SM_DIV: if (fp_done) begin
          abuf[idx_q[AW-1:0]] <= fp_res; idx_q <= idx_q + 1; st_q <= ELEM;
        end
        SL_ADD:  if (fp_done) begin c_q <= fp_res; st_q <= SL_RCP; end
        SL_RCP:  if (fp_done) begin c_q <= fp_res; st_q <= SL_MUL1; end
        SL_MUL1: if (fp_done) begin v_q <= fp_res; st_q <= SL_MUL2; end
        SL_MUL2: if (fp_done) begin
          abuf[idx_q[AW-1:0]] <= fp_res; idx_q <= idx_q + 1; st_q <= ELEM;
        end
        DV_DIV: if (fp_done) begin
          abuf[idx_q[AW-1:0]] <= fp_res; idx_q <= idx_q + 1; st_q <= ELEM;
        end
        STORE: begin
          if (m_req_o && m_gnt_i) begin
            st_cnt_q <= st_cnt_q + 1;
            if (st_cnt_q + 1 == n_q) st_q <= IDLE;
          end
        end

        // ------------------------------------------------ expf(ex_q) -> ey_q, then ret_q
        X_CLS: begin
          if (hx > 32'h7f80_0000) st_q <= X_NAN;
          else if (hx == 32'h7f80_0000) begin ey_q <= xsb ? 32'h0 : ex_q; st_q <= ret_q; end
          else if ($signed(ex_q) > $signed(32'h42b1_7217)) begin ey_q <= POSINF; st_q <= ret_q; end
          else if (xsb && hx > 32'h42cf_f1b5) begin ey_q <= 32'h0; st_q <= ret_q; end
          else if (hx > 32'h3eb1_7218) st_q <= (hx < 32'h3f85_1592) ? X_R1 : X_R2A;
          else if (hx < 32'h3400_0000) st_q <= X_TINY;
          else begin k_q <= 0; st_q <= X_T; end
        end
        X_NAN:  if (fp_done) begin ey_q <= fp_res; st_q <= ret_q; end
        X_TINY: if (fp_done) begin ey_q <= fp_res; st_q <= ret_q; end
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
        X_A1:  if (fp_done) begin a_q <= fp_res; st_q <= X_A2; end
        X_A2:  if (fp_done) begin a_q <= fp_res; st_q <= X_A3; end
        X_A3:  if (fp_done) begin a_q <= fp_res; st_q <= X_A4; end
        X_A4:  if (fp_done) begin a_q <= fp_res; st_q <= X_A5; end
        X_A5:  if (fp_done) begin a_q <= fp_res; st_q <= X_A6; end
        X_A6:  if (fp_done) begin a_q <= fp_res; st_q <= X_A7; end
        X_A7:  if (fp_done) begin a_q <= fp_res; st_q <= X_A8; end
        X_A8:  if (fp_done) begin a_q <= fp_res; st_q <= X_A9; end
        X_A9:  if (fp_done) begin a_q <= fp_res; st_q <= X_C; end
        X_C:   if (fp_done) begin c_q <= fp_res; st_q <= X_XC; end
        X_XC:  if (fp_done) begin xc_q <= fp_res; st_q <= X_DEN; end
        X_DEN: if (fp_done) begin q_q <= fp_res; st_q <= X_Q; end       // q_q holds den
        X_Q:   if (fp_done) begin q_q <= fp_res; st_q <= X_R; end
        X_R:   if (fp_done) begin
          r_q <= fp_res; st_q <= (k_q == 0) ? X_Y : X_R2;
        end
        X_R2:  if (fp_done) begin r_q <= fp_res; st_q <= X_Y; end
        X_Y: if (fp_done) begin
          if (k_q == 0) begin ey_q <= fp_res; st_q <= ret_q; end
          else if (k_q >= -125) begin ey_q <= fp_res + (k_q << 23); st_q <= ret_q; end
          else begin ey_q <= fp_res + ((k_q + 100) << 23); st_q <= X_SCALE; end
        end
        X_SCALE: if (fp_done) begin ey_q <= fp_res; st_q <= ret_q; end
        X_RET: begin abuf[idx_q[AW-1:0]] <= ey_q; idx_q <= idx_q + 1; st_q <= ELEM; end
        default: st_q <= IDLE;
      endcase
    end
  end
endmodule
