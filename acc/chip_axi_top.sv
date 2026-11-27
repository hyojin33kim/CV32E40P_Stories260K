// Board top (S5, 260K, weights on chip): soc_chip + an AXI4-Lite slave for the PS (Zynq US+
// M_AXI_HPM0_LPD / FPD). The PS loads the weights, firmware and data, starts the core, waits for
// DONE and reads the results back. No DDR access from the PL (Decision 11-14: 260K all on-chip).
//
// AXI4-Lite address map (byte offsets in the slave window, 32-bit data, one transaction at a time):
//   0x000_0000 .. 0x01F_FFFF  SRAM 2 MiB (weights, KV, activations, .rodata/.data, results)
//   0x100_0000 .. 0x100_3FFF  imem 16 KB (firmware .text)
//   0x200_0000  CTRL    RW  bit0 RUN: 0 = core held in reset (memories accessible), 1 = run
//   0x200_0004  STATUS  R   bit0 DONE (the firmware wrote 0x2000_0000; cleared by RUN 0 -> 1)
//   0x200_0008  DONE_V  R   value the firmware wrote to 0x2000_0000
//   0x200_000C  CYCLES  R   clock cycles since RUN was set (stops at DONE)
//   0x200_0040  OUT       R   last word the firmware wrote to 0x2000_0010 (an output channel: checkpoints, values; no UART needed)
//   0x200_0044  OUT_CNT   R   number of writes to 0x2000_0010 since RUN
//   0x200_0048  LAST_PC   R   address of the last instruction fetch request (where a stuck or looping core is)
//   0x200_004C  FETCH_CNT R   instruction fetch requests since RUN (two reads that differ: the core is fetching)
//   0x200_0050  TRAP_CNT  R   times the fetch address entered the trap vector region 0x0100_0000 .. 0x0100_007F (mtvec; the firmware starts at 0x0100_0080), i.e. exceptions taken
//   0x200_0054  TRAP_PC   R   the fetch address just before the first trap vector entry (approximate: the prefetcher runs ahead of the instruction that trapped)
//   (0x200_0040 .. 0x200_0054 are cleared when RUN is set, like the counters below)
//   0x200_0020 .. 0x200_0034  performance counters (R, cleared when RUN is set): gemv busy cycles, vfu busy cycles,
//       accelerator memory-grant stall cycles, accelerator read lines, tag-FIFO-full cycles, external line FIFO high-water mark
// Memory windows are accessible only while RUN = 0 (writes ignored, reads return 0 otherwise).
// The core's other external accesses (sim MMIO 0x2000_0004 step log, anything outside the SRAM)
// are answered immediately (reads return 0).
module chip_axi_top #(
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
    parameter bit DBG_PROBE    = 1'b0   // 1: mark the CPU bus, accelerator port and run/done as mark_debug nets for a Vivado ILA (docs/BOARD_ILA.md); 0: no change at all
) (
    input  logic        clk_i,
    input  logic        rst_ni,          // system reset (PS PL reset)
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
    output logic        done_o           // level, e.g. to a PS interrupt
);
  // ---------------------------------------------------------------- control registers
  logic        run_q, done_q;
  logic [31:0] done_v_q, cyc_q;
  logic        core_rst_n;
  logic        ndmreset;                 // reset request of the Debug Module (DM_BUILD), 0 otherwise
  assign core_rst_n = rst_ni && run_q && !ndmreset;
  assign done_o = done_q;

  // ---------------------------------------------------------------- chip
  logic        d_req, d_gnt, d_rvalid, d_we;
  logic [ 3:0] d_be;
  logic [31:0] d_addr, d_wdata;
  logic        a_req, a_we, a_gnt, a_rvalid;
  logic [31:0] a_addr, a_wdata;
  logic        ld_req, ld_we, ld_rvalid;
  logic [31:0] pf_gemv, pf_vfu, pf_stall, pf_rd, pf_tq, pf_eq;
  logic        dbg_ireq, dbg_dreq, dbg_dwe;           // chip observation outputs (CPU instruction fetch and data port)
  logic [31:0] dbg_iaddr, dbg_daddr;
  logic [31:0] ld_addr, ld_wdata, ld_rdata;

