# =============================================================================
# amo.S — RV32A 原子指令自校验 (9 个 AMO + LR.W/SC.W 真预约)
# -----------------------------------------------------------------------------
# tohost = 0x90002000: 1 = 全部通过, (N+1) = 第 N 组失败
# 汇编: python tools/asm.py sim/prog/amo.S -o sim/prog/amo.hex
#
# 【LR.W / SC.W 的口径 (feat/isa-ac 更新, 原口径见 results/p6-a-extension.md)】
#   LR.W : 普通字加载语义 -> rd = 读回的字, 绝不改写内存; 同时**建立预约**
#          (预约寄存器 = {valid, 字地址}, 单核单地址预约, 规范允许)。
#   SC.W : 按预约判定成败:
#          · 预约有效且地址匹配 -> **成功**: rd=0, 把 rs2 写进内存;
#          · 否则               -> 失败:   rd=1, 不写内存。
#          无论成败, SC 之后预约一律失效; 新的 LR 覆盖旧预约。
#   (main 分支上 SC.W 恒失败 —— 那是"规范允许的单核简化"。本分支实现了
#    真预约寄存器, 第 13~16 组就是它的定向回归。)
#   【历史 (W-04, 2026-10-11)】原来 LR/SC 零覆盖, 而 LSU 的写使能只由相位
#   决定、与算子无关 ⇒ LR.W 到了写相会把刚读到的字写成 0。修法是把 LR/SC
#   的写使能整个关掉 (保留至今), SC 的写路径在本分支按预约重新打开。
#
# 【编码已交叉验证】本文件的 AMO 助记符经 GNU gas (-march=rv32ima) 逐位
#   比对, 与 main 分支手工 .word 的编码完全一致 (0x1002A3AF=lr.w 等)。
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
    amoadd.w t2, t1, (t0)
    li   t3, 100
    bne  t2, t3, fail1          # rd = 旧值
    lw   t4, 0(t0)
    li   t3, 123
    bne  t4, t3, fail1          # 内存 = 新值

    # -------- 2. amoswap: 旧值 x, 新值 = rs2 --------
    li   t1, 0x1111
    sw   t1, 0(t0)
    li   t1, 0x2222
    amoswap.w t2, t1, (t0)
    li   t3, 0x1111
    bne  t2, t3, fail2
    lw   t4, 0(t0)
    li   t3, 0x2222
    bne  t4, t3, fail2

    # -------- 3. amoor --------
    li   t1, 0xF0F0F0F0
    sw   t1, 0(t0)
    li   t1, 0x0F0F0F0F
    amoor.w t2, t1, (t0)
    lw   t4, 0(t0)
    li   t3, 0xFFFFFFFF
    bne  t4, t3, fail3

    # -------- 4. amoxor --------
    li   t1, 0xAAAA5555
    sw   t1, 0(t0)
    li   t1, 0xAAAA55AA
    amoxor.w t2, t1, (t0)
    lw   t4, 0(t0)
    li   t3, 0x000000FF
    bne  t4, t3, fail4

    # -------- 5. amoand --------
    li   t1, 0xF0F0F0F0
    sw   t1, 0(t0)
    li   t1, 0x0FF00FF0
    amoand.w t2, t1, (t0)
    lw   t4, 0(t0)
    li   t3, 0x00F000F0
    bne  t4, t3, fail5

    # -------- 6. 【有符号】amomin: -1 vs 1 -> min = -1 --------
    li   t1, -1
    sw   t1, 0(t0)
    li   t1, 1
    amomin.w t2, t1, (t0)
    li   t3, -1
    bne  t2, t3, fail6          # rd = 旧值 -1
    lw   t4, 0(t0)
    li   t3, -1
    bne  t4, t3, fail6          # 有符号 min(-1,1) = -1

    # -------- 7. 【有符号】amomax: 同一对操作数 -> max = 1 --------
    li   t1, -1
    sw   t1, 0(t0)
    li   t1, 1
    amomax.w t2, t1, (t0)
    lw   t4, 0(t0)
    li   t3, 1
    bne  t4, t3, fail7          # 与第 6 组形成对照

    # -------- 8. 【无符号】amominu: 0xFFFFFFFF vs 1 -> minu = 1 --------
    li   t1, -1
    sw   t1, 0(t0)
    li   t1, 1
    amominu.w t2, t1, (t0)
    lw   t4, 0(t0)
    li   t3, 1
    bne  t4, t3, fail8          # 若与第 6 组写混, 这两组必有一组失败

    # -------- 9. 【无符号】amomaxu: 同一对 -> maxu = 0xFFFFFFFF --------
    li   t1, -1
    sw   t1, 0(t0)
    li   t1, 1
    amomaxu.w t2, t1, (t0)
    lw   t4, 0(t0)
    li   t3, -1
    bne  t4, t3, fail9

    # -------- 10. 边界: 0x80000000 vs 0x7FFFFFFF (两套语义完全相反) --------
    lui  t1, 0x80000
    sw   t1, 0(t0)
    lui  t1, 0x7FFFF
    addi t1, t1, 0x7FF
    addi t1, t1, 0x1
    amomin.w t2, t1, (t0)       # amomin: 有符号 -> 0x80000000
    lw   t4, 0(t0)
    lui  t3, 0x80000
    bne  t4, t3, fail10

    lui  t1, 0x80000
    sw   t1, 0(t0)
    lui  t1, 0x7FFFF
    addi t1, t1, 0x7FF
    addi t1, t1, 0x1
    amominu.w t2, t1, (t0)      # amominu: 无符号 -> 0x7FFFFFFF
    lw   t4, 0(t0)
    lui  t3, 0x7FFFF
    addi t3, t3, 0x7FF
    addi t3, t3, 0x1
    bne  t4, t3, fail10

    # -------- 11. 加法回绕 --------
    li   t1, -1
    sw   t1, 0(t0)
    li   t1, 2
    amoadd.w t2, t1, (t0)       # 0xFFFFFFFF + 2 = 1 (回绕)
    lw   t4, 0(t0)
    li   t3, 1
    bne  t4, t3, fail11

    # -------- 12. LR.W: rd = 读回的字; **不得改写内存**; 并建立预约 --------
    li   t1, 0xDEADBEEF
    sw   t1, 0(t0)
    lr.w t2, (t0)
    li   t3, 0xDEADBEEF
    bne  t2, t3, fail12         # rd = 读回的字
    lw   t4, 0(t0)
    bne  t4, t3, fail12         # 内存必须没被改写 (历史 bug: 写相会写成 0)

    # -------- 13. SC.W 无预约 -> 失败: rd=1, 且不写内存 --------
    # (第 12 组的 LR 还占着预约 —— 先用一次"哑 SC"打异地址把它清掉:
    #  SC 无论成败都使预约失效, 之后这一次才是真正的"无预约 SC"。)
    addi t6, t0, 4              # t6 = 0x90003004 (预约地址之外)
    li   t1, 0xCAFEBABE
    sc.w t2, t1, (t6)           # 哑 SC: 地址不匹配 -> 失败, 同时清预约
    sc.w t2, t1, (t0)           # 无预约 -> 失败 -> rd = 1
    li   t3, 1
    bne  t2, t3, fail13         # 无预约 -> 失败 -> rd = 1
    lw   t4, 0(t0)
    li   t3, 0xDEADBEEF
    bne  t4, t3, fail13         # 失败不得写内存

    # -------- 14. LR + SC 同地址 -> 成功: rd=0, 内存 = rs2 --------
    # (本分支核心新语义 —— main 分支上这组期望的是 rd=1)
    lr.w t2, (t0)               # 建立预约 (地址 0x90003000, 上一组刚读过 DEADBEEF)
    li   t1, 0x11223344
    sc.w t2, t1, (t0)
    li   t3, 0
    bne  t2, t3, fail14         # 预约命中 -> 成功 -> rd = 0
    lw   t4, 0(t0)
    li   t3, 0x11223344
    bne  t4, t3, fail14         # 成功必须写内存 (rs2)

    # -------- 15. LR(A) + SC(B 异地址) -> 失败; 且失败后预约已失效 --------
    # 第 14 组之后预约已被那次 SC 清掉, 这里重新 LR 建立到 0(t0)。
    # (AMO 没有立即数字段, 访问 0x90003004 要先把地址算进寄存器。)
    lr.w t2, (t0)               # 预约 -> 0x90003000
    addi t6, t0, 4              # t6 = 0x90003004
    li   t1, 0x55667788
    sc.w t2, t1, (t6)           # 地址 != 预约地址 -> 失败
    li   t3, 1
    bne  t2, t3, fail15         # 失败 -> rd = 1
    lw   t4, 4(t0)
    bnez t4, fail15             # 失败不得写 4(t0) (此前该字恒 0)
    sc.w t2, t1, (t0)           # 失败的 SC 已把预约清掉 -> 这次也必须失败
    li   t3, 1
    bne  t2, t3, fail15
    lw   t4, 0(t0)
    li   t3, 0x11223344
    bne  t4, t3, fail15         # 0(t0) 仍是第 14 组写入的值

    # -------- 16. LR(A) + LR(B) + SC(B) -> 成功 (新 LR 覆盖旧预约) --------
    lr.w t2, (t0)               # 预约 -> 0x90003000
    lr.w t2, (t6)               # 预约 -> 0x90003004 (覆盖, t6 仍是 0x90003004)
    li   t1, 0x99AABBCC
    sc.w t2, t1, (t6)           # 预约地址匹配 -> 成功
    li   t3, 0
    bne  t2, t3, fail16         # 成功 -> rd = 0
    lw   t4, 4(t0)
    li   t3, 0x99AABBCC
    bne  t4, t3, fail16         # 内存 = rs2
    lw   t4, 0(t0)
    li   t3, 0x11223344
    bne  t4, t3, fail16         # 0(t0) 不受影响

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
  fail15:
    li   a0, 0x90002000
    li   a1, 16
    sw   a1, 0(a0)
    j    done
  fail16:
    li   a0, 0x90002000
    li   a1, 17
    sw   a1, 0(a0)
    j    done

  done:
    j    done
