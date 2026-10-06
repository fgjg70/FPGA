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

---

# P3 · fmax 实验 B（2026-10-06）— BRAM imem 带来的新瓶颈：布局策略与 `cf` 预计算

## 背景

`IMEM_REG_READ` BRAM 化打通后（见 `p4-macro-failure.md` 5.1），关键路径的**终点
从 `u_pc/pc_reg[7]/D` 变成了 `u_imem/.../ADDRARDADDR[12]`**：

```
Source:      u_core/u_dmem/mem_reg_1/CLKBWRCLK         (RAMB36_X1Y5)
Destination: u_core/u_imem/rdata_reg_0/ADDRARDADDR[12] (RAMB36_X2Y4)
Data Path:   16.598ns (logic 5.425 = 32.7%, route 11.173 = 67.3%), 19 级
基线(comb):  16.045ns (logic 5.542 = 34.5%, route 10.503 = 65.5%)
```

即同一条 `dmem → LSU 提取 → 前递 → 分支比较 → pred_ok → pc_src → pc_next mux`
的链，现在**还要驱动 imem 的 BRAM 地址脚**。逻辑级数没变、逻辑反而略降，
**涨的全是布线**。路径上最贵的一跳是 `id_ex_ctrl.pc_sel`——**扇出 60，单跳 0.947ns**。

## 实验 B1：`place_design` 策略（每项实测，均 BUILD_OK、ticks 不变）

| 策略 | fmax | WNS | LUT | 适用配置 |
|---|---|---|---|---|
| `ExtraTimingOpt`（默认） | 58.4 | 2.879 | 2821 | regread |
| **`WLDrivenBlockPlacement`** | **58.9** | 3.022 | 2820 | **regread（最佳）** |
| `AltSpreadLogic_high` | 58.4 | 2.879 | 2821 | regread |

**只收 +0.5 MHz** → 光调布局不够，必须动逻辑。

## 实验 B2：控制流类型预计算（`cf`）

把 EX 段 6 处 `id_ex_ctrl.pc_sel == CONST` 的比较**移到 ID 段**算好，
寄存成 3 位 1-hot（`cf[0]`=条件分支 `cf[1]`=JAL `cf[2]`=JALR）带下来，
使 EX 段不再比较 `pc_sel`、`pc_sel` 扇出从 60 降下来。

| 配置 | 策略 | `cf` | fmax | LUT | CM/LUTs | 吞吐 |
|---|---|---|---|---|---|---|
| comb | ExtraTimingOpt | 无 | **61.2** | 4079 | 5.788e-4 | **144.4** |
| comb | ExtraTimingOpt | 有 | 60.5 | 4089 | 5.774e-4 | 142.8 |
| comb | WLDriven | 有 | 59.0 | 4088 | 5.776e-4 | 139.3 |
| regread | WLDriven | 无 | 58.9 | 2820 | 8.373e-4 | 139.1 |
| regread | WLDriven | **有** | **59.5** | 2820 | 8.373e-4 | **140.5** |
| regread | ExtraTimingOpt | 有 | 57.6 | 2819 | 8.376e-4 | 136.1 |

**结论：`cf` 帮 regread（+0.6 MHz）却拖累默认配置（−0.7 MHz）→ 按"
默认配置不进反退则回退"的纪律，已回退 `cf`。**
两条配置对布局策略的偏好正好相反（comb 爱 `ExtraTimingOpt`，regread 爱
`WLDrivenBlockPlacement`），说明差距已在**布局噪声量级**，继续调收益很小。

## 下一步若还要提 fmax（未做，留档）

按路径实测，剩下可动的只有**逻辑**，且都在同一条"load 结果 → 分支决策 → 取指地址"
的链上：

1. **`pred_ok` 的目标比较**：现在比较的是 mux 后的 `actual_target`。因为
   `!actual_taken ||` 已经门控，`actual_taken=1` 时 `actual_target == ex_pc_target`，
   所以可以直接比较 `ex_pc_target`，把一级 32 位 mux 移出比较路径。
2. **`pc_sel` 扇出**（已试 `cf`，与布局相互作用，见上表）。
3. **BTB 预测寄存一级**（`pc <= pred_target_r`）：能把 BTB 的组合查表移出
   `pc` 路径 —— 但会改变预测与指令的相位，属结构性改动，需重新验证配对
   （`p4-macro-failure.md` 5.1 的教训：取指相位一动就要逐拍实测，不能推理）。

> **判据**：以上任何一项都要**同时**报 comb 与 regread 的四项指标 ——
> 实测证明两者对同一改动的反应可以相反，只看一个配置会得出错误结论。

