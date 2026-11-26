#!/bin/bash
# Post-synthesis full-chip simulation of soc_chip in Verilator on a Linux server (D4, V-S1). No Vivado needed: it uses the bundle made by
# pack_handoff.sh (netlist, UNISIM sources, image, reference dump). Steps, each logged with wall time (rule R13):
#   0 checks   1 prep (netlist -> Verilator inputs)   2 build (the heavy step; peak memory logged)   3 speed probe   4 full run   5 dump compare
# usage: fpga/xsim/net_verilator/run_net_vl.sh <bundle dir (contains netlist_net.v unisims/ image_1.bin ref_dump.bin)> [workdir]
#   env: JOBS (default nproc)  BUILD_TIMEOUT (default 6h)  RUN_TIMEOUT (default 12h)  STEP=build|probe|run (start at a later step, reuses the build)
#        OPT (default -O1 for the C++ compiler: faster compile, memory-friendlier than -O3)  SPLIT (default 20000, Verilator --output-split)
# Results: <workdir>/{prep.log,build.log,build.time,probe.log,run.log,result.txt}. result.txt is the line to paste into docs/EXPERIMENT_LOG.md (E14).
set -u
B=$(readlink -f "${1:?bundle dir}"); WD=$(readlink -m "${2:-$B/work}"); mkdir -p "$WD"
H=$(cd "$(dirname "$0")" && pwd)
JOBS=${JOBS:-$(nproc)}; BUILD_TIMEOUT=${BUILD_TIMEOUT:-6h}; RUN_TIMEOUT=${RUN_TIMEOUT:-12h}; OPT=${OPT:--O1}; SPLIT=${SPLIT:-20000}
STEP=${STEP:-all}
log() { echo "[$(date +%T)] $*" | tee -a "$WD/steps.log"; }
log "== 0 checks"
for f in netlist_net.v image_1.bin ref_dump.bin; do [ -f "$B/$f" ] || { log "missing $B/$f"; exit 2; }; done
[ -d "$B/unisims" ] || { log "missing $B/unisims"; exit 2; }
( cd "$B" && sha256sum -c SHA256SUMS --quiet ) || { log "checksum mismatch in the bundle"; exit 2; }
command -v verilator >/dev/null || { log "verilator not found"; exit 2; }
log "verilator: $(verilator --version)   (tested with 5.038)"; log "memory: $(free -g | sed -n 2p)   cpus: $(nproc)   free disk: $(df -h "$WD" | tail -1 | awk '{print $4}')"
[ -n "${DRYRUN:-}" ] && { log "dry run: checks passed"; exit 0; }

if [ "$STEP" = all ]; then
  log "== 1 prep"
  mkdir -p "$WD/net"; cp "$B/netlist_net.v" "$WD/net/"
  python3 "$H/prep.py" "$WD/net" "$B/unisims" > "$WD/prep.log" 2>&1 || { log "prep failed: $(tail -3 "$WD/prep.log")"; exit 1; }
  tail -2 "$WD/prep.log" | cut -c1-200 | tee -a "$WD/steps.log"
  log "== 2 build (Verilator conversion + C++ compile; watch build.mem for the peak RSS in MB)"
  ( while sleep 20; do ps -eo rss,comm | awk '$2 ~ /verilator|cc1plus/ {s+=$1} END {print int(s/1024)}' >> "$WD/build.mem"; done ) & MON=$!
  S0=$(date +%s)
  timeout "$BUILD_TIMEOUT" verilator --cc --exe --build -j "$JOBS" --top-module net_top \
    -Wno-fatal -Wno-lint -Wno-style -Wno-STMTDLY -Wno-TIMESCALEMOD -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-PINMISSING -Wno-WIDTH \
    --no-timing --x-initial 0 --x-assign 0 --output-split "$SPLIT" --output-split-cfuncs "$SPLIT" \
    -CFLAGS "$OPT" -CFLAGS -DVNAME=Vnet_top -f "$WD/net/vl/files.f" "$H/net_sim.cpp" --Mdir "$WD/obj" > "$WD/build.log" 2>&1
  RC=$?; kill $MON 2>/dev/null
  echo "rc=$RC wall=$(( $(date +%s) - S0 )) s peak_rss_MB=$(sort -n "$WD/build.mem" 2>/dev/null | tail -1)" | tee "$WD/build.time"
  log "build: $(cat "$WD/build.time")"
  [ $RC -eq 0 ] || { log "build failed (rc=$RC): $(grep -m3 -E '%Error|error:' "$WD/build.log" | cut -c1-200)"; exit 1; }
fi

if [ "$STEP" = all ] || [ "$STEP" = build ] || [ "$STEP" = probe ]; then
  log "== 3 speed probe (200 loaded words, 2000 run cycles)"
  timeout 30m "$WD/obj/Vnet_top" "$B/image_1.bin" /dev/null +LOADMAX=200 +MAXCYC=2000 +PROGRESS=500 2>&1 | tee "$WD/probe.log" | tail -4 | tee -a "$WD/steps.log"
  TPS=$(grep -o '[0-9]* ticks/s' "$WD/probe.log" | tail -1 | awk '{print $1}')
  if [ -n "$TPS" ] && [ "$TPS" -gt 0 ]; then
    log "estimate: load 1,056,768 ticks + run ~157,500 cycles at $TPS ticks/s = $(( (1056768 + 160000) / TPS / 60 )) min (the probe loads 200 words, so the figure is rough)"
  fi
fi

log "== 4 full run (limit $RUN_TIMEOUT)"
S1=$(date +%s)
timeout "$RUN_TIMEOUT" "$WD/obj/Vnet_top" "$B/image_1.bin" "$WD/net_dump.bin" +PROGRESS=10000 > "$WD/run.log" 2>&1
RC=$?
log "run rc=$RC wall=$(( $(date +%s) - S1 )) s: $(grep -E 'NS DONE|NS WROTE' "$WD/run.log" | tr '\n' ' ')"
echo "== 5 compare"
{
  echo "D4 netlist simulation in Verilator, $(date -Is), host $(hostname), verilator $(verilator --version)"
  echo "build: $(cat "$WD/build.time" 2>/dev/null)"
  grep -E 'NS (loaded|DONE|WROTE)' "$WD/run.log"
  if [ -f "$WD/net_dump.bin" ] && cmp -s "$WD/net_dump.bin" "$B/ref_dump.bin"; then echo "RESULT: netlist dump == RTL Verilator dump (2 MiB)"
  elif [ -f "$WD/net_dump.bin" ]; then echo "RESULT: netlist dump DIFF: $(cmp -l "$WD/net_dump.bin" "$B/ref_dump.bin" | wc -l) bytes"
  else echo "RESULT: no dump (rc=$RC, see run.log)"; fi
  grep DONE "$B/INFO.txt" | head -1
} | tee "$WD/result.txt"
