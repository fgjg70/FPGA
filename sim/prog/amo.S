# =============================================================================
# amo.S — RV32A 原子指令自校验 (LR/SC 暂未实现, 只测 9 个 AMO)
# -----------------------------------------------------------------------------
# tohost = 0x90002000: 1 = 全部通过, (N+1) = 第 N 组失败
# 汇编: python tools/asm.py sim/prog/amo.S -o sim/prog/amo.hex
#
# 【为什么用 .word 手工编码】tools/asm.py 是迷你 RV32I 汇编器, 不认 AMO 助记符。
#   但它支持 .word <imm> 直接放原始指令字, 所以不必改汇编器。
#   编码已用 riscv-none-elf-gcc -march=rv32ia 实测确认
#   (见 results/p6-a-extension.md 第 2 节)。
#
# 字段: [31:27]funct5 [26]aq [25]rl [24:20]rs2 [19:15]rs1 [11:7]rd [6:0]=0101111
# 本文件用到的编码:
#   amoadd.w  t2, t1, (t0)  = 0x0062A3AF   (rs2=t1, rs1=t0, rd=t2)
#   amoswap.w t2, t1, (t0)  = 0x0862A3AF
#   amoor.w   t2, t1, (t0)  = 0x4062A3AF
#   amoxor.w  t2, t1, (t0)  = 0x2062A3AF
#   amoand.w  t2, t1, (t0)  = 0x6062A3AF
#   amomin.w  t2, t1, (t0)  = 0x8062A3AF
#   amomax.w  t2, t1, (t0)  = 0xA062A3AF
#   amominu.w t2, t1, (t0)  = 0xC062A3AF
#   amomaxu.w t2, t1, (t0)  = 0xE062A3AF
#
# 【重点】min/max 有两套符号语义, **只在负数/边界上暴露** —— 所以下面特意用
#   -1 与 1、0x80000000 与 0x7FFFFFFF 这些组合。用普通小正数测会全绿。
# =============================================================================

    .text
    # t0 = 数据区首地址 (用 lui+addi 手算, 避免依赖伪指令)
    lui  t0, 0x90003
    addi t0, t0, 0x100          # t0 = 0x90003100

    # -------- 1. amoadd: 旧值 100 + rs2 23 = 123, rd 应得旧值 100 --------
    li   t1, 100
    sw   t1, 0(t0)
    li   t1, 23
    .word 0x0062A3AF            # amoadd.w t2, t1, (t0)
    li   t3, 100
    bne  t2, t3, fail1          # rd = 旧值 100
    lw   t4, 0(t0)
    li   t3, 123
    bne  t4, t3, fail1          # 内存 = 100+23 = 123

    # -------- 2. amoswap: 旧值 x, 新值 = rs2, rd = 旧值 --------
    li   t1, 0x1111
    sw   t1, 0(t0)
    li   t1, 0x2222
    .word 0x0862A3AF            # amoswap.w t2, t1, (t0)
    li   t3, 0x1111
    bne  t2, t3, fail2          # rd = 旧值
    lw   t4, 0(t0)
    li   t3, 0x2222
    bne  t4, t3, fail2          # 内存 = 新值

    # -------- 3. amoor / amoxor / amoand --------
    li   t1, 0xF0F0F0F0
    sw   t1, 0(t0)
    li   t1, 0x0F0F0F0F
    .word 0x4062A3AF            # amoor.w
    lw   t4, 0(t0)
    li   t3, 0xFFFFFFFF
    bne  t4, t3, fail3

    li   t1, 0xAAAA5555
    sw   t1, 0(t0)
    li   t1, 0xAAAA55AA
    .word 0x2062A3AF            # amoxor.w
    lw   t4, 0(t0)
    li   t3, 0x000000FF
    bne  t4, t3, fail3

    li   t1, 0xF0F0F0F0
    sw   t1, 0(t0)
    li   t1, 0x0FF00FF0
    .word 0x6062A3AF            # amoand.w
    lw   t4, 0(t0)
    li   t3, 0x00F000F0
    bne  t4, t3, fail3

    # -------- 4. 【有符号】amomin: 旧值 -1, rs2 1 -> -1 < 1 -> min = -1 --------
    li   t1, -1
    sw   t1, 0(t0)
    li   t1, 1
    .word 0x8062A3AF            # amomin.w t2, t1, (t0)
    li   t3, -1
    bne  t2, t3, fail4          # rd = 旧值 -1
    lw   t4, 0(t0)
    li   t3, -1
    bne  t4, t3, fail4          # 内存 = -1 (有符号 min)

    # -------- 5. 【有符号】amomax: 旧值 -1, rs2 1 -> max = 1 --------
    li   t1, -1
    sw   t1, 0(t0)
    li   t1, 1
    .word 0xA062A3AF            # amomax.w
    lw   t4, 0(t0)
    li   t3, 1
    bne  t4, t3, fail5          # 有符号 max(-1,1) = 1

    # -------- 6. 【无符号】amominu: 旧值 -1(0xFFFFFFFF), rs2 1 -> minu = 1 --------
    #   这一条是与第 4 条的关键区别: 同一对操作数, 无符号 min 给 1 而不是 -1。
    #   若把两套语义写混, 第 4 与第 6 条必有一条失败。
    li   t1, -1
    sw   t1, 0(t0)
    li   t1, 1
    .word 0xC062A3AF            # amominu.w
    lw   t4, 0(t0)
    li   t3, 1
    bne  t4, t3, fail6          # 无符号 min(0xFFFFFFFF, 1) = 1

    # -------- 7. 【无符号】amomaxu: 同一对操作数 -> maxu = 0xFFFFFFFF --------
    li   t1, -1
    sw   t1, 0(t0)
    li   t1, 1
    .word 0xE062A3AF            # amomaxu.w
    lw   t4, 0(t0)
    li   t3, -1
    bne  t4, t3, fail7          # 无符号 max = 0xFFFFFFFF

    # -------- 8. 边界: 0x80000000 vs 0x7FFFFFFF (两套语义完全相反) --------
    lui  t1, 0x80000            # t1 = 0x80000000 (最小负数)
    sw   t1, 0(t0)
    lui  t1, 0x7FFFF
    addi t1, t1, 0x7FF
    addi t1, t1, 0x1            # t1 = 0x7FFFFFFF
    .word 0x8062A3AF            # amomin.w: 有符号 min(0x80000000, 0x7FFFFFFF) = 0x80000000
    lw   t4, 0(t0)
    lui  t3, 0x80000
    bne  t4, t3, fail8

    lui  t1, 0x80000
    sw   t1, 0(t0)
    lui  t1, 0x7FFFF
    addi t1, t1, 0x7FF
    addi t1, t1, 0x1
    .word 0xC062A3AF            # amominu.w: 无符号 min(0x80000000, 0x7FFFFFFF) = 0x7FFFFFFF
    lw   t4, 0(t0)
    lui  t3, 0x7FFFF
    addi t3, t3, 0x7FF
    addi t3, t3, 0x1
    bne  t4, t3, fail8

    # -------- 9. 加法回绕 (无符号语义) --------
    li   t1, -1
    sw   t1, 0(t0)
    li   t1, 2
    .word 0x0062A3AF            # amoadd.w: 0xFFFFFFFF + 2 = 1 (回绕)
    lw   t4, 0(t0)
    li   t3, 1
    bne  t4, t3, fail9

    # -------- 全部通过 --------
    li   a0, 0x90002000
    li   a1, 1
    sw   a1, 0(a0)
    j    done

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
  fail6:
    li   a0, 0x90002000
    li   a1, 7
    sw   a1, 0(a0)
    j    done
  fail7:
    li   a0, 0x90002000
    li   a1, 8
    sw   a1, 0(a0)
    j    done
  fail8:
    li   a0, 0x90002000
    li   a1, 9
    sw   a1, 0(a0)
    j    done
  fail9:
    li   a0, 0x90002000
    li   a1, 10
    sw   a1, 0(a0)
    j    done

  done:
    j    done
