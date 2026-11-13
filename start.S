.section .text.start
.global _start
_start:
 la sp, __stack_top
 li t0, 0x6000
 csrs mstatus, t0
 la t0, __bss_start
 la t1, __bss_end
1: bgeu t0,t1,2f
 sw zero,0(t0)
 addi t0,t0,4
 j 1b
2: csrwi mcountinhibit, 0
 call boot
3: j 3b
