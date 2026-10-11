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
# 【测试 7 —— R-01 定向复现】中断落在 load-use 停顿之后的那个**流水线气泡**上
#   触发序列 (旧 RTL, irq_take 没有"EX 段指令有效"判据):
#     cycle A: EX = lw, ID = 它的距离 1 消费者  -> load_use=1, pipe_stall=1
#     cycle B: EX = 刚注入的气泡 (id_ex_reg 把 pc 清成 0), pipe_stall=0
#              -> 旧 RTL 在气泡上接受中断: mepc = 0; 而 ID 里那条消费者被
#                 any_redir 同时冲掉、永不重执行; MRET 后 PC=0, imem 忽略高位
#                 (只用 addr[13:2]) -> 从程序开头重跑。
#   本测试的判据:
#     · handler 断言 mepc != 0 —— 否则直接写 tohost = 99 (一眼看出是 R-01)
#     · s5 记录"被打断的 add 在 mret 后确实重新执行"(见测试 7 代码)
#   DELTA 是**实测标定值**: 先让 mtimecmp 在 load-use 窗口那一拍/下一拍到期,
#   中断才会撞上气泡。改程序布局后必须用 +irq_trace 重新标定 (见文件末注释)。
#
# 【测试 8 —— R-02 定向】非法指令陷阱的 mtval 必须记录**触发指令的编码**。
#   trap.S 用的非法编码是 0x00000000, 与旧 RTL 的"mtval 恒 0"不可区分 -> 测不出来;
#   这里用非 0 的 0x0000007F (opcode 0b1111111 未定义), 三项一起断言:
#     mcause=2, mepc=非法指令地址, mtval=0x0000007F。
#   handler 的异常路径自检失败码: s11=1(mcause)/2(mepc)/3(mtval) -> tohost=111/112/113。
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

    # -------- 测试 7 (R-01): 中断不得落在 load-use 之后的气泡上 --------
    csrsi mstatus, 8            # 重新开全局中断 (测试 4 把它关了)

    li   s5, 0                  # 被中断指令"重执行"的证据 (见下)
    li   t0, 0x90001F00         # dmem 暂存区 (空着, 不撞任何东西)
    li   t1, 0x12345678
    sw   t1, 0(t0)              # 准备 load 的源数据

    # 武装定时器: mtimecmp = mtime + DELTA (DELTA 为实测标定值)
    li   t0, 0xA0000030         # MTIME_LO
    lw   t1, 0(t0)
    lw   t2, 4(t0)
    addi t1, t1, 9              # DELTA = 9 (标定见文件头说明)
    li   t0, 0xA0000028         # MTIMECMP_LO
    sw   t1, 0(t0)
    sw   t2, 4(t0)              # 高位不变 (DELTA 不会溢出到高位)

    # 【关键】紧接着放 load-use 对: lw 在 EX、距离 1 消费者在 ID -> 停顿一拍,
    # 下一拍 EX 是刚注入的气泡。中断必须**拒绝**在那一拍被接受。
    li   t0, 0x90001F00
    lw   t3, 0(t0)
    add  s5, s5, t3             # 距离 1 依赖 (load_use) —— 必须是这一条

    # 等中断 (handler 把 s3 加 1; 第 2 次中断)
    li   t1, 2
