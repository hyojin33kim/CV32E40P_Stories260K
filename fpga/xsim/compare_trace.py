#!/usr/bin/env python3
"""Compare two CPU data-port traces (Verilator sim.cpp SIM_TRACE_CPU vs xsim tb_chip.sv TRACE_N), same line format:
  "<cycle> REQ we=<0|1> be=<h> a=<hex> wd=<hex>"   and   "<cycle> RSP rd=<hex>"
The read data of a response to a STORE is a don't care (0 in the 2-state Verilator model, x in 4-state xsim) and is ignored;
responses to loads are compared exactly (an x in a load response is reported as such).
usage: compare_trace.py <verilator trace> <xsim trace>"""
import re, sys
def load(p):
    out, pend = [], []
    for l in open(p):
        if ' APU ' in l: continue
        l = l.rstrip('\n'); m = re.match(r'(\d+) (REQ|RSP) (.*)', l)
        if not m: continue
        cyc, kind, rest = m.groups()
        if kind == 'REQ':
            pend.append('st' if 'we=1' in rest else 'ld'); out.append((int(cyc), l))
        else:
            t = pend.pop(0) if pend else 'ld'
            out.append((int(cyc), f'{cyc} RSP(store)' if t == 'st' else l))
    return out
a, b = load(sys.argv[1]), load(sys.argv[2])
n = min(len(a), len(b))
for i in range(n):
    if a[i][1] != b[i][1]:
        print(f'first difference at event {i} (cycle {a[i][0]}):'); print('  verilator:', a[i][1]); print('  xsim     :', b[i][1])
        for k in range(max(0, i - 4), i): print('  context  :', a[k][1])
        sys.exit(1)
print(f'no difference in {n} events (verilator {len(a)}, xsim {len(b)})')
