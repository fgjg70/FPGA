# P3 · fmax 还债 — 实验 A: 跳转目标专用加法器

> ⚠️ **历史记录（2026-10-05）**：本文里的 `PASS 11` 是**当时**的回归基线；
> 现在是 **PASS 12**（新增 `tb_sw_lu_bench`，矩阵见 `tools/fpga_workflow.py` 的 `test_matrix()`）。
> 改动正文不改（改了就是伪造历史），只在引用时注意口径。

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

---

# P3 · fmax 实验 C（2026-10-07）— 冲 100 MHz 战役：58.9 → 69.2 MHz（+17.5%）

## 起点与目标

交付配置（imem/dmem 全 BRAM）实测 **58.9 MHz / WNS 3.022ns**。
100 MHz 需要数据通路 ≤ **9.5ns**；当时是 **16.35ns**，要砍 **7.1ns（43%）**。

先把关键路径**逐级**拆开（39 段，见下），发现它不是"某一级流水线的逻辑"，而是
**同一拍里串了三级**的组合链（中间没有任何触发器，已用路径上的 cell 清单证实）：

```
起点 = u_dmem/mem_reg_* 的 BRAM 输出寄存器
   └─ WB 段组合:  字节提取/符号扩展 → wb_data mux
        └─ EX 段组合: 前递 3:1 mux → 分支比较 → actual_taken/pred_ok
             └─ IF 段组合: pc_target 优先级 mux → pc_next mux
终点 = u_imem/*/ADDRARDADDR     （全路径 0 个 FDRE/FDCE）
```

两处**故意**的跨级耦合（都是为不牺牲 IPC 做的选择）：
1. **WB 组合 → EX 前递 mux**：为了"寄存读 dmem 不额外加停顿"，字节提取放在 WB 段
   组合完成（`lsu:199-212`），而 EX 前递 mux 直接引用它（`core.sv:440`）。
2. **EX 分支 → IF 的 `pc_next`**：为了"寄存读 imem 不产生气泡"，取指地址用组合的
   下一拍 PC（`core.sv:216`）。

## 已做的两步（都是零 IPC 代价、零面积代价）

### E1+E2：逻辑等价改写 + 扇出约束

| 改动 | 位置 | 说明 |
|---|---|---|
| **E1** `pred_ok` 直接比 `ex_pc_target` | `core.sv:~551` | 该项本就被 `!actual_taken \|\|` 门控，且 `actual_taken=1` 时 `actual_target ≡ ex_pc_target` → **逐位等价**，但把那个 32 位 2:1 mux 移出比较路径 |
| **E2** `(* max_fanout = 16 *)` | `core.sv` 声明处 | `actual_taken` 扇出 **60**（单跳 0.947ns）、`pc_src`/`redirect` 扇出 **34**（1.055ns），合计约 2.0ns = 12% 路径 |

### E3：Pblock（收益最大）

实测错配：数据通路落在 `CLOCKREGION_X1Y0`，而内存 BRAM 落在 `CLOCKREGION_X0Y0`
—— **跨时钟区边界**让最后一跳进 `u_imem/ADDRARDADDR` **单独就 1.93ns**。

| Pblock（`--pblock-range`）| fmax | 说明 |
|---|---|---|
| 无（默认自由布局）| 62.8 | |
| **`CLOCKREGION_X1Y0:CLOCKREGION_X1Y3`** | **69.2** | **最佳**，已设为 `build.tcl` 默认 |
| `CLOCKREGION_X1Y0:CLOCKREGION_X1Y2` | 66.9 | 更紧反而更差 |
| `CLOCKREGION_X1Y0:CLOCKREGION_X1Y1` | 64.2 | 最紧最差 |
| `X1Y0:X1Y3` + `ExtraTimingOpt` | 63.3 | 布局策略与 Pblock 有交互 |
| `X1Y0:X1Y3` + `AltSpreadLogic_high` | 63.3 | |

