OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY
{
    IMEM (rx) : ORIGIN = 0x80000000, LENGTH = 16K
    DMEM (rw) : ORIGIN = 0x90000000, LENGTH = 16K
}
__stack_top = ORIGIN(DMEM) + LENGTH(DMEM);
SECTIONS
{
    .text : {
        KEEP(*(.text.init))
        *(.text .text.*)
        . = ALIGN(4);
    } > IMEM
    .data : {
        *(.srodata .srodata.* .rodata .rodata.*)
        *(.sdata .sdata.* .data .data.*)
        . = ALIGN(4);
    } > DMEM
    .bss (NOLOAD) : {
        __bss_start = .;
        *(.sbss .sbss.* .bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > DMEM
    ASSERT(__bss_end <= __stack_top - 2048, "Digit application needs at least 2 KiB stack")
    /DISCARD/ : { *(.comment .note* .eh_frame* .riscv.attributes) }
}
