#!/usr/bin/env python3
"""Draws key signals of a (small) VCD as a timing table with Graphviz: one row per signal, one column per cycle; a 1-bit signal is green when 1,
a bus shows its hex value (merged over cycles where it does not change). No waveform viewer needed; the PNG can be opened anywhere.
usage: wave_table.py <picked.vcd> <fw.dis> <out_prefix> [preset ...]      presets: reset loop gemv overview  (default: all)
The VCD must hold the signals of docs/wave/vcd_pick.py's boot list (docs/BOOT_WALKTHROUGH.md). Cycles are counted from reset release (waveform time = 2 x cycle + 10)."""
import re, subprocess, sys

vcd, dis, out = sys.argv[1], sys.argv[2], sys.argv[3]
presets = sys.argv[4:] or ['reset', 'loop', 'gemv', 'overview']

# ---- disassembly -> function name of a fetched word
func_at = {}
cur = '?'
for line in open(dis, errors='replace'):
    m = re.match(r'^([0-9a-f]{8}) <([^>]+)>:', line)
    if m: cur = m.group(2); continue
    m = re.match(r'^\s*([0-9a-f]+):\s+[0-9a-f]+\s', line)
    if m: func_at[int(m.group(1), 16)] = cur
def word_func(a): return next((func_at[x] for x in (a, a + 2) if x in func_at), '?')

# ---- VCD value changes by signal base name
ids, hdr, t, chg, width = {}, True, 0, {}, {}
with open(vcd, errors='replace') as f:
    for line in f:
        s = line.split()
        if not s: continue
        if hdr:
            if s[0] == '$var': ids[s[3]] = s[4]; width[s[4]] = int(s[2])
            elif s[0] == '$enddefinitions': hdr = False
            continue
        if line[0] == '#': t = int(line[1:]); continue
        v, idc = (s[0][1:], s[1]) if line[0] in 'bB' else (line[0], line[1:].strip())
        if idc in ids:
            chg.setdefault(ids[idc], []).append((t, None if re.search('[xXzZ]', v) else int(v, 2)))
def at(name, tm):
    r = None
    for tt, v in chg.get(name, []):
        if tt <= tm: r = v
        else: break
    return r
t_rel = next(tt for tt, v in chg['rst_ni'] if v == 1)
k = next(tt for tt, v in chg['clk_i'] if v == 0 and tt >= t_rel) - t_rel     # offset of the clock-low point inside a cycle
sample = lambda c: t_rel + 2 * c + k
HI, LO, BUS = '#7fd08a', '#ffffff', ['#d9e7fa', '#eef3fb']
LW = 250   # width of the signal-name column

def cell(text, bg, span=1, w=30, bold=False, size=9):
    t = f'<B>{text}</B>' if bold else text
    inner = f'<FONT POINT-SIZE="{size}">{t}</FONT>' if text != '' else ''       # Graphviz rejects an empty FONT element
    return f'<TD COLSPAN="{span}" WIDTH="{w * span}" FIXEDSIZE="TRUE" HEIGHT="20" BGCOLOR="{bg}">{inner}</TD>'

def table(title, cycles, rows, w=30, hexw=None, note=''):
    """rows: list of (label, name, kind) kind: 'bit' or 'bus'; cycles: list of cycle numbers (one column each)"""
    h = ['<TR>' + cell('<I>cycle</I>', '#e6e6e6', 1, LW) + ''.join(cell(str(c), '#e6e6e6', 1, w, size=8) for c in cycles) + '</TR>']
    for label, name, kind, qual in rows:
        vals = [at(name, sample(c)) for c in cycles]
        if qual: vals = [(v if at(qual, sample(c)) == 1 else (0 if kind == 'bit' else -1)) for v, c in zip(vals, cycles)]   # -1 = not shown
        line = cell(label, '#f4f4f4', 1, LW, bold=True)
        if kind == 'bit':
            line += ''.join(cell('', HI if v == 1 else LO, 1, w) for v in vals)
        else:
            i, n = 0, 0
            while i < len(vals):
                j = i
                while j + 1 < len(vals) and vals[j + 1] == vals[i]: j += 1
                v = vals[i]
                txt = '' if v == -1 else ('?' if v is None else (f'{v:x}' if hexw is None else f'{v:0{hexw}x}'))
                line += cell(txt, BUS[n % 2], j - i + 1, w); i = j + 1; n += 1
        h.append('<TR>' + line + '</TR>')
    g = ('digraph w { graph [fontname="Helvetica", fontsize=13, labelloc=t, label=<<B>' + title + '</B><BR/><FONT POINT-SIZE="10">' + note + '</FONT>>]; '
         'node [shape=plain, fontname="Helvetica"]; t [label=<<TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0" CELLPADDING="1">' + ''.join(h) + '</TABLE>>]; }')
    return g

def render(g, name):
    for ext, extra in (('png', ['-Gdpi=110']), ('svg', [])):
        subprocess.run(['dot', f'-T{ext}'] + extra + ['-o', f'{out}_{name}.{ext}'], input=g, text=True, check=True)
    print(f'wrote {out}_{name}.png')

