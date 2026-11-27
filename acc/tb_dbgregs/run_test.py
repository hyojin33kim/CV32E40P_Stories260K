#!/usr/bin/env python3
"""Observation registers of the board top (acc/chip_axi_top.sv 0x200_0040 ..): output channel, last fetch address, fetch counter, trap counter.
Builds acc/tb_dbgregs/test_dbgregs.c, runs it on the board-flow simulation (obj_axi/Vchip_axi_top: everything through the AXI4-Lite slave) in two scenarios
and checks the DBGREGS line the simulator prints.
usage: acc/tb_dbgregs/run_test.py       env: TEST_SIM (default obj_axi/Vchip_axi_top), TEST_OUT"""
import os, re, struct, subprocess, sys
from pathlib import Path

W = Path(__file__).resolve().parent.parent.parent
O = Path(os.environ.get('TEST_OUT', W / '.scratch' / 'dbgregs')); O.mkdir(parents=True, exist_ok=True)
SIM = os.environ.get('TEST_SIM', str(W / 'obj_axi/Vchip_axi_top'))
subprocess.run(['env', 'SRC=acc/tb_dbgregs/test_dbgregs.c', f'OUT={O}/test_dbgregs', 'CFLAGS_EXTRA=-O1', str(W / 'build.sh')], cwd=W, check=True, capture_output=True)
elf = (O / 'test_dbgregs.elf').read_bytes()
phoff = struct.unpack_from('<I', elf, 28)[0]; sz, num = struct.unpack_from('<HH', elf, 42)
base = bytearray(0x1020000)
for i in range(num):
    typ, off, va, pa, fs, ms, fl, al = struct.unpack_from('<8I', elf, phoff + i * sz)
    if typ == 1: base[pa:pa + fs] = elf[off:off + fs]
dis = subprocess.run(['riscv64-unknown-elf-objdump', '-d', str(O / 'test_dbgregs.elf')], capture_output=True, text=True).stdout
m = re.search(r'^\s*([0-9a-f]+):\s+ffffffff\s', dis, re.M)
ill = int(m.group(1), 16) if m else None
print(f'illegal instruction at 0x{ill:08x}' if ill else 'illegal instruction: not found in the disassembly')
rc = 0
for s in (0, 1):
    mm = bytearray(base); struct.pack_into('<I', mm, 0x1afff0, s)
    img = O / f'img{s}.bin'; img.write_bytes(mm)
    r = subprocess.run([SIM, str(img), str(O / f'dump{s}.bin'), '2500000'], capture_output=True, text=True)
    g = re.search(r'DBGREGS out=0x([0-9a-f]+) out_cnt=(\d+) last_pc=0x([0-9a-f]+) fetch_cnt=(\d+) trap_cnt=(\d+) trap_pc=0x([0-9a-f]+)', r.stdout)
    if not g:
        print(f'scenario {s}: no DBGREGS line (exit {r.returncode}): {r.stdout[-200:]} {r.stderr[-200:]}'); rc = 1; continue
    out, cnt, lpc, fcnt, tcnt, tpc = int(g.group(1), 16), int(g.group(2)), int(g.group(3), 16), int(g.group(4)), int(g.group(5)), int(g.group(6), 16)
    done = 'DONE cycles' in r.stdout
    line = f'scenario {s}: done={done} out=0x{out:08x} out_cnt={cnt} last_pc=0x{lpc:08x} fetch_cnt={fcnt} trap_cnt={tcnt} trap_pc=0x{tpc:08x}'
    if s == 0:
        ok = done and out == 0xABCD0003 and cnt == 3 and tcnt == 0 and 0x01000080 <= lpc < 0x01004000 and fcnt > 10
    else:
        ok = (not done) and out == 0xABCD0003 and cnt == 3 and tcnt >= 1 and ill is not None and abs(tpc - ill) <= 32 and 0x01000000 <= lpc < 0x01000080
    print(line + ' -> ' + ('PASS' if ok else 'FAIL')); rc |= 0 if ok else 1
sys.exit(rc)
