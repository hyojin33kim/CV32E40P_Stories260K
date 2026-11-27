#!/usr/bin/env python3
"""Draws key signals of a (small) VCD as a real waveform picture: clock square wave, 1-bit signals as high/low lines, buses as boxes with their hex value.
Writes SVG and converts it to PNG with rsvg-convert (apt package librsvg2-bin).
usage: wave_svg.py <picked.vcd> <out_prefix> [preset ...]      presets: reset loop gemv  (default: all)
The VCD must hold the signals of docs/wave/vcd_pick.py's boot list. Cycles are counted from reset release (waveform time = 2 x cycle + 10); a value is read in the
middle of its cycle (clock low) and drawn for the whole cycle, a signal that changes at the clock edge changes at the start of the next column."""
import re, subprocess, sys

vcd, out = sys.argv[1], sys.argv[2]
presets = sys.argv[3:] or ['reset', 'loop', 'gemv']

ids, hdr, t, chg = {}, True, 0, {}
with open(vcd, errors='replace') as f:
    for line in f:
        s = line.split()
        if not s: continue
        if hdr:
            if s[0] == '$var': ids[s[3]] = s[4]
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
k = next(tt for tt, v in chg['clk_i'] if v == 0 and tt >= t_rel) - t_rel
sample = lambda c: t_rel + 2 * c + k

LW, RH, TOP, PAD = 270, 30, 58, 14          # label width, row height, header height, padding
GREEN, BLUE, GREY = '#1a7f37', '#1f5fbf', '#999999'

def svg(title, note, cycles, rows, cw):
    n = len(cycles); W = LW + n * cw + 2 * PAD; H = TOP + len(rows) * RH + 2 * PAD + 20
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" font-family="DejaVu Sans, Helvetica, Arial" font-size="11">',
         f'<rect width="{W}" height="{H}" fill="white"/>',
         f'<text x="{PAD}" y="20" font-size="15" font-weight="bold">{title}</text><text x="{PAD}" y="38" font-size="11" fill="#444">{note}</text>']
    x0 = PAD + LW
    for i, c in enumerate(cycles):          # cycle grid and numbers
        x = x0 + i * cw
        o.append(f'<line x1="{x}" y1="{TOP - 6}" x2="{x}" y2="{TOP + len(rows) * RH}" stroke="#dddddd" stroke-width="1"/>')
        o.append(f'<text x="{x + cw / 2}" y="{TOP - 10}" text-anchor="middle" font-size="9" fill="#666">{c}</text>')
    xe = x0 + n * cw
    o.append(f'<line x1="{xe}" y1="{TOP - 6}" x2="{xe}" y2="{TOP + len(rows) * RH}" stroke="#dddddd"/>')
    for r, (label, kind, name, qual) in enumerate(rows):
        y = TOP + r * RH; yt, yb = y + 6, y + RH - 6
        o.append(f'<line x1="{PAD}" y1="{y + RH}" x2="{xe}" y2="{y + RH}" stroke="#eeeeee"/>')
        o.append(f'<text x="{PAD + 4}" y="{y + RH / 2 + 4}" font-weight="bold">{label}</text>')
        if kind == 'clk':                    # rising edge at the start of the column, falling in the middle
            pts = []
            for i in range(n):
                x = x0 + i * cw
                pts += [(x, yb), (x, yt), (x + cw / 2, yt), (x + cw / 2, yb)]
            pts.append((xe, yb))
            o.append('<polyline points="' + ' '.join(f'{a:.1f},{b:.1f}' for a, b in pts) + f'" fill="none" stroke="{GREEN}" stroke-width="1.6"/>')
            continue
        vals = [at(name, sample(c)) for c in cycles]
        show = [True if not qual else at(qual, sample(c)) == 1 for c in cycles]
        if kind == 'bit':
            lv = [(v == 1 and s) for v, s in zip(vals, show)]
            pts = []
            for i, v in enumerate(lv):
                x = x0 + i * cw; yy = yt if v else yb
                pts += [(x, yy), (x + cw, yy)]
            o.append('<polyline points="' + ' '.join(f'{a:.1f},{b:.1f}' for a, b in pts) + f'" fill="none" stroke="{BLUE}" stroke-width="1.6"/>')
            for i, (v, s) in enumerate(zip(lv, show)):          # vertical edges
                if i and lv[i] != lv[i - 1]:
                    x = x0 + i * cw
                    o.append(f'<line x1="{x}" y1="{yt}" x2="{x}" y2="{yb}" stroke="{BLUE}" stroke-width="1.6"/>')
        else:
            i = 0
            while i < n:
                j = i
                while j + 1 < n and vals[j + 1] == vals[i] and show[j + 1] == show[i]: j += 1
                xa, xb = x0 + i * cw + 3, x0 + (j + 1) * cw - 3
                if not show[i]:
                    o.append(f'<line x1="{xa - 3}" y1="{(yt + yb) / 2}" x2="{xb + 3}" y2="{(yt + yb) / 2}" stroke="{GREY}" stroke-width="1" stroke-dasharray="3,3"/>')
                else:
                    txt = '?' if vals[i] is None else f'{vals[i]:x}'
                    o.append(f'<polygon points="{xa},{(yt + yb) / 2} {xa + 4},{yt} {xb - 4},{yt} {xb},{(yt + yb) / 2} {xb - 4},{yb} {xa + 4},{yb}" fill="#eef4ff" stroke="{BLUE}" stroke-width="1.3"/>')
                    o.append(f'<text x="{(xa + xb) / 2}" y="{(yt + yb) / 2 + 4}" text-anchor="middle" font-size="9">{txt}</text>')
                i = j + 1
    o.append(f'<text x="{PAD}" y="{H - 8}" font-size="9" fill="#777">blue line = signal (high or low), box = bus value in hex, dashed = not shown (request is 0), green = clock; cycle 0 = reset release</text>')
    o.append('</svg>')
    return '\n'.join(o)

