#!/usr/bin/env python3
"""xsim-only workaround for an xsim evaluation bug (found 11-22, see docs/XSIM_VS_VERILATOR.md).

xsim returns wrong values when the format table of fpnew_pkg, a packed array of packed structs, is read with a VARIABLE index
(FP_ENCODINGS[fmt].exp_bits gives 7 for every format; constant indices and a case statement are correct). This rewrites the four
functions that do so (fp_width, exp_bits, man_bits, bias) with constant-index case statements. Same values by construction.
Apply it only to a work copy used for xsim (never to the repository's RTL, Verilator and synthesis are not affected).

usage: fpga/xsim/xsim_workaround.py <work dir containing rtl/vendor/pulp_platform_fpnew/src/fpnew_pkg.sv>"""
import sys
from pathlib import Path

p = Path(sys.argv[1]) / 'rtl' / 'vendor' / 'pulp_platform_fpnew' / 'src' / 'fpnew_pkg.sv'
s = p.read_text()
OLD = [
("""    return FP_ENCODINGS[fmt].exp_bits + FP_ENCODINGS[fmt].man_bits + 1;""",
 """    return exp_bits(fmt) + man_bits(fmt) + 1;"""),
("""    return FP_ENCODINGS[fmt].exp_bits;""",
 """    case (fmt)   // constant indices: xsim mis-evaluates FP_ENCODINGS[<variable>]
      FP32: return FP_ENCODINGS[0].exp_bits;
      FP64: return FP_ENCODINGS[1].exp_bits;
      FP16: return FP_ENCODINGS[2].exp_bits;
      FP8: return FP_ENCODINGS[3].exp_bits;
      default: return FP_ENCODINGS[4].exp_bits;
    endcase"""),
("""    return FP_ENCODINGS[fmt].man_bits;""",
 """    case (fmt)
      FP32: return FP_ENCODINGS[0].man_bits;
      FP64: return FP_ENCODINGS[1].man_bits;
      FP16: return FP_ENCODINGS[2].man_bits;
      FP8: return FP_ENCODINGS[3].man_bits;
      default: return FP_ENCODINGS[4].man_bits;
    endcase"""),
("""    return unsigned'(2**(FP_ENCODINGS[fmt].exp_bits-1)-1); // symmetrical bias""",
 """    return unsigned'(2**(exp_bits(fmt)-1)-1); // symmetrical bias"""),
]
if 'xsim mis-evaluates' in s:
    print('already patched', p)
else:
    for a, b in OLD:
        assert s.count(a) == 1, a
        s = s.replace(a, b)
    p.write_text(s)
    print('patched', p)

# second workaround (hypothesis under test, see docs/XSIM_VS_VERILATOR.md): vfu.sv calls rd_ok() in continuous assigns; the function reads
# rd_v_q/rd_st_q/rd_elem_q, which are not arguments, and xsim may not re-evaluate the assign when only those change (x_req stuck at 0).
# Inline the function so every operand is visible to the assign. Same logic by construction.
import re
v = Path(sys.argv[1]) / 'acc' / 'vfu.sv'
if v.exists():
    t = v.read_text()
    t2, n = re.subn(r'(?<![\w.])rd_ok\(\s*(\w+)\s*,\s*(\w+)\s*\)', r'(rd_v_q && rd_st_q == \1 && rd_elem_q == \2)', t)
    v.write_text(t2); print('inlined rd_ok in', v, n, 'calls')
