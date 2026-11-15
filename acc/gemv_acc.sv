// GEMV accelerator (v2, FPGA-oriented): FFN / all weight matmuls, attention QK and AV.
//
//   y[i] = sum_j W[W_ADDR + i*W_STRIDE + j*J_STRIDE] * x[j]      i < D, j < N
//
//   matmul        : W_STRIDE = 4*N, J_STRIDE = 4
//   attention QK  : W = key cache of the head,   W_STRIDE = 4*kv_dim, J_STRIDE = 4
//   attention AV  : W = value cache of the head, W_STRIDE = 4, J_STRIDE = 4*kv_dim
//
// Bit-exact with the RISC-V software loops (val = 0.0f; val += w*x in j order): every row is
// accumulated sequentially in j order from +0.0, one fmul then one fadd per MAC, through
// cv32e40p_fp_wrapper (the CV32E40P FPU module, FP32, RNE). Pipelining and parallelism only
// change *when* a row's next MAC happens, never its order, so results do not depend on
// LANES, FPU_LAT or the memory timing.
//
// Datapath:
//   FPU_LAT   pipeline registers in each fmul/fadd (fpnew FPU_ADDMUL_LAT; FPGA builds place
//             them DISTRIBUTED). A row's next fadd needs the previous one's result, so each
//             physical lane interleaves R = FPU_LAT rows (R = 1 when FPU_LAT = 0): the rows of
//             a group are logical lanes q = phase*LANES + p (p = physical lane); the phase
//             advances every cycle, so a row's MACs are >= R cycles apart.
//   memory    xbuf (x) and ybuf (y, one bank per physical lane) are block-RAM style arrays
//             (one write port, registered read); each logical lane's weight FIFO is 4 LUT-RAM
//             banks (one write port each, asynchronous read) so a 4-word line is written in
//             one cycle; the tag FIFO is LUT RAM. No register-file arrays.
//
// Memory master: 128-bit read lines (16-byte aligned address, in-order responses), 32-bit word
// writes (complete on grant). Weight fetch per group of LL = LANES*R rows:
//   mode A (J_STRIDE=4, W and W_STRIDE 16B aligned, N%4==0): a line = 4 consecutive j of one
//          row; RUN lines per row before the next row (contiguous bursts)
//   mode B (W_STRIDE=4, J_STRIDE%16==0, W 16B aligned, LANES==4): a line = the same j of the
//          4 rows of one phase
//   mode C (anything else): one word per request
// Per-logical-lane FIFOs with credits (in-flight words reserved).
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
    parameter int XBUF    = 512,
    parameter int YBUF    = 512,
    parameter int LANES   = 4,
    parameter int RUN     = 16,    // mode A lines per row before switching rows
    parameter int FDEPTH  = 256,   // weight FIFO words per physical lane (split over R rows)
    parameter int FPU_LAT = 0      // fmul/fadd pipeline registers (fpnew FPU_ADDMUL_LAT)
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
  localparam int R    = (FPU_LAT < 1) ? 1 : FPU_LAT;   // rows interleaved per physical lane
  localparam int LL   = LANES * R;                       // logical lanes (rows per group)
  localparam int QW   = (LL > 1) ? $clog2(LL) : 1;
  localparam int PW   = (LANES > 1) ? $clog2(LANES) : 1;
  localparam int RW   = (R > 1) ? $clog2(R) : 1;
  localparam int FDL  = FDEPTH / R;                      // FIFO words per logical lane
  localparam int FW   = $clog2(FDL);
  localparam int FB   = FDL / 4;                         // words per FIFO bank
  localparam int TDEPTH = LL * FDL;                      // >= max outstanding requests
  localparam int TW   = $clog2(TDEPTH);
  localparam int XW   = $clog2(XBUF);
  localparam int YB   = YBUF / LANES;                    // words per ybuf bank
  localparam int YW   = $clog2(YB);

  typedef enum logic [2:0] {IDLE, LOADX, ROWS, WBP, WB} state_e;
  typedef enum logic [1:0] {MA, MB, MC} mode_e;
  state_e state_q;
  mode_e  mode_q;

  logic [31:0] x_addr_q, w_addr_q, y_addr_q, n_q, d_q, stride_q, jstride_q, cyc_q;
  logic [31:0] ld_iss_q, ld_rsp_q, wb_q, rows_done_q;

  function automatic logic [31:0] nact(logic [31:0] d, logic [31:0] i0);   // rows in a group
    return (d - i0 >= LL) ? LL : d - i0;
  endfunction

  // ================================================================ xbuf (block RAM)
  logic          xw_en;
  logic [XW-1:0] xw_addr, xr_addr;
  logic [31:0]   xw_data, x_rd_q;
  logic [31:0]   xbuf[XBUF];
  always_ff @(posedge clk_i) begin
    if (xw_en) xbuf[xw_addr] <= xw_data;
    x_rd_q <= xbuf[xr_addr];
  end

  // ================================================================ ybuf (block RAM, per lane)
  logic          yw_en[LANES];
  logic [YW-1:0] yw_idx[LANES], yr_idx;
  logic [31:0]   yw_data[LANES], y_rd[LANES];
  logic [PW-1:0] yr_bank_q;
  for (genvar p = 0; p < LANES; p++) begin : g_ybuf
    logic [31:0] mem[YB];
    always_ff @(posedge clk_i) begin
      if (yw_en[p]) mem[yw_idx[p]] <= yw_data[p];
      y_rd[p] <= mem[yr_idx];
    end
  end

  // ================================================================ weight FIFOs (LUT RAM)
  logic [FW-1:0] f_wr_q[LL], f_rd_q[LL];
  logic [FW:0]   f_cnt_q[LL], f_res_q[LL];
  logic [2:0]    f_push[LL];            // words written this cycle (0, 1 or 4)
  logic [31:0]   f_wd[LL][4];           // the words, in FIFO order
  logic          f_pop[LL];
  logic [31:0]   f_head[LL];
  for (genvar q = 0; q < LL; q++) begin : g_fifo
    logic [31:0] head_b[4];
    for (genvar b = 0; b < 4; b++) begin : g_bank
      logic [31:0]   mem[FB];
      logic [1:0]    w;                  // which pushed word lands in this bank
      logic          we;
      logic [FW-1:0] pos;
      assign w   = 2'(b - f_wr_q[q][1:0]);
      assign we  = {1'b0, w} < f_push[q];
      assign pos = f_wr_q[q] + FW'(w);
      always_ff @(posedge clk_i) if (we) mem[pos[FW-1:2]] <= f_wd[q][w];
      assign head_b[b] = mem[f_rd_q[q][FW-1:2]];
    end
    assign f_head[q] = head_b[f_rd_q[q][1:0]];
  end

  // tag FIFO (LUT RAM): {q base, aux (mode B: rows-1), word offset}
  logic [QW+3:0] tag[TDEPTH];
  logic [TW-1:0] t_wr_q, t_rd_q;
  logic [QW+3:0] r_tag, is_tag;
  logic          tag_we;
  always_ff @(posedge clk_i) if (tag_we) tag[t_wr_q] <= is_tag;
  assign r_tag = tag[t_rd_q];

  // ================================================================ issue
  logic [31:0] is_i0_q, is_k_q, is_q_q, is_kb_q;  // group, chunk/j, row (A,C) or phase (B), run base
  logic [31:0] is_addr, is_na, is_nph, b_cnt;
  logic        is_can, is_done;
  always_comb begin
    is_na   = nact(d_q, is_i0_q);
    is_nph  = (is_na + LANES - 1) / LANES;            // phases with rows (mode B lines per j)
    is_done = is_i0_q >= d_q;
    b_cnt   = (is_na - is_q_q * LANES >= LANES) ? LANES : is_na - is_q_q * LANES;
    is_addr = '0; is_can = 1'b0; is_tag = '0;
    unique case (mode_q)
      MA: begin
        is_addr = w_addr_q + (is_i0_q + is_q_q) * stride_q + (is_k_q << 4);
        is_can  = (FDL - f_cnt_q[is_q_q[QW-1:0]] - f_res_q[is_q_q[QW-1:0]]) >= 4;
        is_tag  = {is_q_q[QW-1:0], 2'b00, 2'b00};
      end
      MB: begin
        is_addr = w_addr_q + ((is_i0_q + is_q_q * LANES) << 2) + is_k_q * jstride_q;
        is_can  = 1'b1;
        for (int p = 0; p < LANES; p++)
          if (p < b_cnt && (FDL - f_cnt_q[is_q_q * LANES + p] - f_res_q[is_q_q * LANES + p]) < 1)
            is_can = 1'b0;
        is_tag  = {QW'(is_q_q * LANES), 2'(b_cnt - 1), is_addr[3:2]};
      end
      default: begin
        is_addr = w_addr_q + (is_i0_q + is_q_q) * stride_q + is_k_q * jstride_q;
        is_can  = (FDL - f_cnt_q[is_q_q[QW-1:0]] - f_res_q[is_q_q[QW-1:0]]) >= 1;
        is_tag  = {is_q_q[QW-1:0], 2'b00, is_addr[3:2]};
      end
    endcase
  end

  // ================================================================ consume / MAC pipeline
  logic [31:0]   cs_i0_q, cs_j_q, cs_na, ph_rows;
  logic [RW-1:0] ph_q;
  logic          cs_done, cs_fire, cs_bubble, x_ok_q;
  always_comb begin
    cs_na    = nact(d_q, cs_i0_q);
    cs_done  = cs_i0_q >= d_q;
    ph_rows  = (cs_na > ph_q * LANES) ?
               ((cs_na - ph_q * LANES >= LANES) ? LANES : cs_na - ph_q * LANES) : 0;
    cs_fire  = state_q == ROWS && !cs_done && x_ok_q && ph_rows != 0;
    for (int p = 0; p < LANES; p++)
      if (p < ph_rows && f_cnt_q[ph_q * LANES + p] == 0) cs_fire = 1'b0;
    cs_bubble = state_q == ROWS && !cs_done && x_ok_q && ph_rows == 0;   // phase without rows
  end
  logic cs_adv, ph_wrap, j_last;
  assign cs_adv  = cs_fire || cs_bubble;                 // phase advances this cycle
  assign ph_wrap = ph_q == RW'(R - 1);
  assign j_last  = cs_j_q + 1 == n_q;
  // x read address = j of the next cycle (x is the same over the R phases of one j)
  always_comb begin
    if (state_q == ROWS && cs_adv && ph_wrap) xr_addr = j_last ? '0 : XW'(cs_j_q + 1);
    else xr_addr = XW'(cs_j_q);
  end

  localparam logic [APU_NDSFLAGS_CPU-1:0] FLAGS = APU_NDSFLAGS_CPU'({
    2'(fpnew_pkg::INT32), 3'(fpnew_pkg::FP32), 3'(fpnew_pkg::FP32), 3'(fpnew_pkg::RNE)});
  localparam logic [APU_WOP_CPU-1:0] OP_MUL = APU_WOP_CPU'({1'b0, 1'b0, 4'(fpnew_pkg::MUL)});
  localparam logic [APU_WOP_CPU-1:0] OP_ADD = APU_WOP_CPU'({1'b0, 1'b0, 4'(fpnew_pkg::ADD)});

  // side band travelling with the fmul (FPU_LAT stages), then with the fadd (FPU_LAT stages)
  typedef struct packed {
    logic          v;
    logic [RW-1:0] ph;
    logic [31:0]   i0;
    logic [31:0]   rows;
    logic          first, last;
  } sb_t;
  sb_t m_sb[FPU_LAT+1];       // m_sb[0] = fmul issued now, m_sb[FPU_LAT] = its result now
  sb_t a_sb[FPU_LAT+1];       // a_sb[0] = fadd issued now, a_sb[FPU_LAT] = its result now
  assign m_sb[0] = '{v: cs_fire, ph: ph_q, i0: cs_i0_q, rows: ph_rows, first: cs_j_q == 0, last: j_last};
  assign a_sb[0] = m_sb[FPU_LAT];
  for (genvar s = 1; s <= FPU_LAT; s++) begin : g_sb
    always_ff @(posedge clk_i or negedge rst_ni)
      if (!rst_ni) begin m_sb[s] <= '0; a_sb[s] <= '0; end
      else begin m_sb[s] <= m_sb[s-1]; a_sb[s] <= a_sb[s-1]; end
  end

  logic [31:0] acc_q[LL];
  logic [31:0] mul_res[LANES], add_res[LANES];
  logic        mul_ok[LANES], add_ok[LANES];
  for (genvar p = 0; p < LANES; p++) begin : g_lane
    logic [APU_NARGS_CPU-1:0][31:0] mops, aops;
    logic          mg, mv, ag, av, fwd;
    logic [31:0]   acc_in;
    logic [QW-1:0] qa, qr;
    assign qa = QW'(a_sb[0].ph * LANES + p);              // row whose fadd is issued now
    assign qr = QW'(a_sb[FPU_LAT].ph * LANES + p);        // row whose fadd result is here now
    // previous partial sum of row qa, forwarded when its fadd completes in this cycle
    // (only possible with a pipelined fadd; FPU_LAT = 0 reads acc_q written last cycle)
    assign fwd    = (FPU_LAT > 0) && a_sb[FPU_LAT].v && p < a_sb[FPU_LAT].rows && qr == qa;
    assign acc_in = fwd ? add_res[p] : acc_q[qa];
    // MUL: operands[0] * operands[1] = w * x[j];  ADD: operands[1] + operands[2] = acc + p
    assign mops = {32'h0, x_rd_q, f_head[ph_q * LANES + p]};
    assign aops = {mul_res[p], (a_sb[0].first ? 32'h0 : acc_in), 32'h0};
    cv32e40p_fp_wrapper #(.FPU_ADDMUL_LAT(FPU_LAT), .FPU_OTHERS_LAT(0)) mul_i (
        .clk_i, .rst_ni, .apu_req_i(cs_fire && p < ph_rows), .apu_gnt_o(mg),
        .apu_operands_i(mops), .apu_op_i(OP_MUL), .apu_flags_i(FLAGS),
        .apu_rvalid_o(mv), .apu_rdata_o(mul_res[p]), .apu_rflags_o());
    cv32e40p_fp_wrapper #(.FPU_ADDMUL_LAT(FPU_LAT), .FPU_OTHERS_LAT(0)) add_i (
        .clk_i, .rst_ni, .apu_req_i(a_sb[0].v && p < a_sb[0].rows), .apu_gnt_o(ag),
        .apu_operands_i(aops), .apu_op_i(OP_ADD), .apu_flags_i(FLAGS),
        .apu_rvalid_o(av), .apu_rdata_o(add_res[p]), .apu_rflags_o());
    assign mul_ok[p] = mg;
    assign add_ok[p] = ag;
    // finished rows -> ybuf bank p, index = row / LANES
    assign yw_en[p]   = a_sb[FPU_LAT].v && p < a_sb[FPU_LAT].rows && a_sb[FPU_LAT].last;
    assign yw_idx[p]  = YW'(a_sb[FPU_LAT].i0 / LANES + a_sb[FPU_LAT].ph);
    assign yw_data[p] = add_res[p];
  end

  // ================================================================ master port
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
        m_addr_o = y_addr_q + (wb_q << 2); m_wdata_o = y_rd[yr_bank_q];
      end
      default: ;
    endcase
  end
  logic issue_fire;
  assign issue_fire = state_q == ROWS && m_req_o && m_gnt_i;
  assign tag_we     = issue_fire;

  // ybuf read address: the row of the next write-back word
  logic [31:0] wb_next;
  assign wb_next = (state_q == WB && m_req_o && m_gnt_i) ? wb_q + 1 : wb_q;
  assign yr_idx  = YW'(wb_next / LANES);

  // x write port (LOADX responses)
  logic [31:0] ld_a;
  assign ld_a    = x_addr_q + (ld_rsp_q << 2);
  assign xw_en   = state_q == LOADX && m_rvalid_i;
  assign xw_addr = XW'(ld_rsp_q);
  assign xw_data = m_rdata_i[32*ld_a[3:2] +: 32];

  // FIFO writes (weight responses) and pops (consume)
  always_comb begin
    for (int q = 0; q < LL; q++) begin
      f_push[q] = '0; f_pop[q] = 1'b0;
      for (int w = 0; w < 4; w++) f_wd[q][w] = m_rdata_i[32*w +: 32];
    end
    if (state_q == ROWS && m_rvalid_i) begin
      unique case (mode_q)
        MA: f_push[r_tag[QW+3:4]] = 3'd4;
        MB: for (int p = 0; p < LANES; p++)
              if (p <= r_tag[3:2]) begin
                f_push[r_tag[QW+3:4] + p] = 3'd1;
                f_wd[r_tag[QW+3:4] + p][0] = m_rdata_i[32*(r_tag[1:0] + 2'(p)) +: 32];
              end
        default: begin
          f_push[r_tag[QW+3:4]] = 3'd1;
          f_wd[r_tag[QW+3:4]][0] = m_rdata_i[32*r_tag[1:0] +: 32];
        end
      endcase
    end
    if (cs_fire) for (int p = 0; p < LANES; p++) if (p < ph_rows) f_pop[ph_q * LANES + p] = 1'b1;
  end

  // ================================================================ slave
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

  // ================================================================ control
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= IDLE; mode_q <= MA;
      {x_addr_q, w_addr_q, y_addr_q, n_q, d_q, stride_q, cyc_q} <= '0;
      jstride_q <= 32'd4;
      {ld_iss_q, ld_rsp_q, wb_q, rows_done_q, is_i0_q, is_k_q, is_q_q, is_kb_q, cs_i0_q, cs_j_q} <= '0;
      {t_wr_q, t_rd_q} <= '0; ph_q <= '0; x_ok_q <= 1'b0; yr_bank_q <= '0;
      for (int q = 0; q < LL; q++) begin
        f_wr_q[q] <= '0; f_rd_q[q] <= '0; f_cnt_q[q] <= '0; f_res_q[q] <= '0; acc_q[q] <= '0;
      end
    end else begin
      if (s_req_i && s_we_i && state_q == IDLE) begin
        unique case (s_addr_i[5:2])
          4'h0: if (s_wdata_i[0]) begin
            state_q <= LOADX; cyc_q <= '0;
            {ld_iss_q, ld_rsp_q, wb_q, rows_done_q, is_i0_q, is_k_q, is_q_q, is_kb_q, cs_i0_q, cs_j_q} <= '0;
            ph_q <= '0; x_ok_q <= 1'b0;
            if (jstride_q == 4 && stride_q[3:0] == 0 && w_addr_q[3:0] == 0 && n_q[1:0] == 0)
              mode_q <= MA;
            else if (LANES == 4 && stride_q == 4 && jstride_q[3:0] == 0 && w_addr_q[3:0] == 0)
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
      yr_bank_q <= PW'(wb_next % LANES);

      unique case (state_q)
        LOADX: begin
          if (m_req_o && m_gnt_i) ld_iss_q <= ld_iss_q + 1;
          if (m_rvalid_i) begin
            ld_rsp_q <= ld_rsp_q + 1;
            if (ld_rsp_q + 1 == n_q) state_q <= ROWS;
          end
        end

        ROWS: begin
          x_ok_q <= 1'b1;   // x_rd_q holds x[cs_j] from the second ROWS cycle on
          // ---- issue: advance
          if (issue_fire) begin
            t_wr_q <= t_wr_q + 1;
            unique case (mode_q)
              MA: begin   // (group, run, row, chunk in run)
                if (is_k_q + 1 - is_kb_q < RUN && ((is_k_q + 1) << 2) < n_q) is_k_q <= is_k_q + 1;
                else if (is_q_q + 1 < is_na) begin is_q_q <= is_q_q + 1; is_k_q <= is_kb_q; end
                else begin
                  is_q_q <= '0;
                  if (((is_k_q + 1) << 2) < n_q) begin is_kb_q <= is_k_q + 1; is_k_q <= is_k_q + 1; end
                  else begin is_kb_q <= '0; is_k_q <= '0; is_i0_q <= is_i0_q + LL; end
                end
              end
              MB: begin   // (group, j, phase)
                if (is_q_q + 1 < is_nph) is_q_q <= is_q_q + 1;
                else begin
                  is_q_q <= '0;
                  if (is_k_q + 1 < n_q) is_k_q <= is_k_q + 1;
                  else begin is_k_q <= '0; is_i0_q <= is_i0_q + LL; end
                end
              end
              default: begin   // (group, j, row)
                if (is_q_q + 1 < is_na) is_q_q <= is_q_q + 1;
                else begin
                  is_q_q <= '0;
                  if (is_k_q + 1 < n_q) is_k_q <= is_k_q + 1;
                  else begin is_k_q <= '0; is_i0_q <= is_i0_q + LL; end
                end
              end
            endcase
          end
          if (m_rvalid_i) t_rd_q <= t_rd_q + 1;

          // ---- consume: phase / j / group counters
          if (cs_adv) begin
            ph_q <= ph_wrap ? '0 : ph_q + 1;
            if (ph_wrap) begin
              if (j_last) begin cs_j_q <= '0; cs_i0_q <= cs_i0_q + LL; end
              else cs_j_q <= cs_j_q + 1;
            end
          end

          // ---- fadd results: partial sums, finished rows
          if (a_sb[FPU_LAT].v) begin
            for (int p = 0; p < LANES; p++)
              if (p < a_sb[FPU_LAT].rows) acc_q[a_sb[FPU_LAT].ph * LANES + p] <= add_res[p];
            if (a_sb[FPU_LAT].last) begin
              rows_done_q <= rows_done_q + a_sb[FPU_LAT].rows;
              if (rows_done_q + a_sb[FPU_LAT].rows == d_q) state_q <= WBP;
            end
          end

          // ---- FIFO bookkeeping: response push, issue reservation, consume pop
          for (int q = 0; q < LL; q++) begin
            logic [2:0] rsv;
            rsv = '0;
            if (issue_fire) begin
              if (mode_q == MA && is_q_q == q) rsv = 3'd4;
              else if (mode_q == MB && q >= is_q_q * LANES && q < is_q_q * LANES + b_cnt) rsv = 3'd1;
              else if (mode_q == MC && is_q_q == q) rsv = 3'd1;
            end
            f_wr_q[q]  <= f_wr_q[q] + FW'(f_push[q]);
            f_rd_q[q]  <= f_rd_q[q] + FW'(f_pop[q]);
            f_cnt_q[q] <= f_cnt_q[q] + (FW+1)'(f_push[q]) - (FW+1)'(f_pop[q]);
            f_res_q[q] <= f_res_q[q] + (FW+1)'(rsv) - (FW+1)'(f_push[q]);
          end
        end

        WBP: state_q <= WB;   // ybuf registered read of row 0
        WB: if (m_req_o && m_gnt_i) begin
          wb_q <= wb_q + 1;
          if (wb_q + 1 == d_q) state_q <= IDLE;
        end
        default: ;
      endcase
    end
  end

`ifndef SYNTHESIS
  // fixed-latency pipeline: the FPU must accept every issue (no back-pressure)
  always_ff @(posedge clk_i) begin
    for (int p = 0; p < LANES; p++) begin
      if (cs_fire && p < ph_rows && !mul_ok[p]) $error("gemv_acc: fmul not accepted");
      if (a_sb[0].v && p < a_sb[0].rows && !add_ok[p]) $error("gemv_acc: fadd not accepted");
    end
  end
`endif
endmodule
