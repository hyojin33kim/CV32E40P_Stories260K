#!/usr/bin/env python3
"""Pre-tiling of GEMV weights (mode D and mode A): repack the matrix so that the accelerator's issue order is address-sequential.

The engine fetches (group of LL rows, run of RUN line-chunks, row, chunk in run): rows of a group are visited one after the
other, RUN lines per row, then the next run of the same rows. With the usual row-major layout consecutive fetches are RUN lines
apart in a row and a row stride away from the next row, so an AXI burst can only be RUN lines (8 x 16 B = 128 B). A pre-tiled
image stores the lines in exactly this fetch order; with CTRL bit2 (tiled) the engine adds 16 B per issued line instead of
computing (row * stride + chunk * 16) and the whole (rows of a group) x (run) block is one contiguous region.

usage: w8/pretile.py [LL=16] [RUN=8]    prints burst statistics for 260K and 15M-class shapes (row-major vs pre-tiled)
Library: fetch_order(d, n, line_elems, LL, RUN) -> list of (row, chunk); tile(matrix_bytes, ...) -> bytes in fetch order."""
import sys

def fetch_order(d, n, line_elems, LL=16, RUN=8):
    """(row, chunk) in the order the engine issues line reads. line_elems: j per 16 B line (16 for int8, 4 for fp32)."""
    nch = -(-n // line_elems)
    out = []
    for i0 in range(0, d, LL):
        na = min(LL, d - i0)
        for kb in range(0, nch, RUN):
            for q in range(na):
                for k in range(kb, min(kb + RUN, nch)):
                    out.append((i0 + q, k))
    return out

def tile(rows, line_bytes=16, LL=16, RUN=8, line_elems=16):
    """rows: list of bytes objects, each padded to a multiple of line_bytes. Returns the tiled byte string."""
    d = len(rows); n = len(rows[0]) * line_elems // line_bytes
    out = bytearray()
    for r, k in fetch_order(d, n, line_elems, LL, RUN):
        out += rows[r][k * line_bytes:(k + 1) * line_bytes]
    return bytes(out)

def burst_stats(d, n, line_elems, LL, RUN, tiled, maxb=16, page_lines=256):
    """Merge consecutive-address line reads into bursts (<= maxb lines, never across a 4 KB = 256 line boundary)."""
    nch = -(-n // line_elems)
    order = fetch_order(d, n, line_elems, LL, RUN)
    addr = [(r * nch + k) if not tiled else i for i, (r, k) in enumerate(order)]
    bursts, run_len, prev = 0, 0, None
    for a in addr:
        if prev is not None and a == prev + 1 and run_len < maxb and a % page_lines != 0:
            run_len += 1
        else:
            bursts += 1; run_len = 1
        prev = a
    return len(addr), bursts

if __name__ == '__main__':
    LL = int(sys.argv[1]) if len(sys.argv) > 1 else 16
    RUN = int(sys.argv[2]) if len(sys.argv) > 2 else 8
    shapes = [('260K  Wq/Wo   int8', 64, 64, 16), ('260K  W1/W3   int8', 172, 64, 16), ('260K  W2      int8', 64, 172, 16),
              ('260K  cls     int8', 512, 64, 16),
              ('15M   Wq/Wo   int8', 288, 288, 16), ('15M   W1/W3   int8', 768, 288, 16), ('15M   W2      int8', 288, 768, 16),
              ('15M   cls(1024) int8', 1024, 288, 16), ('15M   W1/W3   fp32', 768, 288, 4), ('15M   W2      fp32', 288, 768, 4)]
    print(f'LL={LL} rows per group, RUN={RUN} lines per run; bursts merge consecutive lines (<= MAXB, 4 KB safe)')
    print(f'{"matrix":<22}{"lines":>9}{"row-major":>12}{"avg":>7}{"tiled MAXB16":>14}{"avg":>7}{"tiled MAXB64":>14}{"avg":>7}{"tiled MAXB256":>15}{"avg":>7}')
    for name, d, n, le in shapes:
        ln, b0 = burst_stats(d, n, le, LL, RUN, False, 16)
        _, b1 = burst_stats(d, n, le, LL, RUN, True, 16)
        _, b2 = burst_stats(d, n, le, LL, RUN, True, 64)
        _, b3 = burst_stats(d, n, le, LL, RUN, True, 256)
        print(f'{name:<22}{ln:>9,}{b0:>12,}{ln / b0:>7.1f}{b1:>14,}{ln / b1:>7.1f}{b2:>14,}{ln / b2:>7.1f}{b3:>15,}{ln / b3:>7.1f}')
