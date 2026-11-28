// FPGA replacement for bhv/cv32e40p_sim_clock_gate.sv (a latch-based behavioural model): a plain pass-through.
// The core's clock gate is only used when the core sleeps (wfi), which the firmware never does (no wfi in the images). A BUFGCE here gave
// the core a separate clock net 1.7 .. 2.3 ns later than the memories (clock skew on the critical path, E16) and is an FPGA-only primitive.
// In the ASIC this module becomes the library's integrated clock gate (ICG) and the clock tree synthesis balances it.
module cv32e40p_clock_gate (
    input  logic clk_i,
    input  logic en_i,
    input  logic scan_cg_en_i,
    output logic clk_o
);
  wire unused_ok = &{1'b0, en_i, scan_cg_en_i};
  assign clk_o = clk_i;
endmodule
