# =============================================================================
# lu_bench.S — load-use 代价标定微基准 (C-2 的"几拍气泡"标尺)
# -----------------------------------------------------------------------------
# 【为什么要有这个程序 (2026-10-11 第二版)】
#   第一版用"两个阶段: 有冒险 / 插一条 nop 的无冒险对照"来量气泡数。C-2 落地后
#   发现那个对照**不再是零冒险**: 新语义把"load 在 MEM 且 ID 依赖它"也算停顿,
#   于是"load 后隔一条 nop 的消费者"(距离 2) 也会停 1 拍。旧语义下距离 2 是
#   完全免费的 —— 这就是 C-2 真实代价比"事件数 × 1 拍"更大的原因。
#   所以标尺必须**分别量距离 1 与距离 2**, 而不是只看一种。
#
# 【设计】三个阶段, 每组都是 4 条指令, 指令总数/load 数/分支数完全相同,
#         唯一差别是 add(消费者) 相对 load 的位置:
#     阶段 A (距离 3, 无冒险): lw / nop / nop / add
#     阶段 B (距离 2)        : lw / nop / add / nop
#     阶段 C (距离 1)        : lw / add / nop / nop
#   每组 4 条 x 8 组 + 2 条循环开销 = 34 条/轮; I = 128 轮; K*I = 1024 次冒险/阶段。
#   因此三个阶段的指令数**逐字相同**, 周期差只可能来自 load-use 停顿:
#     cycB - cycA = 1024 * (距离2 每险拍数)    旧语义 0, C-2 1
#     cycC - cycA = 1024 * (距离1 每险拍数)    旧语义 1, C-2 2
#   每阶段各自用 MMIO_CYCLE_LO (0xA0000008) 自量周期数, 写进日志区:
#     log[0] = cycA, log[1] = cycB, log[2] = cycC   (tb_sw +dump_words=3 打出)
#
# 【数据正确性 (防"停够了但数据错")】
#   8 个已知值 1..8 被**紧跟 load 的消费者**累加进 s2 (三个阶段都累加,
#   距离 3/2/1 全覆盖), 期望总和 = 3 * 128 * (1+..+8) = 3*128*36 = 13824。
#   任何一次 load 结果错 (陈旧值/0/错位/写优先旁路坏) 都会改变 s2 ->
#   写 tohost=3 -> tb_sw 直接 FAIL。注意消费者就是停顿时被扣住的那条指令,
#   所以这条 checksum 同时证明"停够"与"停完之后数据对"。
#
# 【断言 (tb_sw)】
#   +lu_bubbles=B        距离1 每险恰好 B 拍  => cycC-cycA == B*1024
#   +expect_hazards=N    每阶段冒险数 (本程序 = 1024)
#   +expect_d2_cost=N    距离2 总代价           => cycB-cycA == N (旧语义 N=0)
#   同时断言 n_stall_lu == B*N + expect_d2_cost (TB 侧独立复核)
#
# 结束约定: tohost = 0x90002000, 写 1 = PASS, 写 3 = checksum 不符。
# 汇编: python tools/asm.py sim/prog/lu_bench.S -o sim/prog/lu_bench.hex
# 运行: python sim/run_prog.py --imem sim/prog/lu_bench.hex \
#         --plus +lu_bubbles=2 +expect_hazards=1024 +expect_d2_cost=1024 +dump_words=3
# =============================================================================

    .text

    # ---- 常量准备 ----
    li   a0, 0xA0000008        # a0 = MMIO_CYCLE_LO
    li   a1, 0x90000800        # a1 = 数据基址
    li   a2, 0x90003000        # a2 = 日志区 (存三个阶段周期数)

    # ---- 数据: mem[a1 + 4k] = k+1 (k = 0..7) ----
    li   t0, 1
    sw   t0, 0(a1)
    li   t0, 2
    sw   t0, 4(a1)
    li   t0, 3
    sw   t0, 8(a1)
    li   t0, 4
    sw   t0, 12(a1)
    li   t0, 5
    sw   t0, 16(a1)
    li   t0, 6
    sw   t0, 20(a1)
    li   t0, 7
    sw   t0, 24(a1)
    li   t0, 8
    sw   t0, 28(a1)
    li   s2, 0                 # checksum (三个阶段连续累加)

