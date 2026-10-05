# =============================================================================
# trap.S — Zicsr + 机器模式异常自校验
# -----------------------------------------------------------------------------
# tohost = 0x90002000: 1 = 全部通过, (N+1) = 第 N 组失败
# 汇编: python tools/asm.py sim/prog/trap.S -o sim/prog/trap.hex
#
# 覆盖:
#   1) ECALL      -> mcause = 11 (environment call from M-mode)
#   2) EBREAK     -> mcause = 3  (breakpoint)
#   3) 非法指令   -> mcause = 2  (illegal instruction)
#   4) 陷阱入口的 mstatus 语义: MIE 清 0, 原值进 MPIE
#   5) MRET 恢复:  MIE <- MPIE, 并跳回 mepc
#   6) 异常是精确的: mepc 指向触发指令本身 (handler 里 +4 跳过)
# =============================================================================

    .text
    # -------- 安装陷阱处理程序 --------
    li   t0, handler
    csrw mtvec, t0
    li   s2, 0                  # 陷阱计数
    li   s3, 0                  # 陷阱内自检失败标记

    # -------- 1. ECALL --------
    li   s0, 11                 # 期望 mcause
    ecall
    li   t1, 1
    bne  s2, t1, fail1

    # -------- 2. EBREAK --------
    li   s0, 3
    ebreak
    li   t1, 2
    bne  s2, t1, fail2

    # -------- 3. 非法指令 (全 0 不是合法编码) --------
    li   s0, 2
    .word 0x00000000
    li   t1, 3
    bne  s2, t1, fail3

    # -------- 4. 陷阱内自检必须全过 --------
    bne  s3, zero, fail4

    # -------- 5/6. 读回 CSR, 确认写进去了 --------
    csrw mtvec, t0              # t0 仍是 handler 地址
    csrr t1, mtvec
    bne  t1, t0, fail5

    csrsi mstatus, 8            # MIE = 1
    csrr t1, mstatus
    andi t1, t1, 8
    beq  t1, zero, fail5        # MIE 应为 1

    li   s0, 11
    ecall                       # 陷阱 -> MIE 清 0, MPIE <- 1
    # 回到这里说明 MRET 正常; MIE 应已被恢复为 1
    csrr t1, mstatus
    andi t1, t1, 8
    beq  t1, zero, fail5

    # -------- 全部通过 --------
    li   a0, 0x90002000
    li   a1, 1
    sw   a1, 0(a0)
    j    done

# ---------------------------------------------------------------------------
# 陷阱处理程序
#   s0 = 本条陷阱的期望 mcause (主程序在触发前设置)
#   自检: mcause 对得上; 陷阱入口 MIE 必须为 0; mepc 指向触发指令
# ---------------------------------------------------------------------------
handler:
    csrr t0, mcause
    bne  t0, s0, h_fail

    csrr t0, mstatus            # 陷阱入口 MIE 必须已经清 0
    andi t0, t0, 8
    bne  t0, zero, h_fail

    csrr t0, mepc               # 精确异常: mepc 指向触发指令本身
    addi t0, t0, 4              # 跳过它
    csrw mepc, t0
    addi s2, s2, 1
    mret

h_fail:
    li   s3, 1                  # 记录失败但继续, 让主程序统一上报
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret

# ---------------------------------------------------------------------------
# 失败上报 (a1 = 组号 + 1)
# ---------------------------------------------------------------------------
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
fail3:
    li   a0, 0x90002000
    li   a1, 4
    sw   a1, 0(a0)
    j    done
fail4:
    li   a0, 0x90002000
    li   a1, 5
    sw   a1, 0(a0)
    j    done
fail5:
    li   a0, 0x90002000
    li   a1, 6
    sw   a1, 0(a0)
    j    done

done:
    j    done
