// Read-only AXI4 master for the external weight region (S5b; 15M scope, Decision 11-14 "stream-through").
// Bridges the two external read ports of soc_chip (WEIGHTS_ONCHIP = 0) to one AXI4 master:
//   acc_*  accelerator line reads: 128-bit lines, requests with gnt, responses strictly in order, no
//          back pressure on the response (soc_chip's external line FIFO holds 64 lines)
//   cpu_*  CPU word reads (rare: boot-time copies); one outstanding; writes are not supported
// Consecutive accelerator lines are merged into one INCR burst (up to MAXB lines, never across a 4 KB
// boundary). A burst is issued when it is full, when the next request is not the next line, or after
// WT idle cycles. The number of lines requested but not yet returned is limited to CRED (< 64).
// All responses come from one AXI ID (in order); R is always ready (consumers accept every beat).
// AXI address = base_i + line address; base_i must be 4 KB aligned.
module axi_ext_rd #(
    parameter int MAXB = 16,      // lines per burst (16 B each)
    parameter int WT   = 3,       // idle cycles before an open burst is issued
    parameter int CRED = 48,      // max lines in flight (requested, not yet returned)
    parameter int TD   = 8        // max outstanding AXI reads
) (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic [31:0]  base_i,
    // accelerator line port (read only)
    input  logic         acc_req_i,
    input  logic [31:0]  acc_addr_i,
    output logic         acc_gnt_o,
    output logic         acc_rvalid_o,
    output logic [127:0] acc_rdata_o,
    // CPU word port
    input  logic         cpu_req_i,
    input  logic [31:0]  cpu_addr_i,
    output logic         cpu_gnt_o,
    output logic         cpu_rvalid_o,
    output logic [31:0]  cpu_rdata_o,
    // AXI4 read master (128-bit)
    output logic [31:0]  m_araddr_o,
    output logic [ 7:0]  m_arlen_o,
    output logic         m_arvalid_o,
    input  logic         m_arready_i,
    input  logic [127:0] m_rdata_i,
    input  logic [  1:0] m_rresp_i,
    input  logic         m_rlast_i,
    input  logic         m_rvalid_i,
    output logic         m_rready_o,
    output logic         err_o,
    // counters for the performance study
    output logic [31:0]  n_bursts_o,
    output logic [31:0]  n_lines_o
);
  localparam int LW = 28;                          // line index bits (32-bit byte address / 16)
  localparam int CW = $clog2(MAXB + 1);

  // ---------------------------------------------------------------- accelerator burst accumulator
  logic          open_q;
  logic [LW-1:0] base_ln_q;
  logic [CW-1:0] cnt_q;
  logic [7:0]    idle_q;
  logic [LW-1:0] a_ln;
  logic          consec, full, issue_acc;
  // request FIFO: acc_gnt_o depends on its fill level only (a register), never on the request address;
  // the burst logic below works on the FIFO output (the address would otherwise reach the grant through the
  // consecutive-line compare and the whole interconnect, which missed 150 MHz by 2.3 ns)
  localparam int QD = 4;
  logic [LW-1:0] rq[QD];
  logic [$clog2(QD):0]   rq_n_q;
  logic [$clog2(QD)-1:0] rq_wp_q, rq_rp_q;
  logic          a_req, a_take;
  assign acc_gnt_o = rq_n_q < (($clog2(QD) + 1)'(QD));
  assign a_req = rq_n_q != 0;
  assign a_ln  = rq[rq_rp_q];
  assign full   = cnt_q == CW'(MAXB);
  // next line of the open burst: consecutive and still inside the same 4 KB (256 lines)
  assign consec = open_q && a_ln == base_ln_q + LW'(cnt_q) && !full && (base_ln_q[7:0] + 8'(cnt_q)) != 8'd0;
  assign a_take    = a_req && (!open_q || consec);  // a non-consecutive request waits until the burst is issued
  logic ar_busy_q;                                 // an AR is waiting for arready
  logic [$clog2(TD):0] tg_n_q;
  logic [31:0] infl_q;                             // lines requested, not yet returned
  logic        cpu_pend_q;                         // CPU read waiting to be issued
  logic [31:0] cpu_addr_q;
  logic        cpu_out_q;                          // CPU read issued/outstanding
  logic [1:0]  cpu_off_q;
  logic        ar_room;
  assign ar_room = !ar_busy_q && tg_n_q < (($clog2(TD) + 1)'(TD));
  logic want_acc;
  assign want_acc = open_q && (full || (a_req && !consec) || (idle_q >= 8'(WT) && !a_req)) && (infl_q + 32'(cnt_q) <= 32'(CRED));
  logic issue_cpu;
  assign issue_cpu = ar_room && cpu_pend_q;
  assign issue_acc = ar_room && !cpu_pend_q && want_acc;

  // ---------------------------------------------------------------- AR register + tag FIFO
  logic [31:0] ar_addr_q;
  logic [7:0]  ar_len_q;
  logic        tag_src[TD];
  logic [$clog2(TD)-1:0] tg_wp_q, tg_rp_q;
  assign m_araddr_o  = ar_addr_q;
  assign m_arlen_o   = ar_len_q;
  assign m_arvalid_o = ar_busy_q;

  // ---------------------------------------------------------------- response path
  logic head_src;
  assign head_src     = tag_src[tg_rp_q];            // 0 = accelerator, 1 = CPU
  assign m_rready_o   = 1'b1;
  assign acc_rvalid_o = m_rvalid_i && !head_src;
  assign acc_rdata_o  = m_rdata_i;
  assign cpu_rvalid_o = m_rvalid_i && head_src;
  assign cpu_rdata_o  = m_rdata_i[32*cpu_off_q +: 32];
  assign cpu_gnt_o    = !cpu_pend_q && !cpu_out_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      open_q <= 1'b0; base_ln_q <= '0; cnt_q <= '0; idle_q <= '0; ar_busy_q <= 1'b0;
      rq_n_q <= '0; rq_wp_q <= '0; rq_rp_q <= '0;
      ar_addr_q <= '0; ar_len_q <= '0; tg_wp_q <= '0; tg_rp_q <= '0; tg_n_q <= '0; infl_q <= '0;
      cpu_pend_q <= 1'b0; cpu_out_q <= 1'b0; cpu_addr_q <= '0; cpu_off_q <= '0;
      err_o <= 1'b0; n_bursts_o <= '0; n_lines_o <= '0;
    end else begin
      // request FIFO
      if (acc_req_i && acc_gnt_o) begin rq[rq_wp_q] <= acc_addr_i[31:4]; rq_wp_q <= rq_wp_q + 1'b1; end
      if (a_take) rq_rp_q <= rq_rp_q + 1'b1;
      rq_n_q <= rq_n_q + ((acc_req_i && acc_gnt_o) ? 1 : 0) - (a_take ? 1 : 0);
      // accelerator request taken from the FIFO
      if (a_take) begin
        if (!open_q) begin open_q <= 1'b1; base_ln_q <= a_ln; cnt_q <= CW'(1); end
        else cnt_q <= cnt_q + CW'(1);
        idle_q <= '0;
      end else if (open_q && idle_q != 8'hff) idle_q <= idle_q + 8'd1;
      // CPU read request
      if (cpu_req_i && cpu_gnt_o) begin cpu_pend_q <= 1'b1; cpu_addr_q <= cpu_addr_i; end
      // issue an AR
      if (issue_cpu) begin
        ar_addr_q <= base_i + {cpu_addr_q[31:4], 4'b0}; ar_len_q <= 8'd0; ar_busy_q <= 1'b1;
        tag_src[tg_wp_q] <= 1'b1; tg_wp_q <= tg_wp_q + 1'b1;
        cpu_pend_q <= 1'b0; cpu_out_q <= 1'b1; cpu_off_q <= cpu_addr_q[3:2];
      end else if (issue_acc) begin
        ar_addr_q <= base_i + {base_ln_q, 4'b0}; ar_len_q <= 8'(cnt_q - CW'(1)); ar_busy_q <= 1'b1;
        tag_src[tg_wp_q] <= 1'b0; tg_wp_q <= tg_wp_q + 1'b1;
        open_q <= 1'b0; cnt_q <= '0;
        n_bursts_o <= n_bursts_o + 32'd1; n_lines_o <= n_lines_o + 32'(cnt_q);
      end
      if (ar_busy_q && m_arready_i) ar_busy_q <= 1'b0;
      // R beats: outstanding bookkeeping
      if (m_rvalid_i) begin
        if (m_rresp_i != 2'b00) err_o <= 1'b1;
        if (m_rlast_i) tg_rp_q <= tg_rp_q + 1'b1;
        if (head_src && m_rlast_i) cpu_out_q <= 1'b0;
      end
      tg_n_q <= tg_n_q + ((issue_cpu || issue_acc) ? 1 : 0) - ((m_rvalid_i && m_rlast_i) ? 1 : 0);
      infl_q <= infl_q + ((issue_cpu) ? 32'd1 : issue_acc ? 32'(cnt_q) : 32'd0) - (m_rvalid_i ? 32'd1 : 32'd0);
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk_i) if (rst_ni && m_rvalid_i && tg_n_q == 0) $error("axi_ext_rd: unexpected R beat");
`endif
endmodule
