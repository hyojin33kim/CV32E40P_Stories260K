// Vector function unit (v2, FPGA-oriented): softmax, SiLU*gate, divide-by-scalar and expf,
// bit-exact with the RISC-V software (llama2.c run.c + picolibc 1.8.6 expf).
//
// LANES element engines (vfu_lane.sv, each with its own cv32e40p_fp_wrapper) compute
// independent elements in parallel; every element follows the compiled software's exact
// operation order. Reductions that the software does in index order stay sequential:
//   softmax(x,n): max by '>' scan from x[0] (during load);
//                 pass 1 (lanes)      e[i] = expf(x[i] - max)
//                 pass 2 (sequential) sum = ((0 + e[0]) + e[1]) + ... on one adder
//                 pass 3 (lanes)      x[i] = e[i] / sum
//   silu(h,g,n) : h[i] = (h[i] * (1/(1+expf(-h[i])))) * g[i]          (lanes)
//   divs(x,n,c) : x[i] /= c                                          (lanes)
//   exp(x,n)    : x[i] = expf(x[i])                                  (lanes, unit test)
//   divsoftmax(x,n,c): x[i] /= c (lanes), then softmax as above with the max scan done
//                 sequentially over the divided values (= the CPU's '/=' loop + softmax())
//   softmax2(x,n,K) (Option A, cmd 6): max during load; stream at 1 element/cycle
//                 p[i] = exp2q((x[i] - max) * K)  (fsub, fmul, vfu_exp2 pipeline), x[i] = p[i]
//                 S[i % 4] += p[i] on one pipelined adder (4 partial sums in rotation, forwarded
//                 when FPU_LAT > 0), sum = (S0 + S1) + (S2 + S3) -> SUM register (0x1C)
//   silu2(h,g,n)  (Option A, cmd 7): h[i] = (h[i] * (1/(1+exp2q(h[i]*-log2e)))) * g[i] (lanes)
// '>' for the max scan is an integer compare of the IEEE bit patterns (finite inputs;
// +0 and -0 compare equal), equivalent to flt.s for non-NaN values.
//
// Memory: abuf / bbuf are LANES block-RAM banks (element i in bank i % LANES, which is also the
// lane that computes it), one write port per bank, registered read. Every read result carries
// the (state, element) it was read for and is only used when that matches.
// FPU_LAT: pipeline registers of every FPU (lanes and the sum adder); all FPU use is handshake
// based, so any latency is functionally the same.
//
// MMIO (byte offsets from the slave base):
//   0x00 CMD (W: 1 softmax, 2 silu, 3 divs, 4 exp, 5 divsoftmax, 6 softmax2, 7 silu2 -> starts)
//   0x04 STATUS (R: bit0 busy)
//   0x08 A_ADDR  0x0C B_ADDR (silu gate)  0x10 N (<= BUF)  0x14 SCALAR (divs divisor bits)
//   0x18 LAST_CYCLES (R)  0x1C SUM (R: softmax2 sum)
// Memory master: 128-bit read lines (the addressed word is taken from the line), in-order
// responses, 32-bit writes complete on grant. Load A (and B) -> compute -> store A.
module vfu
  import cv32e40p_apu_core_pkg::*;