**结论：收紧不等于更好** —— 丢掉的布局自由度 > 缩短的物理跨度。

## 累计结果

| 指标 | 基线 | +E1+E2 | **+E3（当前交付）** |
|---|---|---|---|
| **fmax** | 58.9 | 62.8 | **69.2 MHz** |
| WNS | 3.022 | 4.064 | **5.543** |
| 最差路径 | 16.350ns | 15.276ns | **13.971ns** |
| 其中 logic / route | 5.744 / 10.606 | 4.378 / 10.898 | **5.045 / 8.926** |
| 逻辑级数 | 21 | 17 | 18 |
| LUT / FF / BRAM | 2820 / 1345 / 8 | 同 | **同（零面积代价）** |
| CoreMark ticks | 423527 | 423527 | **423527（不变）** |
| 绝对吞吐 | 139.1 | 148.2 | **163.3（+17.4%）** |

**验证**：仿真回归 **PASS 11**；上板 `ila_ctrl=0x42`、CRC bit31=1、
tick **508,155,404**（与历史各版本逐位相同）、10.16 s。

## 距 100 MHz 还差什么

现在路径 **13.971ns**，需 ≤9.5ns → **还差约 4.5ns**。剩余构成：

| 剩余项 | 量级 | 说明 |
|---|---|---|
| **route** | **8.926ns（64%）** | 仍是主项。已用 Pblock 从 10.9 压到 8.9；继续压要试 `-contain_routing`、更细的 Pblock 形状，或 `route_design` 策略 |
| **logic 18 级** | 5.045ns | 尾部是 `pc_target` 的 **4:1 优先级 mux**（trap > mret > redirect > pred）+ BTB 目标 LUTRAM + 一条 5 级 CARRY4 |
| **链首 BRAM** | 2.1ns | 固有 |

**必须付 IPC 才能再进一步的（还没做）**：
1. **解耦耦合 1**：load 结果进寄存器再前递 → 砍掉链首约 3.4ns，**代价 load-use 停顿 1→2 拍（+6.5% 时间）**。
2. **让 trap/mret 让路**：`pc_target` 从 4:1 退化成 2:1。
3. **切 EX 成两级**（5→6 级流水线）。

> **本轮教训**：把关键路径**逐级列出来**（而不是只看"最慢一级"）才找得到
> "跨三级串联"这种结构性事实；而**物理约束（Pblock）贡献了 6.4 MHz**，
> 比逻辑改写（3.9 MHz）还多 —— 在布线占 65% 的设计里这是常见结果。

---

## 实验 D（2026-10-07）— 解耦 WB→EX 跨级链：**一次失败的尝试 + 两个关键测量**

### 做了什么

目标是砍掉跨级链的前两段（WB 组合 + EX 前递，约 6.5ns）。做法：让 load 在 MEM
**多停一拍**（`hazard_unit` 新增 `lu_hold` = 寄存的 `load_use`，纳入 `pipe_stall`
与 `hold_mem`），这样 `mem_load_data` 能在"load 真正离开 MEM"那一拍被 MEM/WB
锁存；再把写回/前递改成**恒取寄存器版**（原 `LOAD_RESULT_REG` 的语义）。

### 结果：**回归从 PASS 11 掉到 PASS 4** —— `tb_core_basic` 第 3 组（`lb`→`li`→`bne`）挂

### 根因（值得记）

dmem 是**寄存读**，数据比地址**晚一拍**。于是 `mem_load_data` 只在 load 的
**WB 拍**才有效，而 MEM/WB 是在 load **离开 MEM 那一拍**锁存的 —— **恰好早一拍**。

我加的 `lu_hold` 只覆盖 **distance-1**（有停顿）的场景；而 CoreMark/basic 里大量
是 **distance-2**（`lb` → 中间一条无关指令 → 消费者）：这条路径**本来不需要停顿**
（原来靠 load 在 WB 拍、消费者也在 EX 拍、走组合前递），加了 `lu_hold` 之后
消费者没被推迟，却拿到"早一拍锁存的旧值" → 读到错数据。

