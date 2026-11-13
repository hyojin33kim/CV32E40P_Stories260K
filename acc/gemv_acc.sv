// GEMV accelerator: step ③ (FFN W1/W3/W2) and step ④ (attention QK and AV).
//
//   y[i] = sum_j W[W_ADDR + i*W_STRIDE + j*J_STRIDE] * x[j]      i < D, j < N
//
//   FFN/LM matmul : W_STRIDE = 4*N, J_STRIDE = 4
//   attention QK  : W = key cache of the head,   W_STRIDE = 4*kv_dim, J_STRIDE = 4
//   attention AV  : W = value cache of the head, W_STRIDE = 4, J_STRIDE = 4*kv_dim
//
// Bit-exact with the RISC-V software matmul() (val = 0.0f; val += w*x in j order):
// products and sums use cv32e40p_fp_wrapper, the same FPU module instance type the
// CV32E40P core uses (FP32, RNE, FPU_ADDMUL_LAT=0), with one fmul then one fadd per
// MAC and a +0.0 start value per row.
//
// MMIO (word offsets from the slave base):
//   0x00 CTRL    W: bit0=1 start
//   0x04 STATUS  R: bit0 busy
//   0x08 X_ADDR  0x0C W_ADDR  0x10 Y_ADDR  (byte addresses, word aligned)
//   0x14 N (<= XBUF)  0x18 D (<= YBUF)  0x1C W_STRIDE (bytes between rows)
//   0x20 LAST_CYCLES R: busy cycles of the last command
//   0x24 J_STRIDE (bytes between consecutive j of a row; reset value 4)
//
// Master port: OBI-like, one request per cycle when granted, in-order read
// responses (rvalid). Writes complete on grant (no response expected).
// Sequence: load x (N reads) -> stream W (D*N reads, 1 MAC/cycle) -> write y (D).
module gemv_acc
  import cv32e40p_apu_core_pkg::*;
