// FPU-only test: cv32e40p_fp_wrapper (CPU FPU, FPU_ADDMUL_LAT / FPU_OTHERS_LAT 4) on vec.hex ("op a b c flags" per line).
// Default: one operation at a time (req until gnt, wait rvalid), results to fpu_out.hex.
// With STREAM defined (V-F4): the vectors of one operation group (ADDMUL / DIVSQRT / NONCOMP / CONV; each group returns in order) are
// requested back to back (a new request every cycle the FPU grants) while a second process collects the results in order; results go to
// fpu_out_stream.hex in the original vector order. Same scheme as fpga/xsim/fpu_verilator.cpp "stream".
// With NETLIST defined the DUT is the post-synthesis functional netlist (parameters fixed at synthesis).
`timescale 1ns / 1ps
module tb_fpu;
  logic clk = 0, rst_n = 0;
  always #3.333 clk = ~clk;
  logic        req = 0, gnt, rvalid;
  logic [2:0][31:0] opnd = '0;
  logic [5:0]  op = 0;
  logic [14:0] flags = 15'h400;             // {INT32, FP32, FP32, RNE} as the CPU sends them
  logic [31:0] rdata;
  logic [4:0]  rflags;
`ifdef NETLIST
  cv32e40p_fp_wrapper dut (
`else
  cv32e40p_fp_wrapper #(.FPU_ADDMUL_LAT(4), .FPU_OTHERS_LAT(4)) dut (
`endif
`ifdef NETLIST   // the netlist splits the packed operand array into escaped-name ports
      .\apu_operands_i[0] (opnd[0]), .\apu_operands_i[1] (opnd[1]), .\apu_operands_i[2] (opnd[2]),
      .clk_i(clk), .rst_ni(rst_n), .apu_req_i(req), .apu_gnt_o(gnt),
`else
      .clk_i(clk), .rst_ni(rst_n), .apu_req_i(req), .apu_gnt_o(gnt), .apu_operands_i(opnd),
`endif
      .apu_op_i(op), .apu_flags_i(flags), .apu_rvalid_o(rvalid), .apu_rdata_o(rdata), .apu_rflags_o(rflags));
  integer fi, fo, n, k;
  logic [31:0] o, a, b, c, f;
`ifndef STREAM
  initial begin
    fi = $fopen("vec.hex", "r"); fo = $fopen("fpu_out.hex", "w");
`ifdef NETLIST
    #200;   // the Xilinx global set/reset (GSR, 100 ns) holds every flip-flop at the start of a post-synthesis simulation
`endif
    repeat (5) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);
    n = 0;
    while ($fscanf(fi, "%h %h %h %h %h\n", o, a, b, c, f) == 5) begin
      @(negedge clk); op = o[5:0]; flags = f[14:0]; opnd[0] = a; opnd[1] = b; opnd[2] = c; req = 1;
      do @(posedge clk); while (!gnt);
      #0.1 req = 0;
      k = 0;
      while (!rvalid) begin @(posedge clk); #0.1; if (++k > 200) $fatal(1, "no rvalid, vector %0d", n); end
      $fdisplay(fo, "%08h", rdata);
      n++;
      @(posedge clk);
    end
    $fclose(fo);
    $display("TB_FPU %0d vectors done", n);
    $finish;
  end
`else
  // ---------------------------------------------------------------- stream mode
  logic [31:0] vo[$], va[$], vb[$], vc[$], vf[$];
  logic [31:0] resv[];
  int idx_q[$];
  int g, iss, col, mo, cyc, extra, ops_total;
  function automatic int grp(logic [31:0] opw);   // operation group of fpnew_pkg::operation_e
    case (opw[3:0])
      4'd0, 4'd1, 4'd2, 4'd3: return 0;           // FMADD, FNMSUB, ADD, MUL
      4'd4, 4'd5:             return 1;           // DIV, SQRT
      4'd6, 4'd7, 4'd8, 4'd9: return 2;           // SGNJ, MINMAX, CMP, CLASSIFY
      default:                return 3;           // F2F, F2I, I2F, ...
    endcase
  endfunction
  initial begin
    fi = $fopen("vec.hex", "r"); fo = $fopen("fpu_out_stream.hex", "w");
`ifdef NETLIST
    #200;
`endif
    repeat (5) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);
    while ($fscanf(fi, "%h %h %h %h %h\n", o, a, b, c, f) == 5) begin
      vo.push_back(o); va.push_back(a); vb.push_back(b); vc.push_back(c); vf.push_back(f);
    end
    n = vo.size(); resv = new[n]; extra = 0; ops_total = 0;
    for (g = 0; g < 4; g++) begin
      idx_q.delete();
      for (int i = 0; i < n; i++) if (grp(vo[i]) == g) idx_q.push_back(i);
      if (idx_q.size() == 0) continue;
      iss = 0; col = 0; mo = 0; cyc = 0;
      fork
        begin : issuer
          while (iss < idx_q.size()) begin
            @(negedge clk);
            op = vo[idx_q[iss]][5:0]; flags = vf[idx_q[iss]][14:0];
            opnd[0] = va[idx_q[iss]]; opnd[1] = vb[idx_q[iss]]; opnd[2] = vc[idx_q[iss]]; req = 1;
            @(posedge clk);
            if (gnt) iss++;                       // granted at this edge
          end
          @(negedge clk); req = 0;
        end
        begin : collector
          while (col < idx_q.size()) begin
            @(posedge clk); #0.1; cyc++;
            if (rvalid) begin
              if (col >= iss) $fatal(1, "stream group %0d: result without request", g);
              resv[idx_q[col]] = rdata; col++;
            end
            if (iss - col > mo) mo = iss - col;
            if (cyc > 200 + 50 * idx_q.size()) $fatal(1, "stream group %0d: timeout (issued %0d, collected %0d of %0d)", g, iss, col, idx_q.size());
          end
        end
      join
      repeat (20) begin @(posedge clk); #0.1; if (rvalid) extra++; end
      $display("TB_FPU stream group %0d: %0d ops, %0d cycles, max in flight %0d", g, idx_q.size(), cyc, mo);
      ops_total += idx_q.size();
    end
    for (int i = 0; i < n; i++) $fdisplay(fo, "%08h", resv[i]);
    $fclose(fo);
    $display("TB_FPU stream %0d vectors done, unexpected extra results %0d", ops_total, extra);
    $finish;
  end
`endif
endmodule