**结论：想用寄存器前递，必须让"数据在锁存沿上已经是对的"成立 —— 只有两条路。**

### 关键测量（新加入 `tb_sw` 的计数器，保留）

| 项 | 值 |
|---|---|
| `load(MEM)`（load 占用的 MEM 周期数 ≈ load 条数）| **66,409 = 周期的 14%** |
| `retire(wb)` | 426,403 |
| `load-use` 停顿 | 30,645（6%）|

> 这条数据直接**推翻了"每个 load-use 多 1 拍只需 +6.5%"的估算**：CoreMark 里
> load 占指令数 **15.6%**，所以"让每个 load 多占一拍 MEM"的代价是 **+14%**。

### 两条可行路线（都还没做）

| 路线 | 做法 | IPC 代价 | 说明 |
|---|---|---|---|
| **B（推荐）** | **把访存地址提前到 EX 段送出** —— dmem 在 EX 拍拿到地址, 数据就在 **MEM 拍**有效 | **0** | 提取落在 MEM 段, MEM/WB 在 MEM→WB 沿锁存到的就是对的；distance-1/2 消费者**都**从寄存器前递，且停顿仍是 1 拍。代价是**结构改动**：LSU 的 `req_*` 要从 EX 段取（地址/写数据/写使能全部提前一拍），拆分访存与 AMO 的 FSM 相位也整体前移 |
| **A'** | 让**每个 load** 多占一拍 MEM | **+14%** | 实现小（LSU 加一个 `ld_extra` 标志即可），但 fmax 必须涨 >14% 才划得来；按账面估约 +30% ⇒ 净吞吐约 +14%，**收益薄、风险不小** |

**为什么 B 是正解**：它不改变任何指令的"占用拍数"，只是把**访存地址的送出时机**
从 MEM 段挪到 EX 段，于是 dmem 的寄存读延迟被 MEM 段自己吸收（而不是溢出到 WB），
WB 段就只剩"从寄存器取数"这一步。这是高频率 CPU 的标准做法（把 MEM 拆成
"地址相 / 数据相"）。

---

## 实验 E5（2026-10-07）— 省掉 BR/JAL 的目标校验：**净亏，已回退**

**动机（理论上是冗余的，依据已逐条核对 `btb.sv`）**：
- 命中要求 `vld[pidx] && (tag[pidx]==ptag)` → 表项必须被真实控制流写过，冷表项不会命中；
- 更新写入的是该 PC **实际算出的目标**；
- 而 **BR/JAL 的目标 = `pc+imm`，对同一条 PC 是常量**（裸机、无自修改代码）
  → 命中即保证目标正确 → 那条 32 位比较（路径上 5 级 CARRY4）对 BR/JAL 是多余的；
- **JALR 不满足**（目标随 rs1 变），必须保留比较。

改法：`pred_ok` 的比较项加 `|| (id_ex_ctrl.pc_sel != PC_JR)`。

**实测**：

| 项 | 结果 |
|---|---|
| 回归 | **PASS 11** |
| CoreMark ticks | **423527 不变**（`MMIO_RESULT` 也不变）|
| **fmax** | **64.9 MHz（原 69.2，−6.2%）** ✗ |
| LUT / FF / BRAM | 2817 / 1345 / 8 |

**为什么反而更慢**：省掉 BR/JAL 的比较后，关键路径转移到 **JALR** 那条 ——
它仍然要做同一个比较，而新加的 `pc_sel != PC_JR` 选择项又给它串了一级；
布局也随之变了。**结论：以"最坏路径"为判据时，只优化其中一类分支没有意义。**

