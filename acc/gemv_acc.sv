// GEMV accelerator: step ③ (FFN), ④ (attention QK/AV, all weight matmuls), MAC lanes.
//
//   y[i] = sum_j W[W_ADDR + i*W_STRIDE + j*J_STRIDE] * x[j]      i < D, j < N
//
//   matmul        : W_STRIDE = 4*N, J_STRIDE = 4
//   attention QK  : W = key cache of the head,   W_STRIDE = 4*kv_dim, J_STRIDE = 4
//   attention AV  : W = value cache of the head, W_STRIDE = 4, J_STRIDE = 4*kv_dim
//
// Bit-exact with the RISC-V software loops (val = 0.0f; val += w*x in j order):
// every row is accumulated sequentially in j order from +0.0 with one fmul and one
// fadd per MAC, through cv32e40p_fp_wrapper (the CV32E40P FPU module, FP32, RNE,
// ADDMUL latency 0). LANES rows are processed in parallel (lane p = row i0+p), each
// lane keeping its own sequential order, so the result does not depend on LANES.
//
// Memory master: 128-bit read lines (address 16-byte aligned by the memory, in-order
// responses), 32-bit word writes (complete on grant). Weight fetch per row group:
//   mode A (J_STRIDE=4, W and W_STRIDE 16B aligned, N%4==0): a line = 4 consecutive j
//          of one row; lines go round-robin over the lanes (16 B/cycle feeds 4 lanes)
//   mode B (W_STRIDE=4, J_STRIDE%16==0, W 16B aligned, LANES<=4): a line = the same j
//          of up to 4 consecutive rows (one line per j feeds all lanes)
//   mode C (anything else): one word per request
// Per-lane FIFOs with credits (in-flight words reserved); lanes consume in lockstep.
//
// MMIO (byte offsets from the slave base):
//   0x00 CTRL    W: bit0=1 start            0x04 STATUS  R: bit0 busy
//   0x08 X_ADDR  0x0C W_ADDR  0x10 Y_ADDR   (byte addresses, word aligned)
//   0x14 N (<= XBUF)  0x18 D (<= YBUF)  0x1C W_STRIDE (bytes between rows)
//   0x20 LAST_CYCLES R  0x24 J_STRIDE (bytes between consecutive j; reset 4)
//   0x28 MODE R (last command: 0 A, 1 B, 2 C)
module gemv_acc
  import cv32e40p_apu_core_pkg::*;
