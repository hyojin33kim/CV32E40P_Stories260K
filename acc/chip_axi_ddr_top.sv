// Board top, weights in DDR (S5b, scope of the 15M step): soc_chip (WEIGHTS_ONCHIP = 0) + axi_ext_rd
// (read-only AXI4 master towards PS DDR through an HP port) + the same AXI4-Lite control slave as
// chip_axi_top. chip_axi_top (weights on chip, the 125 MHz bitstream) is not touched.
//
// CPU address map (S5a layout): weights 0x0000_0000 .. 0x000F_FFFF are in DDR at DDR_BASE + address;
// SRAM 1 MiB at 0x0010_0000 .. 0x001F_FFFF (KV, activations, control); imem 0x0100_0000.
// AXI4-Lite slave window (byte offsets, 32-bit data):
//   0x010_0000 .. 0x01F_FFFF  SRAM 1 MiB (same address as the CPU sees it)
//   0x100_0000 .. 0x100_3FFF  imem 16 KB
//   0x200_0000  CTRL     RW  bit0 RUN
//   0x200_0004  STATUS   R   bit0 DONE, bit1 DDR bus error (sticky)
//   0x200_0008  DONE_V   R
//   0x200_000C  CYCLES   R
//   0x200_0010  DDR_BASE RW  physical address of the weight image (4 KB aligned)
//   0x200_0014  N_BURSTS R   AXI read bursts issued by the accelerator path
//   0x200_0018  N_LINES  R   accelerator lines requested (16 B each)
//   0x200_0020 .. 0x200_0034  performance counters (R, cleared when RUN is set): gemv busy cycles, vfu busy cycles,
//       accelerator memory-grant stall cycles, accelerator read lines, tag-FIFO-full cycles, external line FIFO high-water mark
// The weights themselves are written to DDR by the PS (not through this slave).
module chip_axi_ddr_top #(
    parameter int ACC_LANES   = 4,
    parameter int VFU_LANES   = 4,
    parameter int ACC_RUN     = 8,
    parameter int ACC_FDEPTH  = 256,
    parameter int CPU_FPU_LAT = 4,
    parameter int ACC_FPU_LAT = 4,
    parameter int VFU_FPU_LAT = 4,
    parameter int SRAM_RLAT   = 1,
    parameter int SRAM_RLAT_B = 2,
    parameter int SRAM_CASCADE = 0,
    parameter bit SRAM_BREG    = 1'b1,
    parameter bit SRAM_AREG    = 1'b0,
    parameter int AXI_MAXB     = 16,
    parameter int AXI_WT       = 3,
    parameter int AXI_CRED     = 48
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    // AXI4-Lite slave
    input  logic [25:0] s_axi_awaddr,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,
    input  logic [31:0] s_axi_wdata,
    input  logic [ 3:0] s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,
    output logic [ 1:0] s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,
    input  logic [25:0] s_axi_araddr,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [ 1:0] s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,
    // AXI4 read master (128-bit) to DDR
    output logic [31:0] m_axi_araddr,
    output logic [ 7:0] m_axi_arlen,
    output logic [ 2:0] m_axi_arsize,
    output logic [ 1:0] m_axi_arburst,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,
    input  logic [127:0] m_axi_rdata,
    input  logic [ 1:0] m_axi_rresp,
    input  logic        m_axi_rlast,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready,
    output logic        done_o
);
  // ---------------------------------------------------------------- control registers
  logic        run_q, done_q;
  logic [31:0] done_v_q, cyc_q, ddr_base_q;
  logic        core_rst_n, ext_err;
  assign core_rst_n = rst_ni && run_q;
  assign done_o = done_q;

  logic        d_req, d_gnt, d_rvalid, d_we;
  logic [ 3:0] d_be;
  logic [31:0] d_addr, d_wdata, d_rdata;
  logic        a_req, a_we, a_gnt, a_rvalid;
  logic [31:0] a_addr, a_wdata;
  logic [127:0] a_rdata;
  logic        ld_req, ld_we, ld_rvalid;
  logic [31:0] pf_gemv, pf_vfu, pf_stall, pf_rd, pf_tq, pf_eq;
  logic [31:0] ld_addr, ld_wdata, ld_rdata;

  soc_chip #(.ACC_LANES(ACC_LANES), .VFU_LANES(VFU_LANES), .ACC_RUN(ACC_RUN), .ACC_FDEPTH(ACC_FDEPTH),
             .CPU_FPU_LAT(CPU_FPU_LAT), .ACC_FPU_LAT(ACC_FPU_LAT), .VFU_FPU_LAT(VFU_FPU_LAT),
             .SRAM_RLAT(SRAM_RLAT), .SRAM_RLAT_B(SRAM_RLAT_B), .SRAM_CASCADE(SRAM_CASCADE),
             .SRAM_BREG(SRAM_BREG), .SRAM_AREG(SRAM_AREG), .WEIGHTS_ONCHIP(1'b0)) chip_i (
      .clk_i, .rst_ni(core_rst_n), .fetch_enable_i(1'b1),
      .ld_req_i(ld_req), .ld_we_i(ld_we), .ld_addr_i(ld_addr), .ld_wdata_i(ld_wdata),
      .ld_rdata_o(ld_rdata), .ld_rvalid_o(ld_rvalid),
      .data_req_o(d_req), .data_gnt_i(d_gnt), .data_rvalid_i(d_rvalid), .data_we_o(d_we),
      .data_be_o(d_be), .data_addr_o(d_addr), .data_wdata_o(d_wdata), .data_rdata_i(d_rdata),
      .acc_req_o(a_req), .acc_we_o(a_we), .acc_addr_o(a_addr), .acc_wdata_o(a_wdata),
      .acc_gnt_i(a_gnt), .acc_rvalid_i(a_rvalid), .acc_rdata_i(a_rdata),
      .dbg_instr_req_o(), .dbg_instr_addr_o(), .dbg_data_req_o(), .dbg_data_we_o(), .dbg_data_addr_o(),
      .perf_gemv_busy_o(pf_gemv), .perf_vfu_busy_o(pf_vfu), .perf_acc_stall_o(pf_stall), .perf_acc_rd_o(pf_rd),
      .perf_tq_full_o(pf_tq), .perf_eq_max_o(pf_eq));

  // ---------------------------------------------------------------- DDR read master
  logic        c_gnt, c_rvalid, ax_err;
  logic [31:0] c_rdata, n_bursts, n_lines;
  logic        ext_w, ext_rd, mm_rv_q, ext_out_q;
  assign ext_w  = d_addr < 32'h0010_0000;                 // weight region (DDR)
  assign ext_rd = d_req && ext_w && !d_we && !mm_rv_q;    // CPU read of DDR (no MMIO response pending)
  axi_ext_rd #(.MAXB(AXI_MAXB), .WT(AXI_WT), .CRED(AXI_CRED)) axi_i (
      .clk_i, .rst_ni(core_rst_n), .base_i(ddr_base_q),
      .acc_req_i(a_req), .acc_addr_i(a_addr), .acc_gnt_o(a_gnt), .acc_rvalid_o(a_rvalid), .acc_rdata_o(a_rdata),
      .cpu_req_i(ext_rd), .cpu_addr_i(d_addr), .cpu_gnt_o(c_gnt), .cpu_rvalid_o(c_rvalid), .cpu_rdata_o(c_rdata),
      .m_araddr_o(m_axi_araddr), .m_arlen_o(m_axi_arlen), .m_arvalid_o(m_axi_arvalid), .m_arready_i(m_axi_arready),
      .m_rdata_i(m_axi_rdata), .m_rresp_i(m_axi_rresp), .m_rlast_i(m_axi_rlast), .m_rvalid_i(m_axi_rvalid),
      .m_rready_o(m_axi_rready), .err_o(ax_err), .n_bursts_o(n_bursts), .n_lines_o(n_lines));
  assign m_axi_arsize  = 3'd4;       // 16 bytes
  assign m_axi_arburst = 2'b01;      // INCR

  // CPU data port: DDR reads go to the master; everything else (the DONE write, sim MMIO) is answered
  // next cycle. Responses stay in order: MMIO only while no DDR read is outstanding and vice versa.
  logic mm_req;
  assign mm_req = d_req && !ext_w && !ext_out_q;
  assign d_gnt  = ext_w ? (!d_we ? (c_gnt && !mm_rv_q) : 1'b1) : !ext_out_q;
  assign d_rvalid = c_rvalid || mm_rv_q;
  assign d_rdata  = c_rvalid ? c_rdata : 32'h0;
  always_ff @(posedge clk_i or negedge core_rst_n)
    if (!core_rst_n) begin mm_rv_q <= 1'b0; ext_out_q <= 1'b0; end
    else begin
      mm_rv_q <= (mm_req && d_gnt) || (d_req && ext_w && d_we && d_gnt);   // a write to the weight region is dropped
      if (ext_rd && c_gnt) ext_out_q <= 1'b1;
      else if (c_rvalid) ext_out_q <= 1'b0;
    end
  assign ext_err = ax_err;

  // ---------------------------------------------------------------- AXI4-Lite slave
  typedef enum logic [2:0] {S_IDLE, S_WR, S_B, S_RD, S_RWAIT, S_R} st_e;
  st_e st_q;
  logic [25:0] addr_q;
  logic [31:0] wdata_q, rdata_q;
  logic        is_mem, is_ctrl;
  assign is_mem  = (addr_q >= 26'h010_0000 && addr_q < 26'h020_0000) || (addr_q >= 26'h100_0000 && addr_q < 26'h100_4000);
  assign is_ctrl = addr_q[25:6] == 20'(26'h200_0000 >> 6);

  assign s_axi_awready = st_q == S_IDLE && s_axi_awvalid && s_axi_wvalid;
  assign s_axi_wready  = s_axi_awready;
  assign s_axi_arready = st_q == S_IDLE && !(s_axi_awvalid && s_axi_wvalid) && s_axi_arvalid;
  assign s_axi_bvalid  = st_q == S_B;
  assign s_axi_bresp   = 2'b00;
  assign s_axi_rvalid  = st_q == S_R;
  assign s_axi_rresp   = 2'b00;
  assign s_axi_rdata   = rdata_q;

  assign ld_req   = !run_q && is_mem && (st_q == S_WR || st_q == S_RD);
  assign ld_we    = st_q == S_WR;
  assign ld_addr  = addr_q < 26'h020_0000 ? 32'(addr_q) : 32'h0100_0000 + 32'(addr_q[13:0]);
  assign ld_wdata = wdata_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q <= S_IDLE; addr_q <= '0; wdata_q <= '0; rdata_q <= '0;
      run_q <= 1'b0; done_q <= 1'b0; done_v_q <= '0; cyc_q <= '0; ddr_base_q <= '0;
    end else begin
      if (run_q && !done_q) cyc_q <= cyc_q + 1;
      if (run_q && d_req && d_we && d_addr == 32'h2000_0000) begin done_q <= 1'b1; done_v_q <= d_wdata; end
      unique case (st_q)
        S_IDLE:
          if (s_axi_awready) begin addr_q <= s_axi_awaddr; wdata_q <= s_axi_wdata; st_q <= S_WR; end
          else if (s_axi_arready) begin addr_q <= s_axi_araddr; st_q <= S_RD; end
        S_WR: begin
          if (is_ctrl && addr_q[5:2] == 4'd0) begin
            if (wdata_q[0] && !run_q) begin done_q <= 1'b0; cyc_q <= '0; end
            run_q <= wdata_q[0];
          end
          if (is_ctrl && addr_q[5:2] == 4'd4) ddr_base_q <= wdata_q;
          st_q <= S_B;
        end
        S_B: if (s_axi_bready) st_q <= S_IDLE;
        S_RD:
          if (is_mem && !run_q) st_q <= S_RWAIT;
          else begin
            rdata_q <= '0;
            if (is_ctrl) unique case (addr_q[5:2])
              4'd0: rdata_q <= {31'b0, run_q};
              4'd1: rdata_q <= {30'b0, ext_err, done_q};
              4'd2: rdata_q <= done_v_q;
              4'd3: rdata_q <= cyc_q;
              4'd4: rdata_q <= ddr_base_q;
              4'd5: rdata_q <= n_bursts;
              4'd6: rdata_q <= n_lines;
              4'd8: rdata_q <= pf_gemv;
              4'd9: rdata_q <= pf_vfu;
              4'd10: rdata_q <= pf_stall;
              4'd11: rdata_q <= pf_rd;
              4'd12: rdata_q <= pf_tq;
              4'd13: rdata_q <= pf_eq;
              default: rdata_q <= '0;
            endcase
            st_q <= S_R;
          end
        S_RWAIT: if (ld_rvalid) begin rdata_q <= ld_rdata; st_q <= S_R; end
        S_R: if (s_axi_rready) st_q <= S_IDLE;
        default: st_q <= S_IDLE;
      endcase
    end
  end
endmodule
