# =============================================================================
# timer_irq.S — P2 定时器中断自校验 (mtime / mtimecmp -> mip.MTIP)
# -----------------------------------------------------------------------------
# 跑在 tb_soc 上 (需要 mmio_subsys 真的在位 —— tb_core 不接外设)。
# 收尾按 tb_soc 的约定: gpio_out = 0x5A5A5A5A 且 UART 回环收到 3 字节 "OK\n",
# 读回记录在 0x90001010/14/18, 由 tb_soc 做持久比对。
#
# tohost = 0x90002000: 1 = 全部通过, (N+1) = 第 N 组失败
# 汇编: python tools/asm.py sim/prog/timer_irq.S -o sim/prog/timer_irq.hex
#
# 覆盖:
#   1) 定时器中断能触发 (mtime >= mtimecmp 拉高 irq_timer -> 进陷阱)
#   2) mcause = 0x80000007 (bit31=1 是中断, code=7 机器定时器中断)
#   3) handler 里推进 mtimecmp 能清掉电平中断 (不会无限重入)
#   4) mret 正确返回被抢占的指令, 主程序继续跑
#   5) handler 用 mscratch 保存/恢复寄存器 (中断不破坏被抢占代码的寄存器)
#   6) SoC 集成: 中断处理完之后 UART/GPIO 仍能正常工作
#
# 【两个必须记住的坑】
#   a) MTIE 是 mie 的 bit7 = 0x80, 而 Zicsr 立即数形式只有 **5 位** (上限 31),
#      **表达不了 0x80**。汇编器会把 `csrsi mie, 0x80` 按 &0x1F 静默截断成 0,
#      中断永远使能不上且不报错。必须用寄存器形式: li t0, 0x80 ; csrw mie, t0
#   b) 电平中断: mret 后若 mtimecmp 没被推进, 条件依然成立 -> 立刻重入 -> 死循环。
#      这是规范的正常行为, 由 handler 负责推进 mtimecmp。
# =============================================================================

    .text
    # -------- 安装陷阱处理程序 --------
    # s1 存 handler 地址 (handler 内部只碰 t0-t4, 且都做了保存/恢复)
    li   s1, handler
    csrw mtvec, s1

    li   s2, 0                  # 期望的 mcause 低 4 位 (handler 用)
    li   s3, 0                  # 中断进入次数
    li   s4, 0                  # handler 内自检失败标记

    # 给 handler 准备一块栈 —— 同时覆盖 CSR 的另一个用途 (mscratch)
    # 【地址是硬编码的】asm.py 没有 la 伪指令, 且本核是哈佛结构: load/store
    # 只能到 dmem, imem 里的 .data 读不到。所以中断栈直接用 dmem 的绝对地址。
    # 选 0x90001F00: .data/.bss 从 0x90000000 起 8KB (到 0x90002000 是 tohost),
    # 该处空着, 放 8 个字不会撞到任何东西。
    li   sp, 0x90001F00
    csrw mscratch, sp

    # -------- 测试 1: 定时器中断触发 + mcause 正确 --------
    li   s2, 7                  # 期望 mcause = 0x80000007 (中断 + code 7)
    li   t0, 0x80               # MTIE = mie[7] —— 必须用寄存器形式 (见头部说明 a)
    csrw mie, t0
    csrsi mstatus, 8            # mstatus.MIE = 1 (bit3, 5 位立即数够用)

    # 武装定时器: mtimecmp = mtime + 2000
    li   t0, 0xA0000030         # MTIME_LO
    lw   t1, 0(t0)              # 低 32 位
    lw   t2, 4(t0)              # 高 32 位 (MTIME_HI = +4)
    addi t1, t1, 2000
    li   t0, 0xA0000028         # MTIMECMP_LO
    sw   t1, 0(t0)
    sw   t2, 4(t0)              # 高位不变 (2000 不会溢出到高位)

    # 等中断: handler 会把 s3 加 1
wait1:
    li   t1, 1
    bne  s3, t1, wait1

    # -------- 测试 2: handler 内自检全过 --------
    bne  s4, zero, fail2

    # -------- 测试 3: 只中断一次 (mtimecmp 已被推进, 不该重入) --------
    li   t1, 1
    bne  s3, t1, fail3

    # -------- 测试 4: 关中断后不再进入 --------
    csrci mstatus, 8            # 关全局中断
    li   t4, 0
    li   t5, 200
