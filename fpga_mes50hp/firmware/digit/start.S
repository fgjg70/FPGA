    .section .text.init
    .globl _start
_start:
    .option norelax
    la sp, __stack_top
    la t0, __bss_start
    la t1, __bss_end
clear_bss:
    bgeu t0, t1, enter_main
    sw zero, 0(t0)
    addi t0, t0, 4
    j clear_bss
enter_main:
    call main
halt:
    j halt
