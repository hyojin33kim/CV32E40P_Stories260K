// On-chip SRAM (S5): LINES x 128-bit, true dual port, byte write enables, registered read
// (RLAT = 1 or 2 cycles). Port A: CPU (32-bit word of the line, byte enables). Port B:
// accelerators (128-bit line read, 32-bit word write). Both ports are always ready; the
// SoC never writes one address from both ports in the same cycle. Write mode NO_CHANGE: a write cycle
// does not update the read output (nobody uses read data of a write: CPU stores ignore it, the
// accelerator port has no write response).
// FPGA: inferred as URAM (ram_style "ultra"; Vivado accepts only a literal there); the array is public for the simulator
// (preload / dump), which does not change the hardware.
module sram_dp #(
    parameter int    LINES     = 65536,      // 1 MB
    parameter int    RLAT      = 1
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
  (* ram_style = "ultra" *) logic [127:0] mem[LINES] /*verilator public_flat_rw*/;

  logic [LW-1:0] a_line, b_line;
  logic [1:0]    a_w, b_w;
  logic [15:0]   a_bwe, b_bwe;
  assign a_line = a_addr_i[LW+3:4]; assign a_w = a_addr_i[3:2];
  assign b_line = b_addr_i[LW+3:4]; assign b_w = b_addr_i[3:2];
  assign a_bwe = (a_en_i && a_we_i) ? (16'(a_be_i) << (4 * a_w)) : '0;
  assign b_bwe = (b_en_i && b_we_i) ? (16'hf << (4 * b_w)) : '0;

  logic [127:0] a_q, b_q;
  logic [1:0]   a_w_q;
  always_ff @(posedge clk_i) begin
    if (a_en_i) begin   // NO_CHANGE write mode (required for URAM): read only when not writing
      if (a_we_i) begin
        for (int i = 0; i < 16; i++) if (a_bwe[i]) mem[a_line][8*i +: 8] <= a_wdata_i[8*(i%4) +: 8];
      end else begin
        a_q <= mem[a_line];
        a_w_q <= a_w;
      end
    end
  end
  always_ff @(posedge clk_i) begin
    if (b_en_i) begin
      if (b_we_i) begin
        for (int i = 0; i < 16; i++) if (b_bwe[i]) mem[b_line][8*i +: 8] <= b_wdata_i[8*(i%4) +: 8];
      end else b_q <= mem[b_line];
    end
  end
  if (RLAT == 1) begin : g_l1
    assign a_rdata_o = a_q[32*a_w_q +: 32];
    assign b_rdata_o = b_q;
  end else begin : g_l2
    logic [31:0] a_q2; logic [127:0] b_q2;
    always_ff @(posedge clk_i) begin a_q2 <= a_q[32*a_w_q +: 32]; b_q2 <= b_q; end
    assign a_rdata_o = a_q2;
    assign b_rdata_o = b_q2;
  end
endmodule
