# =============================================================================
# amo_diag2.S — amoswap 单步诊断 (上一步 amo_diag 用同样方法定位了 amoadd 的 bug)
# -----------------------------------------------------------------------------
# tohost = 0x90002000, 写入的值就是"结论":
#   1 = 全部通过
#   2 = sw/lw 基础读写坏
#   3 = amoswap 的 rd 不等于旧值 0x1111
#   4 = amoswap 写回的新值不等于 rs2 (0x2222)
#   5 = rd 读到了新值 (方向反了)
#
# 编码: amoswap.w t2, t1, (t0) = 0x0862A3AF
#   funct5=00001(swap) [26]aq=0 [25]rl=0 rs2=6(t1) rs1=5(t0) f3=010 rd=7(t2) op=0x2F
# =============================================================================

    .text
    lui  t0, 0x90003
    addi t0, t0, 0x000          # t0 = 0x90003000

    # ---- 基础读写自检 ----
    li   t1, 0x1111
    sw   t1, 0(t0)
    lw   t4, 0(t0)
    li   t3, 0x1111
    bne  t4, t3, rep2

    # ---- amoswap: 旧值 0x1111, rs2 = 0x2222 ----
    li   t1, 0x2222
    .word 0x0862A3AF            # amoswap.w t2, t1, (t0)
    # rd 应当 = 旧值 0x1111
    li   t3, 0x1111
    bne  t2, t3, chk_dir        # 先看是不是"方向反了"
    # 内存应当 = 0x2222
    lw   t4, 0(t0)
    li   t3, 0x2222
    bne  t4, t3, rep4

    li   a0, 0x90002000
    li   a1, 1
    sw   a1, 0(a0)
    j    done

  chk_dir:
    # rd 不是旧值 —— 是不是拿到了新值 (方向反了)?
    li   t3, 0x2222
    beq  t2, t3, rep5
    li   a0, 0x90002000
    li   a1, 3
    sw   a1, 0(a0)
    j    done

  rep2:
    li   a0, 0x90002000
    li   a1, 2
    sw   a1, 0(a0)
    j    done
  rep4:
    li   a0, 0x90002000
    li   a1, 4
    sw   a1, 0(a0)
    j    done
  rep5:
    li   a0, 0x90002000
    li   a1, 5
    sw   a1, 0(a0)
    j    done

  done:
    j    done