> 教训：**"理论上冗余"不等于"能从关键路径上消失"** —— STA 看的是最坏路径，
> 只要还有**任何一类指令**保留该逻辑，它就在路径上。要真正省掉，必须让
> **所有**控制流都不需要它（例如改用"预测即信任 + 出错的下一拍修正"的方案），
> 那是另一套机制，不在本轮范围内。

---

## 实验 E6 / E7（2026-10-07）— 物理手段已探尽：**69.2 MHz 是零 IPC 代价的上限**

| 配置 | fmax | 结论 |
|---|---|---|
| **`CLOCKREGION_X1Y0:X1Y3`**（当前交付）| **69.2 MHz** | 最佳 |
| `CLOCKREGION_X0Y0:X0Y3`（换到左列）| 66.5 MHz | 更差（右列对 BRAM/DSP 布局更友好）|
| `X1Y0:X1Y3` + `CONTAIN_ROUTING=1` | 69.2 MHz | 与不加**完全相同**（区域已足够宽松，没起到作用）|

再加上前面已试过的：`ExtraTimingOpt` / `AltSpreadLogic_high` / 更紧的 Pblock（3 区 66.9、2 区 64.2）
—— **零 IPC 代价的旋钮已经全部试完，69.2 MHz 就是天花板。**

### 当前关键路径的形态（说明为什么必须动结构）

```
dmem BRAM 输出(3.5ns, 26%)
  → LSU 字节提取(3 级 LUT)
    → wb_data mux + 前递网络
      → 分支比较(CARRY4)
        → pred_ok / redirect
          → BTB 目标 LUTRAM + pc_target 优先级 mux(含 trap/mret)
            → pc_next mux → imem 的 BRAM 地址脚(最后一跳 1.25ns)
```

- **route 8.926ns（64%）** —— 已用 Pblock 从 10.6 压到 8.9，继续压无路
- **logic 18 级 / 5.045ns** —— 尾部是取指地址那条链

**要再往上，只剩"把这条链从中间切断"，即路线 B（见上）。** 那个改动动的是
`load_store_unit.sv` 的 FSM 停顿语义 + `core.sv` 的接线，属于结构性重构。

---

## 实验 F（2026-10-07）— 路线 A' 真的做出来了：**功能正确，但净亏 −4.8%，已回退**

### 做法（全部改动只有 3 处）

| 位置 | 改动 |
|---|---|
| `load_store_unit.sv` | 新增 `ld_first`/`ld_hold`: **每次 load 在 MEM 多占一拍**（`lsu_stall` 加 `\|\| ld_first`）|
| `load_store_unit.sv` | WB 影子寄存器（`off_wb/size_wb/uns_wb/split_wb`）的锁存条件加 `\|\| first_mem_cyc` —— 多周期序列**第一拍**就锁规格 |
| `core.sv` | `WB_MEM` 的写回/前递恒改为取 `mem_wb_load_data`（寄存器版），并让 `mem_wb_reg.load_data_in` 恒接 `mem_load_data` |

**中间踩了一个坑（值得记）**：第一版只改了前两条、漏了影子寄存器那条，结果
`tb_core_basic` **第 4 组（非对齐硬件拆分访存）**挂 —— 因为原设计里拆分访存的提取是在
**WB 拍**做的（靠"TAIL 拍继续送尾字地址，让 WB 拍 `dmem_rdata` 仍是尾字"），
改成"离开 MEM 那一沿锁存"之后，那一拍的规格还没就绪。补齐 `first_mem_cyc` 后 **PASS 11**。

### 实测（关键：fmax 只涨了 9.8%，远低于预期）

| 指标 | 基线 | **A'** | **A' + 更多扇出约束** |
|---|---|---|---|
| 回归 | PASS 11 | **PASS 11** | — |
| CoreMark ticks | 423,527 | **488,863（+15.4%）** | 488,863 |
| CoreMark/MHz | 2.3611 | 2.0456 | 2.0456 |
| **fmax** | **69.2** | **76.0（+9.8%）** | 72.8（更差）|
| LUT / FF | 2820 / 1345 | 2676 / 1378 | 2703 / 1378 |
| **绝对吞吐** | **163.3** | **155.5（−4.8%）** ✗ | 148.9（−8.8%）✗ |

