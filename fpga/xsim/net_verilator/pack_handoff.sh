#!/bin/bash
# Packs everything the company Linux server needs for the post-synthesis full-chip simulation in Verilator (D4, V-S1) that is NOT in git:
#   netlist_net.v      the synthesized functional netlist of soc_chip (fpga/synth.tcl, token NETLIST), 45 MB
#   unisims/*.v        the vendor UNISIM models of the primitive types the netlist uses (read by prep.py), from the Vivado installation
#   image_1.bin        the full-chip image (16 MiB) and ref_dump.bin, the dump of the RTL Verilator chip simulation (obj_chip) on that image
#   SHA256SUMS, INFO.txt
# usage (on the machine that has Vivado and the build): fpga/xsim/net_verilator/pack_handoff.sh [image.bin] [netlist dir] [unisim dir] [out tar]
set -eu
W=$(cd "$(dirname "$0")/../../.." && pwd); cd "$W"
IMG=$(readlink -f "${1:-prof/chip_full_opta_d2/image_1.bin}")
ND=${2:-/mnt/e/fpga_work/chip_net}
UNI=${3:-/mnt/h/2026.1/Vivado/data/verilog/src/unisims}
OUT=${4:-$ND/handoff_d4.tar.gz}
[ -f "$ND/netlist_net.v" ] || { echo "no $ND/netlist_net.v"; exit 2; }
[ -d "$UNI" ] || { echo "no unisim dir $UNI"; exit 2; }
[ -x obj_chip/Vsoc_chip ] || { echo "build the reference first: TOP=soc_chip ./build_sim.sh"; exit 2; }
S=$(mktemp -d "$ND/handoff.XXXXXX"); mkdir -p "$S/h/unisims"
python3 fpga/xsim/net_verilator/prep.py "$ND" "$UNI" > "$S/prep.out"          # also tells which primitive types are used (vl/unisim) + the own-model ones
for f in "$ND"/vl/unisim/*.v; do cp "$UNI/$(basename "$f")" "$S/h/unisims/"; done
for p in FDRE FDSE FDCE FDPE SRL16E; do cp "$UNI/$p.v" "$S/h/unisims/"; done   # prep.py checks that these exist, although prim_models.v replaces them
cp "$ND/netlist_net.v" "$S/h/"
cp "$IMG" "$S/h/image_1.bin"
obj_chip/Vsoc_chip "$IMG" "$S/h/ref_dump.bin" > "$S/ref.log" 2>&1
grep DONE "$S/ref.log" | head -1
( cd "$S/h" && sha256sum netlist_net.v image_1.bin ref_dump.bin unisims/*.v > SHA256SUMS )
{ echo "packed $(date -Is) from $(git rev-parse --short HEAD) ($(git branch --show-current))"; echo "image: $IMG"; grep DONE "$S/ref.log" | head -1
  echo "netlist: $(wc -c < "$ND/netlist_net.v") bytes; unisim files: $(ls "$S/h/unisims" | wc -l)"; echo "vivado: 2026.1 (unisim sources)"; } > "$S/h/INFO.txt"
tar -C "$S" -czf "$OUT" h
rm -rf "$S"
ls -la "$OUT"
echo "on the server:  git clone/checkout verification-followup; mkdir -p /data/d4 && tar -C /data/d4 -xzf $(basename "$OUT"); fpga/xsim/net_verilator/run_net_vl.sh /data/d4/h"
