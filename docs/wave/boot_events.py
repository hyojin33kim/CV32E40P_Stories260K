#!/usr/bin/env python3
"""Key events of one run from the CPU data-port trace of the Verilator chip sim (SIM_TRACE_CPU=<n>, file trace_verilator.txt).
usage: boot_events.py <trace_verilator.txt>
Prints, with cycle numbers counted from reset release (MMIO accesses to the accelerators are decoded inside soc_top and are NOT in this trace, so the GEMV and VFU lines say not found; use the waveform): first and last store of the start-up loop that clears .bss, first access to the stack, first
GEMV and VFU register access (0x3000_0000 / 0x3000_0040), the first command written to each, the number of commands, and the DONE write (0x2000_0000).
The address ranges are those of this firmware image (prof/chip_full_opta_d2): .bss 0x1b4174..0x1b4210 (fw.map), stack top 0x200000."""
import re, sys
ev = []
for line in open(sys.argv[1]):
    m = re.match(r'(\d+) REQ we=(\d) be=(\w+) a=(\w+) wd=(\w+)', line)
    if m: ev.append((int(m.group(1)), int(m.group(2)), int(m.group(4), 16), int(m.group(5), 16)))
def first(pred):
    for e in ev:
        if pred(e): return e
def last(pred):
    r = None
    for e in ev:
        if pred(e): r = e
    return r
# the .bss clear loop = the run of consecutive word stores (address +4, at most 8 cycles apart) that starts with the first store of the trace
loop = []
for e in ev:
    if not e[1]: continue
    if not loop or (e[2] == loop[-1][2] + 4 and e[0] - loop[-1][0] <= 8): loop.append(e)
    else: break
bss = lambda e: e in loop
stack = lambda e: 0x1f0000 <= e[2] < 0x200000
gemv = lambda e: 0x30000000 <= e[2] < 0x30000040
vfu = lambda e: 0x30000040 <= e[2] < 0x30000080
gcmd = lambda e: e[2] == 0x30000000 and e[1]
vcmd = lambda e: e[2] == 0x30000040 and e[1]
done = lambda e: e[2] == 0x20000000 and e[1]
print(f'data-port events in the trace: {len(ev)}; .bss clear loop: {len(loop)} stores')
for name, pred, which in [('first store of the .bss clear loop', bss, first), ('last store of the .bss clear loop', bss, last),
                          ('first access to the stack', stack, first), ('first access to the GEMV registers', gemv, first),
                          ('first GEMV command (write 0x3000_0000)', gcmd, first), ('first access to the VFU registers', vfu, first),
                          ('first VFU command (write 0x3000_0040)', vcmd, first), ('DONE write (0x2000_0000)', done, first)]:
    e = which(pred)
    print(f'{name:45s}: ' + (f'cycle {e[0]:>7d}  {"write" if e[1] else "read "} addr 0x{e[2]:08x} data 0x{e[3]:08x}' if e else 'not found'))
print(f'GEMV commands: {sum(1 for e in ev if gcmd(e))}, VFU commands: {sum(1 for e in ev if vcmd(e))}')
