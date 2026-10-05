# =============================================================================
# mmio.S - MMIO peripheral self-check (GPIO / cycle counter / UART)
# -----------------------------------------------------------------------------
# tohost = 0x90002000  (1 = 程序跑完)
# 读回的 UART 字节记录在:
#   0x90001010 / 0x90001014 / 0x90001018  <- 期望 0x4F 'O', 0x4B 'K', 0x0A LF
# 由 tb_soc 做持久比对 (把比较放在 tb 里, 避免混入其它变量)
#
# 设计约定: UART TX 忙时丢弃写入 -> 发前必须轮询 STAT;
#           UART RX 只有一个字节寄存器 (无 FIFO) -> 必须发一个读一个。
# =============================================================================

    .text
    # -------- test 1: cycle counter must advance --------
    li   t0, 0xA0000008
    lw   t1, 0(t0)
    lw   t2, 0(t0)
    beq  t1, t2, fail1

    # -------- test 2: counter high word must be 0 --------
    li   t0, 0xA000000C
    lw   t3, 0(t0)
    bne  t3, zero, fail2

    # -------- test 3: GPIO output --------
    li   t0, 0xA0000000
    li   t1, 0x5A5A5A5A
    sw   t1, 0(t0)

    # -------- test 4: UART TX+RX loopback, record readbacks --------
    li   s1, 0x90001010      # 记录基址
    li   t1, 0x4F            # 'O'
    jal  ra, loopback
    li   t1, 0x4B            # 'K'
    jal  ra, loopback
    li   t1, 0x0A            # LF
    jal  ra, loopback

    # -------- all pass --------
    li   a0, 0x90002000
    li   a1, 1
    sw   a1, 0(a0)
    j    done

# ---- putc: 等 TX 空闲后发送 t1[7:0] ----
putc:
    li   t0, 0xA0000014
putc_poll:
    lw   t5, 0(t0)
    bne  t5, zero, putc_poll
    li   t0, 0xA0000010
    sw   t1, 0(t0)
    ret

# ---- loopback: 发送 t1, 读回存入 [s1], s1 += 4 ----
loopback:
    mv   s0, ra
    jal  ra, putc
    li   t0, 0xA000001C      # RSTAT
lb_poll:
    lw   t5, 0(t0)
    beq  t5, zero, lb_poll
    li   t0, 0xA0000018      # RX
    lw   t6, 0(t0)
    sw   t6, 0(s1)           # 记录读回值
    addi s1, s1, 4
    mv   ra, s0
    ret

fail1:
    li   a0, 0x90002000
    li   a1, 2
    sw   a1, 0(a0)
    j    done
fail2:
    li   a0, 0x90002000
    li   a1, 3
    sw   a1, 0(a0)
    j    done

done:
    j    done
