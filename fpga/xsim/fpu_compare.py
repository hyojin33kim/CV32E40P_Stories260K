#!/usr/bin/env python3
"""Compare FPU result files with the expected values, per category (shared by run_fpu_test.sh (xsim) and run_fpu_verilator.sh).
usage: fpu_compare.py <vec.hex> <expect.hex> <cat.txt or -> <tag=result.hex> [...]
Prints "<tag>: <ok>/<total> correct" and, per failing category, the count and the first mismatches. Exit status 1 if anything is wrong or missing."""
import sys

vec = [l.split() for l in open(sys.argv[1])]
exp = open(sys.argv[2]).read().split()
if sys.argv[3] != '-':
    cat = open(sys.argv[3]).read().split('\n')[:len(exp)]
else:
    names = {2: 'ADD', 3: 'MUL', 4: 'DIV', 5: 'SQRT', 8: 'FLT', 11: 'F2I', 12: 'I2F'}
    cat = [names.get(int(v[0], 16) & 0xf, 'op?') for v in vec]
bad_total = 0
for spec in sys.argv[4:]:
    tag, path = spec.split('=', 1)
    try:
        res = open(path).read().split()
    except FileNotFoundError:
        print(f'{tag}: result file missing ({path})'); bad_total += 1; continue
    bad = [i for i in range(len(exp)) if i >= len(res) or res[i] != exp[i]]
    bad_total += len(bad)
    print(f'{tag}: {len(exp) - len(bad)}/{len(exp)} correct' + ('' if len(res) == len(exp) else f' (result lines {len(res)}, expected {len(exp)})'))
    by = {}
    for i in bad:
        by.setdefault(cat[i], []).append(i)
    for c, idx in sorted(by.items()):
        print(f'   {c}: {len(idx)} wrong of {sum(1 for x in cat if x == c)}')
        for i in idx[:3]:
            print(f'      #{i} op/a/b/c/flags={" ".join(vec[i])} -> {res[i] if i < len(res) else None}, expected {exp[i]}')
sys.exit(1 if bad_total else 0)
