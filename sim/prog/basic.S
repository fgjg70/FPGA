# =============================================================================
# basic.S — 五级流水线综合自校验测试程序
# -----------------------------------------------------------------------------
# 覆盖: 算术/逻辑/移位/比较、前递(RAW)、load-use 停顿、分支、JAL/JALR、
#       字节/半字/字访存、非对齐跨字访存(硬件拆分)、x0 语义
#
# 结束约定 (tohost = 0x90001000, 见 rv32_pkg 地址映射):
#   写 1        -> 全部测试通过
#   写 (N + 1)  -> 测试 N 失败 (N = 1..6)
#   写完自旋在 done, testbench 观察到写入后结束仿真
#
# 汇编: python tools/asm.py sim/prog/basic.S -o sim/prog/basic.hex
# =============================================================================

    .text
    # -------- 测试 1: 基础算术 + 前递 (RAW, 背靠背依赖) --------
    li   t0, 5
    li   t1, 37
    add  t2, t0, t1          # 42  (t0/t1 刚从 li 写出 -> 需要前递)
    li   t3, 42
    bne  t2, t3, fail1

    # -------- 测试 2: load-use 停顿 (需要真停顿) --------
    li   t0, 0x90000800
    li   t1, 0x12345678
    sw   t1, 0(t0)
    lw   t2, 0(t0)           # load
    add  t3, t2, t0          # 紧接着使用 -> load-use 停顿 1 拍
    li   t4, 0xA2345E78      # 0x12345678 + 0x90000800
    bne  t3, t4, fail2
    j    t2ok
fail2:
    li   a0, 2
    j    fail
t2ok:

    # -------- 测试 3: 字节/半字访存 + 符号扩展 --------
    li   t0, 0x90000804
    li   t1, 0x000000FF
    sb   t1, 0(t0)           # 存 0xFF
    lb   t2, 0(t0)           # 有符号读 -> 0xFFFFFFFF
    li   t3, -1
    bne  t2, t3, fail3
    lbu  t4, 0(t0)           # 无符号读 -> 0x000000FF
    li   t5, 0xFF
    bne  t4, t5, fail3
    li   t1, 0x0000BEEF
    sh   t1, 2(t0)
    lh   t2, 2(t0)           # 0x0000BEEF 符号位为 1 -> 负数
    li   t3, -16657          # 0xFFFFBEEF
    bne  t2, t3, fail3
    lhu  t4, 2(t0)
    li   t5, 0xBEEF
    bne  t4, t5, fail3
    j    t3ok
fail3:
    li   a0, 3
    j    fail
t3ok:

    # -------- 测试 4: 非对齐访存 (硬件自动拆分) --------
    li   t0, 0x90000810      # 字对齐
    li   t1, 0xAABBCCDD
    sw   t1, 0(t0)           # 字节: [10]=DD [11]=CC [12]=BB [13]=AA
    li   t2, 0x11223344
    sw   t2, 4(t0)           # 字节: [14]=44 [15]=33 [16]=22 [17]=11
    # 跨字字读 (off=2): 字节 [12..15] = BB AA 44 33 -> 0x3344AABB
    lw   t3, 2(t0)
    li   t4, 0x3344AABB
    bne  t3, t4, fail4
    # 字内非对齐半字 (off=1, 不跨字): 字节 [11]=CC [12]=BB -> 0xBBCC, 符号位 1
    lh   t5, 1(t0)
    li   t6, -17460          # 0xFFFFBBCC
    bne  t5, t6, fail4
    # 无符号版本 -> 0x0000BBCC
    lhu  a1, 1(t0)
    li   a2, 0xBBCC
    bne  a1, a2, fail4
    # 跨字非对齐存储: 写 0xFFFF 到 off=3, 要拆成两拍写
    li   a3, 0x0000FFFF
    sh   a3, 3(t0)
    lbu  a4, 3(t0)           # 低字节落在原字
    li   a5, 0xFF
    bne  a4, a5, fail4
    lbu  a6, 4(t0)           # 高字节落在下一个字 (被覆盖前是 0x44)
    bne  a6, a5, fail4
    j    t4ok
fail4:
    li   a0, 4
    j    fail
t4ok:

    # -------- 测试 5: 分支前后向 + JAL/JALR --------
    li   s0, 0
    li   s1, 10
loop:
    addi s0, s0, 1
    blt  s0, s1, loop        # 后向分支, 循环 10 次
    li   s2, 10
    bne  s0, s2, fail5
    jal  ra, sub1            # 前向 JAL: ra = 下一条指令的地址
    j    after5              # 子程序返回后落在这里 -> 跳到 after5
sub1:
    li   s3, 77
    ret                      # jalr x0, 0(ra)
after5:
    li   s4, 77
    bne  s3, s4, fail5
    j    t5ok
fail5:
    li   a0, 5
    j    fail
t5ok:

    # -------- 测试 6: 移位/比较边界 --------
    li   t0, 1
    slli t1, t0, 31          # 0x80000000
    li   t2, -2147483648
    bne  t1, t2, fail6
    srai t3, t2, 31          # 全 1 -> -1
    li   t4, -1
    bne  t3, t4, fail6
    srli t5, t2, 31          # 逻辑右移 -> 1
    li   t6, 1
    bne  t5, t6, fail6
    slt  a1, t2, t0          # -2^31 < 1 -> 1
    li   a2, 1
    bne  a1, a2, fail6
    sltu a3, t2, t0          # 无符号: 0x80000000 > 1 -> 0
    bne  a3, zero, fail6
    j    t6ok
fail6:
    li   a0, 6
    j    fail
t6ok:

    # -------- 全部通过: 写 1 到 tohost --------
    li   a0, 0x90001000
    li   a1, 1
    sw   a1, 0(a0)
    j    done

fail:
    # a0 = 测试号, 写 (测试号 + 1) 到 tohost
    li   a1, 0x90001000
    addi a0, a0, 1
    sw   a0, 0(a1)
    j    done

done:
    j    done                # 自旋等待 TB 结束仿真

fail1:
    li   a0, 1
    j    fail
