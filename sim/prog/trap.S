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
    # 【必须用一个 handler 不会破坏的寄存器, 所以用 s1 而不是 t0】
    # handler 自己要用 t0 (csrr t0, mcause / mepc), 它一执行就把 t0 覆盖成 mcause。
    # 之后主程序那句 `csrw mtvec, s1` 若写成 t0, 就会把 mtvec 写坏 —— 实测写进去
    # 的值正好等于 mcause (11), 下一次陷阱直接跳到 0x00000000 跑飞。
    # 这个 bug 在"陷阱没接线"时永远不会暴露 (ecall 根本没陷入), P1 接线一完成才现形。
    li   s1, handler
    csrw mtvec, s1
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
    csrw mtvec, s1              # s1 仍是 handler 地址 (t0 会被 handler 破坏)
    csrr t1, mtvec
    bne  t1, s1, fail5

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

# ===========================================================================
# 【别挪走下面这段 —— 它是 MRET "精确性"的免费守卫】
# 上面这条 mret 的**紧邻后继指令**就是 fail1 的上报序列 (实测镜像:
#   0x800000ec mret  ->  0x800000f0 li a0,0x90002000 -> li a1,2 -> sw -> tohost=2)。
# MRET 的正确语义要求: 它在 EX 那一拍必须把 ID/EX 里"物理上紧随其后的指令"冲掉
# (core.sv:1049 id_ex_flush = trap_redir || br_redir_r, 而 trap_redir = trap_enter
#  || mret_taken), 并且 PC 改由 mepc 取指。
# 若将来有人把 mret_taken 从 id_ex_flush/trap_redir 里摘掉 (PITFALLS R1 那类改动),
# 或者在这条 mret 与 fail1 之间插一条无害指令, 后果是:
#   · 前一种: 落空指令会被真的执行 -> tohost 变成 2 -> tb_core_trap 立刻 FAIL
#   · 后一种: 守卫被静默削弱 (插进去的那条指令成了新的落空指令)
# 所以: 这条 mret 之后**必须**紧跟会写 tohost!=1 的序列, 且不许插入任何指令。
# ===========================================================================

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
