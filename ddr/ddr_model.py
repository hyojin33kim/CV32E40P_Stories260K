#!/usr/bin/env python3
"""DDR4 channel efficiency model (P1): row/bank/bank-group effects for sequential weight streaming.

A first-order, in-order-issue model with an N-deep lookahead window, NOT validated against any
controller or board. Its job is to rank design choices (access granularity, time-slice quantum,
address mapping), not to predict absolute GB/s. Parameters are DDR4-2400 17-17-17 from memory
(JEDEC-typical); every one is a command-line / dict override.

Model:
  - one 64-bit channel, 64 B per BL8 access (4 tCK on the data bus), peak = 64 B / 4 tCK
  - 16 banks = 4 bank groups x 4, open-page policy, row (page) size per bank = PAGE bytes
  - CAS spacing tCCD_S (different bank group) / tCCD_L (same), ACT spacing tRRD_S/L, tFAW,
    tRCD, tRP, tRAS, tRC, tRTP; refresh every tREFI blocks the channel for tRFC and closes all rows
  - requests are issued in arrival order; a request becomes visible to the controller when the
    request W places earlier has issued its CAS (lookahead window W), so PRE/ACT of an upcoming
    row overlap earlier data transfers
  - address mapping: 'bgint' = consecutive 64 B lines alternate bank group (common for DDR4
    controllers), 'rowseq' = a whole page of one bank before the next bank (page-linear)
Efficiency = bytes / (elapsed tCK * peak bytes per tCK).

usage: ddr/ddr_model.py   -> prints tables (also written to ddr/ddr_model_results.md)
"""
import sys
from collections import deque
from pathlib import Path

T = dict(tRCD=17, tRP=17, tRAS=39, tRC=56, tRTP=9, tCCD_S=4, tCCD_L=6, tRRD_S=4, tRRD_L=6, tFAW=21,
         tREFI=9360, tRFC=420, BURST=4)
LINE = 64


def addr_map(line, page, mapping):
    ppl = page // LINE                       # lines per page
    if mapping == 'bgint':
        bg = line % 4; r = line // 4
        col = r % ppl; r //= ppl
        bk = r % 4; r //= 4
        return bg * 4 + bk, r, col
    bank = (line // ppl) % 16                # rowseq: bank id; bank group = bank % 4 (consecutive pages alternate BG)
    row = (line // ppl) // 16
    return bank, row, line % ppl


def bank_group(bank, mapping):
    return bank // 4 if mapping == 'bgint' else bank % 4


def simulate(lines, page=8192, mapping='bgint', window=16, t=T):
    """lines: iterable of 64 B line numbers in arrival order. Returns elapsed tCK."""
    open_row = [None] * 16; t_act = [-10**9] * 16; t_rdy = [0] * 16; t_pre = [0] * 16
    acts = deque(maxlen=4); last_act = (-10**9, -1)
    last_cas, last_bg = -10**9, -1
    cas_hist = deque(maxlen=window)
    next_ref = t['tREFI']; busy_until = 0
    n = 0; end = 0
    for line in lines:
        bank, row, _ = addr_map(line, page, mapping); bg = bank_group(bank, mapping)
        avail = cas_hist[0] if len(cas_hist) == window else 0
        if open_row[bank] == row:
            cas = max(t_rdy[bank], avail)
        else:
            if open_row[bank] is None: pre_done = avail
            else: pre_done = max(t_pre[bank], avail) + t['tRP']
            act = max(pre_done, t_act[bank] + t['tRC'], avail)
            if acts: act = max(act, acts[-1] + (t['tRRD_L'] if last_act[1] == bg else t['tRRD_S']))
            if len(acts) == 4: act = max(act, acts[0] + t['tFAW'])
            if act >= next_ref: act = max(act, next_ref + t['tRFC'] - 0)
            acts.append(act); last_act = (act, bg)
            t_act[bank] = act; open_row[bank] = row
            cas = act + t['tRCD']
        cas = max(cas, last_cas + (t['tCCD_L'] if bg == last_bg else t['tCCD_S']), busy_until)
        while cas >= next_ref:                       # refresh: close everything, block tRFC
            cas = max(cas, next_ref + t['tRFC']); next_ref += t['tREFI']
            open_row = [None] * 16; busy_until = cas
            if cas >= next_ref - t['tREFI'] + t['tREFI']: pass
        last_cas, last_bg = cas, bg; cas_hist.append(cas)
        t_rdy[bank] = max(t_rdy[bank], t_act[bank] + t['tRCD'])
        t_pre[bank] = max(t_act[bank] + t['tRAS'], cas + t['tRTP'])
        n += 1; end = cas + t['BURST']
    return end, n


def stream(base, nbytes, burst):
    """sequential reads of nbytes from base, as requests of `burst` bytes (all lines in order)"""
    b0 = base // LINE
    return [b0 + i for i in range(nbytes // LINE)]


def interleave(streams, quantum):
    """round-robin between master streams, `quantum` bytes at a time"""
    q = max(1, quantum // LINE); pos = [0] * len(streams); out = []
    while any(p < len(s) for p, s in zip(pos, streams)):
        for i, s in enumerate(streams):
            if pos[i] < len(s):
                out.extend(s[pos[i]:pos[i] + q]); pos[i] += q
    return out


def eff(lines, **kw):
    end, n = simulate(lines, **kw)
    return n * T['BURST'] / end


def main():
    NB = 1 << 20                                  # 1 MiB per master
    out = ['# DDR4 channel efficiency model (first-order, unvalidated; see ddr/ddr_model.py)', '',
           'DDR4-2400 17-17-17, 1 channel x 64 bit (19.2 GB/s peak), page 8 KB/bank, open page, lookahead window W.',
           'Efficiency = streamed bytes / (time x peak). Two masters read separate 1 MiB regions.', '']
    kb = lambda q: f'{q // 1024} KB' if q >= 1024 else f'{q} B'
    Q = [64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
    for mapping in ('bgint', 'rowseq'):
        out += [f'## mapping `{mapping}`', '',
                '| interleave quantum | 1 master | 2 masters, W=16 | 2 masters, W=4 | 2 masters, W=64 |', '|---|---:|---:|---:|---:|']
        one = eff(stream(0, NB, 0), mapping=mapping)
        s0, s1 = stream(0, NB, 0), stream(256 << 20, NB, 0)
        for q in Q:
            e16 = eff(interleave([s0, s1], q), mapping=mapping, window=16)
            e4 = eff(interleave([s0, s1], q), mapping=mapping, window=4)
            e64 = eff(interleave([s0, s1], q), mapping=mapping, window=64)
            out.append(f'| {kb(q)} | {one * 100:.1f}% | {e16 * 100:.1f}% | {e4 * 100:.1f}% | {e64 * 100:.1f}% |')
        out.append('')
    out += ['## page size sensitivity (mapping bgint, W=16, 2 masters)', '', '| quantum | page 2 KB | page 4 KB | page 8 KB |', '|---|---:|---:|---:|']
    for q in (128, 1024, 8192, 32768):
        row = [f'{eff(interleave([s0, s1], q), mapping="bgint", page=p) * 100:.1f}%' for p in (2048, 4096, 8192)]
        out.append(f'| {kb(q)} | ' + ' | '.join(row) + ' |')
    txt = '\n'.join(out)
    print(txt)
    (Path(__file__).parent / 'ddr_model_results.md').write_text(txt + '\n')


if __name__ == '__main__':
    main()