#(
    parameter int XBUF   = 512,
    parameter int YBUF   = 512,
    parameter int LANES  = 4,
    parameter int FDEPTH = 128              // words per lane FIFO (power of two); covers
                                            // ~FDEPTH cycles of memory latency per lane
) (
    input logic clk_i,
    input logic rst_ni,

    input  logic        s_req_i,
    input  logic        s_we_i,
    input  logic [ 5:0] s_addr_i,
    input  logic [31:0] s_wdata_i,
    output logic [31:0] s_rdata_o,

    output logic         m_req_o,
    output logic         m_we_o,
    output logic [ 31:0] m_addr_o,
    output logic [ 31:0] m_wdata_o,
    input  logic         m_gnt_i,
    input  logic         m_rvalid_i,
    input  logic [127:0] m_rdata_i
);
  localparam int LW = (LANES > 1) ? $clog2(LANES) : 1;
  localparam int FW = $clog2(FDEPTH);
  localparam int TDEPTH = LANES * FDEPTH;    // >= max outstanding requests
  localparam int TW = $clog2(TDEPTH);

  typedef enum logic [1:0] {IDLE, LOADX, ROWS, WB} state_e;
  typedef enum logic [1:0] {MA, MB, MC} mode_e;
  state_e state_q;
  mode_e  mode_q;

  logic [31:0] x_addr_q, w_addr_q, y_addr_q, n_q, d_q, stride_q, jstride_q, cyc_q;
  logic [31:0] xbuf[XBUF];
  logic [31:0] ybuf[YBUF];
  logic [31:0] ld_iss_q, ld_rsp_q, wb_q;

  // lane FIFOs
  logic [31:0]   fifo[LANES][FDEPTH];
  logic [FW-1:0] f_wr_q[LANES], f_rd_q[LANES];
  logic [FW:0]   f_cnt_q[LANES], f_res_q[LANES];   // stored words, reserved (in flight)

  // issue side: group base row, chunk (A) / j (B, C), lane (A, C)
  logic [31:0] is_i0_q, is_k_q, is_p_q;
  // consume side: group base row, j
  logic [31:0] cs_i0_q, cs_j_q;

  // tag FIFO, one entry per outstanding request: {lane (A, C) or active lanes-1 (B), word offset}
  logic [LW+1:0] tag[TDEPTH];
  logic [TW-1:0] t_wr_q, t_rd_q;

  function automatic logic [31:0] nact(logic [31:0] d, logic [31:0] i0);  // active lanes
    return (d - i0 >= LANES) ? LANES : d - i0;
  endfunction

  // ---------------------------------------------------------------- issue
  logic [31:0]   is_addr, is_na;
  logic          is_can, is_done;
  logic [LW+1:0] is_tag;
  always_comb begin
    is_na   = nact(d_q, is_i0_q);
    is_done = is_i0_q >= d_q;
    is_addr = '0; is_can = 1'b0; is_tag = '0;
    unique case (mode_q)
      MA: begin
        is_addr = w_addr_q + (is_i0_q + is_p_q) * stride_q + (is_k_q << 4);
        is_can  = (FDEPTH - f_cnt_q[is_p_q[LW-1:0]] - f_res_q[is_p_q[LW-1:0]]) >= 4;
        is_tag  = {is_p_q[LW-1:0], 2'b00};
      end
      MB: begin
        is_addr = w_addr_q + (is_i0_q << 2) + is_k_q * jstride_q;
        is_can  = 1'b1;
        for (int p = 0; p < LANES; p++)
          if (p < is_na && (FDEPTH - f_cnt_q[p] - f_res_q[p]) < 1) is_can = 1'b0;
        is_tag  = {LW'(is_na - 1), is_addr[3:2]};
      end
      default: begin
        is_addr = w_addr_q + (is_i0_q + is_p_q) * stride_q + is_k_q * jstride_q;
        is_can  = (FDEPTH - f_cnt_q[is_p_q[LW-1:0]] - f_res_q[is_p_q[LW-1:0]]) >= 1;
        is_tag  = {is_p_q[LW-1:0], is_addr[3:2]};
      end
    endcase
  end

  // ---------------------------------------------------------------- MAC datapath
  logic [31:0] cs_na, x_j;
  logic        cs_fire, cs_done;
  assign cs_na   = nact(d_q, cs_i0_q);
  assign cs_done = cs_i0_q >= d_q;
  assign x_j     = xbuf[cs_j_q[$clog2(XBUF)-1:0]];
  always_comb begin
    cs_fire = (state_q == ROWS) && !cs_done;
    for (int p = 0; p < LANES; p++) if (p < cs_na && f_cnt_q[p] == 0) cs_fire = 1'b0;
  end

  localparam logic [APU_NDSFLAGS_CPU-1:0] FLAGS = APU_NDSFLAGS_CPU'({
    2'(fpnew_pkg::INT32), 3'(fpnew_pkg::FP32), 3'(fpnew_pkg::FP32), 3'(fpnew_pkg::RNE)});
  localparam logic [APU_WOP_CPU-1:0] OP_MUL = APU_WOP_CPU'({1'b0, 1'b0, 4'(fpnew_pkg::MUL)});
  localparam logic [APU_WOP_CPU-1:0] OP_ADD = APU_WOP_CPU'({1'b0, 1'b0, 4'(fpnew_pkg::ADD)});

  logic        p_valid_q, p_first_q, p_last_q;
  logic [31:0] p_i0_q, p_na_q;
  logic [31:0] prod_q[LANES], acc_q[LANES], mul_res[LANES], add_res[LANES];
  logic        mul_ok[LANES], add_ok[LANES];

  for (genvar p = 0; p < LANES; p++) begin : g_lane
    logic [APU_NARGS_CPU-1:0][31:0] mops, aops;
    logic mg, mv, ag, av;
    // MUL: operands[0] * operands[1] = w * x[j];  ADD: operands[1] + operands[2] = acc + p
    assign mops = {32'h0, x_j, fifo[p][f_rd_q[p]]};
    assign aops = {prod_q[p], (p_first_q ? 32'h0 : acc_q[p]), 32'h0};
    cv32e40p_fp_wrapper #(.FPU_ADDMUL_LAT(0), .FPU_OTHERS_LAT(0)) mul_i (
        .clk_i, .rst_ni, .apu_req_i(cs_fire && p < cs_na), .apu_gnt_o(mg),
        .apu_operands_i(mops), .apu_op_i(OP_MUL), .apu_flags_i(FLAGS),
        .apu_rvalid_o(mv), .apu_rdata_o(mul_res[p]), .apu_rflags_o());
    cv32e40p_fp_wrapper #(.FPU_ADDMUL_LAT(0), .FPU_OTHERS_LAT(0)) add_i (
        .clk_i, .rst_ni, .apu_req_i(p_valid_q && p < p_na_q), .apu_gnt_o(ag),
        .apu_operands_i(aops), .apu_op_i(OP_ADD), .apu_flags_i(FLAGS),
        .apu_rvalid_o(av), .apu_rdata_o(add_res[p]), .apu_rflags_o());
    assign mul_ok[p] = mg && mv;
    assign add_ok[p] = ag && av;
  end

  // ---------------------------------------------------------------- master port
  always_comb begin
    m_req_o = 1'b0; m_we_o = 1'b0; m_addr_o = '0; m_wdata_o = '0;
    unique case (state_q)
      LOADX: begin m_req_o = ld_iss_q < n_q; m_addr_o = x_addr_q + (ld_iss_q << 2); end
      ROWS: begin
        m_req_o  = !is_done && is_can && (t_wr_q + TW'(1) != t_rd_q);
        m_addr_o = is_addr;
      end
      WB: begin
        m_req_o = wb_q < d_q; m_we_o = 1'b1;
        m_addr_o = y_addr_q + (wb_q << 2); m_wdata_o = ybuf[wb_q[$clog2(YBUF)-1:0]];
      end
      default: ;
    endcase
  end
  logic issue_fire;
  assign issue_fire = state_q == ROWS && m_req_o && m_gnt_i;

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
      4'hA: s_rdata_o <= {30'b0, mode_q};
      default: s_rdata_o <= '0;
    endcase
  end

  // ---------------------------------------------------------------- control
  logic [31:0]   ld_a;
  logic [LW+1:0] r_tag;
  assign ld_a  = x_addr_q + (ld_rsp_q << 2);
  assign r_tag = tag[t_rd_q];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= IDLE; mode_q <= MA;
      {x_addr_q, w_addr_q, y_addr_q, n_q, d_q, stride_q, cyc_q} <= '0;
      jstride_q <= 32'd4;
      {ld_iss_q, ld_rsp_q, wb_q, is_i0_q, is_k_q, is_p_q, cs_i0_q, cs_j_q} <= '0;
      {t_wr_q, t_rd_q} <= '0;
      {p_valid_q, p_first_q, p_last_q, p_i0_q, p_na_q} <= '0;
      for (int p = 0; p < LANES; p++) begin
        f_wr_q[p] <= '0; f_rd_q[p] <= '0; f_cnt_q[p] <= '0; f_res_q[p] <= '0;
        prod_q[p] <= '0; acc_q[p] <= '0;
      end
    end else begin
      if (s_req_i && s_we_i && state_q == IDLE) begin
        unique case (s_addr_i[5:2])
          4'h0: if (s_wdata_i[0]) begin
            state_q <= LOADX; cyc_q <= '0;
            {ld_iss_q, ld_rsp_q, wb_q, is_i0_q, is_k_q, is_p_q, cs_i0_q, cs_j_q} <= '0;
            if (jstride_q == 4 && stride_q[3:0] == 0 && w_addr_q[3:0] == 0 && n_q[1:0] == 0)
              mode_q <= MA;
            else if (LANES <= 4 && stride_q == 4 && jstride_q[3:0] == 0 && w_addr_q[3:0] == 0)
              mode_q <= MB;
            else mode_q <= MC;
          end
          4'h2: x_addr_q  <= s_wdata_i;
          4'h3: w_addr_q  <= s_wdata_i;
          4'h4: y_addr_q  <= s_wdata_i;
          4'h5: n_q       <= s_wdata_i;
          4'h6: d_q       <= s_wdata_i;
          4'h7: stride_q  <= s_wdata_i;
          4'h9: jstride_q <= s_wdata_i;
          default: ;
        endcase
      end
      if (state_q != IDLE) cyc_q <= cyc_q + 1;

      p_valid_q <= 1'b0;
      unique case (state_q)
        LOADX: begin
          if (m_req_o && m_gnt_i) ld_iss_q <= ld_iss_q + 1;
          if (m_rvalid_i) begin
            xbuf[ld_rsp_q[$clog2(XBUF)-1:0]] <= m_rdata_i[32*ld_a[3:2] +: 32];
            ld_rsp_q <= ld_rsp_q + 1;
            if (ld_rsp_q + 1 == n_q) state_q <= ROWS;
          end
        end

        ROWS: begin
          // issue: record the tag and advance (group, k, lane)
          if (issue_fire) begin
            tag[t_wr_q] <= is_tag; t_wr_q <= t_wr_q + 1;
            unique case (mode_q)
              MA: begin
                if (is_p_q + 1 < is_na) is_p_q <= is_p_q + 1;
                else begin
                  is_p_q <= '0;
                  if (((is_k_q + 1) << 2) < n_q) is_k_q <= is_k_q + 1;
                  else begin is_k_q <= '0; is_i0_q <= is_i0_q + LANES; end
                end
              end
              MB: begin
                if (is_k_q + 1 < n_q) is_k_q <= is_k_q + 1;
                else begin is_k_q <= '0; is_i0_q <= is_i0_q + LANES; end
              end
              default: begin
                if (is_p_q + 1 < is_na) is_p_q <= is_p_q + 1;
                else begin
                  is_p_q <= '0;
                  if (is_k_q + 1 < n_q) is_k_q <= is_k_q + 1;
                  else begin is_k_q <= '0; is_i0_q <= is_i0_q + LANES; end
                end
              end
            endcase
          end
          if (m_rvalid_i) t_rd_q <= t_rd_q + 1;

          // consume (lockstep over the active lanes) -> stage 1 products
          if (cs_fire) begin
            p_valid_q <= 1'b1;
            p_first_q <= cs_j_q == 0;
            p_last_q  <= cs_j_q + 1 == n_q;
            p_i0_q    <= cs_i0_q;
            p_na_q    <= cs_na;
            for (int p = 0; p < LANES; p++) if (p < cs_na) prod_q[p] <= mul_res[p];
            if (cs_j_q + 1 == n_q) begin cs_j_q <= '0; cs_i0_q <= cs_i0_q + LANES; end
            else cs_j_q <= cs_j_q + 1;
          end
          // stage 2: accumulate, keep finished rows
          if (p_valid_q) begin
            for (int p = 0; p < LANES; p++) if (p < p_na_q) begin
              acc_q[p] <= add_res[p];
              if (p_last_q) ybuf[(p_i0_q + p) & (YBUF - 1)] <= add_res[p];
            end
            if (p_last_q && p_i0_q + LANES >= d_q) state_q <= WB;
          end

          // lane FIFO bookkeeping: response push, issue reservation, consume pop
          for (int p = 0; p < LANES; p++) begin
            logic [2:0] push, rsv;
            logic       pop;
            push = '0; rsv = '0; pop = cs_fire && p < cs_na;
            if (issue_fire) begin
              if (mode_q == MA && is_p_q[LW-1:0] == p) rsv = 3'd4;
              else if (mode_q == MB && p < is_na) rsv = 3'd1;
              else if (mode_q == MC && is_p_q[LW-1:0] == p) rsv = 3'd1;
            end
            if (m_rvalid_i) begin
              if (mode_q == MA && r_tag[LW+1:2] == p) begin
                for (int w = 0; w < 4; w++)
                  fifo[p][f_wr_q[p] + FW'(w)] <= m_rdata_i[32*w +: 32];
                push = 3'd4;
              end else if (mode_q == MB && p <= r_tag[LW+1:2]) begin
                fifo[p][f_wr_q[p]] <= m_rdata_i[32*(r_tag[1:0] + 2'(p)) +: 32];
                push = 3'd1;
              end else if (mode_q == MC && r_tag[LW+1:2] == p) begin
                fifo[p][f_wr_q[p]] <= m_rdata_i[32*r_tag[1:0] +: 32];
                push = 3'd1;
              end
            end
            f_wr_q[p]  <= f_wr_q[p] + FW'(push);
            f_rd_q[p]  <= f_rd_q[p] + FW'(pop);
            f_cnt_q[p] <= f_cnt_q[p] + (FW+1)'(push) - (FW+1)'(pop);
            f_res_q[p] <= f_res_q[p] + (FW+1)'(rsv) - (FW+1)'(push);
          end
        end

        WB: if (m_req_o && m_gnt_i) begin
          wb_q <= wb_q + 1;
          if (wb_q + 1 == d_q) state_q <= IDLE;
        end
        default: ;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    for (int p = 0; p < LANES; p++) begin
      if (cs_fire && p < cs_na && !mul_ok[p]) $error("gemv_acc: MUL not single-cycle");
      if (p_valid_q && p < p_na_q && !add_ok[p]) $error("gemv_acc: ADD not single-cycle");
    end
  end
`endif
endmodule
