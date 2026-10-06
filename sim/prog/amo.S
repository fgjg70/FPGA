# =============================================================================
# amo.S — RV32A 原子指令自校验 (9 个 AMO, 不含 LR/SC)
# -----------------------------------------------------------------------------
# tohost = 0x90002000: 1 = 全部通过, (N+1) = 第 N 组失败
# 汇编: python tools/asm.py sim/prog/amo.S -o sim/prog/amo.hex
#
# 【编码已逐条核对】(funct5 在 instr[31:27]; rs2=t1(6) rs1=t0(5) rd=t2(7) f3=010)
#   amoadd.w  0x0062A3AF   amoswap.w 0x0862A3AF   amoxor.w 0x2062A3AF
#   amoor.w   0x4062A3AF   amoand.w  0x6062A3AF   amomin.w 0x8062A3AF
#   amomax.w  0xA062A3AF   amominu.w 0xC062A3AF   amomaxu.w 0xE062A3AF
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

  done:
    j    done