`ifdef DM_BUILD
  // RISC-V debug (docs/DEBUG_MODULE.md): soc_chip_dm = soc_chip + Debug Module + JTAG. The Debug Module stays on the system reset (rst_ni) while
  // the core is held in reset until RUN. With dmi_bscane_tap.sv the JTAG pins are unused (the BSCANE2 primitives of the FPGA JTAG chain serve it).
  logic dbg_halted;
  soc_chip_dm #(.ACC_LANES(ACC_LANES), .VFU_LANES(VFU_LANES), .ACC_RUN(ACC_RUN), .ACC_FDEPTH(ACC_FDEPTH),
             .CPU_FPU_LAT(CPU_FPU_LAT), .ACC_FPU_LAT(ACC_FPU_LAT), .VFU_FPU_LAT(VFU_FPU_LAT),
             .SRAM_RLAT(SRAM_RLAT), .SRAM_RLAT_B(SRAM_RLAT_B), .SRAM_CASCADE(SRAM_CASCADE), .SRAM_BREG(SRAM_BREG), .SRAM_AREG(SRAM_AREG), .WEIGHTS_ONCHIP(1'b1)) chip_i (
      .clk_i, .rst_ni(core_rst_n), .dm_rst_ni(rst_ni), .fetch_enable_i(1'b1),
      .ld_req_i(ld_req), .ld_we_i(ld_we), .ld_addr_i(ld_addr), .ld_wdata_i(ld_wdata),
      .ld_rdata_o(ld_rdata), .ld_rvalid_o(ld_rvalid),
      .data_req_o(d_req), .data_gnt_i(d_gnt), .data_rvalid_i(d_rvalid), .data_we_o(d_we),
      .data_be_o(d_be), .data_addr_o(d_addr), .data_wdata_o(d_wdata), .data_rdata_i(32'h0),
      .acc_req_o(a_req), .acc_we_o(a_we), .acc_addr_o(a_addr), .acc_wdata_o(a_wdata),
      .acc_gnt_i(1'b1), .acc_rvalid_i(1'b0), .acc_rdata_i('0),
      .dbg_instr_req_o(dbg_ireq), .dbg_instr_addr_o(dbg_iaddr), .dbg_data_req_o(dbg_dreq), .dbg_data_we_o(dbg_dwe), .dbg_data_addr_o(dbg_daddr),
      .perf_gemv_busy_o(pf_gemv), .perf_vfu_busy_o(pf_vfu), .perf_acc_stall_o(pf_stall), .perf_acc_rd_o(pf_rd),
      .perf_tq_full_o(pf_tq), .perf_eq_max_o(pf_eq),
      .jtag_tck_i(1'b0), .jtag_tms_i(1'b0), .jtag_trst_ni(1'b1), .jtag_tdi_i(1'b0), .jtag_tdo_o(),
      .ndmreset_o(ndmreset), .debug_halted_o(dbg_halted));
`else
  assign ndmreset = 1'b0;
  soc_chip #(.ACC_LANES(ACC_LANES), .VFU_LANES(VFU_LANES), .ACC_RUN(ACC_RUN), .ACC_FDEPTH(ACC_FDEPTH),
             .CPU_FPU_LAT(CPU_FPU_LAT), .ACC_FPU_LAT(ACC_FPU_LAT), .VFU_FPU_LAT(VFU_FPU_LAT),
             .SRAM_RLAT(SRAM_RLAT), .SRAM_RLAT_B(SRAM_RLAT_B), .SRAM_CASCADE(SRAM_CASCADE), .SRAM_BREG(SRAM_BREG), .SRAM_AREG(SRAM_AREG), .WEIGHTS_ONCHIP(1'b1)) chip_i (
      .clk_i, .rst_ni(core_rst_n), .fetch_enable_i(1'b1),
      .ld_req_i(ld_req), .ld_we_i(ld_we), .ld_addr_i(ld_addr), .ld_wdata_i(ld_wdata),
      .ld_rdata_o(ld_rdata), .ld_rvalid_o(ld_rvalid),
      .data_req_o(d_req), .data_gnt_i(d_gnt), .data_rvalid_i(d_rvalid), .data_we_o(d_we),
      .data_be_o(d_be), .data_addr_o(d_addr), .data_wdata_o(d_wdata), .data_rdata_i(32'h0),
      .acc_req_o(a_req), .acc_we_o(a_we), .acc_addr_o(a_addr), .acc_wdata_o(a_wdata),
      .acc_gnt_i(1'b1), .acc_rvalid_i(1'b0), .acc_rdata_i('0),
      .dbg_instr_req_o(dbg_ireq), .dbg_instr_addr_o(dbg_iaddr), .dbg_data_req_o(dbg_dreq), .dbg_data_we_o(dbg_dwe), .dbg_data_addr_o(dbg_daddr),
      .perf_gemv_busy_o(pf_gemv), .perf_vfu_busy_o(pf_vfu), .perf_acc_stall_o(pf_stall), .perf_acc_rd_o(pf_rd),
      .perf_tq_full_o(pf_tq), .perf_eq_max_o(pf_eq),
      .dm_debug_req_i(1'b0), .dm_slave_req_o(), .dm_slave_we_o(), .dm_slave_addr_o(), .dm_slave_be_o(), .dm_slave_wdata_o(),
      .dm_slave_rdata_i('0), .debug_halted_o());
`endif

  // ---------------------------------------------------------------- firmware-visible output and core observation registers (0x200_0040 ..)
  // The core's instruction fetch and data addresses are critical paths: they only go into plain registers here (no logic), the decisions are made one cycle later.
  logic        if_v_q, dw_v_q;
  logic [31:0] if_a_q, dw_a_q, dw_d_q;
  logic [31:0] out_q, out_cnt_q, last_pc_q, fetch_cnt_q, trap_cnt_q, trap_pc_q;
  logic        was_vec_q;
  logic        in_vec;
  assign in_vec = if_a_q[31:7] == 25'(32'h0100_0000 >> 7);                  // trap vector region (mtvec = 0x0100_0000, the firmware starts at 0x0100_0080)
  always_ff @(posedge clk_i or negedge core_rst_n)
    if (!core_rst_n) begin
      if_v_q <= 1'b0; dw_v_q <= 1'b0; if_a_q <= '0; dw_a_q <= '0; dw_d_q <= '0;
      out_q <= '0; out_cnt_q <= '0; last_pc_q <= '0; fetch_cnt_q <= '0; trap_cnt_q <= '0; trap_pc_q <= '0; was_vec_q <= 1'b0;
    end else begin
      if_v_q <= dbg_ireq; if_a_q <= dbg_iaddr;
      dw_v_q <= d_req && d_we; dw_a_q <= d_addr; dw_d_q <= d_wdata;
      if (dw_v_q && dw_a_q == 32'h2000_0010) begin out_q <= dw_d_q; out_cnt_q <= out_cnt_q + 32'd1; end
      if (if_v_q) begin
        last_pc_q <= if_a_q; fetch_cnt_q <= fetch_cnt_q + 32'd1; was_vec_q <= in_vec;
        if (in_vec && !was_vec_q) begin
          if (trap_cnt_q == 32'd0) trap_pc_q <= last_pc_q;
          trap_cnt_q <= trap_cnt_q + 32'd1;
        end
      end
    end

  // external CPU accesses: answered next cycle; a write to 0x2000_0000 is DONE
  assign d_gnt = 1'b1;
  always_ff @(posedge clk_i or negedge core_rst_n)
    if (!core_rst_n) d_rvalid <= 1'b0; else d_rvalid <= d_req;

  // ---------------------------------------------------------------- AXI4-Lite slave
  typedef enum logic [2:0] {S_IDLE, S_WR, S_B, S_RD, S_RWAIT, S_R} st_e;
  st_e st_q;
  logic [25:0] addr_q;
  logic [31:0] wdata_q, rdata_q;
  logic        is_mem, is_ctrl;
  assign is_mem  = addr_q < 26'h020_0000 || (addr_q >= 26'h100_0000 && addr_q < 26'h100_4000);
  assign is_ctrl = addr_q[25:7] == 19'(26'h200_0000 >> 7);                  // 128-byte register window

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
      run_q <= 1'b0; done_q <= 1'b0; done_v_q <= '0; cyc_q <= '0;
    end else begin
      // core side
      if (run_q && !done_q) cyc_q <= cyc_q + 1;
      if (run_q && d_req && d_we && d_addr == 32'h2000_0000) begin done_q <= 1'b1; done_v_q <= d_wdata; end
      // bus side
      unique case (st_q)
        S_IDLE:
          if (s_axi_awready) begin addr_q <= s_axi_awaddr; wdata_q <= s_axi_wdata; st_q <= S_WR; end
          else if (s_axi_arready) begin addr_q <= s_axi_araddr; st_q <= S_RD; end
        S_WR: begin
          if (is_ctrl && addr_q[6:2] == 5'h0) begin
            if (wdata_q[0] && !run_q) begin done_q <= 1'b0; cyc_q <= '0; end
            run_q <= wdata_q[0];
          end
          st_q <= S_B;
        end
        S_B: if (s_axi_bready) st_q <= S_IDLE;
        S_RD:
          if (is_mem && !run_q) st_q <= S_RWAIT;
          else begin
            rdata_q <= '0;
            if (is_ctrl) unique case (addr_q[6:2])
              5'd0: rdata_q <= {31'b0, run_q};
              5'd1: rdata_q <= {31'b0, done_q};
              5'd2: rdata_q <= done_v_q;
              5'd3: rdata_q <= cyc_q;
              5'd8: rdata_q <= pf_gemv;
              5'd9: rdata_q <= pf_vfu;
              5'd10: rdata_q <= pf_stall;
              5'd11: rdata_q <= pf_rd;
              5'd12: rdata_q <= pf_tq;
              5'd13: rdata_q <= pf_eq;
              5'd16: rdata_q <= out_q;
              5'd17: rdata_q <= out_cnt_q;
              5'd18: rdata_q <= last_pc_q;
              5'd19: rdata_q <= fetch_cnt_q;
              5'd20: rdata_q <= trap_cnt_q;
              5'd21: rdata_q <= trap_pc_q;
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
