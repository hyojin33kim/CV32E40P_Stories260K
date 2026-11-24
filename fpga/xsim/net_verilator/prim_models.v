// Behavioural models of the five UNISIM primitives that Verilator cannot read (their vendor models use the Verilog-1995 assign/deassign
// to load INIT through the global set/reset pulse). Same ports and parameters as the vendor models, same behaviour without timing and X
// handling: INIT is the power-up value, the clock edge selected by IS_C_INVERTED, synchronous reset/set (FDRE, FDSE) takes priority over CE,
// asynchronous clear/preset (FDCE, FDPE) takes priority over everything. docs/XSIM_VS_VERILATOR.md explains why they are trusted:
// the same synthesized FPU netlist gives the identical 3,896/3,896 result with these models in Verilator and with the vendor models in xsim.
`timescale 1ps/1ps
module FDRE #(parameter [0:0] INIT = 1'b0, parameter [0:0] IS_C_INVERTED = 1'b0, parameter [0:0] IS_D_INVERTED = 1'b0, parameter [0:0] IS_R_INVERTED = 1'b0)
    (output Q, input C, input CE, input D, input R);
  reg q = INIT;
  assign Q = q;
  wire c = C ^ IS_C_INVERTED, d = D ^ IS_D_INVERTED, r = R ^ IS_R_INVERTED;
  always @(posedge c) if (r) q <= 1'b0; else if (CE) q <= d;
endmodule

module FDSE #(parameter [0:0] INIT = 1'b1, parameter [0:0] IS_C_INVERTED = 1'b0, parameter [0:0] IS_D_INVERTED = 1'b0, parameter [0:0] IS_S_INVERTED = 1'b0)
    (output Q, input C, input CE, input D, input S);
  reg q = INIT;
  assign Q = q;
  wire c = C ^ IS_C_INVERTED, d = D ^ IS_D_INVERTED, s = S ^ IS_S_INVERTED;
  always @(posedge c) if (s) q <= 1'b1; else if (CE) q <= d;
endmodule

module FDCE #(parameter [0:0] INIT = 1'b0, parameter [0:0] IS_CLR_INVERTED = 1'b0, parameter [0:0] IS_C_INVERTED = 1'b0, parameter [0:0] IS_D_INVERTED = 1'b0)
    (output Q, input C, input CE, input CLR, input D);
  reg q = INIT;
  assign Q = q;
  wire c = C ^ IS_C_INVERTED, d = D ^ IS_D_INVERTED, clr = CLR ^ IS_CLR_INVERTED;
  always @(posedge c or posedge clr) if (clr) q <= 1'b0; else if (CE) q <= d;
endmodule

module FDPE #(parameter [0:0] INIT = 1'b1, parameter [0:0] IS_C_INVERTED = 1'b0, parameter [0:0] IS_D_INVERTED = 1'b0, parameter [0:0] IS_PRE_INVERTED = 1'b0)
    (output Q, input C, input CE, input D, input PRE);
  reg q = INIT;
  assign Q = q;
  wire c = C ^ IS_C_INVERTED, d = D ^ IS_D_INVERTED, pre = PRE ^ IS_PRE_INVERTED;
  always @(posedge c or posedge pre) if (pre) q <= 1'b1; else if (CE) q <= d;
endmodule

module SRL16E #(parameter [15:0] INIT = 16'h0000, parameter [0:0] IS_CLK_INVERTED = 1'b0)
    (output Q, input A0, input A1, input A2, input A3, input CE, input CLK, input D);
  reg [15:0] data = INIT;
  assign Q = data[{A3, A2, A1, A0}];
  wire clk = CLK ^ IS_CLK_INVERTED;
  always @(posedge clk) if (CE) data <= {data[14:0], D};
endmodule
