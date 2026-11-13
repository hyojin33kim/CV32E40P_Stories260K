#!/bin/bash
# G0: run locally-built (TC=/usr) baseline/profile ELFs through the RTL sim and validate.
set -eu
W="$(cd "$(dirname "$0")/.." && pwd)"
R="$W/g0/run_tc"
mkdir -p "$R"
cd "$W"
cp image.py cases.py validate.py stories260K.bin kv_*.bin ref_*.bin after_kv_*.bin bench_out.bin "$R/"
for m in baseline profile; do
  cp "g0/tc/$m.elf" "$R/firmware.elf"
  (cd "$R" && python3 image.py && python3 cases.py)
  p=base; [ "$m" = profile ] && p=out
  for t in 1 128 512; do
    obj/Vcv32e40p_top "$R/image_$t.bin" "$R/${p}_$t.bin" > "$R/${p}_$t.log" 2>&1 &
  done
  wait
done
cp g0/tc/baseline.elf "$R/firmware.elf"
cd "$R"
python3 image.py
OPENBLAS_NUM_THREADS=1 python3 validate.py > /dev/null
python3 - "$W/results.json" <<'EOF'
import json,sys
a=json.load(open('results.json'));b=json.load(open(sys.argv[1]))
for x,y in zip(a['cases'],b['cases']):
  print(f"ctx{x['context']}: base {y['baseline_cycles']}->{x['baseline_cycles']} ({x['baseline_cycles']/y['baseline_cycles']-1:+.2%})  prof {y['profile_cycles']}->{x['profile_cycles']}  exp_raw {y['exp_window_cycles_raw']}->{x['exp_window_cycles_raw']}  relL2 {x['logits_relative_L2']:.3e} (was {y['logits_relative_L2']:.3e}) argmax {x['argmax']} stack {x['stack_written_bytes']}")
print('pass',a['pass'])
EOF
