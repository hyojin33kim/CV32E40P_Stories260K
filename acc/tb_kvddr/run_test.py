#!/usr/bin/env python3
"""P0 (docs/DDR_ARCH_PLAN.md): attention QK/AV reads of a KV cache in DDR, layouts [t][kv_dim] (today) and head-major, ctx 128 and 512, and the
same pattern on-chip as a reference. Runs obj_axi_ddr/Vchip_axi_ddr_top (the board flow with the DDR model) once per configuration.
usage: acc/tb_kvddr/run_test.py       env: SIM_DDR_LAT (40), SIM_DDR_BW (12.8), TEST_OUT"""
import os, re, struct, subprocess, sys
from pathlib import Path
W = Path(__file__).resolve().parent.parent.parent
O = Path(os.environ.get('TEST_OUT', W / '.scratch' / 'kvddr')); O.mkdir(parents=True, exist_ok=True)
SIM = os.environ.get('TEST_SIM', str(W / 'obj_axi_ddr/Vchip_axi_ddr_top'))
subprocess.run(['env', 'SRC=acc/tb_kvddr/test_kv.c', f'OUT={O}/test_kv', 'CFLAGS_EXTRA=-O2', str(W / 'build.sh')], cwd=W, check=True, capture_output=True)
elf = (O / 'test_kv.elf').read_bytes()
phoff = struct.unpack_from('<I', elf, 28)[0]; sz, num = struct.unpack_from('<HH', elf, 42)
base = bytearray(0x200000)
for i in range(num):
    typ, off, va, pa, fs, ms, fl, al = struct.unpack_from('<8I', elf, phoff + i * sz)
    if typ == 1: base[pa:pa + fs] = elf[off:off + fs]
names = {0: 'DDR  [t][kv_dim] (today)', 1: 'DDR  head-major', 4: 'chip [t][kv_dim] (on-chip)', 5: 'chip head-major (on-chip)'}
print(f"DDR model: latency {os.environ.get('SIM_DDR_LAT', '40')}, {os.environ.get('SIM_DDR_BW', '12.8')} B/cycle")
rows = []
for ctx_bit, ctx in ((0, 128), (2, 512)):
    for cfg in (0, 1, 4, 5):
        c = cfg | ctx_bit
        m = bytearray(base); struct.pack_into('<I', m, 0x1afff0, c)
        img, dump = O / f'img{c}.bin', O / f'dump{c}.bin'; img.write_bytes(m)
        r = subprocess.run([SIM, str(img), str(dump), '50000000'], capture_output=True, text=True)
        d = dump.read_bytes(); qk, av, mark, calls, err = struct.unpack_from('<5I', d, 0x1aff00)
        mm = re.search(r'bursts=(\d+)\s+lines=(\d+)', r.stdout); b, ln = (int(mm.group(1)), int(mm.group(2))) if mm else (0, 0)
        print(f"ctx {ctx:3d} {names[cfg]:<28} QK {qk:>9,}  AV {av:>9,}  total {qk + av:>9,}  bursts {b:>7,} lines {ln:>8,} avg {ln / b if b else 0:5.2f}  calls {calls} err {err} done {mark == 0x600d600d}")
