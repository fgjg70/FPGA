# =============================================================================
# amo.S — RV32A 原子指令自校验 (9 个 AMO + LR.W/SC.W)
# -----------------------------------------------------------------------------
# tohost = 0x90002000: 1 = 全部通过, (N+1) = 第 N 组失败
# 汇编: python tools/asm.py sim/prog/amo.S -o sim/prog/amo.hex
#
# 【LR.W / SC.W 的口径 (W-04, 2026-10-11)】
#   LR.W : 等价于一次普通字加载 -> rd = 读回的字, **绝不写内存**
#   SC.W : **恒失败** -> rd = 1, **绝不写内存**。
#          这是**规范合法**实现: 规范不要求 SC 一定成功 (没有 forward-progress
#          要求), 单核无 cache 的机器不需要预约寄存器。
#   【为什么必须测】原来 LR/SC 零覆盖, 而 LSU 的写使能只由相位决定、与算子无关
#   ⇒ LR.W 到了写相会把刚读到的字写成 0, SC.W 写 0 且 rd 拿旧内存值。
#   修前实测 (定向探针, 位集合): 0x3E = LR 改了内存 + SC rd/写内存全错;
#   修后: 1 (含本文件第 12/13/14 组)。
#
# 【编码已逐条核对】(funct5 在 instr[31:27]; rs2=t1(6) rs1=t0(5) rd=t2(7) f3=010)
#   amoadd.w  0x0062A3AF   amoswap.w 0x0862A3AF   amoxor.w 0x2062A3AF
#   amoor.w   0x4062A3AF   amoand.w  0x6062A3AF   amomin.w 0x8062A3AF
#   amomax.w  0xA062A3AF   amominu.w 0xC062A3AF   amomaxu.w 0xE062A3AF
#   lr.w  t2,(t0)     0x1002A3AF   (funct5=0b00010, rs2 字段为 0)
#   sc.w  t2,t1,(t0)  0x1862A3AF   (funct5=0b00011)
#
# 【重点】min/max 有两套符号语义, **只在负数/边界上暴露** —— 用普通小正数测会全绿:
#   旧值 -1 vs rs2 1  ->  有符号 min=-1/max=1 ; 无符号 min=1/max=-1
#   旧值 0x80000000 vs 0x7FFFFFFF -> 两套语义给出**完全相反**的答案
# =============================================================================

    .text
    lui  t0, 0x90003
    addi t0, t0, 0x000          # t0 = 0x90003000

    # -------- 1. amoadd: 100 + 23 = 123, rd = 旧值 100 --------
    li   t1, 100
    sw   t1, 0(t0)
    li   t1, 23
    .word 0x0062A3AF
    li   t3, 100
    bne  t2, t3, fail1          # rd = 旧值
    lw   t4, 0(t0)
    li   t3, 123
    bne  t4, t3, fail1          # 内存 = 新值

    # -------- 2. amoswap: 旧值 x, 新值 = rs2 --------
    li   t1, 0x1111
    sw   t1, 0(t0)
    li   t1, 0x2222
    .word 0x0862A3AF
    li   t3, 0x1111
    bne  t2, t3, fail2
    lw   t4, 0(t0)
    li   t3, 0x2222
    bne  t4, t3, fail2

    # -------- 3. amoor --------
    li   t1, 0xF0F0F0F0
    sw   t1, 0(t0)
    li   t1, 0x0F0F0F0F
    .word 0x4062A3AF
    lw   t4, 0(t0)
    li   t3, 0xFFFFFFFF
    bne  t4, t3, fail3

    # -------- 4. amoxor --------
    li   t1, 0xAAAA5555
    sw   t1, 0(t0)
    li   t1, 0xAAAA55AA
    .word 0x2062A3AF
    lw   t4, 0(t0)
    li   t3, 0x000000FF
    bne  t4, t3, fail4

    # -------- 5. amoand --------
    li   t1, 0xF0F0F0F0
    sw   t1, 0(t0)
    li   t1, 0x0FF00FF0
    .word 0x6062A3AF
    lw   t4, 0(t0)
    li   t3, 0x00F000F0
    bne  t4, t3, fail5

    # -------- 6. 【有符号】amomin: -1 vs 1 -> min = -1 --------
    li   t1, -1
    sw   t1, 0(t0)
    li   t1, 1
    .word 0x8062A3AF
    li   t3, -1
    bne  t2, t3, fail6          # rd = 旧值 -1
    lw   t4, 0(t0)
    li   t3, -1
    bne  t4, t3, fail6          # 有符号 min(-1,1) = -1

    # -------- 7. 【有符号】amomax: 同一对操作数 -> max = 1 --------
    li   t1, -1
    sw   t1, 0(t0)
    li   t1, 1
    .word 0xA062A3AF
    lw   t4, 0(t0)
    li   t3, 1
    bne  t4, t3, fail7          # 与第 6 组形成对照

    # -------- 8. 【无符号】amominu: 0xFFFFFFFF vs 1 -> minu = 1 --------
    li   t1, -1
    sw   t1, 0(t0)
    li   t1, 1
    .word 0xC062A3AF
    lw   t4, 0(t0)
    li   t3, 1
    bne  t4, t3, fail8          # 若与第 6 组写混, 这两组必有一组失败

    # -------- 9. 【无符号】amomaxu: 同一对 -> maxu = 0xFFFFFFFF --------
    li   t1, -1
    sw   t1, 0(t0)
    li   t1, 1
    .word 0xE062A3AF
    lw   t4, 0(t0)
    li   t3, -1
    bne  t4, t3, fail9

    # -------- 10. 边界: 0x80000000 vs 0x7FFFFFFF (两套语义完全相反) --------
    lui  t1, 0x80000
    sw   t1, 0(t0)
    lui  t1, 0x7FFFF
    addi t1, t1, 0x7FF
    addi t1, t1, 0x1
    .word 0x8062A3AF            # amomin: 有符号 -> 0x80000000
    lw   t4, 0(t0)
    lui  t3, 0x80000
    bne  t4, t3, fail10

    lui  t1, 0x80000
    sw   t1, 0(t0)
    lui  t1, 0x7FFFF
    addi t1, t1, 0x7FF
    addi t1, t1, 0x1
    .word 0xC062A3AF            # amominu: 无符号 -> 0x7FFFFFFF
    lw   t4, 0(t0)
    lui  t3, 0x7FFFF
    addi t3, t3, 0x7FF
    addi t3, t3, 0x1
    bne  t4, t3, fail10

    # -------- 11. 加法回绕 --------
    li   t1, -1
    sw   t1, 0(t0)
    li   t1, 2
    .word 0x0062A3AF            # 0xFFFFFFFF + 2 = 1 (回绕)
    lw   t4, 0(t0)
    li   t3, 1
    bne  t4, t3, fail11

    # -------- 12. LR.W (新增): rd = 读回的字; **不得改写内存** --------
    li   t1, 0xDEADBEEF
    sw   t1, 0(t0)
    .word 0x1002A3AF            # lr.w t2, (t0)
    li   t3, 0xDEADBEEF
    bne  t2, t3, fail12         # rd = 读回的字
    lw   t4, 0(t0)
    bne  t4, t3, fail12         # 内存必须没被改写 (旧 RTL 会写成 0)

    # -------- 13. SC.W (新增): 恒失败 (规范允许) -> rd=1, 且不写内存 --------
    li   t1, 0xCAFEBABE
    .word 0x1862A3AF            # sc.w t2, t1, (t0)
    li   t3, 1
    bne  t2, t3, fail13         # 恒失败 -> rd = 1
    lw   t4, 0(t0)
    li   t3, 0xDEADBEEF
    bne  t4, t3, fail13         # 失败不得写内存 (旧 RTL 会写 0)

    # -------- 14. LR.W 紧跟 SC.W: SC 仍失败且不写 (本核无预约寄存器) --------
    .word 0x1002A3AF            # lr.w t2, (t0)
    li   t1, 0x11223344
    .word 0x1862A3AF            # sc.w t2, t1, (t0)
    li   t3, 1
    bne  t2, t3, fail14
    lw   t4, 0(t0)
    li   t3, 0xDEADBEEF
    bne  t4, t3, fail14

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
  fail10:
    li   a0, 0x90002000
    li   a1, 11
    sw   a1, 0(a0)
    j    done
  fail11:
    li   a0, 0x90002000
    li   a1, 12
    sw   a1, 0(a0)
    j    done
  fail12:
    li   a0, 0x90002000
    li   a1, 13
    sw   a1, 0(a0)
    j    done
  fail13:
    li   a0, 0x90002000
    li   a1, 14
    sw   a1, 0(a0)
    j    done
  fail14:
    li   a0, 0x90002000
    li   a1, 15
    sw   a1, 0(a0)
    j    done

  done:
    j    done