# =============================================================================
# 阶段 A — 距离 3 (lw / nop / nop / add): 无 load-use 冒险, 作为基准曲线
# =============================================================================
    li   t6, 128
    lw   s3, 0(a0)
    nop
    nop

LOOPA:
    lw   t0, 0(a1)
    nop
    nop
    add  s2, s2, t0
    lw   t0, 4(a1)
    nop
    nop
    add  s2, s2, t0
    lw   t0, 8(a1)
    nop
    nop
    add  s2, s2, t0
    lw   t0, 12(a1)
    nop
    nop
    add  s2, s2, t0
    lw   t0, 16(a1)
    nop
    nop
    add  s2, s2, t0
    lw   t0, 20(a1)
    nop
    nop
    add  s2, s2, t0
    lw   t0, 24(a1)
    nop
    nop
    add  s2, s2, t0
    lw   t0, 28(a1)
    nop
    nop
    add  s2, s2, t0
    addi t6, t6, -1
    bne  t6, zero, LOOPA

    lw   s4, 0(a0)
    nop
    nop
    sub  s4, s4, s3            # cycA
    sw   s4, 0(a2)

# =============================================================================
# 阶段 B — 距离 2 (lw / nop / add / nop): 旧语义 0 拍, C-2 起 1 拍
# =============================================================================
    li   t6, 128
    lw   s3, 0(a0)
    nop
    nop

LOOPB:
    lw   t0, 0(a1)
    nop
    add  s2, s2, t0
    nop
    lw   t0, 4(a1)
    nop
    add  s2, s2, t0
    nop
    lw   t0, 8(a1)
    nop
    add  s2, s2, t0
    nop
    lw   t0, 12(a1)
    nop
    add  s2, s2, t0
    nop
    lw   t0, 16(a1)
    nop
    add  s2, s2, t0
    nop
    lw   t0, 20(a1)
    nop
    add  s2, s2, t0
    nop
    lw   t0, 24(a1)
    nop
    add  s2, s2, t0
    nop
    lw   t0, 28(a1)
    nop
    add  s2, s2, t0
    nop
    addi t6, t6, -1
    bne  t6, zero, LOOPB

    lw   s4, 0(a0)
    nop
    nop
    sub  s4, s4, s3            # cycB
    sw   s4, 4(a2)

# =============================================================================
# 阶段 C — 距离 1 (lw / add / nop / nop): 旧语义 1 拍, C-2 2 拍
# =============================================================================
    li   t6, 128
    lw   s3, 0(a0)
    nop
    nop

LOOPC:
    lw   t0, 0(a1)
    add  s2, s2, t0
    nop
    nop
    lw   t0, 4(a1)
    add  s2, s2, t0
    nop
    nop
    lw   t0, 8(a1)
    add  s2, s2, t0
    nop
    nop
    lw   t0, 12(a1)
    add  s2, s2, t0
    nop
    nop
    lw   t0, 16(a1)
    add  s2, s2, t0
    nop
    nop
    lw   t0, 20(a1)
    add  s2, s2, t0
    nop
    nop
    lw   t0, 24(a1)
    add  s2, s2, t0
    nop
    nop
    lw   t0, 28(a1)
    add  s2, s2, t0
    nop
    nop
    addi t6, t6, -1
    bne  t6, zero, LOOPC

    lw   s4, 0(a0)
    nop
    nop
    sub  s4, s4, s3            # cycC
    sw   s4, 8(a2)

# =============================================================================
# 数据正确性: 三个阶段被停顿的消费者累加出的 checksum
#   3 * 128 * (1+2+...+8) = 3 * 128 * 36 = 13824
# =============================================================================
    li   t1, 13824
    bne  s2, t1, fail

    li   a0, 0x90002000
    li   a1, 1
    sw   a1, 0(a0)
    j    done

fail:
    li   a0, 0x90002000
    li   a1, 3
    sw   a1, 0(a0)

done:
    j    done
