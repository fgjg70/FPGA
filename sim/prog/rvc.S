# =============================================================================
# rvc.S — RV32C 压缩指令集系统级自校验 (feat/isa-ac 新增)
# -----------------------------------------------------------------------------
# tohost = 0x90002000: 1 = 全部通过, (N+1) = 第 N 组失败
# 汇编: python tools/asm.py sim/prog/rvc.S -o sim/prog/rvc.hex
#
# 覆盖 (RV32IMAC 全部 25 条压缩指令中与控制流/访存相关的每一类):
#   1)  c.li / c.addi        — CI 立即数 (6 位符号)
#   2)  c.mv / c.add         — CR 寄存器-寄存器
#   3)  c.andi/c.or/c.xor/c.sub — CA/CB 立即数与寄存器算符 (压缩窗口 x8..x15)
#   4)  c.slli/c.srli/c.srai — CB 移位
#   5)  c.swsp / c.lwsp      — CSS/CI 栈相对访存
#   6)  c.addi16sp           — 栈帧 10 位立即数
#   7)  c.lui                — 6 位 {17:12} 立即数 (含负数)
#   8)  c.addi4spn + c.sw/c.lw — CIW 与 CL/CS (rd'/rs1' 压缩窗口)
#   9)  c.beqz / c.bnez      — 压缩条件分支 (taken / not-taken / 回环)
#   10) c.j                  — 压缩无条件跳转 (跳过毒药序列)
#   11) c.jal + c.jr         — 压缩调用/返回: **链接值必须是 pc+2**
#       (若链接值错成 pc+4, 紧跟 c.jal 的那条哨兵指令会被跳过 -> 直接暴露)
#   12) c.jalr               — 压缩间接调用 (目标来自寄存器)
#   13) 非法压缩指令 (.half 0x0000, 规范定义非法) -> 陷阱:
#       mcause=2, mtval=0 (16 位原始编码零扩展), handler mepc+=2 跳过
#   14) c.ebreak             -> mcause=3, handler mepc+=2
#
# 【取指路径覆盖】程序里 16/32 位指令自然交错, 取指在 pc[1]=0/1 两种相位间
# 反复切换 (半字选择 + 字序推进); 压缩分支的回环目标落在字内两个半字槽上,
# 覆盖 BTB 索引 (pc[13:2]) 在同字两条压缩指令间的别名情形。
#
# 【编码可信度】本文件由 tools/asm.py 汇编; 该汇编器的全部压缩编码已与
# GNU gas (-march=rv32imac) 逐位比对一致 (见 .fpga-cache/probe_c.S 流程)。
# =============================================================================

    .text
    # -------- 安装陷阱处理程序 (先于一切, handler 只动 t0/t1) --------
    li   s10, handler
    csrw mtvec, s10
    li   t2, 0                  # 陷阱计数
    li   sp, 0x90001000         # 栈顶 (dmem 区, 向下生长)

    # -------- 1. c.li + c.addi: 5 + 3 = 8 --------
    c.li a1, 5
    c.addi a1, 3
    li   t0, 8
    bne  a1, t0, fail1

    # -------- 2. c.mv + c.add: 8 + 8 = 16 --------
    c.mv a2, a1
    c.add a2, a1
    li   t0, 16
    bne  a2, t0, fail2

    # -------- 3. c.andi/c.or/c.xor/c.sub (压缩窗口寄存器 s0/s1) --------
    c.li s0, 0x0F
    li   s1, 0xA0
    c.or s1, s0                 # 0xA0 | 0x0F = 0xAF
    li   t0, 0xAF
    bne  s1, t0, fail3
    c.xor s1, s0                # 0xAF ^ 0x0F = 0xA0
    li   t0, 0xA0
    bne  s1, t0, fail3
    c.sub s1, s0                # 0xA0 - 0x0F = 0x91
    li   t0, 0x91
    bne  s1, t0, fail3
    c.andi s0, 0x03             # 0x0F & 0x03 = 0x03
    li   t0, 0x03
    bne  s0, t0, fail3

    # -------- 4. c.slli/c.srli/c.srai --------
    c.li a2, 1
    c.slli a2, 4                # 1 << 4 = 16
    li   t0, 16
    bne  a2, t0, fail4
    c.srli a2, 2                # 16 >> 2 = 4
    li   t0, 4
    bne  a2, t0, fail4
    li   a3, -8
    c.srai a3, 1                # -8 >> 1 (算术) = -4
    li   t0, -4
    bne  a3, t0, fail4

    # -------- 5. c.swsp + c.lwsp (栈相对访存) --------
    addi sp, sp, -64
    li   t0, 0xCAFE
    c.swsp t0, 60(sp)
    c.lwsp a4, 60(sp)
    li   t1, 0xCAFE
    bne  a4, t1, fail5
    addi sp, sp, 64

    # -------- 6. c.addi16sp: sp -= 64 再还原 --------
    mv   t1, sp
    c.addi16sp -64
    sub  t6, sp, t1             # 期望 -64
    li   t0, -64
    bne  t6, t0, fail6
    c.addi16sp 64
    bne  sp, t1, fail6          # 还原后 sp 应与 t1 相同

    # -------- 7. c.lui (正/负) --------
    c.lui a3, 0x9000            # 0x9000 = 9 << 12
    c.addi a3, 31               # c.addi 单步最大 +31
    c.addi a3, 4                # 累计 +0x23 -> 0x9023
    li   t0, 0x9023
    bne  a3, t0, fail7
    c.lui a4, -4096             # -1 << 12 -> 0xFFFFF000
    srli t0, a4, 12             # 高 20 位 -> 0xFFFFF
    li   t1, 0xFFFFF
    bne  t0, t1, fail7

    # -------- 8. c.addi4spn + c.sw / c.lw (压缩窗口访存) --------
    c.addi4spn a2, 64           # a2 = sp + 64
    li   a5, 0xBEEF
    c.sw a5, 0(a2)              # sw 压缩: 数据 rs2' = a5(x15), 基址 a2(x12)
    c.lw a3, 0(a2)
    li   t0, 0xBEEF
    bne  a3, t0, fail8
    li   a4, 0xF00D
    c.sw a4, 4(a2)
    c.lw a3, 4(a2)
    li   t0, 0xF00D
    bne  a3, t0, fail8

    # -------- 9. c.bnez 回环 (3 次迭代) + c.beqz taken / c.bnez not-taken --------
    # (回环计数器必须用压缩窗口寄存器 x8..x15 —— 这里用 a4=x14;
    #  压缩分支只能跳 ±256B, 到 fail 处理器走近端蹦床 f9_near。)
    c.li a4, 3