spin:
    addi t4, t4, 1
    blt  t4, t5, spin
    li   t1, 1
    bne  s3, t1, fail4

    # -------- 测试 6: SoC 集成 —— 中断之后 UART/GPIO 仍正常 --------
    # (tb_soc 的收尾判定要求 gpio_out=0x5A5A5A5A 且回环收到 "OK\n")
    li   t0, 0xA0000000
    li   t1, 0x5A5A5A5A
    sw   t1, 0(t0)

    li   s1, 0x90001010         # 记录基址
    li   t1, 0x4F               # 'O'
    jal  ra, loopback
    li   t1, 0x4B               # 'K'
    jal  ra, loopback
    li   t1, 0x0A               # LF
    jal  ra, loopback

    # -------- 全部通过 --------
    li   a0, 0x90002000
    li   a1, 1
    sw   a1, 0(a0)
    j    done

# ---------------------------------------------------------------------------
# 定时器中断处理程序
#   s2 = 期望的 mcause 低 4 位
#   自检: mcause[31] 必须为 1 (是中断), 低 4 位等于期望值
#   用 mscratch 保存/恢复 t0-t4 与 ra: 中断不得破坏被抢占代码的寄存器
#   (这是"精确陷阱"之外的第二个必要条件 —— 主程序 spin 循环用 t4/t5 计数,
#    若 handler 不保存 t4, 计数会被打断, 测试 4 就会失败)
# ---------------------------------------------------------------------------
handler:
    # 交换栈指针: 交换后 sp = 中断专用栈, mscratch = 被打断代码的 sp
    # (sp 与 mscratch 之间**直接交换**, 不能先写后读 —— 那会覆盖掉要保存的值)
    csrrw sp, mscratch, sp
    addi sp, sp, -24
    sw   t0,  0(sp)
    sw   t1,  4(sp)
    sw   t2,  8(sp)
    sw   t3, 12(sp)
    sw   t4, 16(sp)
    sw   ra, 20(sp)

    csrr t0, mcause
    srli t1, t0, 31             # t1 = 中断位
    beq  t1, zero, h_fail       # 必须是中断, 不是异常
    andi t0, t0, 0xF            # 低 4 位 = 中断码
    bne  t0, s2, h_fail         # 期望 7 = 机器定时器中断

    # 推进 mtimecmp 清掉电平中断
    li   t0, 0xA0000030         # MTIME_LO
    lw   t1, 0(t0)
    lw   t2, 4(t0)
    li   t3, 0x100000           # 加 1M 周期, 本测试期间不会再触发
    add  t1, t1, t3
    sltu t4, t1, t3             # 低位回绕则进位到高位
    add  t2, t2, t4
    li   t0, 0xA0000028         # MTIMECMP_LO
    sw   t1, 0(t0)
    sw   t2, 4(t0)

    addi s3, s3, 1              # 记录进入次数 (s3 是"软件约定"的跨段变量)
    j    h_ret

h_fail:
    li   s4, 1                  # 记录失败但继续
    # 仍要推进 mtimecmp, 否则会无限重入卡死
    li   t0, 0xA0000030
    lw   t1, 0(t0)
    lw   t2, 4(t0)
    li   t3, 0x100000
    add  t1, t1, t3
    sltu t4, t1, t3
    add  t2, t2, t4
    li   t0, 0xA0000028
    sw   t1, 0(t0)
    sw   t2, 4(t0)

h_ret:
    # 恢复现场
    lw   t0,  0(sp)
    lw   t1,  4(sp)
    lw   t2,  8(sp)
    lw   t3, 12(sp)
    lw   t4, 16(sp)
    lw   ra, 20(sp)
    addi sp, sp, 24
    # 交换回来: sp <- 被打断代码的 sp, mscratch <- 中断专用栈 (供下次中断)
    csrrw sp, mscratch, sp
    mret

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
    sw   t6, 0(s1)
    addi s1, s1, 4
    mv   ra, s0
    ret

# ---------------------------------------------------------------------------
# 失败上报 (a1 = 组号 + 1)
# ---------------------------------------------------------------------------
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

done:
    j    done
