# CoreMark 基线 v1 — 2026-10-05

## 结论

| 指标 | 值 |
|---|---|
| **CoreMark/MHz** | **0.826** |
| Total ticks (1 iteration) | 1,210,148 cycles |
| 综合资源 | 3499 LUT / 732 FF / 0 BRAM / 0 DSP |
| 隐含 fmax | ≈ 78.4 MHz (WNS +7.248 ns @ 20 ns 约束) |
| CoreMark/LUTs | 0.826 / 3499 = **2.36e-4** |

## 正确性证据

CoreMark 自校验 CRC 全部匹配官方期望值（2K / PERFORMANCE_RUN）：

| 项 | 实测 | 官方期望 |
|---|---|---|
| seedcrc | 0xe9f5 | 0xe9f5 |
| crclist | 0xe714 | 0xe714 |
| crcmatrix | 0x1fd7 | 0x1fd7 |
| crcstate | 0x8e3a | 0x8e3a |
| crcfinal | 0xe714 | 0xe714 |

无任何 `ERROR! ... crc` 输出 → 校验零错误。这是对 RV32I 内核 + 工具链 +
哈佛双存储器 + crt0 的一次端到端逐位验证。

## 复现

```bash
# 1) 构建 (iterations 可调)
python tools/build_sw.py sw/coremark/*.c -I sw/coremark \
    -D ITERATIONS=1 -D 'FLAGS_STR="-Os -march=rv32i -mabi=ilp32"' \
    -o sim/prog/coremark.hex
# 2) 仿真 (tb_sw 会把 dmem 日志缓冲区 dump 出来)
vsim -c -do "run -all; quit -f" work.tb_sw \
    +imem=<abs>/coremark.hex +dmem=<abs>/coremark.dmem.hex +max_cycles=50000000
```

## 说明

- `Total time (secs): 0` + `ERROR! Must execute for at least 10 secs` 是**仿真必然结果**：
  1 次迭代只有 121 万周期 = 24 ms @50MHz。赛题要求的 ≥10 秒只能在真实硬件上跑
  （需 ITERATIONS≈420+）。**但 CoreMark/MHz 与主频无关，仿真 1 次迭代即可得到
  准确值** —— 所以后续所有流水线优化都能在仿真里度量和验证。
- 当前是典型"教科书 5 级流水线"水平：分支在 EX 判定 → 每次 taken 分支 2 拍惩罚。
  参考量级：Cortex-M3/M4 ≈ 3.4，M7 ≈ 5.0，简单学术 5 级 ≈ 0.8–1.2。
- 提升杠杆排序（按预期收益）：
  1. **分支预测 (BTB + 动态方向预测)**：CoreMark 分支密集，预期 +80%~150%
  2. **I/D Cache**：当前 0 BRAM，两个 16KB 阵列全落分布式 RAM（占 2096 LUT），
     换 BRAM 既提升 CoreMark/LUTs 又减少访存停顿
  3. **M 扩展**：GCC 当前用 libgcc 的 `__mulsi3`/`__udivsi3`，预期 +5%~15%
