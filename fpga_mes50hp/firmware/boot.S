    .text
    li sp, 0x90003ff0
    li t0, 0xA0000000
    li t1, 0x5A5A5A5A
    sw t1, 0(t0)

    li a0, 0x52
    jal ra, putc
    li a0, 0x49
    jal ra, putc
    li a0, 0x53
    jal ra, putc
    li a0, 0x43
    jal ra, putc
    li a0, 0x56
    jal ra, putc
    li a0, 0x20
    jal ra, putc
    li a0, 0x4F
    jal ra, putc
    li a0, 0x4B
    jal ra, putc
    li a0, 0x0D
    jal ra, putc
    li a0, 0x0A
    jal ra, putc

    li t0, 0x90002000
    li t1, 1
    sw t1, 0(t0)

echo_poll:
    li t0, 0xA000001C
    lw t1, 0(t0)
    beq t1, zero, echo_poll
    li t0, 0xA0000018
    lw a0, 0(t0)
    jal ra, putc
    j echo_poll

putc:
    li t0, 0xA0000014
putc_poll:
    lw t1, 0(t0)
    bne t1, zero, putc_poll
    li t0, 0xA0000010
    sw a0, 0(t0)
    ret