#(
    parameter int XBUF = 512,
    parameter int YBUF = 512
) (
    input logic clk_i,
    input logic rst_ni,

    // MMIO slave (single cycle access; read data valid next cycle)
    input  logic        s_req_i,
    input  logic        s_we_i,
    input  logic [ 5:0] s_addr_i,   // byte offset
    input  logic [31:0] s_wdata_i,
    output logic [31:0] s_rdata_o,

    // memory master
    output logic        m_req_o,
    output logic        m_we_o,
    output logic [31:0] m_addr_o,
    output logic [31:0] m_wdata_o,
    input  logic        m_gnt_i,
    input  logic        m_rvalid_i,
    input  logic [31:0] m_rdata_i
);

  typedef enum logic [1:0] {IDLE, LOADX, ROWS, WB} state_e;
  state_e state_q;

  logic [31:0] x_addr_q, w_addr_q, y_addr_q, n_q, d_q, stride_q, jstride_q, cyc_q;
  logic [31:0] xbuf[XBUF];
  logic [31:0] ybuf[YBUF];

  // request side counters
  logic [31:0] iss_i_q, iss_j_q, iss_row_addr_q, iss_addr_q;
  // response side counters
  logic [31:0] rsp_i_q, rsp_j_q;
  logic [31:0] rows_done_q, wb_q;

  // mul stage register
  logic        p_valid_q, p_first_q, p_last_q;
  logic [31:0] p_q, p_row_q;
  logic [31:0] acc_q;

  // ---------------------------------------------------------------- FPU
  localparam logic [APU_NDSFLAGS_CPU-1:0] FLAGS = APU_NDSFLAGS_CPU'({
    2'(fpnew_pkg::INT32), 3'(fpnew_pkg::FP32), 3'(fpnew_pkg::FP32), 3'(fpnew_pkg::RNE)});
  localparam logic [APU_WOP_CPU-1:0] OP_MUL = APU_WOP_CPU'({1'b0, 1'b0, 4'(fpnew_pkg::MUL)});
  localparam logic [APU_WOP_CPU-1:0] OP_ADD = APU_WOP_CPU'({1'b0, 1'b0, 4'(fpnew_pkg::ADD)});

  logic        mul_in, mul_gnt, mul_valid, add_in, add_gnt, add_valid;
  logic [31:0] mul_res, add_res, x_j;
  logic [APU_NARGS_CPU-1:0][31:0] mul_ops, add_ops;

  assign x_j     = xbuf[rsp_j_q[$clog2(XBUF)-1:0]];
  // MUL: operands[0] * operands[1]
  assign mul_ops = {32'h0, x_j, m_rdata_i};
  // ADD: operands[1] + operands[2]  (acc + p, as in fadd.s acc,acc,p)
  assign add_ops = {p_q, (p_first_q ? 32'h0000_0000 : acc_q), 32'h0};
  assign mul_in  = (state_q == ROWS) && m_rvalid_i;
  assign add_in  = p_valid_q;

  cv32e40p_fp_wrapper #(.FPU_ADDMUL_LAT(0), .FPU_OTHERS_LAT(0)) mul_i (
      .clk_i, .rst_ni,
      .apu_req_i(mul_in), .apu_gnt_o(mul_gnt),
      .apu_operands_i(mul_ops), .apu_op_i(OP_MUL), .apu_flags_i(FLAGS),
      .apu_rvalid_o(mul_valid), .apu_rdata_o(mul_res), .apu_rflags_o()
  );
  cv32e40p_fp_wrapper #(.FPU_ADDMUL_LAT(0), .FPU_OTHERS_LAT(0)) add_i (
      .clk_i, .rst_ni,
      .apu_req_i(add_in), .apu_gnt_o(add_gnt),
      .apu_operands_i(add_ops), .apu_op_i(OP_ADD), .apu_flags_i(FLAGS),
      .apu_rvalid_o(add_valid), .apu_rdata_o(add_res), .apu_rflags_o()
  );

  // ---------------------------------------------------------------- master
  always_comb begin
    m_req_o   = 1'b0;
    m_we_o    = 1'b0;
    m_addr_o  = '0;
    m_wdata_o = '0;
    unique case (state_q)
      LOADX: begin
        m_req_o  = iss_j_q < n_q;
        m_addr_o = x_addr_q + (iss_j_q << 2);
      end
      ROWS: begin
        m_req_o  = iss_i_q < d_q;
        m_addr_o = iss_addr_q;
      end
      WB: begin
        m_req_o   = wb_q < d_q;
        m_we_o    = 1'b1;
        m_addr_o  = y_addr_q + (wb_q << 2);
        m_wdata_o = ybuf[wb_q[$clog2(YBUF)-1:0]];
      end
      default: ;
    endcase
  end

  // ---------------------------------------------------------------- slave
  always_ff @(posedge clk_i) begin
    unique case (s_addr_i[5:2])
      4'h1: s_rdata_o <= {31'b0, state_q != IDLE};
      4'h2: s_rdata_o <= x_addr_q;
      4'h3: s_rdata_o <= w_addr_q;
      4'h4: s_rdata_o <= y_addr_q;
      4'h5: s_rdata_o <= n_q;
      4'h6: s_rdata_o <= d_q;
      4'h7: s_rdata_o <= stride_q;
      4'h8: s_rdata_o <= cyc_q;
      4'h9: s_rdata_o <= jstride_q;
      default: s_rdata_o <= '0;
    endcase
  end

  // ---------------------------------------------------------------- control
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= IDLE;
      {x_addr_q, w_addr_q, y_addr_q, n_q, d_q, stride_q, cyc_q} <= '0;
      jstride_q <= 32'd4;
      {iss_i_q, iss_j_q, iss_row_addr_q, iss_addr_q, rsp_i_q, rsp_j_q, rows_done_q, wb_q} <= '0;
      {p_valid_q, p_first_q, p_last_q} <= '0;
      {p_q, p_row_q, acc_q} <= '0;
    end else begin
      // register writes (ignored while busy)
      if (s_req_i && s_we_i && state_q == IDLE) begin
        unique case (s_addr_i[5:2])
          4'h0: if (s_wdata_i[0]) begin
            state_q <= LOADX;
            cyc_q   <= '0;
            {iss_i_q, iss_j_q, rsp_i_q, rsp_j_q, rows_done_q, wb_q} <= '0;
            iss_row_addr_q <= w_addr_q;
            iss_addr_q     <= w_addr_q;
          end
          4'h2: x_addr_q <= s_wdata_i;
          4'h3: w_addr_q <= s_wdata_i;
          4'h4: y_addr_q <= s_wdata_i;
          4'h5: n_q      <= s_wdata_i;
          4'h6: d_q      <= s_wdata_i;
          4'h7: stride_q <= s_wdata_i;
          4'h9: jstride_q <= s_wdata_i;
          default: ;
        endcase
      end
      if (state_q != IDLE) cyc_q <= cyc_q + 1;

      p_valid_q <= 1'b0;
      unique case (state_q)
        LOADX: begin
          if (m_req_o && m_gnt_i) iss_j_q <= iss_j_q + 1;
          if (m_rvalid_i) begin
            xbuf[rsp_j_q[$clog2(XBUF)-1:0]] <= m_rdata_i;
            rsp_j_q <= rsp_j_q + 1;
            if (rsp_j_q + 1 == n_q) begin
              state_q <= ROWS;
              {iss_i_q, iss_j_q, rsp_i_q, rsp_j_q} <= '0;
            end
          end
        end
        ROWS: begin
          if (m_req_o && m_gnt_i) begin
            if (iss_j_q + 1 == n_q) begin
              iss_j_q        <= '0;
              iss_i_q        <= iss_i_q + 1;
              iss_row_addr_q <= iss_row_addr_q + stride_q;
              iss_addr_q     <= iss_row_addr_q + stride_q;
            end else begin
              iss_j_q    <= iss_j_q + 1;
              iss_addr_q <= iss_addr_q + jstride_q;
            end
          end
          // stage 1: product of the returning weight and x[j]
          if (m_rvalid_i) begin
            p_valid_q <= 1'b1;
            p_q       <= mul_res;
            p_first_q <= rsp_j_q == 0;
            p_last_q  <= rsp_j_q + 1 == n_q;
            p_row_q   <= rsp_i_q;
            if (rsp_j_q + 1 == n_q) begin
              rsp_j_q <= '0;
              rsp_i_q <= rsp_i_q + 1;
            end else rsp_j_q <= rsp_j_q + 1;
          end
          // stage 2: accumulate
          if (p_valid_q) begin
            acc_q <= add_res;
            if (p_last_q) begin
              ybuf[p_row_q[$clog2(YBUF)-1:0]] <= add_res;
              rows_done_q <= rows_done_q + 1;
              if (rows_done_q + 1 == d_q) state_q <= WB;
            end
          end
        end
        WB: begin
          if (m_req_o && m_gnt_i) begin
            wb_q <= wb_q + 1;
            if (wb_q + 1 == d_q) state_q <= IDLE;
          end
        end
        default: ;
      endcase
    end
  end

`ifndef SYNTHESIS
  // The datapath assumes combinational FPU results (FPU_ADDMUL_LAT=0).
  always_ff @(posedge clk_i) begin
    if (mul_in && !(mul_gnt && mul_valid)) $error("gemv_acc: MUL not single-cycle");
    if (add_in && !(add_gnt && add_valid)) $error("gemv_acc: ADD not single-cycle");
  end
`endif
endmodule
