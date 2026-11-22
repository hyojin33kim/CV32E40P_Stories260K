#!/bin/bash
# FPU-only check: numpy IEEE expected vs xsim RTL vs xsim post-synthesis netlist (and Verilator on demand).
# Usage: fpga/xsim/run_fpu_test.sh [workdir]
set -u
W=$(cd "$(dirname "$0")/../.." && pwd); WD=${1:-/mnt/e/fpga_work/fpu_test}
[ -f "$WD/fpu_funcsim.v" ] || PIPE_DIST=1 python3 "$W/fpga/prepare.py" "$WD" > /dev/null
cp "$W/fpga/xsim/tb_fpu.sv" "$W/fpga/xsim/run_fpu_test.tcl" "$WD/"
python3 "$W/fpga/xsim/fpu_vectors.py" "$WD"
cd "$WD"
~/bin/vivado -mode batch -nojournal -log fpu.log -source run_fpu_test.tcl > fpu.out 2>&1
grep -E "TB_FPU|FPU TEST FINISHED|^ERROR" fpu.out | head
python3 - <<'EOF'
e = open('expect.hex').read().split(); v = [l.split() for l in open('vec.hex')]
names = {2: 'ADD', 3: 'MUL', 4: 'DIV', 5: 'SQRT', 12: 'I2F'}
for tag in ('rtl', 'net'):
    try: r = open(f'fpu_out_{tag}.hex').read().split()
    except FileNotFoundError: print(tag, 'missing'); continue
    bad = [i for i in range(len(e)) if i >= len(r) or r[i] != e[i]]
    by = {}
    for i in bad: by[names[int(v[i][0], 16)]] = by.get(names[int(v[i][0], 16)], 0) + 1
    print(f'{tag}: {len(e) - len(bad)}/{len(e)} correct, wrong by op {by}', '' if not bad else
          f'(first #{bad[0]}: {v[bad[0]]} -> {r[bad[0]] if bad[0] < len(r) else None}, expected {e[bad[0]]})')
EOF