**净亏 → 已回退。**

### 为什么 fmax 只涨 9.8%（这次优化最有价值的收获）

A' 之后关键路径**完全换了位置**：

```
改前: u_dmem/mem_reg_*/CLKBWRCLK  -> imem ADDR   13.971ns (logic 5.045 / route 8.926)
改后: u_id_ex/rs2_addr_reg[2]/C   -> imem ADDR   12.617ns (logic 2.580 / route 10.037)
      逻辑级数 18 -> 13, 逻辑 5.045 -> 2.580ns (-2.5ns!)
      但 route 反而 8.926 -> 10.037ns
```

**WB→EX 那条跨级链确实被切断了**（源端从 dmem 变成了 ID/EX 的地址寄存器），
**逻辑也确实少了 2.5ns** —— 但**布线涨回去了**，净省只有 0.81ns。

新路径是：`id_ex_rs2 地址寄存器 → 前递选择(地址比较) → 操作数 mux → 分支比较
→ ex_taken → redirect → pc_target/pc_next → imem 地址`，
**route 占 80%**，且路上有 **两个扇出 115** 的广播网络。

> **结论（对本核最有指导意义的一条）**：这个设计的**逻辑已经不是瓶颈, 布线才是**
> （两次的 route 占比 65% → 80%）。所以"砍逻辑"的改动收益会被布线吃掉；
> 想靠 A'/B 这类改动上 100 MHz，**必须先解决布线**（Pblock 已到极限，
> 需要更细的 floorplan 或降扇出），否则每砍 1ns 逻辑只换来 0.2~0.3ns 的净收益。

### 顺带

- A' + 追加 `max_fanout`（`pred_hit/pred_taken/pred_target/actual_target`）反而更差（76.0 → 72.8）
  —— 扇出约束与布局有强交互，不能盲目加。
- `check` 在本轮暴露过一次"bitstream 比 RTL 旧"：改 RTL 后**必须重建 bitstream**，
  否则拿的是上一版设计的产物（与 R28 同族）。

---

## 实验 G（2026-10-07）— 路由策略也试尽：69.2 MHz 是三方面（布局/布线/逻辑）的当前极值

| `route_design -directive` | fmax | 说明 |
|---|---|---|
| **`AggressiveExplore`**（交付默认）| **69.2 MHz** | 最佳 |
| `NoTimingRelaxation` | 69.2 MHz | 完全相同 |
| `HigherDelayCost` | 69.1 MHz | 相同（−0.1） |
| `Explore` | 68.2 MHz | 更差 |

**至此，三大类"零 IPC 代价"旋钮全部试完并封顶在 69.2 MHz：**

| 类别 | 试过的 | 最佳 |
|---|---|---|
| 布局策略 | `WLDrivenBlockPlacement` / `ExtraTimingOpt` / `AltSpreadLogic_high` | WLDriven |
| 物理区域 | 自由 / `X1Y0:X1Y3` / `X1Y0:X1Y2` / `X1Y0:X1Y1` / `X0Y0:X0Y3` / `CONTAIN_ROUTING` | `X1Y0:X1Y3` |
| 布线策略 | `AggressiveExplore` / `NoTimingRelaxation` / `HigherDelayCost` / `Explore` | AggressiveExplore |
| 逻辑改写 | `pred_ok` 直接比较、`max_fanout`（3 组信号）、省 BR/JAL 目标校验 | 前两项 |

