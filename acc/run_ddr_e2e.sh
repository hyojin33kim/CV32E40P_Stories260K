#!/bin/bash
# Memory-model study E2E (64 steps) with the DDR/SRAM model (SIM_DDR=1, default parameters):
# full offload with burst runs (ACC_RUN=16), RMSNorm weights in SRAM, word-copy embedding;
# and the SW baseline under the same DDR. Must stay bit-exact vs gen/out_64_Os.
set -u
cd "$(dirname "$0")/.."
[ -x obj_soc_ddr16/Vsoc_top ] || LOG=/dev/null ACC_RUN=16 MDIR=obj_soc_ddr16 TOP=soc_top ./build_sim.sh
[ -x obj_ddr/Vcv32e40p_top ] || LOG=/dev/null MDIR=obj_ddr ./build_sim.sh
SIM_DDR=1 GEN_SIM=$PWD/obj_soc_ddr16/Vsoc_top GEN_EXTRA="-DRMS_SRAM -DEMB_WORDS" GEN_HW=_l4v4r16_ddr_opt \
  GEN_ACC=full python3 gen/run_gen.py 64 > gen/run_64_ddr_full.txt 2>&1 &
SIM_DDR=1 GEN_SIM=$PWD/obj_ddr/Vcv32e40p_top GEN_OUT=$PWD/gen/ddr_sw \
  python3 gen/run_gen.py 64 > gen/run_64_ddr_sw.txt 2>&1 &
wait
for f in gen/out_64_O2u_accfull_l4v4r16_ddr_opt_L0_G1/result.json gen/ddr_sw/out_64_O2u/result.json; do
  python3 -c "import json;r=json.load(open('$f'));print('$f',{k:r[k] for k in ('pass','cycles_total','cycles_first','cycles_last','logits_kv_tokens_bitexact_vs_Os')})"
done