wait7:
    bne  s3, t1, wait7

    # 被打断的 add 必须在 mret 后**重新执行一次**: s5 = mem[0x90001F00]
    # (旧 RTL 会在气泡上陷入, 把这条 add 永久丢掉 -> s5 保持 0 或被清零)
    li   t3, 0x12345678
    bne  s5, t3, fail7

    # -------- 测试 8 (R-02): 非法指令的 mtval 必须记录**指令编码** --------
    # csr_file.sv 头注释承诺"非法指令放指令编码", 而旧 RTL 把 trap_tval 硬接 0
    # ⇒ mtval 恒 0。trap.S 用的是 0x00000000, 与"恒 0"不可区分, 所以一直没暴露;
    # 这里特意选**非 0** 的非法编码 0x0000007F (opcode 0b1111111 未定义)。
    # 期望: mcause=2, mepc=非法指令地址, mtval=0x0000007F。三者任一不符 -> tohost=111+s11。
    li   s10, 0                 # 异常进入次数
    li   s11, 0                 # 异常路径自检失败码 (1=mcause 2=mepc 3=mtval)
    auipc s7, 0                 # s7 = 本指令地址
    addi  s7, s7, 16            # 非法指令在 +16 (布局见下)
    li   s6, 0x7F               # 期望 mtval
    # 布局: +0 auipc / +4 addi / +8 lui(s6) / +12 addi(s6) / +16 .word 非法指令
    .word 0x0000007F
    # handler 用 mepc+4 跳过非法指令后回到这里
    li   t1, 1
    bne  s10, t1, fail8         # 必须恰好进 1 次异常陷阱
    bne  s11, zero, fail8       # handler 内的三项自检必须全过

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
    beq  t1, zero, h_exc        # bit31=0 -> 异常 (测试 8 的非法指令)
    # 【R-01 断言】中断被接受的那一拍, EX 段必须是一条**真指令** (mepc != 0)。
    # 旧 RTL 会在 load-use 之后注入的气泡上接受中断, 此时 id_ex_pc 被清成 0,
    # mepc 记下来就是 0 —— 这里当场抓住, 直接写 tohost=99 上报, 不再 mret
    # (避免带着坏 mepc 跑飞, 掩盖证据)。
    csrr t2, mepc
    beq  t2, zero, h_bad_mepc
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

# ---------------------------------------------------------------------------
# 异常路径 (测试 8 / R-02): 只支持非法指令 (mcause = 2)
#   s7 = 期望 mepc (非法指令地址), s6 = 期望 mtval (非法指令编码)
#   自检失败只记录到 s11 (1=mcause, 2=mepc, 3=mtval), 不跑飞; 主程序统一判定
#   成功/失败都按 mepc+4 跳过非法指令 —— 保证"精确异常"语义可继续被验证
# ---------------------------------------------------------------------------
h_exc:
    andi t0, t0, 0xF            # 去掉 bit31, 取异常码
    li   t1, 2                  # 2 = illegal instruction
    bne  t0, t1, h_exc_bad1
    csrr t2, mepc
    bne  t2, s7, h_exc_bad2     # mepc 必须指向触发指令本身
    csrr t2, mtval
    bne  t2, s6, h_exc_bad3     # mtval 必须是触发指令的编码 (R-02 的核心判据)
    addi s10, s10, 1            # 记录一次成功的异常陷阱
    j    h_exc_skip
h_exc_bad1:
    li   s11, 1
    j    h_exc_skip
h_exc_bad2:
    li   s11, 2
    j    h_exc_skip
h_exc_bad3:
    li   s11, 3
h_exc_skip:
    csrr t0, mepc
    addi t0, t0, 4              # 精确异常: 跳过触发指令
    csrw mepc, t0
    j    h_ret

# 【R-01 复现点】中断被接受在流水线气泡上 -> mepc = 0
# 直接上报 tohost = 99 并停住: tb_soc 会把 tohost 判成"第 98 组失败",
# 一眼就能从日志区分"R-01 复现"与其它失败。
h_bad_mepc:
    li   a0, 0x90002000
    li   a1, 99
    sw   a1, 0(a0)
h_bad_spin:
    j    h_bad_spin

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
fail7:
    li   a0, 0x90002000
    li   a1, 8
    sw   a1, 0(a0)
    j    done
# 测试 8 上报: 111/112/113 = handler 异常路径自检失败(mcause/mepc/mtval),
#              114 = 异常陷阱进入次数 != 1
fail8:
    li   a0, 0x90002000
    li   a1, 110
    add  a1, a1, s11
    bne  s11, zero, fail8_rep
    li   a1, 114
fail8_rep:
    sw   a1, 0(a0)
    j    done

done:
    j    done