> **总判断**：本核在这套架构下的**零 IPC 代价上限是 69.2 MHz**（WNS 5.543）。
> 关键路径 route 占 64%，逻辑 5.045ns/18 级；任何"砍逻辑"的改动（实验 F 实测砍掉
> 2.5ns 逻辑）净收益只有 0.2~0.3 倍，因为省下的逻辑被布线吃掉。
> **下一步只能是更深的结构改动**（把 MEM 拆成地址相/数据相 = 路线 B，或 5→6 级流水线），
> 且必须先解决布线（需要按模块细分的 floorplan，而不是整核一个大 Pblock）。

---

## 实验 H（2026-10-07）— 综合器重定时：**空操作**（逐位相同）

用 `synth_design -retiming`（形式等价变换，自动搬移触发器切长链）：

| 指标 | 默认 | **`-retiming`** |
|---|---|---|
| fmax | 69.2 MHz | **69.2 MHz（相同）** |
| LUT / FF / BRAM | 2820 / 1345 / 8 | **2820 / 1345 / 8（相同）** |
| CoreMark ticks | 423,527 | **423,527（相同）** |

**结论：Vivado 一个触发器都没搬。** 原因判断：本设计大量使用**异步复位**
（`always_ff @(posedge clk or posedge rst)`，重定时不能跨异步复位移动寄存器），
加上 BTB/RAS 的 `initial` 表项，重定时的可动空间被压到零。
**这也从另一个角度印证：靠"工具自动切链"这条路走不通。**

### 至此，本设计 fmax 的完整结论

| 类别 | 数量 | 最佳 |
|---|---|---|
| 布局策略 | 3 | `WLDrivenBlockPlacement` |
| Pblock 区域 | 5 | `CLOCKREGION_X1Y0:X1Y3` |
| 布线策略 | 4 | `AggressiveExplore` |
| 逻辑改写 | 3 | `pred_ok` 直接比较 + `max_fanout` |
| 工具自动切链（重定时）| 1 | 空操作 |
| 付 IPC 的结构改动（A'）| 1 | 净亏 −4.8% |

**零 IPC 代价上限 = 69.2 MHz（+17.5%），付 IPC 的 A' 也不划算。**
`58.9 → 69.2 MHz` 已全部落袋并上板验证过；再要往上，必须先做
**按模块细分的 floorplan**（把 route 从 8.9ns 压下来），否则任何结构改动
的收益都会被布线吃掉（实验 F 已量化：砍 2.5ns 逻辑只换回 0.81ns）。

---

## 实验 I（2026-10-07）— 定向 floorplan：**也无效，物理空间确认探尽**

### 先测出真实坐标（数据驱动，而不是猜）

把关键路径上的站点映射到时钟区（`tools/_map_cr.tcl`，一次 40 秒的器件查询）：

| 模块 | 所在时钟区 |
|---|---|
| **dmem**（`RAMB36_X1Y13`）| X1**Y1** |
| LSU / ID-EX / EX-MEM / MEM-WB（`SLICE_X71..X82 Y54..Y69`）| X1**Y1** |
| **imem**（`RAMB36_X1Y4`）| X1**Y0** |
| PC / redirect / BTB（`SLICE_X61..X73 Y38`）| X1**Y0** |

**关键路径在中途跨了一次时钟区**：数据通路全在 `X1Y1`，而取指侧逻辑与 imem 在 `X1Y0`。
理论上"把整核压进 `X1Y1` 一个区"能消掉这次跨界。

### 实测：反而明显更差

| Pblock | fmax | 对比当前交付 |
|---|---|---|
| **`CLOCKREGION_X1Y0:X1Y3`**（交付）| **69.2 MHz** | — |
| `CLOCKREGION_X1Y1:X1Y1`（数据通路所在单区）| 67.4 MHz | −1.8 |
| `CLOCKREGION_X1Y1:X1Y2` | 65.0 MHz | −4.2 |

**结论：工具"铺开"是为了可布线性，强制局部化是负收益。**
至此 Pblock 共试过 **7 种**，无一超过 `X1Y0:X1Y3`。

### 物理空间已确认探尽（三类共 14 种组合 + 重定时）

