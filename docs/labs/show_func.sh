#!/bin/bash
# prints the disassembly of one function from a .dis file: show_func.sh <file.dis> <function> [max lines]
awk -v fn="<$2>:" '$2==fn{f=1} f&&NF==0{exit} f{print}' "$1" | head -${3:-60} | cut -c1-100
