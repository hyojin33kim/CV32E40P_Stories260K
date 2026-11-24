#!/usr/bin/env python3
"""Prepares the post-synthesis netlist of soc_chip (netlist_net.v from fpga/synth.tcl with the token NETLIST) for Verilator (D4, V-S1).
xsim cannot run it: the Vivado Simulator BASIC license allows 50,000 instances and the netlist has 107,091.
Writes into <dir>/vl/:
  netlist_vl.v   the netlist without its own `glbl` module (a timing model of the global set/reset pulse)
  glbl_vl.v      a constant `glbl` (GSR = GTS = PRLD = 0: every flip-flop starts from its INIT value, as in a real configuration)
  unisim/        the vendor UNISIM models of the primitive types the netlist uses, with the `specify` blocks removed (timing only; Verilator
                 cannot parse them)
  files.f        Verilator file list: wrapper, glbl, prim_models.v (own models of FDRE FDSE FDCE FDPE SRL16E), netlist, unisim/
usage: prep.py [dir with netlist_net.v (default /mnt/e/fpga_work/chip_net)] [unisim dir]"""
import collections
import os
import re
import sys
from pathlib import Path

D = Path(sys.argv[1] if len(sys.argv) > 1 else '/mnt/e/fpga_work/chip_net')
UNI = Path(sys.argv[2] if len(sys.argv) > 2 else '/mnt/h/2026.1/Vivado/data/verilog/src/unisims')
HERE = Path(__file__).resolve().parent
O = D / 'vl'; O.mkdir(exist_ok=True)
t = (D / 'netlist_net.v').read_text(errors='replace')
# drop the module glbl (last module of the file)
i = t.index('module glbl')
j = t.index('endmodule', i) + len('endmodule')
t = t[:i] + t[j:]
(O / 'netlist_vl.v').write_text(t)
(O / 'glbl_vl.v').write_text('''`timescale 1ps/1ps
module glbl ();
  wire GSR = 1'b0;
  wire GTS = 1'b0;
  wire GWE = 1'b1;
  wire PRLD = 1'b0;
  wire GRESTORE = 1'b0;
  tri1 p_up_tmp;
  tri (weak1, strong0) PLL_LOCKG = p_up_tmp;
endmodule
''')
defs = set(re.findall(r'^module\s+(\w+)', t, re.M))
toks = collections.Counter(re.findall(r'^\s*(?:\(\*.*?\*\)\s*)?([A-Z][A-Z0-9_]+)\s+(?:#\s*\(|\\|\w+\s*\()', t, re.M))
prims = sorted(k for k in toks if k not in defs)
missing = [p for p in prims if not (UNI / f'{p}.v').exists()]
assert not missing, missing
OWN = {'FDRE', 'FDSE', 'FDCE', 'FDPE', 'SRL16E'}          # vendor models use assign/deassign: replaced by prim_models.v
(O / 'unisim').mkdir(exist_ok=True)
vendor = []
for p in prims:
    if p in OWN: continue
    src = (UNI / f'{p}.v').read_text(errors='replace')
    src = re.sub(r'(?ms)^[ \t]*specify\b.*?^[ \t]*endspecify\b', '', src)
    # the vendor models test every input for "not connected" (X !== 1'bz); in this netlist every input is connected, and Verilator rejects
    # the tri-state literal: replace the tests by their constant results
    src = re.sub(r"[\w\.]+(?:\[[^\]]*\])?\s*!==\s*1'bz", "1'b1", src)
    src = re.sub(r"[\w\.]+(?:\[[^\]]*\])?\s*===\s*1'bz", "1'b0", src)
    (O / 'unisim' / f'{p}.v').write_text(src)
    vendor.append(str(O / 'unisim' / f'{p}.v'))
lines = [str(HERE / 'net_top.sv'), str(O / 'glbl_vl.v'), str(HERE / 'prim_models.v'), str(O / 'netlist_vl.v')] + vendor
(O / 'files.f').write_text('\n'.join(lines) + '\n')
print(f'{len(prims)} primitive types: {" ".join(prims)}\nwrote {O}/netlist_vl.v, glbl_vl.v, files.f')
