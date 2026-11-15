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
//   0x00 CMD (W: 1 softmax, 2 silu, 3 divs, 4 exp, 5 divsoftmax -> starts)
//   0x04 STATUS (R: bit0 busy)
//   0x08 A_ADDR  0x0C B_ADDR (silu gate)  0x10 N (<= BUF)  0x14 SCALAR (divs divisor bits)
//   0x18 LAST_CYCLES (R)
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
      C_DIVSM = 3'd5;
  localparam logic [1:0] O_EXP = 2'd0, O_SUBEXP = 2'd1, O_SILU = 2'd2, O_DIV = 2'd3;

  typedef enum logic [2:0] {IDLE, LOAD, PAR, MAX, SUM, STORE} st_e;
  st_e st_q;

  logic [2:0]  cmd_q;
  logic [1:0]  pass_q;                           // softmax: 0 pre-divide, 1 exp, 2 normalise
  logic        is_sm;
  assign is_sm = cmd_q == C_SOFTMAX || cmd_q == C_DIVSM;
  logic [31:0] a_addr_q, b_addr_q, n_q, scalar_q, cyc_q;
  logic [31:0] iss_q, rsp_q, st_cnt_q, disp_q, done_q, sum_i_q, max_i_q;
  logic [31:0] max_q, sum_q;
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
  logic [1:0]  l_op;
  logic [31:0] l_b;
  logic        disp_go;                          // element disp_q starts on lane disp_q % LANES
  always_comb begin
    unique case (cmd_q)
      C_SOFTMAX, C_DIVSM: l_op = (pass_q == 1) ? O_SUBEXP : O_DIV;
      C_SILU:    l_op = O_SILU;
      C_DIVS:    l_op = O_DIV;
      default:   l_op = O_EXP;
    endcase
    unique case (cmd_q)
      C_SOFTMAX, C_DIVSM: l_b = (pass_q == 0) ? scalar_q : (pass_q == 1) ? max_q : sum_q;
      C_SILU:    l_b = rdb;
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

  // ---------------------------------------------------------------- master port
  logic [31:0] n_load, ld_addr, ld_word;
  logic        st_go;
  assign n_load  = (cmd_q == C_SILU) ? 2 * n_q : n_q;
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
      default: s_rdata_o <= '0;
    endcase
  end

  // ---------------------------------------------------------------- control
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q <= IDLE; cmd_q <= '0; pass_q <= '0; sum_pend_q <= 1'b0;
      {a_addr_q, b_addr_q, n_q, scalar_q, cyc_q, iss_q, rsp_q, st_cnt_q, disp_q, done_q, sum_i_q, max_i_q} <= '0;
      {max_q, sum_q, rd_elem_q} <= '0; rd_st_q <= IDLE; rd_v_q <= 1'b0; rd_bank_q <= '0;
      for (int p = 0; p < LANES; p++) l_idx_q[p] <= '0;
    end else begin
      rd_elem_q <= ra_elem; rd_st_q <= st_q; rd_v_q <= st_q != IDLE; rd_bank_q <= PW'(ra_elem % LANES);
      if (s_req_i && s_we_i && st_q == IDLE) begin
        unique case (s_addr_i[5:2])
          4'h0: if (s_wdata_i[2:0] != 0) begin
            cmd_q <= s_wdata_i[2:0]; st_q <= LOAD; cyc_q <= '0;
            pass_q <= (s_wdata_i[2:0] == C_DIVSM) ? 2'd0 : 2'd1;
            {iss_q, rsp_q, st_cnt_q, disp_q, done_q, sum_i_q} <= '0; sum_q <= '0; sum_pend_q <= 1'b0;
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
            if (rsp_q + 1 == n_load) begin st_q <= PAR; disp_q <= '0; done_q <= '0; end
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
        STORE: if (st_go) begin
          st_cnt_q <= st_cnt_q + 1;
          if (st_cnt_q + 1 == n_q) st_q <= IDLE;
        end
        default: st_q <= IDLE;
      endcase
    end
  end
endmodule
