#!/usr/bin/env python3
"""Run the CV32E40P Stories260K chip on a ZCU104 with PYNQ (the board version of sim_axi.cpp).

usage (on the board, as root):  python3 run_chip.py board.bit <image.bin> [expected_dump.bin]
  board.bit / board.hwh : from fpga/bd/run_board.sh (out/), copied side by side to the board
  image.bin             : the same image the simulators take (gen/out_*/image.bin, repro/hold/image_*.bin)
  expected_dump.bin     : optional, the Verilator chip sim dump of the same image (obj_chip/Vsoc_chip
                          <image> <dump>); the 2 MiB SRAM read back from the board is compared byte by byte
Flow (AXI4-Lite map of acc/chip_axi_top.sv): CTRL.RUN=0 -> write imem (16 KB) and the SRAM image (2 MiB,
every word, so stale contents cannot matter) -> CTRL.RUN=1 -> poll STATUS.DONE -> read CYCLES / DONE_V ->
CTRL.RUN=0 -> read the SRAM back -> dump.bin (+ compare). Not run on hardware yet (written 11-18).
"""
import sys, time
import numpy as np
from pynq import Overlay, MMIO

CTRL, STATUS, DONE_V, CYCLES = 0x200_0000, 0x200_0004, 0x200_0008, 0x200_000C
IMEM, IMEM_WORDS, SRAM_WORDS = 0x100_0000, 4096, 524288

def main():
    bit, img_path = sys.argv[1], sys.argv[2]
    expect = sys.argv[3] if len(sys.argv) > 3 else None
    ol = Overlay(bit)
    ip = next(v for k, v in ol.ip_dict.items() if 'chip' in k)
    base, rng = ip['phys_addr'], ip['addr_range']
    print(f'chip at 0x{base:x}, range 0x{rng:x}, PL clock {ol.clock_dict if hasattr(ol, "clock_dict") else "?"}')
    m = MMIO(base, 0x400_0000)
    img = np.fromfile(img_path, dtype='<u4')
    m.write(CTRL, 0)                                            # core held in reset
    t0 = time.time()
    imem = img[IMEM // 4: IMEM // 4 + IMEM_WORDS]
    for i, w in enumerate(imem):
        m.write(IMEM + 4 * i, int(w))
    sram = img[:SRAM_WORDS]
    for i, w in enumerate(sram):                                # all words (board SRAM is not zeroed)
        m.write(4 * i, int(w))
    print(f'loaded {IMEM_WORDS} + {SRAM_WORDS} words in {time.time() - t0:.1f} s')
    m.write(CTRL, 1)
    t0 = time.time()
    while (m.read(STATUS) & 1) == 0:
        if time.time() - t0 > 60:
            sys.exit('timeout waiting for DONE')
    cycles, done_v = m.read(CYCLES), m.read(DONE_V)
    print(f'DONE value 0x{done_v:x}, {cycles:,} cycles (PL clock cycles from RUN to DONE)')
    m.write(CTRL, 0)
    dump = np.array([m.read(4 * i) for i in range(SRAM_WORDS)], dtype='<u4')
    dump.tofile('dump.bin')
    print('wrote dump.bin')
    if expect:
        ref = np.fromfile(expect, dtype='<u4')[:SRAM_WORDS]
        diff = np.nonzero(dump != ref)[0]
        print('board == simulation (2 MiB)' if len(diff) == 0 else
              f'{len(diff)} words differ, first at byte 0x{4 * diff[0]:x}')

if __name__ == '__main__':
    main()
