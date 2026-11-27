#!/usr/bin/env python3
"""Picks a few signals out of a big Verilator VCD (thousands of signals) and writes a small VCD plus a GTKWave save file with those signals already
added, so the waveform viewer opens with only what matters.
usage: docs/wave/vcd_pick.py <in.vcd> <out.vcd> <out.gtkw> [full signal path ...]
Without signal paths a default list is used (soc_chip bus ports, accelerator busy flags and states, core control state, debug halt).
Open:  gtkwave <out.vcd> <out.gtkw>      (or: surfer <out.vcd>)
Signal paths are those of the Verilator VCD of the soc_chip build (TRACE=1 TOP=soc_chip ./build_sim.sh), e.g. TOP.soc_chip.soc_i.acc_i.state_q."""
import sys

DEFAULT = [
    'TOP.clk_i',
    'TOP.soc_chip.i_req', 'TOP.soc_chip.i_addr',
    'TOP.soc_chip.d_req', 'TOP.soc_chip.d_we', 'TOP.soc_chip.d_addr', 'TOP.soc_chip.d_wdata', 'TOP.soc_chip.d_rdata',
    'TOP.soc_chip.a_req', 'TOP.soc_chip.a_we', 'TOP.soc_chip.a_addr', 'TOP.soc_chip.a_gnt', 'TOP.soc_chip.a_rvalid',
    'TOP.soc_chip.soc_i.g_busy', 'TOP.soc_chip.soc_i.vfu_busy',
    'TOP.soc_chip.soc_i.acc_i.state_q', 'TOP.soc_chip.soc_i.acc_i.mode_q',
    'TOP.soc_chip.soc_i.vfu_i.st_q', 'TOP.soc_chip.soc_i.vfu_i.cmd_q',
    'TOP.soc_chip.soc_i.cpu_i.core_i.id_stage_i.controller_i.ctrl_fsm_cs',
    'TOP.soc_chip.soc_i.cpu_i.debug_halted_o',
]

def main():
    if len(sys.argv) < 4:
        print(__doc__); return 2
    src, out_vcd, out_gtkw = sys.argv[1:4]
    want = sys.argv[4:] or DEFAULT
    wanted = set(want)
    stack, picked, timescale = [], {}, '1ps'   # id code -> (path, width, range)
    with open(src, errors='replace') as f:
        header_end = 0
        for line in f:
            t = line.split()
            if not t: continue
            if t[0] == '$timescale': timescale = ' '.join(t[1:-1])
            elif t[0] == '$scope': stack.append(t[2])
            elif t[0] == '$upscope': stack.pop()
            elif t[0] == '$var':
                name = t[4]
                path = '.'.join(stack) + '.' + name
                if path in wanted and t[3] not in picked:
                    picked[t[3]] = (path, int(t[2]), t[5] if len(t) > 6 else '')
            elif t[0] == '$enddefinitions': break
    missing = [w for w in want if w not in {v[0] for v in picked.values()}]
    for m in missing: print('not in the VCD (skipped):', m)
    ids_by_path = {v[0]: (k, v) for k, v in picked.items()}
    # new header: one scope chain per picked signal (grouped by scope path)
    groups = {}
    for k, (path, w, rng) in picked.items():
        scope, name = path.rsplit('.', 1)
        groups.setdefault(scope, []).append((k, w, name, rng))
    # scope tree, each scope opened once (GTKWave would show a repeated "TOP" several times otherwise)
    tree = {}
    for scope, sigs in groups.items():
        node = tree
        for part in scope.split('.'): node = node.setdefault(part, {})
        node.setdefault('', []).extend(sigs)
    def emit(o, node):
        for k, w, name, rng in node.get('', []):
            o.write(f'$var wire {w} {k} {name} {rng} $end\n' if rng else f'$var wire {w} {k} {name} $end\n')
        for part in sorted(x for x in node if x != ''):
            o.write(f'$scope module {part} $end\n'); emit(o, node[part]); o.write('$upscope $end\n')
    with open(out_vcd, 'w') as o:
        o.write(f'$timescale {timescale} $end\n')
        emit(o, tree)
        o.write('$enddefinitions $end\n')
        pending, n_changes = None, 0
        with open(src, errors='replace') as f:
            body = False
            for line in f:
                if not body:
                    if line.startswith('$enddefinitions'): body = True
                    continue
                if not line.strip(): continue
                c = line[0]
                if c == '#': pending = line; continue
                if c in '$': continue
                idc = line.split()[-1] if c in 'bBrR' else line[1:].strip()
                if idc in picked:
                    if pending is not None: o.write(pending); pending = None
                    o.write(line); n_changes += 1
    with open(out_gtkw, 'w') as g:
        g.write('[*]\n[*] made by docs/wave/vcd_pick.py\n[*]\n')
        g.write(f'[dumpfile] "{out_vcd}"\n[timestart] 0\n[treeopen] TOP.\n[treeopen] TOP.soc_chip.\n')
        for path in want:
            if path not in ids_by_path: continue
            k, (p, w, rng) = ids_by_path[path]
            g.write('@28\n' if w == 1 else '@22\n')
            g.write(p + (rng if rng else '') + '\n')
    print(f'{len(picked)} signals, {n_changes} value changes -> {out_vcd}, {out_gtkw}')
    return 0

if __name__ == '__main__':
    sys.exit(main())
