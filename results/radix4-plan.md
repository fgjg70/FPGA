# radix-4 除法器实测计划（分支 `exp/radix4-div`）

**状态**：⬜ 未实施（本文件是可直接执行的实施规格） **日期**：2026-10-08
**分支**：`exp/radix4-div`（从 `fa3562f` 拉出） **原子指令相关任务：暂停**

---

## 0. 为什么做这件事

`muldiv.sv:93-113` 已有一段**分析结论**：「待办 #8 (radix-4) 判定不做」，依据是——

| 项 | 实测值 |
|---|---|
| CoreMark 里除法条数 | **84 条** |
| 累计 busy | 2,897 拍（纯迭代 **2,687 拍 = 92.7%**）|
| 平均每次除法 | ~34.5 拍（迭代 ~32 拍，与 32 步恢复余数法一致）|
| radix-4 可省 | 每次 ~16 拍 × 84 = **~1,344 拍 = 0.29%** |
| 且 `stall_muldiv` 14,415 拍里**绝大部分是乘法的启动拍** | radix-4 帮不上 |

**本次任务：把这条"分析判定"变成"上板实测"** —— 拿到真实的 A/B 数字（四项指标 + tick），
再决定采不采纳。**注意收益极小，所以必须拿精确 tick 差（tick 是精确计数）才能判定。**

---

## 1. 基线（本分支实测，`results/coremark.csv` 末行 `bugfix-csr-gemm`）

| 指标 | 值 |
|---|---|
| CoreMark/MHz | **2.4209**（仿真 ticks **413,070**）|
| fmax | **69.6 MHz** |
| LUT / FF / BRAM | **2653 / 1234 / 8** |
| CoreMark/LUTs | **9.125e-4** |
| 绝对吞吐 | **168.4** |
| **上板 tick（1300 迭代）** | **536,943,384** ／ 10.74 s ／ `ila_ctrl=0x42` ／ CRC bit31=1 |
| 回归 | 默认 PASS 11 / `--imem_comb_read` PASS 11 |

**预测**：radix-4 省 ~1,344 拍 ⇒ 仿真 ticks ≈ **411,726**；上板 tick ≈ **535,599,000** 上下；
CM/MHz ≈ **2.4287**（+0.32%）。

---

## 2. 实施规格

### 2.1 `muldiv.sv`：加 radix-4 路径，`ifdef DIV_RADIX4` 宏门控，**默认关闭**

现有除法器（`:73-123`）是 **32 步无符号恢复余数法**：
`rem[32:0]`、`quo`、每拍 `rem_shift = {rem[31:0], dvnd[31]}` → `rem_sub = rem_shift - dvsr`
→ `rem_ge` → `rem_n` / `quo_n = {quo[30:0], rem_ge}`。

**radix-4（16 次迭代）**：
```systemverilog
wire [33:0] rem_shift2 = {rem[31:0], dvnd[31:30]};   // 34 位
wire [33:0] dvsr3      = {1'b0, dvsr} + {1'b0, dvsr, 1'b0};  // 3*dvsr (启动时算一次)
// 候选: 0 / 1*d / 2*d / 3*d
wire [33:0] s1 = rem_shift2 - {1'b0, dvsr};
wire [33:0] s2 = rem_shift2 - {1'b0, dvsr, 1'b0};
wire [33:0] s3 = rem_shift2 - dvsr3;
wire [1:0]  digit = !s1[33] ? 2'd1 : (!s2[33] ? 2'd2 : (!s3[33] ? 2'd3 : 2'd0));
// 注意: 用最高位判"够减"(无符号), 别用 >= 比较器 —— 减法器已经算了
wire [33:0] rem_n2 = (digit == 2'd0) ? rem_shift2
                   : (digit == 2'd1) ? s1
                   : (digit == 2'd2) ? s2 : s3;
wire [31:0] quo_n2 = {quo[29:0], digit};
// dvnd 每拍右移 2 位
```

