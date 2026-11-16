// On-chip SRAM (S5): LINES x 128-bit, true dual port, byte write enables, registered read
// (RLAT = 1 or 2 cycles). Port A: CPU (32-bit word of the line, byte enables). Port B:
// accelerators (128-bit line read, 32-bit word write). Both ports are always ready; the
// SoC never writes one address from both ports in the same cycle. Write mode NO_CHANGE: a write
// cycle does not update the read output (nobody uses read data of a write: CPU stores ignore it,
// the accelerator port has no write response).
// Synthesis (`SYNTHESIS, Vivado): xpm_memory_tdpram with MEMORY_PRIMITIVE "ultra" (URAM; plain
// RTL inference fell back to BRAM, see fpga/P6_FPGA_SYNTH.md). Simulation: the behavioural
// array below, public for the simulator's preload / dump. Both have the same port behaviour.
module sram_dp #(
    parameter int LINES = 131072,     // 2 MiB
    parameter int RLAT  = 1,
    parameter int CASCADE = 0         // XPM CASCADE_HEIGHT (0 = Vivado's choice; synthesis only)
) (
    input  logic                     clk_i,
    // port A (CPU)
    input  logic                     a_en_i,
    input  logic                     a_we_i,
    input  logic [3:0]               a_be_i,
    input  logic [$clog2(LINES)+3:0] a_addr_i,    // byte address within the SRAM
    input  logic [31:0]              a_wdata_i,
    output logic [31:0]              a_rdata_o,
    // port B (accelerators)
    input  logic                     b_en_i,
    input  logic                     b_we_i,
    input  logic [$clog2(LINES)+3:0] b_addr_i,
    input  logic [31:0]              b_wdata_i,
    output logic [127:0]             b_rdata_o
);
  localparam int LW = $clog2(LINES);

  logic [LW-1:0] a_line, b_line;
  logic [1:0]    a_w, b_w;
  logic [15:0]   a_bwe, b_bwe;
  assign a_line = a_addr_i[LW+3:4]; assign a_w = a_addr_i[3:2];
  assign b_line = b_addr_i[LW+3:4]; assign b_w = b_addr_i[3:2];
  assign a_bwe = (a_en_i && a_we_i) ? (16'(a_be_i) << (4 * a_w)) : '0;
  assign b_bwe = (b_en_i && b_we_i) ? (16'hf << (4 * b_w)) : '0;

  logic [127:0] a_line_q, b_line_q;          // line read, RLAT cycles after the request
  logic [1:0]   a_w_p[RLAT];                 // word select, delayed with the read

  always_ff @(posedge clk_i) begin
    if (a_en_i && !a_we_i) a_w_p[0] <= a_w;
    for (int i = 1; i < RLAT; i++) a_w_p[i] <= a_w_p[i-1];
  end
  assign a_rdata_o = a_line_q[32*a_w_p[RLAT-1] +: 32];
  assign b_rdata_o = b_line_q;

`ifdef SYNTHESIS
  xpm_memory_tdpram #(
      .ADDR_WIDTH_A(LW), .ADDR_WIDTH_B(LW), .CASCADE_HEIGHT(CASCADE),
      .BYTE_WRITE_WIDTH_A(8), .BYTE_WRITE_WIDTH_B(8),
      .CLOCKING_MODE("common_clock"),
      .ECC_MODE("no_ecc"),
      .MEMORY_INIT_FILE("none"), .USE_MEM_INIT(0),
      .MEMORY_OPTIMIZATION("true"),
      .MEMORY_PRIMITIVE("ultra"),
      .MEMORY_SIZE(LINES * 128),
      .READ_DATA_WIDTH_A(128), .READ_DATA_WIDTH_B(128),
      .WRITE_DATA_WIDTH_A(128), .WRITE_DATA_WIDTH_B(128),
      .READ_LATENCY_A(RLAT), .READ_LATENCY_B(RLAT),
      .READ_RESET_VALUE_A("0"), .READ_RESET_VALUE_B("0"),
      .WRITE_MODE_A("no_change"), .WRITE_MODE_B("no_change")
  ) xpm_i (
      .clka(clk_i), .clkb(clk_i), .rsta(1'b0), .rstb(1'b0), .sleep(1'b0),
      .ena(a_en_i), .regcea(1'b1), .wea(a_bwe), .addra(a_line), .dina({4{a_wdata_i}}), .douta(a_line_q),
      .enb(b_en_i), .regceb(1'b1), .web(b_bwe), .addrb(b_line), .dinb({4{b_wdata_i}}), .doutb(b_line_q),
      .injectsbiterra(1'b0), .injectdbiterra(1'b0), .injectsbiterrb(1'b0), .injectdbiterrb(1'b0),
      .sbiterra(), .dbiterra(), .sbiterrb(), .dbiterrb());
`else
  logic [127:0] mem[LINES] /*verilator public_flat_rw*/;
  logic [127:0] a_q[RLAT], b_q[RLAT];
  always_ff @(posedge clk_i) begin
    if (a_en_i) begin
      if (a_we_i) begin
        for (int i = 0; i < 16; i++) if (a_bwe[i]) mem[a_line][8*i +: 8] <= a_wdata_i[8*(i%4) +: 8];
      end else a_q[0] <= mem[a_line];
    end
    if (b_en_i) begin
      if (b_we_i) begin
        for (int i = 0; i < 16; i++) if (b_bwe[i]) mem[b_line][8*i +: 8] <= b_wdata_i[8*(i%4) +: 8];
      end else b_q[0] <= mem[b_line];
    end
    for (int i = 1; i < RLAT; i++) begin a_q[i] <= a_q[i-1]; b_q[i] <= b_q[i-1]; end
  end
  assign a_line_q = a_q[RLAT-1];
  assign b_line_q = b_q[RLAT-1];
`endif
endmodule
