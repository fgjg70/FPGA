# P3 · fmax 还债 — 实验 A: 跳转目标专用加法器

**日期**：2026-10-05  **tag**：`p3a-jalr-addder`  **结论：保留（净赚）**

## 靶子是怎么选的（先测量，不猜）

`python tools/fpga_workflow.py profile --prog cm_rv32im` 实测停顿构成：

| 项 | 占比 | 说明 |
|---|---|---|
| load-use 停顿 | **6.5%** | 30,645 / 468,659 周期，最大项 |
| 重定向（预测错误）| 4.9% | 11,535 次 × 2 拍 |
| 乘除法忙 | 3.1% | 14,415 |
| 拆分访存 | 0.0% | — |

CPI 1.099，预测精度 88.7%。

注意：占比的**分母必须用 tb 的 cycles（468,659）**，不能用 CoreMark 的
`Total ticks`（423,527）—— 后者只统计 CoreMark 自己的计时区间，少了启动/收尾
的几万拍，会把占比系统性低估约 10%。

## 关键路径（P1 之后的实测）

```
Slack (MET) :  3.710ns        fmax = 61.4 MHz
Source:      u_core/u_dmem/mem_reg_3/CLKBWRCLK     ← BRAM 输出寄存器
Destination: u_core/u_pc/pc_reg[2]_rep__0/D        ← PC
Data Path:   16.125ns  (logic 5.268 = 32.7% | route 10.857 = 67.3%)
Logic Levels: 19  (CARRY4=4 LUT2=1 LUT3=3 LUT5=4 LUT6=7)
```

**布线占 67%** —— 这不是逻辑深度问题，是布局/扇出问题（与 `SKILL.md` §9.4 一致）。
所以"少一级逻辑"的真正价值往往在于**同时减少扇出与布线长度**。

## 改动

原写法取 ALU 的原始加法器输出 `ex_sum`，它已经绕过了 ALU 的结果 mux，但
**操作数 mux 仍在路径上**：`ex_a` 是 3:1（PC/ZERO/rs1）、`ex_b` 是 2:1（imm/rs2）。

而 BR/JAL/JALR 的 `alu_op` 恒为 ADD、操作数确定：BR/JAL 是 `pc + imm`，
JALR 是 `rs1 + imm`。所以给它们一条**只有 1 级 mux** 的专用加法器：

```systemverilog
wire [31:0] ex_ctrl_operand_a = id_ex_ctrl.pc_sel == PC_JR ? ex_rs1 : id_ex_pc;
wire [31:0] ex_ctrl_sum       = ex_ctrl_operand_a + id_ex_imm;
assign ex_pc_target = (id_ex_ctrl.pc_sel == PC_JR)
                      ? {ex_ctrl_sum[31:1], 1'b0}   // JALR 清最低位
                      : ex_ctrl_sum;
```

**零周期代价**，代价只是一个 32 位加法器。

## 实测结果

| 指标 | P1 基线 | 实验 A | 变化 |
|---|---|---|---|
| CoreMark/MHz | 2.3614 | 2.3614 | **0（ticks 完全相同 423,486）** |
| **fmax** | 61.4 MHz | **64.4 MHz** | **+4.9%** |
| CoreMark/LUTs | 6.019e-04 | 5.986e-04 | −0.6% |
| **绝对吞吐** | 145.0 | **152.1** | **+4.9%** |
| LUT | 3923 | 3945 | +22（+0.6%）|
| FF | 1333 | 1333 | 0 |

回归：**7 PASS**。

## 判定：保留

按 `metrics` 的既定规则（0.5% 阈值，赢 2 输 1 才留）判为 **TIE**：赢一项（fmax）、
输一项（CoreMark/LUTs −0.6%）、平一项（CoreMark/MHz）。规则本身提示
"TIE → 看赛题取向"。

**按赛题取向裁决：保留。** 理由：

- 赛题三项指标里 **fmax 是当前唯一大幅退步的**（78.4 → 61.4），把它挣回来是主线目标；
- 代价是 **+22 LUT（+0.6%）**，而换来 **+4.9% fmax 与 +4.9% 绝对吞吐** —— 
  用 0.6% 的一项换 4.9% 的两项，方向明确；
- **绝对吞吐**（= CoreMark/MHz × fmax，即每秒迭代次数）**+4.9%**，
  它是三项互相矛盾时的最终裁判。

> 纪律说明：这一步是"规则判 TIE、人做取舍"，所以理由必须写清楚 —— 
> 否则下一个会话看到 TIE 会不知道当初为什么留。

## 下一步线索

关键路径**换了位置**（说明本改动确实生效了）：

```
现在: u_core/u_dmem/mem_reg_1/CLKBWRCLK -> u_core/u_id_ex/rs1_data_reg[29]/D
      15.427ns (logic 5.368 = 34.8% | route 10.059 = 65.2%), 19 级
```

即 **load 结果 → 写回 mux → 前递 mux → ID/EX 的 rs1**，仍然是"load 结果落进
前递/写回路径"这一类问题（与 `HANDOFF.md` P3 描述的根因同源，只是终点从 PC
变成了 ID/EX 的输入寄存器）。

**要不要动它，取决于一笔必须先算清的账**：`HANDOFF.md` 的方案 1（load 结果寄存器
+ 专用前递通道）会把 **load-use 停顿 1→2 拍**，而 load-use 正好是当前最大项
**6.5%** → 加一倍约 **+30,645 周期 ≈ +6.5% 时间**。fmax 需至少涨 **6.9%**
（64.4 → 68.8 MHz）才刚打平；涨到 78.4 则是净赚约 +15%。
**所以做之前要先用 `profile` 的 cost_if_load_use_2cyc_pct 把账算出来，不能凭感觉。**
