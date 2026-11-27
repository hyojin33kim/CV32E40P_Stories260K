#!/usr/bin/env python3
"""Step-by-step view of a run from reset release: which code the core fetches (mapped to fw.dis), data accesses, accelerator busy flags.
usage: walkthrough.py <picked.vcd> <fw.dis> [first_n_instructions (default 40)]
The VCD must contain TOP.clk_i, TOP.rst_ni, TOP.soc_chip.{i_req,i_gnt,i_addr,d_req,d_we,d_addr,d_wdata} and soc_i.{g_busy,vfu_busy}
(docs/wave/vcd_pick.py with the list used in docs/BOOT_WALKTHROUGH.md). Cycle numbers count from reset release; one cycle = 2 time units."""
import re, sys

vcd, dis = sys.argv[1], sys.argv[2]
first_n = int(sys.argv[3]) if len(sys.argv) > 3 else 40

# ---- disassembly: address -> (function, text); function start lines look like "01000080 <_start>:"
func_at, text_at, cur = {}, {}, '?'
for line in open(dis, errors='replace'):
    m = re.match(r'^([0-9a-f]{8}) <([^>]+)>:', line)
    if m: cur = m.group(2); continue
    m = re.match(r'^\s*([0-9a-f]+):\s+([0-9a-f]+)\s+(.*)$', line)
    if m:
        a = int(m.group(1), 16); func_at[a] = cur; text_at[a] = re.sub(r'\s+', ' ', m.group(3)).strip()

# ---- VCD: value changes of the picked signals
ids, stack, hdr, t = {}, [], True, 0
chg = {}                                            # name -> list of (time, int value)
with open(vcd, errors='replace') as f:
    for line in f:
        s = line.split()
        if not s: continue
        if hdr:
            if s[0] == '$scope': stack.append(s[2])
            elif s[0] == '$upscope': stack.pop()
            elif s[0] == '$var': ids[s[3]] = s[4]
            elif s[0] == '$enddefinitions': hdr = False
            continue
        if line[0] == '#': t = int(line[1:]); continue
        if line[0] in 'bB': v, idc = s[0][1:], s[1]
        else: v, idc = line[0], line[1:].strip()
        if idc in ids and 'x' not in v.lower() and 'z' not in v.lower():
            chg.setdefault(ids[idc], []).append((t, int(v, 2)))

def at(name, tm):                                   # value of a signal at time tm (last change <= tm)
    r = 0
    for tt, v in chg.get(name, []):
        if tt <= tm: r = v
        else: break
    return r
def rises(name, v1=1):
    prev = 0; out = []
    for tt, v in chg.get(name, []):
        if v == v1 and prev != v1: out.append(tt)
        prev = v
    return out

def word_text(a):                                   # the core fetches aligned 4-byte words; a word can hold two 16-bit (compressed) instructions
    parts = [text_at[x] for x in (a, a + 2) if x in text_at]
    return ' | '.join(parts) if parts else '?'
def word_func(a):
    return next((func_at[x] for x in (a, a + 2) if x in func_at), '?')

t_rel = next((tt for tt, v in chg['rst_ni'] if v == 1), 0)
cyc = lambda tm: (tm - t_rel) // 2                  # cycle number counted from reset release
print(f'reset released at time {t_rel} (cycle 0); the clock period is 2 time units')
clk_falls = [tt for tt, v in chg['clk_i'] if v == 0 and tt >= t_rel]

# ---- instruction fetches: sampled in the middle of each cycle (clock low)
fetch, last_key = [], None
for tm in clk_falls:
    if at('i_req', tm) and at('i_gnt', tm):
        fetch.append((cyc(tm), at('i_addr', tm)))
print(f'\n== the first {first_n} instruction fetches after reset release (cycle, address, instruction, function)')
for c, a in fetch[:first_n]:
    print(f'  cycle {c:5d}  0x{a:08x}  {word_text(a):52s} {word_func(a)}')
print('\n== which function the core is fetching from, in order (consecutive fetches of one function are one line)')
seg = []
for c, a in fetch:
    f = word_func(a)
    if seg and seg[-1][0] == f: seg[-1][2] = c; seg[-1][3] += 1
    else: seg.append([f, c, c, 1])
for f, c0, c1, n in seg[:60]:
    print(f'  cycles {c0:5d}..{c1:5d}  {n:5d} fetches  {f}')
if len(seg) > 60: print(f'  ... ({len(seg)} segments in this window)')

# ---- data accesses and accelerators
d = []
for tm in clk_falls:
    if at('d_req', tm): d.append((cyc(tm), 'write' if at('d_we', tm) else 'read ', at('d_addr', tm), at('d_wdata', tm)))
print(f'\n== data-port accesses in this window: {len(d)}; the first 8:')
for c, w, a, v in d[:8]: print(f'  cycle {c:5d}  {w} 0x{a:08x}  data 0x{v:08x}')
for name in ('g_busy', 'vfu_busy'):
    # same convention as the fetch and data lines: the cycle in which the signal is first seen high when sampled in the middle of the cycle
    prev, r = 0, []
    for tm in clk_falls:
        v = at(name, tm)
        if v == 1 and prev == 0: r.append(cyc(tm))
        prev = v
    print(f'{name}: first rises (first cycle seen high) at ' + (', '.join(f'cycle {x}' for x in r[:4]) if r else 'never in this window'))