#(
    parameter int BUF     = 512,
    parameter int LANES   = 4,
    parameter int FPU_LAT = 0    // FPU pipeline registers (lanes and the sum adder)
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
    input  logic [127:0] m_rdata_i,

    output logic busy_o
);
  localparam int AW = $clog2(BUF);
  localparam int BW = BUF / LANES;                       // words per bank
  localparam int BI = $clog2(BW);
  localparam int PW = (LANES > 1) ? $clog2(LANES) : 1;
  localparam logic [2:0] C_SOFTMAX = 3'd1, C_SILU = 3'd2, C_DIVS = 3'd3, C_EXP = 3'd4,
      C_DIVSM = 3'd5, C_SM2 = 3'd6, C_SILU2 = 3'd7;
  localparam logic [2:0] O_EXP = 3'd0, O_SUBEXP = 3'd1, O_SILU = 3'd2, O_DIV = 3'd3, O_SILU2 = 3'd4;
  localparam int AF = 32;                                // softmax2: p values awaiting the adder

  typedef enum logic [2:0] {IDLE, LOAD, PAR, MAX, SUM, STORE, XS, FIN} st_e;
  st_e st_q;

  logic [2:0]  cmd_q;
  logic [1:0]  pass_q;                           // softmax: 0 pre-divide, 1 exp, 2 normalise
  logic        is_sm;
  assign is_sm = cmd_q == C_SOFTMAX || cmd_q == C_DIVSM;
  logic [31:0] a_addr_q, b_addr_q, n_q, scalar_q, cyc_q;
  logic [31:0] iss_q, rsp_q, st_cnt_q, disp_q, done_q, sum_i_q, max_i_q;
  logic [31:0] max_q, sum_q, sum2_q;
  logic        sum_pend_q;

  // ---------------------------------------------------------------- banked buffers
  logic [31:0] ra_elem;                          // element whose data is read this cycle
  logic [31:0] rd_elem_q;
  st_e         rd_st_q;
  logic        rd_v_q;
  logic [PW-1:0] rd_bank_q;
  logic        aw_en[LANES], bw_en[LANES];
  logic [BI-1:0] aw_idx[LANES], bw_idx[LANES];
  logic [31:0] aw_dat[LANES], bw_dat[LANES], rd_a[LANES], rd_b[LANES];
  for (genvar p = 0; p < LANES; p++) begin : g_bank
    logic [31:0] amem[BW];
    logic [31:0] bmem[BW];
    always_ff @(posedge clk_i) begin
      if (aw_en[p]) amem[aw_idx[p]] <= aw_dat[p];
      if (bw_en[p]) bmem[bw_idx[p]] <= bw_dat[p];
      rd_a[p] <= amem[BI'(ra_elem / LANES)];
      rd_b[p] <= bmem[BI'(ra_elem / LANES)];
    end
  end
  logic [31:0] rda, rdb;                         // the addressed element's words
  assign rda = rd_a[rd_bank_q];
  assign rdb = rd_b[rd_bank_q];
  function automatic logic rd_ok(st_e s, logic [31:0] e);
    return rd_v_q && rd_st_q == s && rd_elem_q == e;
  endfunction

  // ---------------------------------------------------------------- lanes
  logic        l_start[LANES], l_busy[LANES], l_done[LANES];
  logic [31:0] l_res[LANES], l_idx_q[LANES];
  logic [2:0]  l_op;
  logic [31:0] l_b;
  logic        disp_go;                          // element disp_q starts on lane disp_q % LANES
  always_comb begin
    unique case (cmd_q)
      C_SOFTMAX, C_DIVSM: l_op = (pass_q == 1) ? O_SUBEXP : O_DIV;
      C_SILU:    l_op = O_SILU;
      C_SILU2:   l_op = O_SILU2;
      C_DIVS:    l_op = O_DIV;
      default:   l_op = O_EXP;
    endcase
    unique case (cmd_q)
      C_SOFTMAX, C_DIVSM: l_b = (pass_q == 0) ? scalar_q : (pass_q == 1) ? max_q : sum_q;
      C_SILU, C_SILU2: l_b = rdb;
      C_DIVS:    l_b = scalar_q;
      default:   l_b = '0;
    endcase
    disp_go = st_q == PAR && disp_q < n_q && rd_ok(PAR, disp_q) && !l_busy[disp_q % LANES];
    for (int p = 0; p < LANES; p++) l_start[p] = disp_go && (disp_q % LANES == p);
  end

  for (genvar p = 0; p < LANES; p++) begin : g_lane
    vfu_lane #(.FPU_LAT(FPU_LAT)) lane_i (
        .clk_i, .rst_ni, .start_i(l_start[p]), .op_i(l_op), .a_i(rda), .b_i(l_b),
        .busy_o(l_busy[p]), .done_o(l_done[p]), .res_o(l_res[p]));
  end

  // ---------------------------------------------------------------- sequential sum adder
  localparam logic [APU_NDSFLAGS_CPU-1:0] FLAGS = APU_NDSFLAGS_CPU'({
    2'(fpnew_pkg::INT32), 3'(fpnew_pkg::FP32), 3'(fpnew_pkg::FP32), 3'(fpnew_pkg::RNE)});
  localparam logic [APU_WOP_CPU-1:0] OP_ADD = APU_WOP_CPU'({1'b0, 1'b0, 4'(fpnew_pkg::ADD)});
  logic        sum_in, sum_gnt, sum_valid, sum_done;
  logic [31:0] sum_res;
  assign sum_in   = st_q == SUM && sum_i_q < n_q && !sum_pend_q && rd_ok(SUM, sum_i_q);
  assign sum_done = st_q == SUM && sum_valid && (sum_pend_q || (sum_in && sum_gnt));
  cv32e40p_fp_wrapper #(.FPU_ADDMUL_LAT(FPU_LAT), .FPU_OTHERS_LAT(FPU_LAT)) sum_i (
      .clk_i, .rst_ni, .apu_req_i(sum_in), .apu_gnt_o(sum_gnt),
      .apu_operands_i({rda, sum_q, 32'h0}),           // sum + e[i]
      .apu_op_i(OP_ADD), .apu_flags_i(FLAGS),
      .apu_rvalid_o(sum_valid), .apu_rdata_o(sum_res), .apu_rflags_o());

  // ---------------------------------------------------------------- softmax2 stream (cmd 6)
  // source: element src_q read from the banks -> fsub (x - max) -> fmul (* K) -> vfu_exp2 ->
  // p written back to the banks (element wr_q) and queued for the partial-sum adder.
  // Issue is credit limited so that every p in flight fits in the adder queue (AF entries).
  localparam logic [APU_WOP_CPU-1:0] OP_SUB = APU_WOP_CPU'({1'b0, 1'b1, 4'(fpnew_pkg::ADD)});
  localparam logic [APU_WOP_CPU-1:0] OP_MUL = APU_WOP_CPU'({1'b0, 1'b0, 4'(fpnew_pkg::MUL)});
  logic [31:0] src_q, wr_q, add_n_q;
  logic [$clog2(AF):0] af_cnt_q;
  logic        x_req, x_gnt, x_go, sub_valid, mul_gnt, mul_valid, e2_valid;
  logic [31:0] sub_res, mul_res, e2_res;
  assign x_req = st_q == XS && src_q < n_q && rd_ok(XS, src_q) &&
                 (src_q - wr_q) + 32'(af_cnt_q) < AF;
  assign x_go  = x_req && x_gnt;
  cv32e40p_fp_wrapper #(.FPU_ADDMUL_LAT(FPU_LAT), .FPU_OTHERS_LAT(FPU_LAT)) xsub_i (
      .clk_i, .rst_ni, .apu_req_i(x_req), .apu_gnt_o(x_gnt),
      .apu_operands_i({max_q, rda, 32'h0}), .apu_op_i(OP_SUB), .apu_flags_i(FLAGS),   // x - max
      .apu_rvalid_o(sub_valid), .apu_rdata_o(sub_res), .apu_rflags_o());
  cv32e40p_fp_wrapper #(.FPU_ADDMUL_LAT(FPU_LAT), .FPU_OTHERS_LAT(FPU_LAT)) xmul_i (
      .clk_i, .rst_ni, .apu_req_i(sub_valid), .apu_gnt_o(mul_gnt),
      .apu_operands_i({32'h0, scalar_q, sub_res}), .apu_op_i(OP_MUL), .apu_flags_i(FLAGS),  // * K
      .apu_rvalid_o(mul_valid), .apu_rdata_o(mul_res), .apu_rflags_o());
  vfu_exp2 xexp2_i (.clk_i, .rst_ni, .valid_i(mul_valid), .y_i(mul_res), .valid_o(e2_valid), .res_o(e2_res));
`ifndef SYNTHESIS
  always_ff @(posedge clk_i) if (sub_valid && !mul_gnt) $error("vfu: softmax2 fmul not ready");
`endif

  // adder queue (p, partial index) and the 4 partial sums
  logic [31:0] af_p[AF];
  logic [1:0]  af_k[AF];
  logic [$clog2(AF)-1:0] af_wp_q, af_rp_q;
  logic [31:0] ps_q[4];
  logic [2:0]  ps_n_q[4];                                // adds in flight per partial sum
  logic [1:0]  tf_k[8];                                  // in-flight add tags (in order)
  logic [2:0]  tf_wp_q, tf_rp_q;
  logic [3:0]  tf_cnt_q;
  logic        a_cand, a_req, a_gnt, a_valid, a_go;
  logic [31:0] a_op1, a_op2, a_res;
  logic [1:0]  hk, rk;
  logic        ret;
  logic [2:0]  fin_q;                                    // FIN: 0 S0+S1, 1 S2+S3, 2 T0+T1, 3 done
  logic        fin_pend_q;
  logic [31:0] t0_q, t1_q;
  assign hk  = af_k[af_rp_q];
  assign ret = st_q == XS && a_valid;
  assign rk  = (tf_cnt_q == 0) ? hk : tf_k[tf_rp_q];     // same-cycle return only when FPU_LAT = 0
  logic fwd;                                             // head's partial sum returns this cycle
  assign fwd = (FPU_LAT > 0) && ret && rk == hk;
  assign a_cand = st_q == XS && af_cnt_q != 0 &&
                  (ps_n_q[hk] == 0 || (fwd && ps_n_q[hk] == 1));
  always_comb begin
    a_req = 1'b0; a_op1 = '0; a_op2 = '0;
    if (st_q == XS) begin
      a_req = a_cand; a_op1 = fwd ? a_res : ps_q[hk]; a_op2 = af_p[af_rp_q];
    end else if (st_q == FIN && !fin_pend_q && fin_q < 3) begin
      a_req = 1'b1;
      unique case (fin_q)
        3'd0: begin a_op1 = ps_q[0]; a_op2 = ps_q[1]; end
        3'd1: begin a_op1 = ps_q[2]; a_op2 = ps_q[3]; end
        default: begin a_op1 = t0_q; a_op2 = t1_q; end
      endcase
    end
  end
  assign a_go = a_req && a_gnt;
  cv32e40p_fp_wrapper #(.FPU_ADDMUL_LAT(FPU_LAT), .FPU_OTHERS_LAT(FPU_LAT)) xadd_i (
      .clk_i, .rst_ni, .apu_req_i(a_req), .apu_gnt_o(a_gnt),
      .apu_operands_i({a_op2, a_op1, 32'h0}), .apu_op_i(OP_ADD), .apu_flags_i(FLAGS),
      .apu_rvalid_o(a_valid), .apu_rdata_o(a_res), .apu_rflags_o());

  always_ff @(posedge clk_i) begin
    if (st_q == XS && e2_valid) begin af_p[af_wp_q] <= e2_res; af_k[af_wp_q] <= wr_q[1:0]; end
    if (st_q == XS && a_go) tf_k[tf_wp_q] <= hk;
  end

  // ---------------------------------------------------------------- master port
  logic [31:0] n_load, ld_addr, ld_word;
  logic        st_go;
  assign n_load  = (cmd_q == C_SILU || cmd_q == C_SILU2) ? 2 * n_q : n_q;
  assign ld_addr = (rsp_q < n_q) ? a_addr_q + (rsp_q << 2) : b_addr_q + ((rsp_q - n_q) << 2);
  assign ld_word = m_rdata_i[32*ld_addr[3:2] +: 32];
  always_comb begin
    m_req_o = 1'b0; m_we_o = 1'b0; m_addr_o = '0; m_wdata_o = '0;
    if (st_q == LOAD && iss_q < n_load) begin
      m_req_o  = 1'b1;
      m_addr_o = (iss_q < n_q) ? a_addr_q + (iss_q << 2) : b_addr_q + ((iss_q - n_q) << 2);
    end else if (st_q == STORE && st_cnt_q < n_q && rd_ok(STORE, st_cnt_q)) begin
      m_req_o = 1'b1; m_we_o = 1'b1;
      m_addr_o = a_addr_q + (st_cnt_q << 2); m_wdata_o = rda;
    end
  end
  assign st_go  = st_q == STORE && m_req_o && m_gnt_i;
  assign busy_o = st_q != IDLE;

  function automatic logic fgt(logic [31:0] a, logic [31:0] b);   // a > b, finite
    if (a[30:0] == 0 && b[30:0] == 0) return 1'b0;
    if (a[31] != b[31]) return !a[31];
    return a[31] ? (a[30:0] < b[30:0]) : (a[30:0] > b[30:0]);
  endfunction

  // read address = the element the current state needs next cycle
  logic max_go;
  assign max_go = st_q == MAX && rd_ok(MAX, max_i_q);
  always_comb begin
    unique case (st_q)
      PAR:     ra_elem = disp_q + (disp_go ? 1 : 0);
      MAX:     ra_elem = max_i_q + (max_go ? 1 : 0);
      SUM:     ra_elem = sum_i_q + (sum_done ? 1 : 0);
      XS:      ra_elem = src_q + (x_go ? 1 : 0);
      STORE:   ra_elem = st_cnt_q + (st_go ? 1 : 0);
      default: ra_elem = '0;
    endcase
  end

  // bank write ports: loader (LOAD) or the lane owning the bank (PAR)
  always_comb begin
    for (int p = 0; p < LANES; p++) begin
      aw_en[p] = 1'b0; aw_idx[p] = BI'(l_idx_q[p] / LANES); aw_dat[p] = l_res[p];
      bw_en[p] = 1'b0; bw_idx[p] = '0; bw_dat[p] = ld_word;
      if (st_q == LOAD && m_rvalid_i) begin
        if (rsp_q < n_q) begin
          if (rsp_q % LANES == p) begin aw_en[p] = 1'b1; aw_idx[p] = BI'(rsp_q / LANES); aw_dat[p] = ld_word; end
        end else if ((rsp_q - n_q) % LANES == p) begin
          bw_en[p] = 1'b1; bw_idx[p] = BI'((rsp_q - n_q) / LANES);
        end
      end else if (st_q == XS) begin
        if (e2_valid && PW'(wr_q % LANES) == PW'(p)) begin
          aw_en[p] = 1'b1; aw_idx[p] = BI'(wr_q / LANES); aw_dat[p] = e2_res;
        end
      end else if (l_done[p]) aw_en[p] = 1'b1;
    end
  end

  always_ff @(posedge clk_i) begin
    unique case (s_addr_i[5:2])
      4'h1: s_rdata_o <= {31'b0, busy_o};
      4'h2: s_rdata_o <= a_addr_q;
      4'h3: s_rdata_o <= b_addr_q;
      4'h4: s_rdata_o <= n_q;
      4'h5: s_rdata_o <= scalar_q;
      4'h6: s_rdata_o <= cyc_q;
      4'h7: s_rdata_o <= sum2_q;
      default: s_rdata_o <= '0;
    endcase
  end

  // ---------------------------------------------------------------- control
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q <= IDLE; cmd_q <= '0; pass_q <= '0; sum_pend_q <= 1'b0;
      {a_addr_q, b_addr_q, n_q, scalar_q, cyc_q, iss_q, rsp_q, st_cnt_q, disp_q, done_q, sum_i_q, max_i_q} <= '0;
      {max_q, sum_q, sum2_q, rd_elem_q} <= '0;
      {src_q, wr_q, add_n_q, t0_q, t1_q} <= '0; af_cnt_q <= '0; af_wp_q <= '0; af_rp_q <= '0;
      tf_wp_q <= '0; tf_rp_q <= '0; tf_cnt_q <= '0; fin_q <= '0; fin_pend_q <= 1'b0;
      for (int k = 0; k < 4; k++) begin ps_q[k] <= '0; ps_n_q[k] <= '0; end rd_st_q <= IDLE; rd_v_q <= 1'b0; rd_bank_q <= '0;
      for (int p = 0; p < LANES; p++) l_idx_q[p] <= '0;
    end else begin
      rd_elem_q <= ra_elem; rd_st_q <= st_q; rd_v_q <= st_q != IDLE; rd_bank_q <= PW'(ra_elem % LANES);
      if (s_req_i && s_we_i && st_q == IDLE) begin
        unique case (s_addr_i[5:2])
          4'h0: if (s_wdata_i[2:0] != 0) begin
            cmd_q <= s_wdata_i[2:0]; st_q <= LOAD; cyc_q <= '0;
            pass_q <= (s_wdata_i[2:0] == C_DIVSM) ? 2'd0 : 2'd1;
            // (disp_q / done_q are cleared when PAR is entered; not here: keeps the CPU store
            //  address -> MMIO decode path off their enables, the 150 MHz critical path)
            {iss_q, rsp_q, st_cnt_q, sum_i_q} <= '0; sum_q <= '0; sum_pend_q <= 1'b0;
          end
          4'h2: a_addr_q <= s_wdata_i;
          4'h3: b_addr_q <= s_wdata_i;
          4'h4: n_q      <= s_wdata_i;
          4'h5: scalar_q <= s_wdata_i;
          default: ;
        endcase
      end
      if (st_q != IDLE) cyc_q <= cyc_q + 1;

      begin : count_done
        logic [31:0] nd;
        nd = 0;
        for (int p = 0; p < LANES; p++) nd = nd + 32'(l_done[p]);
        if (st_q == PAR) done_q <= done_q + nd;
      end
      if (disp_go) begin
        l_idx_q[disp_q % LANES] <= disp_q;
        disp_q <= disp_q + 1;
      end

      unique case (st_q)
        IDLE: ;
        LOAD: begin
          if (m_req_o && m_gnt_i) iss_q <= iss_q + 1;
          if (m_rvalid_i) begin
            if (rsp_q < n_q && (rsp_q == 0 || fgt(ld_word, max_q))) max_q <= ld_word;
            rsp_q <= rsp_q + 1;
            if (rsp_q + 1 == n_load) begin
              if (cmd_q == C_SM2) begin
                st_q <= XS; {src_q, wr_q, add_n_q} <= '0; af_cnt_q <= '0; af_wp_q <= '0; af_rp_q <= '0;
                tf_wp_q <= '0; tf_rp_q <= '0; tf_cnt_q <= '0;
                for (int k = 0; k < 4; k++) begin ps_q[k] <= '0; ps_n_q[k] <= '0; end
              end else begin st_q <= PAR; disp_q <= '0; done_q <= '0; end
            end
          end
        end
        PAR: begin
          // all elements of this pass done (count includes this cycle's completions)
          logic [31:0] nd2;
          nd2 = 0;
          for (int p = 0; p < LANES; p++) nd2 = nd2 + 32'(l_done[p]);
          if (done_q + nd2 == n_q) begin
            if (is_sm && pass_q == 0) begin st_q <= MAX; max_i_q <= '0; end
            else if (is_sm && pass_q == 1) begin st_q <= SUM; sum_i_q <= '0; sum_pend_q <= 1'b0; end
            else begin st_q <= STORE; st_cnt_q <= '0; end
          end
        end
        MAX: if (max_go) begin   // max scan over the divided values, index order (as softmax())
          if (max_i_q == 0 || fgt(rda, max_q)) max_q <= rda;
          max_i_q <= max_i_q + 1;
          if (max_i_q + 1 == n_q) begin st_q <= PAR; pass_q <= 2'd1; disp_q <= '0; done_q <= '0; end
        end
        SUM: begin
          if (sum_done) begin
            sum_q <= sum_res; sum_i_q <= sum_i_q + 1; sum_pend_q <= 1'b0;
            if (sum_i_q + 1 == n_q) begin
              st_q <= PAR; pass_q <= 2'd2; disp_q <= '0; done_q <= '0;
            end
          end else if (sum_in && sum_gnt) sum_pend_q <= 1'b1;
        end
        XS: begin
          if (x_go) src_q <= src_q + 1;
          if (e2_valid) begin wr_q <= wr_q + 1; af_wp_q <= af_wp_q + 1; end
          if (a_go) af_rp_q <= af_rp_q + 1;
          af_cnt_q <= af_cnt_q + (e2_valid ? 1 : 0) - (a_go ? 1 : 0);
          // in-flight add tags (a same-cycle return, FPU_LAT = 0, bypasses the tag FIFO)
          if (a_go && !(ret && tf_cnt_q == 0)) begin tf_wp_q <= tf_wp_q + 1; end
          if (ret && tf_cnt_q != 0) tf_rp_q <= tf_rp_q + 1;
          tf_cnt_q <= tf_cnt_q + ((a_go && !(ret && tf_cnt_q == 0)) ? 1 : 0) - ((ret && tf_cnt_q != 0) ? 1 : 0);
          for (int k = 0; k < 4; k++)
            ps_n_q[k] <= ps_n_q[k] + ((a_go && hk == 2'(k)) ? 1 : 0) - ((ret && rk == 2'(k)) ? 1 : 0);
          if (ret) begin
            ps_q[rk] <= a_res;
            add_n_q <= add_n_q + 1;
            if (add_n_q + 1 == n_q) begin st_q <= FIN; fin_q <= '0; fin_pend_q <= 1'b0; end
          end
        end
        FIN: begin
          if (a_valid && (fin_pend_q || a_go)) begin
            fin_pend_q <= 1'b0; fin_q <= fin_q + 1;
            unique case (fin_q)
              3'd0: t0_q <= a_res;
              3'd1: t1_q <= a_res;
              default: begin sum2_q <= a_res; st_q <= STORE; st_cnt_q <= '0; end
            endcase
          end else if (a_go) fin_pend_q <= 1'b1;
        end
        STORE: if (st_go) begin
          st_cnt_q <= st_cnt_q + 1;
          if (st_cnt_q + 1 == n_q) st_q <= IDLE;
        end
        default: st_q <= IDLE;
      endcase
    end
  end
endmodule
