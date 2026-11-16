// S5 chip top: soc_top (CPU + gemv_acc + vfu) with its memories in RTL.
//   imem  : 0x0100_0000 .. +16 KB, 32-bit, 1-cycle read (BRAM), preloaded (sim: public array,
//           FPGA: IMEM_INIT hex file)
//   SRAM  : WEIGHTS_ONCHIP=1 (default): 0x0000_0000 .. 0x0020_0000 (2 MiB: weights, KV cache,
//           activations, control/stack); =0: 0x0010_0000 .. 0x0020_0000 (1 MiB, weights external).
//           sram_dp (URAM via XPM in synthesis), port A = CPU data, port B = accelerator master
//   external (ports below, same names/protocol as soc_top's, so sim.cpp drives them as before):
//     data_* : CPU data accesses outside the SRAM (DDR weights < 0x10_0000, sim MMIO 0x2000_0000)
//     acc_*  : accelerator reads below 0x10_0000 (DDR weights), 128-bit lines, in order
// Ordering: the CPU never has SRAM and external responses in flight together; accelerator
// responses are returned in request order (tag FIFO, fall-through data FIFOs), so with
// SRAM_RLAT = 1 and an ideal external memory the timing equals the soc_top simulation.
module soc_chip #(
    parameter int    ACC_LANES   = 4,
    parameter int    VFU_LANES   = 4,
    parameter int    ACC_RUN     = 8,
    parameter int    ACC_FDEPTH  = 256,
    parameter int    CPU_FPU_LAT = 4,
    parameter int    ACC_FPU_LAT = 4,
    parameter int    VFU_FPU_LAT = 4,
    parameter int    SRAM_RLAT   = 1,
    // 1 (default, Decision 11-14 "260K all on-chip"): weights in the on-chip SRAM too, SRAM =
    //   0x0000_0000 .. 0x0020_0000 (2 MiB); the external acc_* port is unused.
    // 0: weights outside (< 0x0010_0000) through the external acc_*/data_* ports (DDR), SRAM =
    //   0x0010_0000 .. 0x0020_0000 (1 MiB) - the S5a layout, kept for larger models.
    parameter bit    WEIGHTS_ONCHIP = 1'b1,
    parameter string IMEM_INIT   = ""
) (
    input logic clk_i,
    input logic rst_ni,
    input logic fetch_enable_i,

    // loader port (board: chip_axi_top's AXI-lite slave; sim: preloaded, tied 0). Used only while
    // the core is held in reset (rst_ni = 0): 32-bit word read/write of imem or the SRAM (the SRAM
    // shares the CPU's port A). Reads return ld_rdata_o with ld_rvalid_o (imem 1, SRAM RLAT cycles).
    input  logic        ld_req_i,
    input  logic        ld_we_i,
    input  logic [31:0] ld_addr_i,
    input  logic [31:0] ld_wdata_i,
    output logic [31:0] ld_rdata_o,
    output logic        ld_rvalid_o,

    output logic        data_req_o,
    input  logic        data_gnt_i,
    input  logic        data_rvalid_i,
    output logic        data_we_o,
    output logic [ 3:0] data_be_o,
    output logic [31:0] data_addr_o,
    output logic [31:0] data_wdata_o,
    input  logic [31:0] data_rdata_i,

    output logic         acc_req_o,
    output logic         acc_we_o,
    output logic [ 31:0] acc_addr_o,
    output logic [ 31:0] acc_wdata_o,
    input  logic         acc_gnt_i,
    input  logic         acc_rvalid_i,
    input  logic [127:0] acc_rdata_i,

    // observation only (simulator profiler / trap check; unconnected on the FPGA)
    output logic        dbg_instr_req_o,
    output logic [31:0] dbg_instr_addr_o,
    output logic        dbg_data_req_o,
    output logic        dbg_data_we_o,
    output logic [31:0] dbg_data_addr_o
);
  localparam logic [31:0] SRAM_BASE = WEIGHTS_ONCHIP ? 32'h0000_0000 : 32'h0010_0000;
  localparam int          SRAM_LINES = WEIGHTS_ONCHIP ? 131072 : 65536;
  localparam logic [31:0] SRAM_END = SRAM_BASE + 32'(SRAM_LINES) * 16;
  localparam int          SAW = $clog2(SRAM_LINES) + 4;          // SRAM byte address bits
  localparam logic [31:0] IMEM_BASE = 32'h0100_0000;
  // imem read port: CPU fetch, or the loader while the core is in reset
  logic        im_ren;
  logic [11:0] im_raddr;
  assign im_ren   = i_req || (ld_imem && !ld_we_i);
  assign im_raddr = i_req ? i_addr[13:2] : ld_addr_i[13:2];
  // loader decode (core in reset only)
  logic        ld_imem, ld_sram;
  logic [31:0] ld_off;
  assign ld_imem = !rst_ni && ld_req_i && (ld_addr_i & ~32'h3fff) == IMEM_BASE;
  assign ld_sram = !rst_ni && ld_req_i && ld_addr_i >= SRAM_BASE && ld_addr_i < SRAM_END;
  assign ld_off  = ld_addr_i - SRAM_BASE;
  localparam int IMEM_WORDS = 4096;

  // ---------------------------------------------------------------- core + accelerators
  logic        i_req, i_gnt, i_rvalid;
  logic [31:0] i_addr, i_rdata;
  logic        d_req, d_gnt, d_rvalid, d_we;
  logic [ 3:0] d_be;
  logic [31:0] d_addr, d_wdata, d_rdata;
  logic        a_req, a_gnt, a_rvalid, a_we;
  logic [31:0] a_addr, a_wdata;
  logic [127:0] a_rdata;

  soc_top #(.ACC_LANES(ACC_LANES), .VFU_LANES(VFU_LANES), .ACC_RUN(ACC_RUN), .ACC_FDEPTH(ACC_FDEPTH),
            .CPU_FPU_LAT(CPU_FPU_LAT), .ACC_FPU_LAT(ACC_FPU_LAT), .VFU_FPU_LAT(VFU_FPU_LAT)) soc_i (
      .clk_i, .rst_ni, .pulp_clock_en_i(1'b1),
      // clock gates forced open during reset (as sim.cpp drives soc_top): the FPU divider's
      // gated clock must see the reset, otherwise its first request is never granted
      .scan_cg_en_i(!rst_ni),
      .boot_addr_i(32'h0100_0080), .mtvec_addr_i(32'h0100_0000), .fetch_enable_i,
      .instr_req_o(i_req), .instr_gnt_i(i_gnt), .instr_rvalid_i(i_rvalid), .instr_addr_o(i_addr),
      .instr_rdata_i(i_rdata),
      .data_req_o(d_req), .data_gnt_i(d_gnt), .data_rvalid_i(d_rvalid), .data_we_o(d_we),
      .data_be_o(d_be), .data_addr_o(d_addr), .data_wdata_o(d_wdata), .data_rdata_i(d_rdata),
      .acc_req_o(a_req), .acc_we_o(a_we), .acc_addr_o(a_addr), .acc_wdata_o(a_wdata),
      .acc_gnt_i(a_gnt), .acc_rvalid_i(a_rvalid), .acc_rdata_i(a_rdata));

  assign dbg_instr_req_o = i_req; assign dbg_instr_addr_o = i_addr;
  assign dbg_data_req_o = d_req; assign dbg_data_we_o = d_we; assign dbg_data_addr_o = d_addr;

  // ---------------------------------------------------------------- instruction memory
  // BRAM, not URAM: the fetch address comes straight from the core's prefetcher, and URAM's
  // EN/ADDR setup missed 150 MHz by 1.58 ns (11-16 synthesis)
  (* ram_style = "block" *) logic [31:0] imem[IMEM_WORDS] /*verilator public_flat_rw*/;
  if (IMEM_INIT != "") begin : g_init
    initial $readmemh(IMEM_INIT, imem);
  end
  assign i_gnt = 1'b1;
  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) i_rvalid <= 1'b0; else i_rvalid <= i_req;
  always_ff @(posedge clk_i) begin
    if (ld_imem && ld_we_i) imem[ld_addr_i[13:2]] <= ld_wdata_i;
    if (im_ren) i_rdata <= imem[im_raddr];      // one read port (BRAM inference needs a single read)
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk_i) if (rst_ni && i_req && (i_addr & ~32'h3fff) != IMEM_BASE)
    $error("instruction fetch outside imem: %h", i_addr);
`endif

  // ---------------------------------------------------------------- SRAM
  logic        sa_en, sb_en;
  logic [31:0] sa_rdata;
  logic [127:0] sb_rdata;
  logic [31:0] d_off, a_off;
  assign d_off = d_addr - SRAM_BASE;
  assign a_off = a_addr - SRAM_BASE;
  sram_dp #(.LINES(SRAM_LINES), .RLAT(SRAM_RLAT)) sram_i (
      .clk_i,
      .a_en_i(sa_en || ld_sram), .a_we_i(ld_sram ? ld_we_i : d_we), .a_be_i(ld_sram ? 4'hf : d_be),
      .a_addr_i(ld_sram ? ld_off[SAW-1:0] : d_off[SAW-1:0]), .a_wdata_i(ld_sram ? ld_wdata_i : d_wdata),
      .a_rdata_o(sa_rdata),
      .b_en_i(sb_en), .b_we_i(a_we), .b_addr_i(a_off[SAW-1:0]), .b_wdata_i(a_wdata), .b_rdata_o(sb_rdata));

  // ---------------------------------------------------------------- CPU data port
  // responses in order: an SRAM request is granted only when no external response is
  // pending beyond this cycle, and vice versa
  logic        d_sram;
  logic [SRAM_RLAT-1:0] s_pipe_q;              // SRAM responses in flight (shift register)
  logic [1:0]  e_pend_q;                       // external responses pending
  logic        s_busy, e_busy;
  assign d_sram = d_addr >= SRAM_BASE && d_addr < SRAM_END;
  assign s_busy = |(s_pipe_q >> 1);            // SRAM responses due after this cycle
  assign e_busy = (e_pend_q - (data_rvalid_i ? 2'd1 : 2'd0)) != 0;
  assign sa_en  = d_req && d_sram && !e_busy;
  assign data_req_o   = d_req && !d_sram && !s_busy;
  assign data_we_o    = d_we; assign data_be_o = d_be; assign data_addr_o = d_addr; assign data_wdata_o = d_wdata;
  assign d_gnt    = d_sram ? !e_busy : (data_gnt_i && !s_busy);
  assign d_rvalid = s_pipe_q[0] || data_rvalid_i;
  assign d_rdata  = s_pipe_q[0] ? sa_rdata : data_rdata_i;
  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) begin s_pipe_q <= '0; e_pend_q <= '0; end
    else begin
      s_pipe_q <= SRAM_RLAT'({sa_en, s_pipe_q} >> 1);   // bit 0 = due this cycle
      e_pend_q <= e_pend_q + ((data_req_o && data_gnt_i) ? 2'd1 : 2'd0) - (data_rvalid_i ? 2'd1 : 2'd0);
    end

  // ---------------------------------------------------------------- accelerator port
  localparam int TQ = 256, SQ = 32, EQ = 64;
  logic        a_ext, a_go, t_full, s_room;
  assign a_ext  = !WEIGHTS_ONCHIP && a_addr < SRAM_BASE;   // below the SRAM: DDR
  // tag FIFO: one entry per granted read (1 = external)
  logic        tq[TQ];
  logic [$clog2(TQ)-1:0] tq_wp_q, tq_rp_q;
  logic [$clog2(TQ):0]   tq_n_q;
  // SRAM line FIFO (fall-through) and external line FIFO (fall-through)
  logic [127:0] sq[SQ], eq[EQ];
  logic [$clog2(SQ)-1:0] sq_wp_q, sq_rp_q;
  logic [$clog2(SQ):0]   sq_n_q, s_fly_n;
  logic [$clog2(EQ)-1:0] eq_wp_q, eq_rp_q;
  logic [$clog2(EQ):0]   eq_n_q;
  logic [SRAM_RLAT-1:0]  b_pipe_q;                        // SRAM line reads in flight
  logic        s_in, e_in, head_v, head_ext, pop_s, pop_e;
  logic [127:0] s_head, e_head;
  always_comb begin
    s_fly_n = '0;
    for (int i = 0; i < SRAM_RLAT; i++) s_fly_n = s_fly_n + b_pipe_q[i];
  end
  assign t_full = tq_n_q >= TQ - 1;
  assign s_room = sq_n_q + s_fly_n < SQ - 1;
  assign acc_req_o   = a_req && a_ext && !a_we && !t_full;
  assign acc_we_o    = 1'b0;
  assign acc_addr_o  = a_addr; assign acc_wdata_o = '0;
  assign sb_en = a_req && !a_ext && (a_we || (!t_full && s_room));
  assign a_gnt = a_ext ? (!a_we && !t_full && acc_gnt_i) : (a_we || (!t_full && s_room));
  assign a_go  = a_req && a_gnt && !a_we;                 // granted read -> one response
  assign s_in  = b_pipe_q[0];
  assign e_in  = acc_rvalid_i;
  assign head_v   = tq_n_q != 0;
  assign head_ext = tq[tq_rp_q];
  assign s_head   = (sq_n_q != 0) ? sq[sq_rp_q] : sb_rdata;
  assign e_head   = (eq_n_q != 0) ? eq[eq_rp_q] : acc_rdata_i;
  assign pop_s    = head_v && !head_ext && (sq_n_q != 0 || s_in);
  assign pop_e    = head_v &&  head_ext && (eq_n_q != 0 || e_in);
  assign a_rvalid = pop_s || pop_e;
  assign a_rdata  = pop_e ? e_head : s_head;
  always_ff @(posedge clk_i) begin
    if (a_go) tq[tq_wp_q] <= a_ext;
    if (s_in && !(pop_s && sq_n_q == 0)) sq[sq_wp_q] <= sb_rdata;
    if (e_in && !(pop_e && eq_n_q == 0)) eq[eq_wp_q] <= acc_rdata_i;
  end
  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) begin
      {tq_wp_q, tq_rp_q, tq_n_q, sq_wp_q, sq_rp_q, sq_n_q, eq_wp_q, eq_rp_q, eq_n_q} <= '0; b_pipe_q <= '0;
    end else begin
      b_pipe_q <= SRAM_RLAT'({sb_en && !a_we, b_pipe_q} >> 1);
      if (a_go) tq_wp_q <= tq_wp_q + 1;
      if (a_rvalid) tq_rp_q <= tq_rp_q + 1;
      tq_n_q <= tq_n_q + (a_go ? 1 : 0) - (a_rvalid ? 1 : 0);
      begin : sfifo
        logic push, pop;
        push = s_in && !(pop_s && sq_n_q == 0);           // not bypassed
        pop  = pop_s && sq_n_q != 0;
        if (push) sq_wp_q <= sq_wp_q + 1;
        if (pop)  sq_rp_q <= sq_rp_q + 1;
        sq_n_q <= sq_n_q + (push ? 1 : 0) - (pop ? 1 : 0);
      end
      begin : efifo
        logic push, pop;
        push = e_in && !(pop_e && eq_n_q == 0);
        pop  = pop_e && eq_n_q != 0;
        if (push) eq_wp_q <= eq_wp_q + 1;
        if (pop)  eq_rp_q <= eq_rp_q + 1;
        eq_n_q <= eq_n_q + (push ? 1 : 0) - (pop ? 1 : 0);
      end
    end
  // loader read response: imem after 1 cycle (i_rdata), SRAM after SRAM_RLAT cycles (port A)
  logic             ld_i_q;
  logic [SRAM_RLAT-1:0] ld_s_q;
  always_ff @(posedge clk_i) begin
    ld_i_q <= ld_imem && !ld_we_i;
    ld_s_q <= SRAM_RLAT'({ld_sram && !ld_we_i, ld_s_q} >> 1);
  end
  assign ld_rvalid_o = ld_i_q || ld_s_q[0];
  assign ld_rdata_o  = ld_i_q ? i_rdata : sa_rdata;
`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (rst_ni && a_req && a_we && a_ext) $error("accelerator write to DDR address %h", a_addr);
    if (rst_ni && eq_n_q >= EQ) $error("acc external line FIFO overflow");
  end
`endif
endmodule