def bits(*pairs): return [(p[0], p[1], 'bit', p[2] if len(p) > 2 else None) for p in pairs]
def buses(*pairs): return [(p[0], p[1], 'bus', p[2] if len(p) > 2 else None) for p in pairs]

if 'reset' in presets:
    cyc = list(range(-5, 31))
    rows = bits(('rst_ni (reset released at cycle 0)', 'rst_ni'), ('i_req (fetch request)', 'i_req')) + buses(('i_addr (shown while i_req = 1)', 'i_addr', 'i_req')) + \
           bits(('i_rvalid (instruction arrives)', 'i_rvalid'), ('d_req (data access)', 'd_req'), ('d_we (write, while d_req = 1)', 'd_we', 'd_req')) + buses(('d_addr (shown while d_req = 1)', 'd_addr', 'd_req'))
    render(table('Reset release and start-up code (cycles -5 to 30)', cyc, rows, w=52, note='green = 1; addresses in hex without leading zeros (1000080 = 0x01000080); i_addr and d_addr are shown only while their request is 1. The first fetch is at cycle 2; the first data write at cycle 17.'), 'reset')
if 'loop' in presets:
    cyc = list(range(12, 50))
    rows = bits(('i_req', 'i_req'), ('d_req (data access)', 'd_req'), ('d_we (write, while d_req = 1)', 'd_we', 'd_req')) + buses(('i_addr (shown while i_req = 1)', 'i_addr', 'i_req'), ('d_addr (shown while d_req = 1)', 'd_addr', 'd_req'), ('d_wdata (shown while d_req = 1)', 'd_wdata', 'd_req'))
    render(table('Clearing variable memory: the 6-cycle loop (cycles 12 to 49)', cyc, rows, w=52, note='i_addr repeats 9c, a0, a4, a8, ac; every 6 cycles one write of 0 goes to d_addr (1b4174, 1b4178, ... +4 each time).'), 'loop')
if 'gemv' in presets:
    cyc = list(range(3955, 3995))
    rows = bits(('g_busy (GEMV working)', 'g_busy'), ('i_req', 'i_req')) + buses(('i_addr (shown while i_req = 1)', 'i_addr', 'i_req'), ('acc_i.state_q (GEMV state number)', 'state_q'))
    render(table('The first GEMV starts (cycles 3955 to 3994)', cyc, rows, w=52, note='g_busy is high from cycle 3966 (the rising edge is at waveform time 7941). state_q (GEMV state number) changes right after. The core then fetches a short polling loop.'), 'gemv')
if 'overview' in presets:
    BIN = 40
    bins = list(range(0, 8000, BIN))
    funcs, busy = [], []
    for b in bins:
        cnt = {}
        bu = 0
        for c in range(b, b + BIN):
            tm = sample(c)
            if at('i_req', tm) == 1 and at('i_gnt', tm) == 1:
                f = word_func(at('i_addr', tm) or 0); cnt[f] = cnt.get(f, 0) + 1
            if at('g_busy', tm) == 1: bu = 1
        funcs.append(max(cnt, key=cnt.get) if cnt else '-'); busy.append(bu)
    h = ['<TR>' + cell('<I>cycle (each column = 40 cycles)</I>', '#e6e6e6', 1, 260) + ''.join(cell(str(b) if (i % 5 == 0) else '', '#e6e6e6', 1, 9, size=6) for i, b in enumerate(bins)) + '</TR>']
    line, i, n = cell('code being fetched (majority per column)', '#f4f4f4', 1, 260, bold=True), 0, 0
    pal = {'_start': '#dbe9fb', 'boot': '#c8dcf5', 'forward': '#f0e3c8', 'rmsnorm': '#e8d3f0', 'acc_gemv': '#c9e8cc', 'acc_vfu_sum': '#c9e8cc', '-': '#eeeeee'}
    while i < len(funcs):
        j = i
        while j + 1 < len(funcs) and funcs[j + 1] == funcs[i]: j += 1
        line += cell(funcs[i], pal.get(funcs[i], '#f3f3f3'), j - i + 1, 9, size=7); i = j + 1
    h.append('<TR>' + line + '</TR>')
    line = cell('g_busy (GEMV working in this column)', '#f4f4f4', 1, 260, bold=True) + ''.join(cell('', HI if b else LO, 1, 9) for b in busy)
    h.append('<TR>' + line + '</TR>')
    g = ('digraph w { graph [fontname="Helvetica", fontsize=13, labelloc=t, label=<<B>Overview of the first 8,000 cycles</B><BR/><FONT POINT-SIZE="10">A column is 40 cycles wide. Code: _start (start-up), boot (set-up and weight copy), forward / rmsnorm (CPU), acc_gemv / acc_vfu_sum (accelerator calls and the polling loop). Green = GEMV busy at some point of the column.</FONT>>]; '
         'node [shape=plain, fontname="Helvetica"]; t [label=<<TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0" CELLPADDING="1">' + ''.join(h) + '</TABLE>>]; }')
    render(g, 'overview')