def write(s, name):
    p = f'{out}_{name}.svg'
    open(p, 'w').write(s)
    subprocess.run(['rsvg-convert', '-o', f'{out}_{name}.png', '-z', '1.3', p], check=True)
    print(f'wrote {out}_{name}.png')

CLK = ('clk_i', 'clk', 'clk_i', None)
if 'reset' in presets:
    rows = [CLK, ('rst_ni (reset released at cycle 0)', 'bit', 'rst_ni', None), ('i_req (fetch request)', 'bit', 'i_req', None), ('i_addr (while i_req = 1)', 'bus', 'i_addr', 'i_req'),
            ('i_rvalid (instruction arrives)', 'bit', 'i_rvalid', None), ('d_req (data access)', 'bit', 'd_req', None), ('d_we (write, while d_req = 1)', 'bit', 'd_we', 'd_req'),
            ('d_addr (while d_req = 1)', 'bus', 'd_addr', 'd_req')]
    write(svg('Reset release and start-up code (cycles -5 to 30)', 'The first fetch is at cycle 2, address 0x01000080; the first data write at cycle 17 (address 0x1b4174, value 0).', list(range(-5, 31)), rows, 60), 'reset')
if 'loop' in presets:
    rows = [CLK, ('i_req', 'bit', 'i_req', None), ('i_addr (while i_req = 1)', 'bus', 'i_addr', 'i_req'), ('d_req (data access)', 'bit', 'd_req', None),
            ('d_we (write, while d_req = 1)', 'bit', 'd_we', 'd_req'), ('d_addr (while d_req = 1)', 'bus', 'd_addr', 'd_req'), ('d_wdata (while d_req = 1)', 'bus', 'd_wdata', 'd_req')]
    write(svg('Clearing variable memory: the 6-cycle loop (cycles 12 to 49)', 'i_addr repeats 9c, a0, a4, a8, ac; every 6 cycles one write of 0 goes to d_addr (1b4174, 1b4178, ... +4 each time).', list(range(12, 50)), rows, 60), 'loop')
if 'gemv' in presets:
    rows = [CLK, ('g_busy (GEMV working)', 'bit', 'g_busy', None), ('i_req', 'bit', 'i_req', None), ('i_addr (while i_req = 1)', 'bus', 'i_addr', 'i_req'),
            ('acc_i.state_q (GEMV state number)', 'bus', 'state_q', None)]
    write(svg('The first GEMV starts (cycles 3955 to 3994)', 'g_busy is high from cycle 3966 (the rising edge is at waveform time 7941); state_q changes from 0 to 1 at the same time; the core then loops in a short polling loop.', list(range(3955, 3995)), rows, 60), 'gemv')
