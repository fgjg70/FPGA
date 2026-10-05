    .text
    csrr  t0, mstatus
    csrw  mtvec, t0
    csrrsi t1, mstatus, 8
    ecall
    ebreak
    mret
    fence
    li    a0, 0x90002000
    li    a1, 1
    sw    a1, 0(a0)
done:
    j done