**必须原样保留的协议（`muldiv.sv` 注释里有血泪史，改坏会挂测试）**：
1. `busy` 覆盖**启动那一拍**（否则 DIV 会在结果出来前离开 EX —— 实测 `m_ext` 第 6 组栽在这里）。
2. **末次迭代（radix-4: `cnt==1`，即 16 步中的最后一步）就要拉低 `busy_r` 并给出一拍 `done_r` 脉冲**，让结果恰好被 EX/MEM 捕获。
3. **除零 / 溢出仍是单周期特例**（同样要占一拍，`m_ext` 第 8 组栽在这里）。
4. 符号处理（`a_abs/b_abs/a_neg/b_neg` → 无符号除 → 符号修正）**两者完全一致**。
5. `cnt` 位宽与比较逻辑相应改成 16 步。
6. **radix-2 默认分支必须逐字保留**，不要"顺手重构"——基线要和现在逐位一致。

### 2.2 宏传递（四处，缺一处就会"测的不是这一版"）

| 文件 | 要求 |
|---|---|
| `muldiv.sv` | `` `ifdef DIV_RADIX4 `` 路径 |
| `fpga/build.tcl` | 环境变量 `DIV_RADIX4=1` → `append IMEM_DEFS " DIV_RADIX4=1"`；打印 `BUILD_DIV_RADIX4=1` / `BUILD_DIV_RADIX4_OFF=1` |
| **`fpga/build_ila.tcl`** | **已加好** ✅：`ILA_BUILD_DIV_RADIX4=1` / `ILA_BUILD_DIV_RADIX4_OFF=1`（上板闭环走这条，**不改它就白测**）|
| `tools/fpga_workflow.py` | 加 `--div-radix4`，接到 `verify` 与 `synth`；**并写进综合缓存指纹**（否则命中旧缓存拿到旧数字）|

> **自证纪律**（见 `skills/fpga-riscv-a100t/PITFALLS.md` R31）：这些打印串就是防"宏静默无效"的。
> 每次构建都要在日志里确认它出现了，且是**我们以为的那一版**。

---

## 3. 验收清单

| # | 命令 / 动作 | 期望 |
|---|---|---|
| 1 | `verify --force` | **PASS 11**（radix-2 回归不能坏）|
| 2 | `verify --force --imem_comb_read` | **PASS 11** |
| 3 | `verify --force --div-radix4` | **PASS 11** ← radix-4 正确性证明 |
| 4 | `verify --force --div-radix4 --imem_comb_read` | **PASS 11** |
| 5 | CoreMark ticks（radix-4）| ≈ **411,726**（基线 413,070，省 ~1,344）|
| 6 | `synth --tag div-r2-base --record --force` | 复现 LUT 2653 / fmax 69.6 |
| 7 | `synth --div-radix4 --tag div-r4 --record --force` | 四项指标对照 |
| 8 | **上板 radix-4**：`DIV_RADIX4=1 build_ila` + 抓取 | tick ≈ **535,599,000**，CRC bit31=1，≥10 s |
| 9 | 上板 radix-2（对照）| tick **536,943,384**（应逐位复现）|

**判据**：吞吐 = CM/MHz × fmax。
- 若 fmax 不掉：CM/MHz **+0.32%** ⇒ 净赚（很小但为正）。
- **若 fmax 掉 >0.32%** ⇒ 净亏（`muldiv` 输出正对 EX/MEM，加深组合逻辑有风险 —— 这正是要实测的关键点）。

---

## 4. 已知风险

1. **fmax**：radix-4 每次迭代多两个 34 位减法器 + 一个 4:1 mux。迭代期间流水线被 `busy` 冻结，所以**迭代路径本身不在流水线关键路径上**；但 `busy` 译码与出口 mux 可能变深。
2. **面积**：预计 LUT **+100 左右**（3 个减法器 vs 1 个）。
3. **`_global_defines()` 与缓存指纹**：忘了其中任一处，就会出现"以为测了 radix-4，实际是基线"的**静默错误**（本项目已踩过，R31）。
4. **ITERATIONS**：radix-4 会让设计更快一点点（−0.32%），上板时间 10.74 → ~10.71 s，**仍 ≥10 s** ✓ 无需重算；但若后续叠加其他优化要按 R35 重算。
