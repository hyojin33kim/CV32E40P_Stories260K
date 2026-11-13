#!/bin/bash
set -eu
cd "$(dirname "$0")"
# Default: Ubuntu 24.04 apt gcc-riscv64-unknown-elf (13.2) + picolibc-riscv64-unknown-elf (1.8.6).
# HOLD numbers were made with GCC 14.2 + picolibc prefix; override TC to use another prefix.
TC=${TC:-/usr}
CC=$TC/bin/riscv64-unknown-elf-gcc
LIB=$TC/lib/picolibc/riscv64-unknown-elf
SRC=${SRC:-firmware.c}
OUT=${OUT:-firmware}
FLAGS="-march=rv32imfc_zicsr -mabi=ilp32f -Os -ffp-contract=off -fno-math-errno -fno-delete-null-pointer-checks -msmall-data-limit=0 -fstack-usage -I$LIB/include ${CFLAGS_EXTRA:-}"
$CC $FLAGS -c "$SRC" -o "$OUT.o"
$CC $FLAGS -nostdlib -Wl,--no-relax,-Map=${OUT}.map -T link.ld start.S "$OUT.o" -L$LIB/lib/rv32imf/ilp32f -lm -lc -lgcc -o ${OUT}.elf
$TC/bin/riscv64-unknown-elf-size -A ${OUT}.elf > ${OUT}_size.txt
$TC/bin/riscv64-unknown-elf-objdump -d ${OUT}.elf > ${OUT}.dis