| 类别 | 数量 | 最佳 |
|---|---|---|
| 布局 / 布线 / 重定时策略 | 8 | 默认（WLDriven / AggressiveExplore / 关）|
| Pblock 区域 | 7 | `CLOCKREGION_X1Y0:X1Y3` |

> **判断**：`69.2 MHz` 是本架构在"零 IPC 代价"下的真实上限；`route` 占 64% 且
> **无法通过任何区域/策略约束压下去**（工具已在自己认为最优的位置）。
> 剩下的只有**目标里最后一项尚未实测的改动**：**trap/mret 让路** ——
> 把 `pc_target` 从 4:1 优先级 mux 退化成 2:1（`redirect ? actual_target : pred_target`），
> 让 `trap_enter`/`mret_taken` 走 `pc.sv` 的 `flush` 端口。**理论代价为零**：
> 陷阱本来就要冲刷两级，所以跨界那一拍取错的指令会被冲掉，不产生额外停拍。
> 这是唯一还没试过的零 IPC 改动。

---

## 实验 J（2026-10-07）— trap/mret 让路：**实测失败，已回退（根因未完全定位）**

### 做法（`core.sv` 两处）

| 位置 | 改动 |
|---|---|
| `u_pc` | `.flush(1'b0)` → `.flush((trap_enter \|\| mret_taken) && !pipe_stall)`；`.flush_pc(trap_enter ? trap_vector : mret_pc)` —— 用 `pc.sv` 本来就预留好的端口（其注释原文就是"预留: trap 单元接管时改用 flush_pc"）|
| `pc_target` | 4:1 优先级 mux → **2:1**：`assign pc_target = redirect ? actual_target : pred_target;` |

**安全性论证（改前逐条核过）**：`pc.sv` 里 `flush` 优先于 `stall` 与 `pc_src`，所以功能等价；
`pc_target[1:0]` 的自检（core.sv:955）在两种情况下仍为 0（`actual_target` / `pred_target` 均 4 字节对齐）。

### 实测：`tb_core_trap` **第 1 组挂**（其余 10 项 PASS）

```
cycle 23 | if_pc 0x800000ec  0x30200073 (mret) | ex_pc 0x800000e8
cycle 24 | if_pc 0x800000f0  0x90002537        | ex_pc 0x800000ec   <- mret 在 EX
cycle 25 | if_pc 0x00000000  0x00000013        | ex_pc 0x00000000   <- pc 落到 0, 应为 mepc!
cycle 26 | if_pc 0x80000028 ...                                    <- 取到非法指令 -> 触发陷阱
```

**症状**：`mret` 那一拍 `pc` 装入了 **0 而不是 `mepc`**，随后取到非法指令触发陷阱进
`0x80000028`，程序走到失败路径。

### 为什么"理论等价"却没成立（诚实记录）

两种写法在**同一拍、同一目标**上应该完全一致（`mret_taken` 本身就是
`is_mret && !pipe_stall`，`pc.sv` 的 flush 优先级也更高）。实测不同，
说明差异出在**更早的取指流**上 —— 我的改动让程序跑到了**不同的时序**（追踪显示
`if_pc`/`ex_pc` 在改动前后只差 4 字节，与"正常应差 8 字节"不符），
也就是**在进入这段之前流水线状态就已经不同**。

**根因定位需要"基线对照轨迹"**（同一程序在改动前后的逐拍 `if_pc/ex_pc/trap_enter/
redirect` 对照），本轮余量不足以做完，**故按纪律回退**，不把问题留在树里。

> **结论**：`69.2 MHz` 是这套架构在**所有已实测手段**（含目标里列出的全部 5 条路线）下的产出。
> 再往上必须先解决**布线**（route 占 64%，14 种布局/布线/区域/重定时组合都无法压低），
> 而"trap/mret 让路"这一项需要先建立**逐拍基线对照**的诊断方法才能安全推进。

