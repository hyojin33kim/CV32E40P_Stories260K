#!/bin/bash
# V-A2 follow-up checks for acc/tb_axi_ext_rd (run after run.sh passes):
#   1. constraint probes: parameter sets outside the intended range (result is reported, not required to pass)
#   2. mutation checks: copies of axi_ext_rd.sv with one protection removed must make the test FAIL
# usage: acc/tb_axi_ext_rd/checks.sh      output: one line per check
set -u
cd "$(dirname "$0")"
M=mut; rm -rf $M; mkdir -p $M
echo "== constraint probes (expected: the unsupported sets fail)"
for cfg in "16 3 48 1" "16 3 48 3" "16 3 48 6" "64 3 48 8" "16 3 8 8"; do
  OUT=$M/probe CONFIGS="$cfg" bash run.sh 6 2>&1 | grep -E "^AXI_EXT_RD|build failed" | cut -c1-170 | sed "s/^/  /"
done
echo "== mutation checks (expected: FAIL)"
mutate() {   # name, sed expression
  mkdir -p $M/$1; sed "$2" ../axi_ext_rd.sv > $M/$1/axi_ext_rd.sv
  if cmp -s ../axi_ext_rd.sv $M/$1/axi_ext_rd.sv; then echo "  $1: mutation did not change the file"; return; fi
  DUT_DIR=$M/$1 OUT=$M/obj_$1 CONFIGS="16 3 48 8" bash run.sh 20 2>&1 | grep -E "^AXI_EXT_RD|^  FAIL" | head -3 | cut -c1-200 | sed "s/^/  $1: /"
}
mutate no_4k_check   's/ \&\& (base_ln_q\[7:0\] + 8.(cnt_q)) != 8.d0;/;/'
mutate no_err_flag   's/if (m_rresp_i != 2.b00) err_o <= 1.b1;//'
mutate no_credit     's/ \&\& (infl_q + 32.(cnt_q) <= 32.(CRED));/;/'
mutate wrong_word    's/cpu_off_q <= cpu_addr_q\[3:2\];/cpu_off_q <= cpu_addr_q[3:2] + 2'"'"'d1;/'
mutate no_td_limit   's/tg_n_q < ((\$clog2(TD) + 1).(TD))/1'"'"'b1/'
