#!/usr/bin/env python3
"""Compiles a small C program with the project's flow (build.sh: riscv64-unknown-elf-gcc, start.S, link.ld) and runs it on the board-flow chip simulation
(chip_axi_top: the image is written through the AXI4-Lite slave, the core runs, the SRAM is read back). Prints DONE cycles, the output channel and any memory words.
usage: docs/labs/run_c.py <file.c> [--opt O2] [--ctrl N] [--words ADDR:COUNT[,ADDR:COUNT...]] [--sim PATH] [--maxcyc N]
  The program must define  void boot(void)  (start.S calls it) and finish by writing a nonzero value to 0x2000_0000 (DONE).
  --ctrl N      value of the control word at 0x1afff0 that the program may read (a way to pass one number in)
  --words       print 32-bit words of the final SRAM contents, e.g. --words 0x1aff00:4
  --sim         simulator, default obj_axi/Vchip_axi_top (build it with:  TOP=chip_axi_top ./build_sim.sh)
Output channel: a write to 0x2000_0010 shows up in the OUT / OUT_CNT registers (acc/chip_axi_top.sv); only the last value and the count are kept."""
import argparse, os, re, struct, subprocess, sys
from pathlib import Path

W = Path(__file__).resolve().parent.parent.parent
ap = argparse.ArgumentParser()
ap.add_argument('src'); ap.add_argument('--opt', default='Os'); ap.add_argument('--ctrl', type=lambda x: int(x, 0), default=0)
ap.add_argument('--words', default=''); ap.add_argument('--sim', default=os.environ.get('TEST_SIM', str(W / 'obj_axi/Vchip_axi_top')))
ap.add_argument('--maxcyc', default='20000000')
a = ap.parse_args()
src = Path(a.src).resolve()
O = W / '.scratch' / 'labs' / src.stem; O.mkdir(parents=True, exist_ok=True)
r = subprocess.run(['env', f'SRC={src.relative_to(W)}', f'OUT={O}/prog', f'CFLAGS_EXTRA=-{a.opt}', str(W / 'build.sh')], cwd=W, capture_output=True, text=True)
if r.returncode != 0:
    print('build failed:\n' + r.stdout[-1500:] + r.stderr[-1500:]); sys.exit(1)
elf = (O / 'prog.elf').read_bytes()
phoff = struct.unpack_from('<I', elf, 28)[0]; sz, num = struct.unpack_from('<HH', elf, 42)
img = bytearray(0x1020000)
for i in range(num):
    typ, off, va, pa, fs, ms, fl, al = struct.unpack_from('<8I', elf, phoff + i * sz)
    if typ == 1: img[pa:pa + fs] = elf[off:off + fs]
struct.pack_into('<I', img, 0x1afff0, a.ctrl)
(O / 'image.bin').write_bytes(img)
size = subprocess.run(['riscv64-unknown-elf-size', str(O / 'prog.elf')], capture_output=True, text=True).stdout.strip().splitlines()[-1].split()
print(f'built {src.name} with -{a.opt}: text {size[0]} bytes, data {size[1]}, bss {size[2]}   (files in {O.relative_to(W)}: prog.elf prog.dis prog.map)')
r = subprocess.run([a.sim, str(O / 'image.bin'), str(O / 'dump.bin'), a.maxcyc], capture_output=True, text=True)
out = r.stdout
m = re.search(r'DONE cycles=(\d+) done_value=0x([0-9a-f]+)', out)
print(f'run: DONE after {m.group(1)} cycles (done value 0x{m.group(2)})' if m else f'run: no DONE ({r.stderr.strip()[-200:]})')
g = re.search(r'DBGREGS out=0x([0-9a-f]+) out_cnt=(\d+) last_pc=0x([0-9a-f]+) fetch_cnt=(\d+) trap_cnt=(\d+) trap_pc=0x([0-9a-f]+)', out)
if g:
    ov = int(g.group(1), 16); f = struct.unpack('<f', struct.pack('<I', ov))[0]
    print(f'OUT = 0x{ov:08x} (as float {f!r}, as signed int {struct.unpack("<i", struct.pack("<I", ov))[0]}), written {g.group(2)} time(s); fetches {g.group(4)}; traps {g.group(5)}')
if a.words and (O / 'dump.bin').exists():
    d = (O / 'dump.bin').read_bytes()
    for item in a.words.split(','):
        ad, cnt = item.split(':'); ad = int(ad, 0); cnt = int(cnt, 0)
        ws = struct.unpack_from(f'<{cnt}I', d, ad)
        print(f'memory 0x{ad:06x}: ' + ' '.join(f'0x{x:08x}' for x in ws))
sys.exit(0 if m else 1)
