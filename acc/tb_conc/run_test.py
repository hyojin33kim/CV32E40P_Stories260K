#!/usr/bin/env python3
"""V-A3: runs acc/tb_conc/test_conc.c scenarios 1..4 (one simulator run each) on the SoC RTL sim and prints the verdicts.
usage: acc/tb_conc/run_test.py [scenarios, e.g. 1 2 3 4]      env: TEST_SIM (default obj_soc/Vsoc_top), TEST_OUT, TEST_MAXCYC
Scenarios 1 and 2 must PASS: no mismatch, no timeout, and at least one CPU pass ended while the accelerator was busy (real overlap).
Scenarios 3 and 4 start the second accelerator a third of the way into the first one (outside the firmware rule: the firmware polls busy
before the next command): the result is characterized and the first accelerator must have been busy when the second was started."""
import os, struct, subprocess, sys
from pathlib import Path

W = Path(__file__).resolve().parent.parent.parent
O = Path(os.environ.get('TEST_OUT', W / '.scratch' / 'conc')); O.mkdir(parents=True, exist_ok=True)
SIM = os.environ.get('TEST_SIM', str(W / 'obj_soc/Vsoc_top'))
scen = [int(a) for a in sys.argv[1:]] or [1, 2, 3, 4]
subprocess.run(['env', 'SRC=acc/tb_conc/test_conc.c', f'OUT={O}/test_conc', 'CFLAGS_EXTRA=-O2 -funroll-loops', str(W / 'build.sh')], cwd=W, check=True, capture_output=True)
elf = (O / 'test_conc.elf').read_bytes()
phoff = struct.unpack_from('<I', elf, 28)[0]; sz, num = struct.unpack_from('<HH', elf, 42)
base = bytearray(0x1020000)
for i in range(num):
    typ, off, va, pa, fs, ms, fl, al = struct.unpack_from('<8I', elf, phoff + i * sz)
    if typ == 1: base[pa:pa + fs] = elf[off:off + fs]
rc = 0
for s in scen:
    m = bytearray(base); struct.pack_into('<I', m, 0x1afff0, s)
    img, dump = O / f'img{s}.bin', O / f'dump{s}.bin'
    img.write_bytes(m)
    r = subprocess.run([SIM, str(img), str(dump), os.environ.get('TEST_MAXCYC', '300000000')], capture_output=True)
    d = dump.read_bytes()
    sc, gbad, vbad, cbad, to, evid, cycles, gc, vc, wc = struct.unpack_from('<10I', d, 0x1aff00)
    marker = struct.unpack_from('<I', d, 0x1aff00 + 40)[0]
    fin = marker == 0x600d600d
    what = 'CPU passes that ended while the accelerator was busy (of 6)' if s in (1, 2) else 'first accelerator busy when the second started'
    line = (f'scenario {s}: finished={fin} gemv mismatches {gbad}/128, vfu mismatches {vbad}/512, cpu mismatches {cbad}/256, timeouts '
            f'gemv={to & 1} vfu={(to >> 1) & 1}, {what}: {evid}, cycles {cycles:,} (blocking gemv {gc:,}, vfu {vc:,}, cpu work {wc:,})')
    if s in (1, 2):
        ok = fin and gbad == 0 and vbad == 0 and cbad == 0 and to == 0 and evid > 0
        line += ' -> ' + ('PASS' if ok else 'FAIL')
        rc |= 0 if ok else 1
    else:
        line += ' -> characterized' + ('' if evid else ' (INVALID: the first accelerator was not busy, no overlap happened)')
        rc |= 0 if evid else 1
    if r.returncode != 0: line += f' [simulator exit code {r.returncode}]'
    print(line)
sys.exit(rc)