rvc_loop:
    c.addi a4, -1
    c.bnez a4, rvc_loop         # 回环目标在半字槽上 (pc[1] 相位由布局决定)
    bnez a4, f9_near            # 循环结束 a4 必为 0 (32 位分支可远跳)
    c.beqz a4, beq_taken        # a4==0 -> taken, 跳过毒药
    li   t4, 0xBAD1
beq_taken:
    li   t0, 0xBAD1
    beq  t4, t0, f9_near        # 毒药必须没被执行
    c.bnez a4, f9_near          # a4==0 -> 不跳 (not-taken 路径)
    j    t9_pass
  f9_near:
    j    fail9
  t9_pass:

    # -------- 10. c.j 跳过毒药序列 --------
    c.j j_over
    li   t4, 0xBAD2
    li   t5, 0xBAD3
j_over:
    li   t0, 0xBAD2
    beq  t4, t0, fail10

    # -------- 11. c.jal + c.jr: 链接值 = pc+2 (哨兵指令必须执行) --------
    c.jal func1
    li   a4, 0x77               # 哨兵: 若链接值错成 pc+4, 这条被跳过
    li   t0, 0x77
    bne  a4, t0, fail11
    li   t0, 0x5A
    bne  a5, t0, fail11         # func1 的返回值

    # -------- 12. c.jalr: 间接调用 --------
    li   a2, func2
    c.jalr a2
    li   a3, 0x88               # 哨兵 (链接值 = pc+2)
    li   t0, 0x88
    bne  a3, t0, fail12
    li   t0, 0xA5
    bne  a5, t0, fail12

    # -------- 13. 非法压缩指令 (.half 0x0000) -> 陷阱 mcause=2, mtval=0 --------
    li   s11, 2                 # 期望 mcause
    .half 0x0000                # 规范定义的非法半字
    li   t1, 1
    bne  t2, t1, fail13         # 陷阱计数必须 = 1

    # -------- 14. c.ebreak -> 陷阱 mcause=3 --------
    li   s11, 3
    c.ebreak
    li   t1, 2
    bne  t2, t1, fail14

    # -------- 陷阱内自检 --------
    bne  s9, zero, fail13       # s9 = handler 内自检失败标记

    # -------- 全部通过 --------
    li   a0, 0x90002000
    li   a1, 1
    sw   a1, 0(a0)
    j    done

# ---------------------------------------------------------------------------
func1:
    li   a5, 0x5A               # 0x5A 超 c.li 的 6 位立即数范围, 用 32 位 li
    c.jr ra                     # 返回到 c.jal 的下一条 (pc+2)
func2:
    li   a5, 0xA5
    c.jr ra

# ---------------------------------------------------------------------------
# 陷阱处理程序: 只用 t0/t1; s9 = 自检失败标记; 跳过量 = 2 (本测试的陷阱
# 触发指令都是 16 位: 非法半字与 c.ebreak)
# ---------------------------------------------------------------------------
    .align 2                  # mtvec 要求 4 字节对齐 ({mtvec[31:2],2'b00})
handler:
    csrr t0, mcause
    bne  t0, s11, h_fail
    csrr t1, mtval
    bnez t1, h_fail             # 两种陷阱的 mtval 都应为 0
    c.addi t2, 1                # 陷阱计数 (压缩加法顺带再测一条)
    csrr t0, mepc
    c.addi t0, 2                # 跳过 16 位触发指令
    csrw mepc, t0
    mret
  h_fail:
    li   s9, 1
    mret

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
