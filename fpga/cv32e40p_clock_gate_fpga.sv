// FPGA replacement for bhv/cv32e40p_sim_clock_gate.sv (a latch-based behavioural model):
// the same enable function on an UltraScale+ global clock buffer with clock enable.
module cv32e40p_clock_gate (
    input  logic clk_i,
    input  logic en_i,
    input  logic scan_cg_en_i,
    output logic clk_o
);
  BUFGCE #(.CE_TYPE("SYNC")) bufgce_i (.O(clk_o), .CE(en_i | scan_cg_en_i), .I(clk_i));
endmodule
