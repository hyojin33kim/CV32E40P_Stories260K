#!/bin/bash
# Packs the files for the ZCU104 first runs (V-B0..V-B4) into one folder with checksums: bitstream, run script, three images and the dumps the
# Verilator chip simulation (obj_chip/Vsoc_chip) gives for them. Copy the folder to the board (scp / Jupyter upload) and follow README.txt there.
# usage: pynq/pack_board_kit.sh [bit dir (default /mnt/e/fpga_work/board_release_125_int8)] [out dir (default /mnt/e/fpga_work/board_kit)]
set -eu
W=$(cd "$(dirname "$0")/.." && pwd); cd "$W"
BD=${1:-/mnt/e/fpga_work/board_release_125_int8}; OUT=${2:-/mnt/e/fpga_work/board_kit}
[ -x obj_chip/Vsoc_chip ] || { echo "build the reference first: TOP=soc_chip ./build_sim.sh"; exit 2; }
( cd "$BD" && sha256sum -c SHA256SUMS --quiet ) || { echo "bitstream checksum mismatch"; exit 2; }
rm -rf "$OUT"; mkdir -p "$OUT"
cp "$BD/board.bit" "$BD/board.hwh" "$BD/README.txt" "$OUT/" ; mv "$OUT/README.txt" "$OUT/BITSTREAM_README.txt"
cp pynq/run_chip.py "$OUT/"
for n in 1 128 512; do
  cp prof/chip_full_opta_d2/image_$n.bin "$OUT/image_$n.bin"
  obj_chip/Vsoc_chip "$OUT/image_$n.bin" "$OUT/dump_sim_$n.bin" 2>&1 | grep DONE | sed "s/^/image_$n: /" | tee -a "$OUT/sim_cycles.txt"
done
cat > "$OUT/README.txt" <<EOF
ZCU104 first runs. Packed $(date -Is) from $(git rev-parse --short HEAD) ($(git branch --show-current)).
Bitstream: see BITSTREAM_README.txt (built from commit d3b41bf, NOT run on hardware before).
Order (do not skip ahead; stop at the first failure and send the output):
  1. Boot PYNQ, copy this folder to the board, cd into it, check:  sha256sum -c SHA256SUMS
  2. sudo python3 run_chip.py board.bit image_1.bin dump_sim_1.bin      (one token, the Verilator chip sim DONE is in sim_cycles.txt)
  3. then image_128.bin / dump_sim_128.bin, then image_512.bin / dump_sim_512.bin
Pass criteria per run: DONE_V equal to the simulation, 2 MiB dump byte-identical. CYCLES: the simulator prints "DONE cycles" counted by sim.cpp
(157,437 for image_1) and the xsim testbench counted 157,433 for the same image, so the counting differs by a few cycles; judge by the dump first,
and record CYCLES from the board next to both numbers.
Loading goes word by word through Python MMIO (about 0.5 M words): the first run may take minutes; this is not a failure.
Send back: the full terminal output of each run.
EOF
( cd "$OUT" && sha256sum board.bit board.hwh run_chip.py image_*.bin dump_sim_*.bin > SHA256SUMS )
ls -la "$OUT"; cat "$OUT/sim_cycles.txt"
