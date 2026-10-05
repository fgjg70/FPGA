# =============================================================================
# m_ext.S - RV32M 乘除法自校验
# -----------------------------------------------------------------------------
# tohost = 0x90002000: 1 = 全部通过, (N+1) = 第 N 组失败
# 汇编: python tools/asm.py sim/prog/m_ext.S -o sim/prog/m_ext.hex
#
# 重点覆盖 RISC-V 明确定义、但最容易写错的边界:
#   除零   -> 商 = -1, 余数 = 被除数
#   溢出   -> INT_MIN / -1 => 商 = INT_MIN, 余数 = 0
#   REM    -> 符号跟 *被除数*
#   有符号除法 -> 截断向零 (不是向下取整)
# =============================================================================

    .text
    # -------- 1. MUL 基本 --------
    li   t0, 6
    li   t1, 7
    mul  t2, t0, t1
    li   t3, 42
    bne  t2, t3, fail1

    # -------- 2. MUL 只取低 32 位 --------
    li   t0, 0x00010000
    mul  t2, t0, t0          # 0x1_0000_0000 -> 低 32 位 = 0
    bne  t2, zero, fail2

    # -------- 3. MULHU 取高 32 位 --------
    mulhu t2, t0, t0         # 高 32 位 = 1
    li   t3, 1
    bne  t2, t3, fail3

    # -------- 4. 有符号乘法 (MUL / MULH) --------
    li   t0, -3
    li   t1, 5
    mul  t2, t0, t1
    li   t3, -15
    bne  t2, t3, fail4
    mulh t2, t0, t1          # (-15) 的高 32 位 = -1
    li   t3, -1
    bne  t2, t3, fail4

    # -------- 5. MULHSU (有符号 x 无符号) --------
    li   t0, -1              # 视作 -1
    li   t1, 2
    mulhsu t2, t0, t1        # (-1)*2 = -2 -> 高 32 位 = -1
    li   t3, -1
    bne  t2, t3, fail5

    # -------- 6. 有符号 DIV / REM: 截断向零, 余数符号跟被除数 --------
    li   t0, -20
    li   t1, 3
    div  t2, t0, t1          # -6  (向零截断; 向下取整会得 -7)
    li   t3, -6
    bne  t2, t3, fail6
    rem  t2, t0, t1          # -2
    li   t3, -2
    bne  t2, t3, fail6

    # -------- 7. 无符号 DIVU / REMU --------
    li   t0, -20             # 0xFFFFFFEC = 4294967276
    li   t1, 16
    divu t2, t0, t1          # 0x0FFFFFFE = 268435454   (算术右移 4 位)
    li   t3, 268435454
    bne  t2, t3, fail7
    remu t2, t0, t1          # 0xC = 12                (低 4 位)
    li   t3, 12
    bne  t2, t3, fail7

    # -------- 8. 除零边界 --------
    li   t0, 123
    li   t1, 0
    div  t2, t0, t1
    li   t3, -1              # 商 = 全 1
    bne  t2, t3, fail8
    rem  t2, t0, t1
    li   t3, 123             # 余数 = 被除数
    bne  t2, t3, fail8

    # -------- 9. 溢出边界 INT_MIN / -1 --------
    li   t0, 0x80000000
    li   t1, -1
    div  t2, t0, t1
    bne  t2, t0, fail9       # 商 = INT_MIN
    rem  t2, t0, t1
    bne  t2, zero, fail9     # 余数 = 0

    # -------- 10. 连乘 + 除法组合 (验证多周期除法不破坏流水线) --------
    li   t0, 1000
    li   t1, 1000
    mul  t2, t0, t1          # 1000000
    li   t3, 7
    div  t4, t2, t3          # 142857
    li   t5, 142857
    bne  t4, t5, fail10
    rem  t4, t2, t3          # 1
    li   t5, 1
    bne  t4, t5, fail10

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

done:
    j    done
