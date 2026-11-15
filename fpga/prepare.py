#!/usr/bin/env python3
"""Copy the synthesizable RTL to a Windows-visible work directory and write files.tcl.

usage: fpga/prepare.py <work dir under /mnt/<drive>/...>
Source list = cv32e40p_fpu_manifest.flist minus simulation-only files (bhv/ tracer,
tb wrapper, sim clock gate) + fpga/cv32e40p_clock_gate_fpga.sv + acc/*.sv.
"""
import shutil, sys
from pathlib import Path

W = Path(__file__).resolve().parent.parent
D = Path(sys.argv[1]); D.mkdir(parents=True, exist_ok=True)
rtl = W / 'cv32e40p-master' / 'rtl'
SIM_ONLY = ('bhv/cv32e40p_sim_clock_gate.sv', 'bhv/include/cv32e40p_tracer_pkg.sv', 'bhv/cv32e40p_tb_wrapper.sv')
files, incs = [], []
for line in (W / 'cv32e40p-master' / 'cv32e40p_fpu_manifest.flist').read_text().splitlines():
    line = line.strip()
    if not line or line.startswith('//'): continue
    path = line.replace('${DESIGN_RTL_DIR}', 'rtl').replace('rtl/../', '')
    if path.startswith('+incdir+'):
        p = path[len('+incdir+'):]
        if p.startswith('bhv') or p.startswith('sva'): continue
        incs.append(p)
    elif not any(path.endswith(s) for s in SIM_ONLY):
        files.append(path)
# copy the RTL tree (vendor included) and the accelerator / FPGA sources
if (D / 'rtl').exists(): shutil.rmtree(D / 'rtl')
shutil.copytree(rtl, D / 'rtl')
(D / 'acc').mkdir(exist_ok=True); (D / 'fpga').mkdir(exist_ok=True)
for f in ('gemv_acc.sv', 'vfu_lane.sv', 'vfu.sv', 'soc_top.sv'):
    shutil.copy(W / 'acc' / f, D / 'acc' / f)
shutil.copy(W / 'fpga' / 'cv32e40p_clock_gate_fpga.sv', D / 'fpga')
shutil.copy(W / 'fpga' / 'synth.tcl', D)
files += ['fpga/cv32e40p_clock_gate_fpga.sv', 'acc/gemv_acc.sv', 'acc/vfu_lane.sv', 'acc/vfu.sv', 'acc/soc_top.sv']
for f in files:
    assert (D / f).exists(), f
with open(D / 'files.tcl', 'w') as o:
    o.write('set inc_dirs [list ' + ' '.join(incs) + ']\n')
    for f in files:
        o.write(('read_verilog ' if f.endswith('.v') else 'read_verilog -sv ') + f + '\n')
print(f'{len(files)} files, include dirs {incs} -> {D}')
