> **文档性质声明（开发/交接文档）**：本文是内部开发/交接/审查文档，不是赛题交付结论或对外验收报告；涉及的数字请以根 [`COMPLIANCE.md`](https://github.com/fgjg70/FPGA/blob/main/COMPLIANCE.md) 的"证据分级"与对应证据文件为准。

# 交接文档 — RISC-V CPU (紫光同创杯 2026 选题一)

> **给接手的 AI**：这是全新会话的第一条消息，你没有上下文。请先完整读一遍，
> 再读仓库里的两颗「记忆胶囊」：
> - `skills/fpga-riscv-a100t/SKILL.md` — 环境事实 / 命令配方 / RTL 与工具链经验（24KB）
> - `skills/fpga-riscv-a100t/PITFALLS.md` — **错误台账，症状优先**
>   （**62 KB / 921 行，R1~R51 共 51 条**，务必先看；最值钱的新条目是
>   **R43** MMCM 漏接 `.CLKFBIN` 会把整颗 CPU 永久按在复位里、**R47** top-N 是"一堵墙"时
>   RTL 逻辑重排期望 ≈ 0）
>
> 这两份是 10 轮迭代的全部经验沉淀，能帮你避开已经踩过的几十个坑。
>
> **口径（先立规矩）**：本文到处都有"验证"二字，请一律按下面两栏拆开读 ——
> | 说法 | 含义 | 证据在哪 |
> |---|---|---|
> | **仿真通过** | ModelSim 回归 `python tools\fpga_workflow.py verify` 打印 `RESULT : PASS` | `verify` 输出 / `.fpga-cache/logs/` |
> | **上板验证** | 真实板卡 JTAG 烧录 + ILA 读回 | `results/ila_done.capture.json`（采集清单）+ `fpga/cap_done.log`（`CAPTURE_OK`） |
>
> **最后一次成功的上板验证 = 2026-10-11 15:22:41** —— 判据是 **采集清单
> `results/ila_done.capture.json`**（`captured_at_local` / `csv_sha256` / `rtl_sha256` + 文件数 /
> `iterations=3000` / `clk_hz=105000000` / `expect_tick=1380933000` / `wait_seconds=18`），
> 它由 `ila_cap_done.tcl` 写出、**被 .gitignore 忽略**（不入库 ⇒ 全新克隆必然没有 ⇒ `hw` 必然拒绝给结论）。
> ⚠️ **`results/ila_done.csv` 的 mtime 是假见证**（X-02）：它被 git 跟踪，克隆/checkout/重写都会刷新
> mtime 而不产生新采集 —— **2026-10-11 10:51 实测发生**（内容逐字节未变、mtime 变"现在"，`check` [HIL] 误报"刚上过板"）。
> ⚠️ **那次采集覆盖 22 个 `.sv`，当前树是 23 个**（`bht.sv` 由 `028ca4d` 在 **15:55** 引入 ⇒ 采集发生在 C-1 之前）。
> 所以"那一次上板"= **C-1 之前的 RTL**；当前源码的仿真 ticks 与它不同（见下）。
>
> **fmax 口径**：任何 fmax 都必须带**时钟名 + 周期 + 运行频率 + WNS** —— 时钟名已改为**频率无关的
> `sys_clk_core`**（`fpga/daVinciPro.xdc`），不是 `sys_clk` @20 ns，也不是带频率的 `sys_clk_75`；
> 旧写法 `1000/(20 − WNS)` 已失效。
> ⚠️ **"运行频率"与 `fmax` 不是独立的评分项**（PITFALLS **R50**）：把约束从 14.286 收紧到 13.333 ns
> 之后 fmax 自己就从 74.4 升到 76.2 —— 所以报 fmax 必须同时说清"在哪个约束下测的"。
> **`fmax_src` 列尚待 M-04 落地**（`results/coremark.csv` 表头 12 列无此列；在它落地前以该行 `notes` 为准）。
> 完整纪律见 §8「口径纪律」。

---

## 0. 一句话现状

**RV32IM 五级流水线 CPU 已在真实板卡上跑通 CoreMark v1.0（3000 次迭代 / 约 13.15 秒 @105 MHz /
CRC 逐位匹配官方参考值），三项评分指标与绝对吞吐齐备，赛题基础任务全部完成，
动态分支预测（C-1 两级流水 gshare）与完整异常/中断两项高阶任务完成，RV32A 原子指令已完成（9 AMO + LR.W；
SC.W 按规范恒失败），应用场景（神经网络 GEMM）已落地。
> ⚠ **历史文档（2026-10-11 口径）**："最新已上板档 = 105 MHz / 当前目标 131.25 MHz"均已被 **2026-10-17 的 150 MHz 交付档**取代；当前口径见 `README-ARTIX.md` 与 `COMPLIANCE.md`。

**当时最新已上板档 = 105 MHz**（`sys_clk_core` @9.524 ns，采集 2026-10-11 15:22:41；历史）；
**当前交付档 = 150 MHz**（2026-10-17 达成，WNS +0.007；见 `README-ARTIX.md` ②）。

仓库：`D:\USER\Desktop\FPGA\FPGA`（git）

**上手第一件事（不要跳过）**：
```bat
cmd /c tools\doctor.bat                          REM 环境自检 + R1 漂移检测
python tools\fpga_workflow.py verify             REM 回归, 期望 PASS 12 (无 XFAIL)
python tools\fpga_workflow.py check              REM 7 项: 漂移/镜像/bitstream/内存布局/ASCII/综合警告门
cmd /c fpga\jtag_probe.bat                       REM 改 RTL 前先确认板子在位!
```

### 当前实测指标（**三件事必须一起写**：时钟名 / 已上板档 / 设计目标档）

| # | 项 | 值 | 来源 |
|---|---|---|---|
| ① | 时钟名 | **`sys_clk_core`**（频率无关命名） | `fpga/daVinciPro.xdc`（当前 `-multiply_by 21 -divide_by 7` ⇒ 150 MHz）|
| ② | **历史已上板档（2026-10-11）** | **105 MHz**（@9.524 ns），2026-10-11 **15:22:41** | `results/ila_done.capture.json`（`clk_hz=105000000`）|
| ② | 该档上板实测 | `ila_ctrl=0xC2`（locked/done/pass/illegal=0）、`score_result=0xD24B8AFE`（bit31=1）、tick **1,380,682,494**（预期 1,380,933,000，偏差 0.02%）、**13.15 s**、硬件 CM/MHz **2.1728** | `results/ila_done.csv` + 采集清单 |
| ② | 该档综合 | fmax **106.30 MHz**（WNS **+0.117** @9.524 ns）；LUT **2706** / FF **1290** / BRAM 8 / DSP 8 | `results/coremark.csv` 行 `c14-105mhz` + `.fpga-cache/reports/20261011-151614-cm_hw/metrics.json` |
| ③ | **历史设计目标档（2026-10-11）** | **131.25 MHz**（@7.619 ns）—— 当时**时序未收敛**：`Timing constraints are not met.`、WNS **−0.963**、1141/4437 失败端点；工作区 LUT **2865** / FF **1393** / BRAM **9.5** | `fpga/timing.rpt` + `fpga/util.rpt`（16:19 那次构建）|
| — | **当前源码仿真**（C-1） | ticks **453,942** ⇒ CoreMark/MHz **2.2029**（**未上板**） | `.fpga-cache/logs/tb_sw_coremark.log` |

> **口径**：本核**始终是 5 级**（IF/ID/EX/MEM/WB）—— **IF/ID 由 IMEM 的输出寄存器承担**；
> 规范说法是"**4 个流水寄存器 ⇒ 5 级**"。见 `results/p8-ifid-elide.md`。
> **指标的来源不是同一个东西，别混**：`fmax` 与资源来自 **Vivado 综合报告**；
> `CoreMark/MHz` 来自**仿真** ticks；上板只提供 tick 与 CRC 佐证。**别把"综合"写成"上板实测"。**
> ⚠️ **硬件 2.1728 与当前源码仿真 2.2029 不同**，因为**上板那版比当前源码早**（C-1 于 15:55 落地，
> 采集在 15:22；清单覆盖 22 个 `.sv`，当前 23 个）—— 别当成同一个配置（X-03）。
> ⚠️ **跨约束比 fmax 要小心**（R50）：基线 78.4 MHz 是 20 ns 约束下测的。

回归：**PASS 12，无 XFAIL**（**仿真级**，判据 `python tools\fpga_workflow.py verify`；
矩阵 = `tools/fpga_workflow.py` 的 `test_matrix()`，12 项；新增
**`tb_sw_lu_bench`**：load-use 代价标定 —— 距离 1 = **2 拍** / 距离 2 = **1 拍** + checksum。
`tb_units` 的检查点数**以运行时打印为准**）。

> **fmax 的来源怎么读**：`results/coremark.csv` 的 **`fmax_src` 列尚待 `CODE-REVIEW-PLAN.md` M-04 落地**
> （表头 12 列无此列，全仓 0 命中）。在此之前以该行 `notes` 为准（人工修正的行会写明
> "the fmax cell is hand-corrected"；其余由 `fpga_workflow.py` 按**最差 setup 路径块自带的 `Requirement`** 算出）。
> 表头第 2 行的 `fmax_mhz = 1000/(20 - wns_ns)` 是**旧口径**，已失效。

### 存储策略：**imem 与 dmem 全部走 BRAM**（默认，非可选）

| 存储器 | 实现 | 资源 |
|---|---|---|
| `imem` | 寄存读 → 行为级推断 | **RAMB36 ×4** |
| `dmem` | 寄存读（`always @(posedge clk) rdata <= mem[...]`）| **RAMB36 ×4** |

合计 **8 块 RAMB36**，纯行为级推断、**不例化任何厂商 IP**（为迁移紫光同创保留）。

回退开关：`--imem-comb-read`（仿真）/ `IMEM_COMB_READ=1`（综合）可退回组合读
的 LUT ROM 做 A-B 对照；**组合读会多吃约 1228 LUT**（在 3945 LUT 的版本上测得，
即当时的全核 31%），不是省资源的方向。

> `imem` 的寄存读**零周期代价**：取指地址接**组合推出的下一拍 pc**（`pc_next`），
> 于是 `imem_rdata(N) == mem[pc(N)]`，与组合读逐位同口径 —— IF/ID 一行都不用改、
> 重定向代价仍 2 拍、CoreMark ticks 逐位一致。完整五轮失败史见
> `results/p4-macro-failure.md` **5.1 节**。

### ⛔ 已封路（都留了数据，别重复踩）

1. **`LOAD_RESULT_REG`** —— 实测**更差**，已否决。见 `results/p4-macro-failure.md` 5.2。
2. **Cache（2 路组相联 + 突发）** —— **架构性无收益**：`imem`/`dmem` 都是单周期
   命中的片上 BRAM。见 `results/p7-cache-analysis.md`。
3. **RAS / gshare** —— **gshare 已由 C-1 复活**（两级流水 + 8192 项 PHT，见 `results/p4-c1-2stage-gshare.md`）；
   `RAS_EN` 当年的否决理由是"栈顶 mux 落在最紧路径上"，**C-1 之后该理由很可能已失效**
   （实测 `--ras` ticks 453,942 → **452,288**、JALR 误判 3,650 → 2,796）⇒ **需重测 fmax 再定**
   （`synth --ras` 已支持）。见 `results/p4-ras.md`、`results/p4-c1-2stage-gshare.md`。
4. **GEMM 加速单元** —— 机制验证过（42.59× 计算加速）但缓冲落成**触发器阵列**
   （FF 1387→14097，+916%），且 C 读回未修完 → 已 `GEMM_EN` 门控默认关闭。
   见 `results/p5-ai-accelerator.md`。
上板宏自证：`build_ila.tcl` 会打印 **`ILA_BUILD_IMEM_BRAM=1`**（退回组合读时打
`ILA_BUILD_IMEM_COMB_READ=1`）—— 防 R18 假 PASS，**认这个串**。
（历史文档曾写成 `ILA_BUILD_IMEM_REG_READ=1`，**那个串脚本从来不打**，等于自证形同虚设。）

### 剩下的工作（设计与铺垫都已就绪）

| 工作 | 现状 | 从哪接 |
|---|---|---|
| ~~**A 扩展的多周期"读-改-写"**~~ | ✅ **2026-10-06 打通，此后一直 PASS** —— `tb_core_amo` 由 **XFAIL 翻 PASS**，全量回归 **PASS 12，无 XFAIL**。真根因是一行：LSU 在 AMO launch 拍漏拉 `lsu_stall`（与拆分访存不对称），导致紧随的 `lw` 的 WB 相位与 `amo_mode_r` 错开一拍 | `results/p6-a-extension.md` **5.13 节** |
| **GEMM 的 C 读回 + 缓冲改 BRAM** | ⬜ **唯一仍在待办的功能项**：寻址/取数/写回计数已验证正确；C 只有前 16 字对 | `results/p5-ai-accelerator.md` 第 0.2 节 |
| **fmax 物理/逻辑优化（待办 #3）** | 已试 3 种 `place_design` 策略 + `cf` 预计算，收益都在噪声量级（已回退）。关键路径 route 占比高 | `results/p3-fmax.md` 实验 B（含未做的下一步）|
| ~~**`IMEM_REG_READ`（imem 寄存读 → BRAM）**~~ | ✅ **2026-10-06 打通并转为默认**（宏语义反转：**不定义任何宏就是全 BRAM**，`IMEM_COMB_READ` 才是回退开关）。对照：组合读 4079 LUT → BRAM 2820 LUT（−30.9%）| `results/p4-macro-failure.md` 5.1 节、`results/gap-analysis.md` 存储策略一节 |

#### A 扩展：✅ **已打通**（2026-10-06 收尾，此后一直是 PASS）

**结论（先说，避免再被下面那段历史误导）**：`tb_core_amo` 与 `tb_core_amo_diag` 都已 **PASS**
（**不再是 XFAIL**，测试矩阵里已摘掉 `expect_fail_ok`），全量回归 **PASS 12、无 XFAIL**。
证据：`results/p6-a-extension.md` **§5.13**。

**真根因（一行）**：`load_store_unit.sv` 的 `lsu_stall` 在 **AMO launch 拍漏拉**
（拆分的非对齐访存在同一位置是拉的，两条多周期路径**不对称**）：

```systemverilog
assign lsu_stall = (state == S_HEAD) || (state == S_IDLE && (needs_split || amo_en))
                 || (state == S_AMO && (amo_wait || !amo_phase));
```

后果：launch 拍不拉停 → 流水线**多前进一拍** → 紧随 AMO 的 `lw` 的 WB 提前落到
`amo_mode_r` 仍为 1 的那一拍 → 它取的是 `amo_old` 而不是 `dmem_rdata`。
决定性证据：`cyc44 wb_rd=29(=t4) wb=0xf0f0f0f0 mode_r=1`（正确应为 `0xFFFFFFFF`）。

**当前状态**：`A_EN` 仍**默认关闭** —— 这**不是"没做完"**，而是它对 CoreMark 三项**零贡献**
（CoreMark 不含原子指令），且打开只改变布局（实测 fmax 61.2 → 63.1，属关键路径移动，
不是架构性提升）。复验：`python tools\fpga_workflow.py verify --a-ext`（同样 PASS 12）。

**这段路留下的方法（已固化为 PITFALLS R26/R27/R32，比结论更值钱）**：
1. **先用 tohost 上报** —— 把"哪一环错了"变成一个数字
   （`2`=基础读写坏、`4`=AMO 读 0、`5`=`rd` 不对、`6`=写回不对）；
2. **再逐拍打印中间量**，且**打印必须带"这是哪条指令"**（`wb_rd`/`pc`）——
   最后就是靠 `wb_rd=29 wb=0xf0f0f0f0 mode_r=1` 一行定位的（R32）；
3. **同一段新逻辑上往往不止一个 bug**（R26）：AMO 的**地址**与**数据来源**各叠了两个
   bug，**修掉一个不见效不代表方向错了**；而且三次把"值不对"归到数据通路，
   真因都是**时序/相位**。

**仍然现成的资产**（保留，供以后改 AMO / LSU 时复用）：
- `sim/prog/amo_diag.S` / `amo_diag2.S` —— 单步诊断程序（tohost 直接上报）
- `tools/amo_vectors.py` → `sim/prog/amo_vectors.hex` —— **108 条黄金向量**
  （9 算符 × 12 组操作数，含符号边界），已与 RTL ALU **双向交叉验证 13/13**
- `tools/asm.py` **已支持 `.word`**，写 AMO 测试**不需要改汇编器**

> **纪律提醒**：板子掉线就**立刻停下报告**，不要自己继续推（用户明确要求）。
> `hw` 有新鲜度门限；**另外上板前先 `Test-Path` 确认 bit 文件存在**（R28）。

---

## 1. 项目定位

| 项 | 内容 |
|---|---|
| 赛事 | 2026 紫光同创杯 · 选题一「基于紫光同创 RISC-V 指令集 CPU 设计」|
| 目标 | 至少支持 RV32IM，力争国二 |
| 开发板 | 正点原子 达芬奇Pro，XC7A100T-FGG484-2，板载 50 MHz |
| 评分三项 | CoreMark/MHz、最高时钟频率、CoreMark/LUTs |
| 工具链 | riscv-none-elf-gcc 15.2.0（xpack）|
| 基准 | CoreMark v1.0 |

### 赛题任务分解

**基础任务（必须）**：RV32I 通用处理单元 / ≥3 级流水线 + 数据冲突与分支处理 / 外设集成（UART、GPIO）
→ **本仓库全部完成** ✅

**高阶任务（加分）**：2 路组相联 I/D Cache + 总线突发 / 动态分支预测(BTB) + 完整异常中断 / AI 加速单元
→ BTB ✅；**完整异常/中断 ✅（P1 异常 + P2 定时器中断）**；**RV32A 原子指令 ✅**；
Cache ⚖ **经分析判定架构性无收益（不是"没做"）**；AI 加速单元 ⚠ 机制已验证但门控关闭

**其他评分维度**：代码规范 ✅ / 分析报告 ✅ **已成文** / **应用场景 ✅ 已完成**
（`sw/nn_demo.c` GEMM 推理核心，`tb_sw_nn_demo` PASS，与独立参考实现 mismatch=0）/
AI 模型性能 ⚠ 软件基线可信、加速单元不计入成绩

### 还剩什么（按赛题加分价值排序）

| 项 | 价值 | 难度 |
|---|---|---|
| **fmax 提频/收敛（历史）** | 三项指标之一；当时最新上板档 106.30 MHz（+35.6%），当时目标 131.25 MHz 未收敛（WNS −0.963）；**150 MHz 已于 2026-10-17 达成** | 中（根因已定位：route 占 2/3，见 PITFALLS R47/R50）|
| ~~mtimecmp 定时器中断（P2）~~ | ✅ **已完成**（`tb_soc_timer_irq` PASS，见第 6 节 P2）| — |
| Cache（2 路组相联 + 突发）| 高阶任务 —— **已分析判定架构性无收益，不实现** | — |
| AI 加速单元 + 应用场景 | 应用场景 ✅ 已完成；**加速单元的 C 读回仍待修** | 高 |
| 迁移紫光同创 PDS | 赛题平台要求（但 CPU 核零厂商原语，已具可移植性）| 中（等装 PDS）|

---

## 2. 当前实测成果

> ⚠️ **先看这条**：下面「硬件闭环」一节是**上一版 bitstream（P1 之前）**的实测结果。
> **含 P1+P2+P3 的 bitstream 也已上板验证通过**（tick 逐位相同），
> 见下方 P4-old 节与 `results/hw-verified.md` 第 0 节 —— 那是 **2026-10-05** 的采集，
> **不是最后一次**（最后一次 = 2026-10-09 21:29，见文件头口径表）。
> 另外历史行的 `LUT 2481 / fmax 74.6` 用当前代码复现不出来，原因见第 6 节 P1 的说明。

### 三项评分指标

> ⛔ **2026-10-05 事故更正（务必先读 `results/p4-macro-failure.md`）**
> 下面这张表里的 `fmax 70.9 / LUT 2526 / 9.347e-4 / 167.5` **不可复现**。
> 它对应的是"架构宏全开"的配置，而那个配置**仿真跑不过** ——
> 原因是我工具的宏传递写错了（`vlog +FOO` 应为 `+define+FOO`，见 PITFALLS R17），
> **宏在仿真侧从未生效**，于是"综合开了宏、仿真没开宏"，
> "ticks 逐位不变、零代价"这条证据是无效的。
> 修好后实测：`IMEM_REG_READ` / `LOAD_RESULT_REG` 单独开都会 timeout，
> `BTB_GSHARE` 慢 6%。三个宏已全部回退为默认关闭（与**上板验证过的配置**一致）。
> **下表是 2026-10-05 那次事故更正的快照**，已被 2026-10-08 的改动超越；
> **当前数字以本节顶部（第 0 节）那张表为准**（时钟 `sys_clk_core`；已上板档 105 MHz /
> fmax 106.30 / LUT 2706 / FF 1290 / 硬件 CM-MHz 2.1728；目标档 131.25 未收敛）。

| 指标 | 基线 | 更正后（2026-10-05 口径）| 变化 |
|---|---|---|---|
| **CoreMark/MHz** | 0.8263 | **2.3611** | **+185.8%** |
| **最高时钟频率** | 78.4 MHz | **61.6 MHz** | −21.4% |
| **CoreMark/LUTs** | 2.361e-4 | **5.875e-4** | **+148.8%** |

资源（当时代码）：**LUT 4019 / FF 1387 / BRAM 4 / DSP 8**（三宏全关，不含 ILA）
绝对吞吐 = CoreMark/MHz × fmax = **145.4**（基线 64.8，**+124.4%**）

> CoreMark/MHz **+185.8%** 这一项是真的且不受事故影响（BTC/分支预测/M 扩展都是
> 早期完成的，与三个宏无关）。受损的是资源与 fmax。
> 重做三个宏是当前最大的收益机会，见 `results/p4-macro-failure.md` 第 5 节。

### 硬件闭环（真实板卡，非仿真）—— **P1 之前的版本**

```
ila_ctrl     = 0x42  ->  done=1  pass=1  fail=0  illegal=0
score_result = 0x9E49D60C
  bit31 = 1  ->  crclist/crcmatrix/crcstate 全部匹配 CoreMark 官方参考值
  tick  =  508,155,404   (预期 508,232,400, 偏差 0.015%)
  时长  =  10.16 s       (满足赛题 >=10 秒硬性要求)
```

CoreMark/MHz 硬件 2.3615 vs 仿真 2.3611，吻合到 0.02%。
**含 P1/P2/P3 的新评分版此后已多次复跑通过**（当时 tick 与历史版本逐位相同）。

### 逐轮指标历史（`results/coremark.csv`，含被否决的配置）

| tag | ticks | CM/MHz | LUT | fmax | 状态 |
|---|---|---|---|---|---|
| baseline-v1 | 1,210,148 | 0.8263 | 3499 | 78.4 | keep |
| branch-pred-v1 | 973,352 | 1.0274 | 3877 | 70.1 | keep |
| rv32im-v1 | 414,062 | 2.4151 | 4532 | 64.7 | **rejected** |
| m-ext-v2 | 423,486 | 2.3614 | 4551 | 74.6 | keep |
| branch-pred-v2-ras | 419,180 | 2.3856 | 4809 | 71.2 | **rejected** |
| bram-v1 | 423,486 | 2.3614 | 2481 ⚠️ | 63.9 | keep |
| HARDWARE-VERIFIED | 508,155,404 | **2.3615** | 2481 ⚠️ | 74.6 | 上板实测（P1 前）|
| p0-score-cm_hw | 423,486 | 2.3614 | 3679 | 64.0 | keep（P0 重建）|
| p1-trap-wired | 423,486 | 2.3614 | 3923 | 61.4 | keep（P1 异常/中断）|
| p3a-jalr-addder | 423,486 | 2.3614 | 3945 | 64.4 | keep（跳转目标专用加法器）|
| p3e-imem-bram-default | 423,486 | 2.3614 | 2656 | 65.3 | keep（取指寄存读/BRAM）|
| p3g-default-final | 423,486 | 2.3614 | 2444 | 75.0 | keep（load 结果寄存·**P3 最好**）|
| p2-timer-irq | 423,527 | 2.3611 | 2526 | 70.9 | keep（P2 完成时·含完整中断）|
| lv4-noidid → lv4-final | 413,070 | **2.4209** | 2769 | 69.5 | keep（2026-10-08 删冗余 `if_id_reg`）|
| issues-1234 / review-fix | 413,070 | 2.4209 | 2649 | 69.8 | keep（2026-10-08 交付配置）|
| clk75 | 413,070 | 2.4209 | 2734 | 76.2 | keep（**历史**：2026-10-11 75 MHz 冻结版）|
| review-fixes-v1 | 413,070 | 2.4209 | 2736 | 74.4 | keep（**历史**：同日 70 MHz 版）|
| c12c / c12c-alt-y2 | 469,735 | 2.1289 | 2643 / 2689 | 88.6 / 92.5 | rejected（C-12c 重定向实验）|
| c13-95mhz | — | — | 2708 | 106.4 | measure（95 MHz 档）|
| **c14-105mhz** | — | — | **2706** | **106.3** | **keep（最新已上板档 = 105 MHz）**|
| — 同版 FF / BRAM / DSP | — | — | FF **1290** / BRAM 8 / DSP 8 | — | 上板：tick **1,380,682,494**、`ila_ctrl=0xC2`（2026-10-11 15:22:41）|
| （当时工作区 2026-10-11） | — | — | 2865 | — | **131.25 MHz 历史目标（未收敛）**（WNS −0.963）|

> ⚠️ `fmax` 一列**混着两种口径**（MMCM 之前是 `1000/(20−WNS)`）——
> **`fmax_src` 列尚待 M-04 落地**（表头 12 列无此列）；在此之前以各行 `notes` 为准，不要横向直接比大小。
> 另：C-1 之后的 `ticks` 列在 CSV 里可能是空的（只做了综合、没跑仿真），
> 需要 CM/MHz 时看 `.fpga-cache/logs/tb_sw_coremark.log` 或对应 `metrics.json`。

⚠️ = 该 LUT 值用当前代码复现不出来，详见第 6 节 P1 小节末尾的说明。

> **本轮两项重大修正（都来自实测，见 `results/p3-imem.md` 与 `results/p3-load-result.md`）**：
> 1. `imem` 原来既不是 BRAM 也不是 LUTRAM，而是 **1228 个纯 LUT 的组合 ROM**（占全核 31%）。
>    改寄存读后进 BRAM，`u_imem` 1228 → **36 LUT**，全核 LUT 3945 → 2656，**CoreMark/MHz 逐位不变**。
> 2. `core.sv` 里 `mem_wb_reg` 的 `load_data_in` 原本**硬接 `32'h0`**，load 结果直接从
>    LSU 组合输出进 `wb_data` mux → 前递 mux → ID/EX，两跳压在一拍。
>    改成真正走 MEM/WB 寄存器后 **fmax 65.3 → 75.0（+14.8%）**，LUT −8.1%，
>    而 **ticks 与 load-use 停顿完全不变（零代价）**。
>
> ⚠️ 第 2 条曾长期被 `HANDOFF.md` 的 P3 方案 1 标注为"代价：load-use 停顿 1→2 拍，约 +7% 周期"
> 而搁置 —— **实测那个代价根本不存在**（dmem 的寄存读已经提供了那一拍）。
> **教训：文档里的"预期代价"必须重新实测，否则会白白放弃大收益。**
>
> 诊断建议：怀疑某个数组没进 BRAM、或某段逻辑被实现成了 LUT 时，跑
> `tools/hier_util.tcl`（按层次报告资源）。普通 `report_utilization` 看不出
> "imem 是 1228 个 LUT" 这类问题 —— 它在两张内存映射表里都不出现。

---

## 3. 环境事实（必读，否则寸步难行）

### 工具路径（已核实存在）

```
Vivado     D:\software\Learn\Xilinx\Vivado\2018.3
ModelSim   D:\software\tools\Modelsim\win64        (LICENSE.TXT 同目录)
RISC-V GCC D:\software\tools\riscv-none-elf\xpack-riscv-none-elf-gcc-15.2.0-1\bin
Python     C:\Users\19716\AppData\Local\Programs\Python\Python313\python.exe
```

没有 iverilog，没有 Pango PDS。

> ⚠️ 因此 **`sim\run.bat` / `sim\run.sh` 不能作为测试入口**（它们硬依赖 iverilog，且只跑 2/11）。
> 仿真**一律**走 ModelSim 的 `python tools\fpga_workflow.py verify`。
> 详见 `README.md`「跑测试」一节与 `CODE-REVIEW-PLAN.md` **D-04 / W-05 / W-06**。

### 【最重要】子进程环境被剥离

DSH 会话的 `process.env` 是**空的**。直接 spawn 子进程会缺 `PROCESSOR_ARCHITECTURE`，
Vivado 会报 `32-bit platform is not supported`；ModelSim 会报 `Unable to checkout a license`。

**一切构建/仿真都通过 `.bat`，并在 bat 里显式 set：**

```bat
@echo off
set "PROCESSOR_ARCHITECTURE=AMD64"
set "LM_LICENSE_FILE=D:\software\tools\Modelsim\win64\LICENSE.TXT"
set "PATH=D:\software\tools\Modelsim\win64;%PATH%"
REM Vivado 用 settings64.bat 最省事:
call "D:\software\Learn\Xilinx\Vivado\2018.3\settings64.bat" >nul 2>&1
```

### 【最重要】`.bat` 与 Vivado 的 `.tcl` 一律纯 ASCII

两种不同成因，同一个结论：
- `.bat`：`cmd` 用 OEM 代码页解析，中文会让**每行首字符被吃掉**（报 `'et' 不是内部或外部命令`）
- `.tcl`：若用 7 位掩码编码写文件，非 ASCII 注释字节会变成控制字符，**其中一些正好是 `0x0A`，
  把注释行劈成代码行**，报 `invalid command name`

### 串口在本板不通

FT2232H 只有 D2XX 驱动、**没有 COM 口**；CH340 也都不在。所以**无法用 printf 读回结果**。
现有替代方案：**MMIO 上报 + ILA over JTAG**（见第 5.3 节）。
如果要让串口可用，需要装 FTDI 的 VCP 驱动 —— 那是驱动安装，得让用户操作。

### 上板链路（**最近核实：2026-10-11 10:45，`JTAG_PROBE_OK`**）

> 凭据：`fpga/jtag_probe.log`（Start 10:44:59 → `JTAG_PROBE_OK` 10:45:06，`IDCODE=00010011011000110001000010010011`
> = `0x13631093`，`PART=xc7a100t`，target `localhost:3121/xilinx_tcf/Digilent/210512180081`）。
> **注意这是"JTAG 链路在位"，不等于"做过一次上板采集"** —— 最近一次成功的 ILA 采集仍是
> **2026-10-09 21:29:30**（`results/ila_done.csv` + `fpga/cap_done.log`）。两者别混。
> **这条链路可用性不是永久事实**：板子掉线（`No devices detected on target`）本工程遇到过两次，
> **改 RTL 前先 `jtag_probe` 确认识别器件**。

```
IDCODE 0x13631093, part xc7a100tfgg484-2
FT2232H 被 Digilent EEPROM 编程过, Vivado 能识别: localhost:3121/xilinx_tcf/Digilent/210512180081
LED 高电平点亮: led[0]=心跳 led[1]=PASS led[2]=FAIL led[3]=非法指令
```

---

## 4. 代码结构

```
D:\USER\Desktop\FPGA\FPGA\
├── 21 个 .sv (CPU 核, 纯行为级, 零厂商原语; 根目录实测; 含 fpga/ 两个共 23 个)
│     rv32_pkg.sv      类型/常量/MMIO 地址表/控制束 ctrl_s
│     core.sv          数据通路 + 流水寄存器 + 前递/停滞/重定向
│     control_unit.sv  主译码 (RV32IM + SYSTEM/FENCE + RV32A/A_EN)
│     alu.sv  muldiv.sv  branch_unit.sv  imm_gen.sv  pc.sv  regfile.sv
│     hazard_unit.sv  load_store_unit.sv  imem.sv  dmem.sv  btb.sv
│     id_ex_reg.sv  ex_mem_reg.sv  mem_wb_reg.sv      (IF/ID 由 IMEM 输出寄存器承担)
│     bht.sv          方向预测表 PHT (8192 项×2 位, C-1 两级流水 gshare; 由 btb.sv 例化 u_bht)
│     ras.sv  gemm_accel.sv            (宏门控, 默认关)
│     csr_file.sv      M-mode CSR + 陷阱状态机 (已接进 core, P1)
├── fpga/          顶层与构建
│     top_a100t.sv       顶层 (ILA 在此, 被 ifdef USE_ILA 隔离)
│     mmio_subsys.sv     GPIO / 64位周期计数器 / UART / 跑分上报寄存器 / mtimecmp
│     daVinciPro.xdc     引脚与时钟约束
│     build.bat/.tcl     评分版构建 (非工程模式)
│     build_ila.bat/.tcl 带 ILA 的调试构建 (工程模式)
│     ila_cap_done/mark  上板抓取脚本
├── sw/            裸机软件
│     link.ld  crt0.S  libc_min.c  portme.c  hello.c  nn_demo.c
│     coremark/    CoreMark v1.0 源码 + 移植层
├── sim/           测试台
│     tb_units.sv (检查点数以运行时打印为准)  tb_core.sv  tb_soc.sv  tb_sw.sv
│     prog/  basic.S  mmio.S  m_ext.S  trap.S  amo.S  timer_irq.S (+ 生成的 .hex)
├── tools/         asm.py  build_sw.py  elf2hex.py  run_coremark.py
│     fpga_workflow.py  ★统一入口: doctor/check/verify/report (见 tools/README.md)
│     mk_cm_hw.py       重建跑分镜像并重算 ITERATIONS (见 PITFALLS R35)
│     trace_diff.py     逐拍轨迹比对 (找 RTL 改动的第一处分歧)
│     amo_vectors.py    RV32A 黄金向量生成器 (108 条, 独立参考实现)
│     hier_util.tcl     按层次报告资源 (普通 report_utilization 看不出问题)
│     doctor.bat        零摩擦包装 (纯 ASCII, 一条命令跑完自检+漂移检测)
│     flash_boot.ps1    ★QSPI 固化一条命令 (accessor+建像+烧写+全片读回比对)
│     flash_run/sweep.ps1 + flash_*.tcl   QSPI 实验与只读诊断 (见 tools/flash_logs/REPORT.md)
├── results/       每轮优化的设计与实测数据 (见第 10 节)
└── skills/
      fpga-riscv-a100t/  SKILL.md + PITFALLS.md   (环境事实 + 错误台账)
      fpga-workflow/     SKILL.md                (改→验→量→记 的标准动作)
```

### 内存布局（改动过，注意）

```
0x80000000 .. 0x80003FFF   imem 16KB (.text, 有初始化镜像)
0x90000000 .. 0x90001FFF   dmem .data / .bss (8KB, 有 ASSERT 守卫)
0x90002000 .. 0x90002003   tohost
0x90002004 .. 0x90002BFF   栈 (顶 0x90002C00)
0x90003000 .. 0x90003FFF   日志缓冲区 (printf 重定向目标)
0xA0000000 ...             MMIO (见 rv32_pkg 地址表)
```

---

## 5. 已完成的工作

### 5.1 微架构

| 特性 | 实现 | 效果 |
|---|---|---|
| **5 级**流水 IF/ID/EX/MEM/WB（IF/ID 由 IMEM 输出寄存器承担）| `core.sv` | 见 `results/p8-ifid-elide.md` |
| EX/MEM + MEM/WB 前递 | `hazard_unit.sv` | load-use 停顿仅 1 拍 |
| **分支预测** | `btb.sv` 64 项 BTB + 2 位 Smith | 精度 89%，CoreMark/MHz +24% |
| **RV32M** | `muldiv.sv` | CoreMark/MHz **+130%** |
| **BRAM 存储** | `dmem.sv` 寄存读 + 字节提取挪到 WB 拍 | LUT −45%，**零性能损失** |

**分支预测的关键语义**：`redirect` 重定义为**「预测错误」**而非「分支 taken」。
预测正确时绝不冲刷，否则两条正确路径被白丢、收益归零。

**M 扩展收益远超预期的原因**：libgcc 的 `__mulsi3/__udivsi3/__umodsi3` 是函数调用 + 循环，
分支密集。启用 M 后 **redirect 从 59,466 掉到 11,501（−81%）**，那部分分支流量整个消失。

**BRAM 怎么做到零损失**：BRAM 输出寄存器直接充当原来 MEM/WB 里那份 load 数据寄存器，
把字节提取/符号扩展挪到 WB 拍组合完成 —— 既不加深流水线，也不增加 load-use 停顿。

### 5.2 外设（`fpga/mmio_subsys.sv`）

| 外设 | MMIO 地址 | 说明 |
|---|---|---|
| GPIO_OUT / GPIO_IN | 0xA0000000 / 04 | |
| 64 位周期计数器 | 0xA0000008 / 0C | CoreMark 计时依赖它 |
| UART TX / STAT / RX / RSTAT | 0xA0000010/14/18/1C | 115200 8N1，回环自测通过；`BAUD_DIV = CLK_HZ ÷ 115200`（整数除，**随档位变**：105 MHz→**911**⇒115,258 baud/+0.05%；131.25 MHz→**1139**⇒115,233/+0.028%）|
| **MMIO_MARK** | 0xA0000020 | W：单拍脉冲，ILA 触发点 |
| **MMIO_RESULT** | 0xA0000024 | W/R：写锁存并置 done |
| MTIMECMP / MTIME | 0xA0000028..0034 | **已实现**（P2 定时器中断：`mtime` 复用周期计数器，`mtime >= mtimecmp` → `mip.MTIP`）|

地址译码在 `core.sv` 内完成：DMEM 窗口 → 内部 dmem；其它 → `ext_*` 总线。

### 5.3 上板自主读回（串口不通的替代方案）

```
软件 --(MMIO)--> 硬件 --(ILA)--> JTAG --> PC
```

**一个 32 位寄存器打包两件事**（上板只能回读一个数）：
```
bit31   = 1 表示 crclist/crcmatrix/crcstate 全部等于官方参考值
bit30:0 = 实测 tick 数
```

**为什么用这三个 CRC 而非 `crcfinal`**：它们与迭代次数**无关**（实测 1 次与 3 次完全一致），
只有跨迭代累积的 `crcfinal` 会变。所以 10 秒要求改了迭代次数后判据依然成立。

### 5.4 验证

**ModelSim 全套回归（当前 **PASS 12**，无 XFAIL；判据是 tb 打印的 `RESULT : PASS`；
矩阵 = `test_matrix()`，12 项）**：
```
tb_units  单元检查 (ALU/立即数/控制单元/CSR/regfile/BTB/AMO...)  <- 检查点数以运行时打印为准
tb_core   basic.hex (含非对齐访存) + m_ext.hex (RV32M) + trap.hex + amo.hex + amo_diag.hex
tb_soc    mmio.hex (UART 回环) + timer_irq.hex (P2 定时器中断)
tb_sw     hello.hex / **lu_bench** (load-use 代价标定) / cm_rv32im.hex (CoreMark) / nn_demo.hex (GEMM 应用场景)
```

**CoreMark 正确性证据**：`seedcrc 0xe9f5` / `crclist 0xe714` / `crcmatrix 0x1fd7` /
`crcstate 0x8e3a` 全部等于官方 2K PERFORMANCE_RUN 值。

---

## 6. 待办（按优先级，含具体怎么做）

### P0 · ~~重建评分版 bitstream~~ ✅ 已完成（本轮）

原来 `fpga/cpu_a100t.bit` 是旧的（`tohost` 上移与 MMIO 新增之前构建），且
`build.tcl` **只定义了 `IMEM_INIT_FILE`** —— 本核是哈佛结构，缺少
`DMEM_INIT_FILE` 会让 `.data/.rodata` 全是 0，跑不了真正的程序。

**已修**：`build.tcl` 现在同时定义两个镜像，并把程序镜像**参数化**：

```tcl
set PROG basic        # 工具会临时改写这一行, 跑完自动还原
set imem "$root/sim/prog/$PROG.hex"
set dmem "$root/sim/prog/$PROG.dmem.hex"
# 两个镜像都存在才继续; 缺 dmem 直接报错退出, 不静默继续
```

一键重建评分版（跑分程序）并同时得到四项指标：

```bat
python tools\fpga_workflow.py synth --prog cm_hw --tag <标签> --record
```

`synthesize` 会自己加**全局构建锁**（Vivado 必须串行，两个实例重叠会谎报
`pkgIndex.tcl` 缺失）、按内容哈希缓存、并把 `timing.rpt`/`util.rpt` **归档**
（它们每次构建都被覆盖，不留档就无法复核历史数字）。

**上板复验：✅ 已完成**（见 P4 节）—— `score_result` bit31=1；当时 tick 508,155,404。
**当前交付配置（2026-10-11 75 MHz 冻结版）为 tick 1,239,079,510 / 16.52 s @75 MHz / 3000 迭代**（见第 0 节）。
注意 `results/coremark.csv` 里 `bram-v1`/`HARDWARE-VERIFIED`
两行的 LUT=2481 用当前代码复现不出来，详见下方"P1 已完成"小节的说明。

### P1 · ~~异常/中断的 core 接线~~ ✅ 已完成（见下方"P1 已完成"小节）

**P1 之前已完成的部件**（接线时原样沿用，未改逻辑）：
- `csr_file.sv` —— mstatus/mie/mtvec/mscratch/mepc/mcause/mtval/mip + 进陷阱/MRET 状态机
- `control_unit.sv` —— SYSTEM（ECALL/EBREAK/MRET/Zicsr）+ FENCE 译码，**tb_units 12 项新检查已通过**
- `tools/asm.py` —— CSR 指令 + 助记名表（编码已逐条手工验算）
- `sim/prog/trap.S` —— 6 组异常自校验程序

**缺的就是 `core.sv` 里的接线。设计已经想清楚，照下面写即可：**

```systemverilog
// ---- csr_file 实例 ----
csr_file u_csr (
  .clk, .rst,
  .raddr (id_ex_ctrl.csr_addr),  .rdata (csr_rdata),
  .we    (csr_we),               .waddr (id_ex_ctrl.csr_addr),  .wdata (csr_wdata),
  .trap_req (trap_req), .trap_cause (trap_cause), .trap_pc (id_ex_pc), .trap_tval (32'd0),
  .trap_enter (trap_enter), .trap_vector (trap_vector),
  .mret_req (is_mret && !pipe_stall), .mret_taken (mret_taken), .mret_pc (mret_pc),
  .irq_timer (1'b0), .irq_ext (1'b0),        // P2 再接
  .irq_pending (irq_pending), .irq_cause (irq_cause)
);

// ---- EX 段：CSR 读改写 ----
is_csr    = (id_ex_ctrl.sys_op == SYS_CSR);
csr_src   = id_ex_ctrl.csr_src_imm ? {27'b0, id_ex_ctrl.csr_uimm} : ex_rs1;
csr_wdata = (id_ex_ctrl.csr_cmd == 2'b01) ? csr_src
          : (id_ex_ctrl.csr_cmd == 2'b10) ? (csr_rdata |  csr_src)
          :                                 (csr_rdata & ~csr_src);
// 规范: CSRRS/CSRRC 且源为 0 时不写 (读只读寄存器不得触发异常)
csr_we    = is_csr && !pipe_stall && (id_ex_ctrl.csr_cmd == 2'b01 || csr_src != 32'd0);

// 写回旧值: 给 ex_result 加一路
ex_result = is_muldiv ? md_result : is_csr ? csr_rdata : ex_alu_out;
// 写回 mux 里 WB_CSR 走 mem_wb_alu_out (EX/MEM 已存下 ex_result)

// ---- 陷阱判定 (EX 段, 指令提交前) ----
is_mret   = (id_ex_ctrl.sys_op == SYS_MRET);
exc_req   = !pipe_stall && (id_ex_ctrl.illegal
                          || id_ex_ctrl.sys_op == SYS_ECALL
                          || id_ex_ctrl.sys_op == SYS_EBREAK);
exc_cause = id_ex_ctrl.illegal           ? CAUSE_ILLEGAL
          : id_ex_ctrl.sys_op==SYS_ECALL ? CAUSE_ECALL_M : CAUSE_BREAKPOINT;
irq_take  = irq_pending && !pipe_stall && !exc_req && !is_mret;
trap_req  = exc_req || irq_take;
trap_cause= exc_req ? {1'b0, exc_cause} : irq_cause;

// ---- 重定向 (与分支预测冲刷共用一套机制) ----
trap_redir  = trap_enter | mret_taken;
any_redir   = redirect | trap_redir;
pc_src      = any_redir || pred_taken;
pc_target   = trap_enter ? trap_vector
            : mret_taken ? mret_pc
            : redirect   ? actual_target : pred_target;
if_id_flush = any_redir;                 // 原来只写 redirect
id_ex_reg 的 .flush 也改成 any_redir;    // 原来只写 redirect
```

**关键点**：陷阱时冲刷 ID/EX 会把触发指令变成气泡 → 它**不写寄存器、不写存储器** → 精确陷阱。
`csr_file` 里 `mepc` 取 `trap_pc` 本身**不 +4**，因为异常与中断都在指令提交前裁决，
被抢占的指令必须重新执行，两种情况语义统一。

**改完必须**：`tb_units` / `tb_core(basic,m_ext)` / `tb_soc` / `tb_sw(hello,coremark)` 全过，
并把 `sim/prog/trap.S` 加进 tb_sw 测试列表跑通。

#### ✅ P1 已完成（本轮）—— 以上就是最终落地的接线

**回归 7 PASS**（`tb_units` / `tb_core_basic` / `tb_core_trap` / `tb_core_m_ext` /
`tb_soc` / `tb_sw_hello` / `tb_sw_coremark`）。`csr_file.sv` 已进三处 RTL 清单与
`CORE_SV_ORDER`，`KNOWN_UNWIRED` 白名单已清空（`check` 不再报未接线）。

**过程中修掉的三个真 bug（都在 PITFALLS 里立了条）：**

| # | 症状 | 真因 |
|---|---|---|
| R5 | `tb_core` 在 555ns 就 `$fatal`，测试程序没机会跑 handler | `dbg_illegal` 在 **ID 段**锁存，而陷阱在 **EX 段**裁决，早整一拍 → 改用 `id_ex_ctrl.illegal` |
| R4 | 第二次陷阱跳到 `0x00000000`（实际是 `mtvec` 被写成 `11`） | `trap.S` 用 `t0` 存 handler 地址，而 handler 也用 `t0` → 已改用 `s1` |
| — | `tb_core` 报的非法指令地址差 8 字节 | 诊断用了 `dbg_pc`（IF 段）而非 `dbg_id_pc`（与 `dbg_instr` 同级）——SKILL 6.10 早写过，这次真踩了 |

**测量到的代价（`results/coremark.csv` 的 `p1-trap-wired` 行）：**

| 指标 | P1 前 | P1 后 | 变化 |
|---|---|---|---|
| CoreMark/MHz | 2.3614 | 2.3614 | 0（诚实：trap 逻辑不在热路径上）|
| LUT | 3679 | **3923** | +6.6% |
| FF | 1146 | **1333** | +16.3% |
| fmax | 64.0 | **61.4** | **−4.1%** |
| CoreMark/LUTs | 6.418e-4 | 6.019e-4 | −6.2% |
| 绝对吞吐 | 151.1 | 145.0 | −4.0% |

**结论**：用 +6.6% LUT、−4.1% fmax 换来了赛题高阶任务「完整异常中断」——
**值得**，因为它从"未完成"变成"完成"。fmax 的 −4.1% 大概率是
`pc_target` 从 2 路 mux 变 4 路 mux（陷阱向量 / MRET / 重定向 / 预测目标）加在
**关键路径末端**上，属于 P3 要还的同一类债，可与 P3 一起修。

> ⚠️ 另外记一笔：`results/coremark.csv` 里 `bram-v1` 与 `HARDWARE-VERIFIED` 两行的
> LUT=2481 **用当前代码与构型复现不出来**。现在这条 `synth` 命令实测稳定给出
> LUT 3679（P1 前）/ 3923（P1 后），且 BRAM 推断正常
> （`LUT as Distributed RAM = 83`、`Block RAM Tile = 4`，与 bram-v1 的意图一致）。
> 推测 2481 来自更早的 RTL 修订。**后续以 `synth` 的实测值为准**，历史行仅供趋势参考。

### P2 · ~~mtimecmp 定时器中断~~ ✅ 已完成（本轮）

`rv32_pkg.sv` 里的地址常量（`MMIO_MTIMECMP_LO/HI`、`MMIO_MTIME_LO/HI`）已落地：

- `fpga/mmio_subsys.sv`：64 位 `mtimecmp` 寄存器（复位值全 1 → 上电不会立刻中断），
  `mtime` **复用**已有周期计数器（保证 MMIO_MTIME_* 与 MMIO_CYCLE_* 读数必然一致），
  `irq_timer = (mtime >= mtimecmp)` 电平输出
- `core.sv`：新增 `irq_timer` 端口 → `csr_file.irq_timer`（→ `mip.MTIP`），不再硬接 1'b0
- `top_a100t.sv` / `tb_soc.sv` / `tb_sw.sv` 已接线（`tb_core` 保持恒 0，它不接外设）
- 新测试 `sim/prog/timer_irq.S` + `tb_soc_timer_irq`：验证中断触发、`mcause` 判定、
  handler 推进 mtimecmp 清电平、`mret` 返回、**handler 用 mscratch 保存/恢复现场**、
  以及中断之后 UART/GPIO 仍正常。**全套回归 8 PASS。**

> ⚠️ **中断是电平触发**：`mret` 后若 handler 没推进 `mtimecmp`，条件依然成立 → 立刻重入
> → 死循环。这是**规范的正常行为**，由中断处理程序负责写 `mtimecmp`。

**本轮修掉的两个真 bug（都只在测中断时才暴露）：**

| # | 症状 | 真因 |
|---|---|---|
| R6 | 中断进了但 handler 走错分支；`mcause` 读回 `0x17` 而非 `0x80000007` | `mcause <= {27'b0, trap_cause}` 把**中断位放到了 bit4**，规范要求 bit31。**同步异常下 bit31 本来就是 0，所以此前一直没暴露** |
| R7 | 定时器测试自旋等待、中断永不使能 | `csrsi mie, 0x80` 的立即数**只有 5 位**（规范），`0x80 & 0x1F = 0` → 静默变成 `csrsi mie, 0`。MTIE 是 bit7，**必须用寄存器形式** `li t0,0x80` + `csrw mie,t0` |

### P3 · ~~fmax 还债（61.4 → 75.0 MHz，+22.2%）~~ ⛔ **已被 P4 推翻，本节数字不可复现**

> **本节结论作废**：下面三个实验里 B（imem 寄存读）与 C（load 结果寄存器）
> 的"**零代价**"是**无效证据** —— 当时 ModelSim 侧的宏传递写错了
> （`vlog +FOO` 应为 `+define+FOO`，见 `PITFALLS` R17），这两个宏**在仿真里从未生效**，
> 所以"ticks 逐位不变"测的根本不是那份设计。修好宏后实测：两者单独开启**都会仿真 timeout**。
> 综合出的 LUT/fmax 数字是真的，但**功能不正确**。
> 只有实验 A（跳转目标专用加法器）是有效且保留的。
> **当前真实指标见上面 P4 节。** 完整事故记录见 `results/p4-macro-failure.md`。

三个实验，全部已落地为**默认配置**，详见 `results/p3-fmax.md` / `p3-imem.md` / `p3-load-result.md`：

| 实验 | 改动 | fmax | LUT | 绝对吞吐 |
|---|---|---|---|---|
| （起点，P1 之后） | — | 61.4 | 3923 | 145.0 |
| A | 跳转目标专用加法器（绕开 ALU 操作数 mux）| 64.4 | 3945 | 152.1 |
| B | 取指存储器改寄存读 → 进 BRAM | 65.3 | 2656 | 154.2 |
| **C** | **load 结果改由 MEM/WB 寄存器给出** | **75.0** | **2444** | **177.1** |

**全部零周期代价**（CoreMark ticks 逐位不变 423,527）；CoreMark/LUTs 与绝对吞吐
两项均已**超过历史最好**。距 78.4 仅差 4.3%。

> ⚠️ **一条重要教训**：`HANDOFF.md` 原先把实验 C 标注为"代价：load-use 停顿 1→2 拍，
> 约 +7% 周期"而长期搁置。**实测那个代价根本不存在** —— `dmem` 的寄存读已经提供了
> 那一拍，`MEM/WB` 只是把同一个值再接一次。**文档里的"预期代价"必须重新实测再据此决策。**
>
> 两个可回退开关：`--load-comb`（实验 C）与 `--imem-comb-read`（实验 B）。

**当前关键路径**（已不是 load 路径）：
```
Source:      u_id_ex/rs2_addr_reg[4]/C
Destination: u_id_ex/rs1_data_reg[28]/D
13.236ns (logic 28.5% | route 71.5%), slack 6.664ns
```

### P4 · 微架构优化续（本轮：RAS / gshare / 取指错位定位）⏸ 三条路都走完了

**P4 收官时的真实状态（2026-10-07 口径；已被 2026-10-08 的 P8 超越 —— 最新见第 0 节）**：

| 指标 | 值 |
|---|---|
| CoreMark/MHz | **2.3611**（ticks 423,527）|
| fmax | **61.6 MHz** |
| LUT / FF / BRAM / DSP | **4019 / 1387 / 4 / 8** |
| CoreMark/LUTs | **5.875e-4** |
| 绝对吞吐 | **145.4** |

配置 = **四宏全关**（`IMEM_REG_READ` / `LOAD_RESULT_REG` / `BTB_GSHARE` / `RAS_EN`），
与上板验证过的 ILA 版一致。**当时**上板确认：`ila_ctrl=0x42`、CRC 判定=1、
tick=508,155,404、10.16 s。（这是 **2026-10-07/08** 的历史记录；当前口径见第 0 节。）

**本轮三个结论（都是"实测否决"，但把路探清了）**：

1. **`IMEM_REG_READ`（LUT −1228，单项最大）** —— 根因钉死：**必须重排取指流水**，
   不是加个寄存器能补的。寄存读让 `pc` 寄存器本身成为取指流水的一部分，
   `pc_plus4 → if_pc_plus4 → id_ex_pc_plus4 →` 链接值/分支后继/纠正目标**全部早一拍**。
   两轮修复尝试都失败（[ALIGN] 自检证明取指已对齐，但跳转目标仍错）。
   `build.tcl` 现在检测到该宏**直接报错退出**。详见 `results/p4-macro-failure.md` 5.1。
2. **`RAS_EN`（返回地址栈）** —— 机制**完全有效**（JALR 误判 4378→3558，ticks −0.38%），
   但栈顶 mux 落在最紧的 `pc_target` 路径上 → fmax −2.8%，**绝对吞吐 −2.3%**，净亏。
   > ⚠️ **这条否决理由可能已被 C-1 推翻**：C-1 把 `pred_target` 的两个来源都变成**寄存器输出**，
   > 栈顶 mux 不再串在取指地址路径上。`p4-c1-2stage-gshare.md` 实测 `--ras`
   > ticks 453,942 → **452,288**、JALR 误判 3,650 → **2,796** ⇒ **需重测 fmax 再定**
   > （`python tools\fpga_workflow.py synth --ras` 已支持）。
   实现与自证保留在宏后。详见 `results/p4-ras.md`。
3. **`BTB_GSHARE`** —— 两个变体都输给纯局部 Smith（记全部控制流慢 6%；
   只记条件分支精度崩到 74%，冷启动/表摊薄）。详见 `results/p4-gshare.md`。

**本轮留下的可复用设施**（比结论更值钱）：

- **取指对齐自检**（`tb_sw.sv` 的 `[ALIGN]`）：断言 `mem[if_pc] == if_instr`，
  把"静默错位"变成一行报错。已验证在正确配置下报 `OK (0 次错位)`。
- **分类型预测错误统计** + **层次化直读 BTB 阵列**：这一组测量**推翻了 `btb.sv`
  自己的注释**（"64 项冲突是误判主因"）—— 实测 96% 的分支在表里、80% 的误判是
  方向判错。**改结构前先把"表命中率"与"方向准确率"分开量。**
- **宏自证 `$display`**：每个架构宏生效时打印一行。`RAS_EN` 那次就是靠
  "BTB 中 is_ret=1 的表项 = 0" 一句话定位到"标记只补进了 gshare 分支、
  默认的 Smith 分支漏了"。

**下一步（按收益排序）**：

1. **重做取指流水**（唯一能同时拿回 LUT 1228 与继续提 fmax 的路）—— 引入标准的
   "取指地址寄存器 + 取指数据寄存器"两级结构，让重定向在这一级闭环。
   **这会改流水线结构**，需要重新评估周期代价（预计每次 taken 分支 +1 拍，
   约 4.9% 周期），且必须与 BTB/RAS 一起重排。这是当前最大的一块。
2. **`LOAD_RESULT_REG`** —— 与 imem 同源的**结构性**问题（dmem 寄存读让 load 数据
   晚一拍，MEM/WB 再打一拍就成了两拍）。修它等价于重新安排访存级，所以应与第 1 项
   合并考虑。
3. **CPI 侧**：load-use 停顿 6.5%（30,645 拍）是最大单项，但它已不在关键路径上，
   优化它只对 CPI 有益、不影响 fmax。
4. **功能完备**：A 扩展（原子指令）、Cache（2 路组相联 + 突发）、AI 加速单元。

### P4-old · fmax 还债（历史，已被 P4 更正）

**上板验证 PASS**（`cmd /c fpga\ila_cap_done.bat`，**2026-10-05 采集**，凭据 `results/hw-verified.md` §0 +
`fpga/cap_done.log`）：

```
ila_ctrl     = 0x42  ->  done=1 pass=1 fail=0 illegal=0
score_result = 0x9E49D60C
  bit31 = 1  ->  CRC 全部匹配 CoreMark 官方参考值
  tick  = 508,155,404    (预期 508,232,400, 偏差 0.015%)
  时长  = 10.16 s        (赛题 >=10s 满足)
  CoreMark/MHz = 2.3615  (仿真 2.3611, 吻合 0.02%)
```

> **tick 与 P1 之前逐位相同** —— P1/P2/P3 都不改变指令数与周期数（P3 是纯时序优化，
> P1/P2 的陷阱逻辑不在热路径），硬件上逐位复现，证明**仿真与硬件在三次结构性改动后仍一致**。

流水线波形见 `results/ila_pipeline.csv`（stall 11.57%、redirect 0.68%），
详细记录见 `results/hw-verified.md` 第 0 节。

**上板闭环是全自动的**，见 `HANDOFF-HW-LOOP.md`。要点：
1. **改过 RTL 必须先重建 ILA 版**（`cmd /c fpga\build_ila.bat`，约 5-6 分钟）——
   ILA bit 与 RTL 脱节是**静默失败**（抓到旧设计的信号，不报错）。
   核对脚本：比 `fpga/ila_proj.runs/impl_1/top_a100t.bit` 与各 RTL 的 mtime。
2. `write_hw_ila_data` 目标 CSV 已存在时**必须加 `-force`**（否则 `Labtoolstcl 44-54`）。
3. 读回用 `python tools\fpga_workflow.py hw --tag <标签> --record`。
   **通常不必手传 `--iterations` / `--clk-hz`** —— 工具按
   `命令行 > results/ila_done.capture.json（采集清单）> sim/prog/cm_hw.build.json（构建清单）`
   的顺序自动推断，并把**来源打印出来**；三处都没有才拒绝给结论（报 BLOCK）。
   只有做"假设性复算"时才显式传（旧默认值 1200 / 50e6 会**静默算错**，见 M-03）。

### 上板闭环快照 —— ✅ **2026-10-05 22:48** 那次采集（**当时的** RTL，不是当前改动）

```
ILA 版重建: 22:47 (ILA_BUILD_OK, 时序约束满足)
抓取       : 22:48:13   CSV_MTIME 自证 AGE_SEC=0
ila_ctrl     = 0x42  -> done=1 pass=1 fail=0 illegal=0
bit31 = 1  -> CRC 判定 全部匹配官方参考值
tick  = 508,155,404      时长 = 10.16 s      CoreMark/MHz = 2.3615
=> 上板验证 PASS
```

**这一版对应的是当前仓库的 RTL**（GEMM 加速单元已用 `GEMM_EN` 门控关闭）。
此前 22:25 那次跑的是门控**之前**的 RTL，所以那次不能代表当前代码 —— 已重做。

流水线波形也重新抓了（`results/ila_pipeline.csv`，22:48）：
```
stall    = 236/2048 = 11.52%     (上次 11.57%)
redirect =  15/2048 =  0.73%     (上次 0.68%)
illegal  = 0
PC 热点  = 0x80001218 ~ 0x80001248
```
与上次量级一致 —— 核的行为稳定，RTL 改动（GEMM 门控）没影响 CoreMark 路径。

### ⚠️ 板子掉线要**立刻停下并报告** —— 当前状态（2026-10-05 23:19）

**板子再次掉线**，报错原文：
```
ERROR: [Labtools 27-2269] No devices detected on target
       localhost:3121/xilinx_tcf/Digilent/210512180081
```

**最后一次成功上板：23:05:43**（`CSV_MTIME` 自证 `AGE_SEC=0`）：
`ila_ctrl=0x42`、CRC 判定=1、tick=508,155,404、10.16 s → **PASS**。

#### 23:05 之后改过的 RTL，以及它们是否已被上板覆盖

| 提交 | 时间 | 是否已上板覆盖 |
|---|---|---|
| `1020652` 记录多周期 RMW 难点（纯文档）| 23:05 前 | 文档，无需上板 |
| `8b1afd6` A 扩展译码 + `A_EN` 门控 | 23:12 | **是** —— 见下面的论证 |

**为什么 `8b1afd6` 已被 23:05 那次覆盖（不是"跳过验证"）**：

它在**评分配置下是 inert 的** —— `A_EN` 默认不定义，`control_unit` 里那段
译码走的是 `` `else OPC_AMO: illegal = 1'b1; ``，与加 A 扩展之前**完全一致**。
用两次综合的归档报告实证：

| 项 | 加译码前 (22:58) | **加译码后 A_EN=0 (23:18)** |
|---|---|---|
| Slice LUTs | 4078 | **4079** |
| Slice Registers | 1377 | **1377** |
| Slack | 3.783 ns | **3.783 ns** |
| fmax | 61.2 MHz | **61.2 MHz** |
| 关键路径 | `u_dmem/mem_reg_1` → `u_pc/pc_reg[4]` | **同左，逐项相同** |

综合是确定性的（同一工具、同一选项），两份报告在所有可观测量上逐项相同
→ **`A_EN=0` 的网表与加译码之前一致**。因此 23:05 那次上板验证的
就是当前的评分配置。

> 结论：**当时（2026-10-05）评分配置是已验证的**；未上板验证的只有 `A_EN=1` 那条路。
> ⚠️ **这句现在已经过时**：此后 RTL 又改过多轮，最后上板停在 **2026-10-09 21:29**，
> 而 `load_store_unit.sv` + `fpga/build.tcl`（`d6b48fe`，2026-10-11 00:50）**尚未上板**。
> 判断"哪些改动没上板"请按文件头口径表 + `python tools\fpga_workflow.py hw --stale` 现查，不要读本节。
> ⚠️ 原文这里还写着"它本来也执行不了原子指令 —— 多周期控制未实现"——
> **那是 2026-10-05 的实情，现已过时**：多周期"读-改-写"于 2026-10-06 打通
> （`tb_core_amo` PASS，见 `results/p6-a-extension.md` §5.13）。

#### 恢复步骤（**2026-10-05 板子掉线事故的现场记录**，不是常态流程）
> ⚠️ **别把它读成"上板需要用户操作"** —— 见 `HANDOFF-HW-LOOP.md`：烧录 / 运行 / ILA 读回
> **全程自动**，不需要用户看 LED、也不需要串口。这里唯一要人的动作是**物理插拔 USB/JTAG 线**
> （硬件故障恢复，不是验证流程的一部分）。
重新插好 USB/JTAG 线 → `cmd /c fpga\jtag_probe.bat` 确认识别器件 →
若要继续做 A 扩展的 `A_EN=1` 路径，再 `build_ila.bat` + 抓取。

### ⚠️ 纪律：板子掉线要**立刻停下并报告**，不要自己继续推

**用户明确要求**：硬件在环（HIL）是本项目的核心验证手段，它断了就等于**闭环断了**。
继续往前推代码 = 在无验证的情况下积累未验证的改动 —— 正是本项目已经吃过三次亏的模式
（P1/P3 的"零代价"结论、R17 宏失效，都是"先推进、后验证"的产物）。

**正确做法**：发现板子掉线 -> **立即停止本轮**，向用户报告：
- 掉线时间与报错原文（`No devices detected on target`）
- 最后一次成功上板的时间与结论
- 哪些改动是在最后一次上板**之后**做的（即"未上板验证的改动清单"）
- 恢复所需的操作

**不要**：自己重试很多轮、把"板子恢复"当成可以等的机会、或者拿陈旧 CSV 当结论。

**历史记录**：2026-10-05 22:13 曾掉线一次，当时我继续跑了 3 轮才报告 ——
这是判断错误。22:2x 板子恢复，随即补做了完整的重建 + 抓取验证。


### P5 · Cache / AI 加速单元

- **Cache**：⚖ **已分析判定架构性无收益，不实现**（`results/p7-cache-analysis.md`）——
  `imem`/`dmem` 都是单周期命中的片上 BRAM。
- **AI 加速单元**：⚠ 机制已验证（42.59× 计算加速），但 `GEMM_EN` 门控默认关闭；
  **唯一未完成项是 C 读回 + 缓冲改 BRAM**（`results/p5-ai-accelerator.md`）。
- **应用场景**：✅ 已完成（`sw/nn_demo.c`，`tb_sw_nn_demo` PASS）。

### P6 · 迁移紫光同创 PDS（需用户先装 PDS）

可移植性已经保证：**CPU 核 21 个源文件（根目录）零厂商原语**，只需重写 `top_a100t.sv` 与约束文件。
注意 Xilinx BRAM 是 36Kb、紫光同创是 18Kb，**不要例化 BRAM IP** —— 现在是行为级推断，能直接迁。

---

## 7. 命令配方

### 【先跑这个】统一工作流入口

`skills/fpga-riscv-a100t/PITFALLS.md` 记了 **R1~R51** 共 **51** 条坑，最高频的是 **R1「改了 A 忘了同步 B」——
全部静默失败**。这套工具把那条纪律从"靠人记"变成"机器每次都查"：

```bat
rem 收尾必跑: 环境自检 + R1 漂移检测 (约 2 秒; check 现在 7 项, 第 7 项 = 综合警告门)
cmd /c tools\doctor.bat

rem 分诊完一批无害综合警告后, 把当前状态固化成基线 (之后**新增**的才报警)
python tools\fpga_workflow.py check --update-baseline

rem 回归: ModelSim 增量 (未受影响的测试直接跳过)
python tools\fpga_workflow.py verify

rem 指标: 三项指标 + 绝对吞吐 (从 results/coremark.csv 重算)
python tools\fpga_workflow.py report
```

`verify` 的判定依据是 testbench 打印的 **`RESULT : PASS`**，不是 `vsim` 退出码
（ModelSim 用 `quit -f` 退出时无论成败都返回 0）。当前基线：
**PASS 12**，全量约 25 秒，未受影响时 < 3 秒。

`check` 查六件事：三处 RTL 清单是否同步 / 有无未登记或未接线的模块 /
软件源是否比 `.hex` 镜像新 / **bitstream 是否比 RTL 与镜像新** /
tohost 地址与注释是否一致 / `.bat`·`.tcl` 是否纯 ASCII。
**新增 `.sv` 必须登记进 `tools/fpga_workflow.py` 的 `CORE_SV_ORDER`**
（`rv32_pkg.sv` 必须排第一 —— 其余模块 `import` 它，顺序是语义不是格式）。

### 改一处 RTL → 四项指标全出（测量半环）

```bat
python tools\fpga_workflow.py synth --prog cm_hw --tag <标签> --record
```

自动串行化（全局构建锁）、内容哈希缓存、报告归档，一次给出
CoreMark/MHz + fmax + CoreMark/LUTs + 绝对吞吐 并追加进 `results/coremark.csv`。

### 软件构建

```bash
# 【干净克隆第一步】建全部 11 个回归镜像
python tools/build_sw.py --all
# 再多一个上板镜像 cm_hw.hex (含 HW_CLK_HZ) —— 与 ITERATIONS/CLK_HZ 一起写进 cm_hw.build.json
python tools/build_sw.py --all --with-hw
# 等价性穷举: LSU 字节通道 mux（675 万组, ~5 s）
python tools/check_equiv.py

# 只做 CoreMark (注意: --march 才是真生效的, -D FLAGS_STR 只改打印出来的字符串)
# 更省事、且会自己重算迭代数(当前 3000): python tools/mk_cm_hw.py
python tools/build_sw.py sw/coremark/*.c -I sw/coremark -D ITERATIONS=3000 \
    -D 'FLAGS_STR="-Os -march=rv32im -mabi=ilp32"' --march=rv32im \
    -o sim/prog/cm_hw.hex
# 【R35】每次性能提升后必须重算 ITERATIONS (CoreMark 要求 >=10 s, 否则成绩无效)
#   当前值: 3000 迭代 @75 MHz -> 16.52 s, expect_tick=1,239,100,117, wait_seconds=21
#   (都由 tools/mk_cm_hw.py 写进 sim/prog/cm_hw.build.json, 不要在别处硬编码)
#   31 位 tick 硬闸门: expect_tick > 2^31-1 直接 [BLOCK] (当前占 57.7%, 上限 ~5199 迭代)

# 普通裸机程序 (build_sw 已自动包含 crt0.S 和 libc_min.c, 不要再手动传)
python tools/build_sw.py sw/hello.c sw/portme.c -I sw -o sim/prog/hello.hex

# 汇编程序
python tools/asm.py sim/prog/basic.S -o sim/prog/basic.hex
```

### ModelSim 仿真（必须走 .bat，见第 3 节）

```bat
set "LM_LICENSE_FILE=D:\software\tools\Modelsim\win64\LICENSE.TXT"
set "PATH=D:\software\tools\Modelsim\win64;%PATH%"
vlib work
vlog -sv -work work <21 个根 .sv + fpga\mmio_subsys.sv + fpga\top_a100t.sv> sim\tb_XXX.sv
vsim -c -do "run -all; quit -f" work.tb_sw +imem=<abs>/cm_rv32im.hex +dmem=<abs>/cm_rv32im.dmem.hex
```

### 上板构建

```bat
cmd /c fpga\build.bat        REM 评分版 (非工程模式, 快)
cmd /c fpga\build_ila.bat    REM 带 ILA 调试版 (工程模式, 慢; 产物在 fpga/ila_proj.runs/)
```

### QSPI Flash 固化（断电自举）—— **已打通，别重复造轮子**

板载 QSPI（Micron **MT25QL128 / N25Q128**，128 Mbit）已写入我们的 bitstream，
并**逐字节读回校验通过**（`5bd8e37`，2026-10-09）。完整故事（两个根因、part 对照表、
失败日志）见 **`tools/flash_logs/REPORT.md`**，坑见 PITFALLS **R44/R45/R46**。

**一条命令端到端**（自动预载 flash accessor → `write_cfgmem` 建镜像 → 烧写 → **16 MB 全片读回逐字节比对**）：

```powershell
powershell -File tools\flash_boot.ps1 -Bit fpga\cpu_a100t_spix4.bit -Iface SPIx4
rem 回退 SPIx1（同样验证过）: powershell -File tools\flash_boot.ps1 -Iface SPIx1
```

判据是最后一行 `VERIFY=PASS`（**不是** Labtools 那句 `Flash programming completed successfully` ——
`CFG_PROGRAM=0` 时它照样打印"成功"却什么都没写，见 R45）。

> 命令形式取自 `tools/flash_boot.ps1` 自己的 Usage 头（第 4-5 行）。两点提醒：
> ① 脚本里 Vivado / Python 路径是**硬编码绝对路径**（与 `CODE-REVIEW-PLAN.md` E-02 同类，
> 换机器会失败）；② `-Bit` 用相对路径时按当前工作目录解析，若取不到会在
> `MKIMAGE: bit exists = 0` 处**显式失败**（不会静默烧错镜像）；`REPORT.md` 里实测用的是绝对路径。

| 脚本 | 干什么 |
|---|---|
| `tools/flash_boot.ps1` | **推荐入口**：accessor 预载 + 建像 + 烧写 + 全片读回比对 |
| `tools/flash_run.ps1` | 单次实验 runner（`-Part` / `-Action`），完整 stdout/stderr 落 `tools/flash_logs/` |
| `tools/flash_sweep.ps1` | 9+2 个 128Mb cfgmem part 逐一试烧 → `sweep_results.csv` |
| `tools/flash_program.tcl` | 底层 Tcl 流程（accessor 预载 + 器件过滤绑定 + 8 种 action） |
| `tools/flash_mkimage.tcl` | `write_cfgmem` 生成 `.mcs`/`.bin`（env: `IMG_BIT`/`IMG_IFACE`/`IMG_SIZE`/`IMG_TAG`）|
| `tools/flash_readback.tcl` / `flash_probe.tcl` / `flash_partcheck.tcl` | 只读诊断：全片读回 / 枚举 part 库 / 对比器件过滤查找 |

两个必须记住的坑：**① `PROGRAM.CFG_PROGRAM` 必须为 1**；**② 必须先 `program_hw_devices`
预载 accessor**，否则报 `[Labtools 27-3347] Failure to set flash parameters`。

> **上电自举验证剩下的最后一步需要人**：断电再上电，看板上 **DONE 绿灯**（约 1 s 内常亮）。
> 步骤与回退见 `tools/flash_logs/REPORT.md` §4。**跑分/读回本身仍是全自动的**（ILA over JTAG）。

---

## 8. 必读的坑（完整版在 `skills/fpga-riscv-a100t/PITFALLS.md`）

### 最高频 · 改了 A 忘了同步 B（已踩 5+ 次，全部静默失败）

> **现在这条已经机器化了** —— 改完直接跑 `cmd /c tools\doctor.bat`，
> 下面这张表里的第 1、2、3 行都会被自动查出来。

| 改了什么 | 必须同步 |
|---|---|
| 新增 RTL 文件 | `fpga/build.tcl`、`fpga/build_ila.tcl`、`tools/run_coremark.py`、以及所有 vlog 列表、**`tools/fpga_workflow.py` 的 `CORE_SV_ORDER`** |
| 改软件源码 | 重建 `.hex`，**并重新综合 bitstream**（imem/dmem 是综合时 `$readmemh` 进去的）|
| 改 `link.ld` 地址 | portme.c / crt0.S / core_portme.c / top_a100t.sv / 三个 tb 的 TOHOST_ADDR / **`sim/prog/*.S` 里硬编码的地址** |
| 改 `.S` | 重新用 asm.py 汇编（tb 用的是 .hex，不是 .S）|

**识别信号**：结果与上次「完全一致」、镜像逐字节相同、或程序跑到 `j .` 自旋。

### 其他高频坑

| 症状 | 真因 |
|---|---|
| `.bat` 报 `'et' 不是内部或外部命令` | 文件里有中文，cmd 用 OEM 代码页吃掉了行首字符 |
| Vivado Tcl 报 `invalid command name` | `.tcl` 里有中文，7 位掩码编码把注释行劈成了代码行 |
| `Synth 8-2715 syntax error near /` | `verilog_define` 里路径没加引号 |
| `[Synth 8-27] string type not supported` | `string` 不可综合，要用 ifdef SYNTHESIS 包住 |
| ModelSim `vopt-7061` | `initial` 与 `always_ff` 同时驱动一个变量，改用 `always` |
| 信号恒为 X | `logic x = expr;` 是声明式初始化，只在 0 时刻求值一次，要用 `assign` |
| `vlog-13069 unexpected '['` | 不能对括号表达式位选，`(a>>b)[31:0]` 非法，要先赋中间 wire |
| `get_hw_probes probe2` 返回空 | ILA 探针名是**连接的网络名**（`dbg_pc`/`ila_ctrl`/…），不是 `probe0..3` |
| `TRIGGER_COMPARE_VALUE` 各种报错 | 需要比较前缀且位宽匹配：`eq8'h40` 可以 |
| ILA 触发值看着对却永不触发 | 精确匹配太脆弱（结束时 locked+pass 位都是 1，`0xC2` 不等于 `0x40`），用默认 `eq8'hXX` 无条件触发 |
| 综合出 25 个 LUT | 没装程序，全被常量折叠；必须 `-verilog_define IMEM_INIT_FILE=...` |

### 设计纪律

**赛题记三项指标，改一项必须同时量三项 + 绝对吞吐（CoreMark/MHz × fmax）。**
反例：RAS+BTB128 让 CoreMark/MHz +1.0%，但 fmax −4.6%、CoreMark/LUTs −4.4%，净亏，已回退。
> ⚠️ 该反例的**否决理由已被 C-1 动摇**（栈顶 mux 不再串在取指地址路径上）——
> `--ras` 的 ticks 现在净赚 −0.36%，**待重测 fmax**（见 `results/p4-c1-2stage-gshare.md`）。
**优化前先测量** —— 当初就是靠剖析发现分支惩罚占 29%，才决定先做预测而不是 M 扩展。

#### 【口径纪律】fmax 必须带**时钟名 + 周期 + 运行频率 + WNS**，否则不许进文档

引入 MMCM 之后，核心跑在 MMCM 输出域上，**时钟名已改为频率无关的 `sys_clk_core`**
（`fpga/daVinciPro.xdc`；旧名 `sys_clk_75` 已废），而 `sys_clk`（20 ns）那一行
**已不是设计主时钟**。因此：

1. **任何进入文档/报告的 fmax 都必须写出"哪条时钟 @ 多少 ns（运行频率）+ WNS"**，并给出推导式。
   只写 `fmax = 106.3` 会被误读成 20 ns 域的成绩。
2. 正确口径：**`fmax = 1000 / (该时钟周期 − 该路径 WNS)`**。
   `tools/fpga_workflow.py` 会直接打印完整推导，历史输出形如：
   `fmax 76.2 MHz  sys_clk_75 @13.333ns, 运行 75.00 MHz; WNS +0.206ns -> fmax=1000/(13.333 - 0.206)`
   —— 以工具当次输出为准（**时钟名以当次报告为准**，现在应为 `sys_clk_core`）。
3. **旧口径 `1000/(20 − WNS)` 只在 MMCM 之前的 50 MHz 版本上成立，别再照抄**
   （PITFALLS **R42.1**；根因分析见 `CODE-REVIEW-PLAN.md` **M-01/X-01**）。
4. **`fmax` 与"运行频率"不是独立的两项**（PITFALLS **R50**）：约束从 14.286 收紧到 13.333 ns 后，
   fmax 自己就从 74.4 升到 76.2（工具在更紧的目标下更卖力）。所以报 fmax 时必须同时说清
   **"在哪个约束/运行频率下测的"**，否则"提频"会被误当成"逻辑优化"。
5. `results/coremark.csv` 的 **`fmax` 列混着两种口径**（人工修正值 + 旧工具算出的虚高值）——
   ⚠️ 曾被写的"必须同时看 `fmax_src` 列"**目前做不到：该列尚待 `CODE-REVIEW-PLAN.md` M-04 落地**
   （表头 12 列无此列）。在它落地前，**以该行 `notes` 为准**：人工修正的行会写明
   "the fmax cell is hand-corrected"，其余行由 `fpga_workflow.py` 按最差 setup 路径块自带的
   `Requirement` 算出。
6. ⚠️ **跨约束不要直接比大小**：基线 78.4 MHz 是 20 ns 约束下的数，与 `sys_clk_core` 域不可直接减。

> 一句话：**"快了 1 MHz"只有配上"哪条时钟、周期多少、运行频率多少、WNS 多少"才是一个可复核的结论。**

#### 【检查门】`check` 现在有 **7 项**，第 7 项是**综合警告门**（M-06）

**Vivado 报的警告才是本工程的真 lint** —— 本机没有 verilator / slang / svlint
（`Get-Command` 全部 NOT FOUND），ModelSim 的 `vlog` 对全核 20+ 文件只报 3 条无关警告
（`Defaulting port kind to var`）。而本项目真吃过亏的警告**只在 Vivado 日志里**，
且都被当成"标准提示"放过：

| 警告 | 真身 |
|---|---|
| `[Synth 8-3331] design mmio_subsys has unconnected port wstrb[3..0]`（4 次）| **X-08**：MMIO 写忽略 wstrb |
| `[Timing 38-1] ... without a feedback net` | **R43**：MMCM 没接反馈环 ⇒ CPU 被永久按在复位里 |
| 36 × `RAMB36 async control check ...`；31 × `[Synth 8-3332] prod_ss_reg unused`；20 × `btb unconnected port pred_pc/upd_pc` | BRAM 异步控制引脚 / 死状态 / BTB 高位天然未连 |

机制（细节见 `tools/README.md` §`check`）：

- 来源 `fpga/build.log` + `fpga/ila_build.log`；警告键**归一化**（去行号/绝对路径/位下标/常量），
  否则每次综合都"看起来是新的"、门天天响然后被忽略；
- 基线 `.fpga-cache/synth-warn-baseline.json`；**新增**的警告类判 `[FAIL]`；
- **R43 判据已机器化**：任一日志出现 `Timing 38-1` 反馈环警告 → **FAIL**
  （`top_a100t.sv` 里那句"重新综合后该警告必须消失"不再靠人记）；
- 分诊完无害警告后用 `python tools\fpga_workflow.py check --update-baseline` 固化基线，
  **之后新增的才会报警**。（首个基线是 48 类 / 274 条；RTL 清理后当前 `fpga/build.log`
  为 **23 类 / 245 条**，其中 9 类不在旧基线里 ⇒ `[7]` 现在判 `[FAIL]`，**待分诊后重新固化基线**。）

另外 `check` 有一节非编号的 `[HIL] 硬件在环健康度`：上板数据超过 1 小时未更新 → `[warn]`。
> ✅ 它**已改用采集清单见证**（与 `hw` 同源），输出形如
> `最后一次上板数据: 2026-10-11 12:19:02  (N 分钟前)   [来源: 采集清单]`。
> ⚠️ **mtime 永远不能当见证**：`results/ila_done.csv` 被 git 跟踪，2026-10-11 10:51
> 实测过"内容未变、mtime 变现在"（X-02）；唯一见证是 `results/ila_done.capture.json`。

---

## 9. 关键设计决策与理由

| 决策 | 理由 |
|---|---|
| `redirect` = 「预测错误」而非「分支 taken」 | 预测正确时冲刷会把两条正确路径白丢，收益归零 |
| 跳转目标直接取 ALU 的**原始加法器输出** | BR/JAL/JALR 的 alu_op 恒为 ADD，少走一级操作码 mux（零面积代价）|
| 乘法乘积寄存进 DSP 的 MREG/PREG | 组合乘法路径 15.5ns 拖垮 fmax；寄存后用 2.2% CoreMark 换回 15% fmax |
| 除法 `busy` 覆盖启动拍 + 单周期特例 | 否则 DIV 在结果出来前离开 EX，或 EX/MEM 捕获上一次的结果 |
| BRAM 用寄存读 + 提取挪到 WB | 组合读只能落分布式 RAM（2131 LUT，占全核 47%）|
| FENCE 译成合法 NOP 而非 illegal | 编译器/运行库会插 fence，误判为非法会让正常程序一上来就掉陷阱 |
| `mepc` 取 `trap_pc` 不 +4 | 异常与中断都在指令提交前裁决，被抢占的指令必须重新执行 |
| MMIO 需要读选通 `ext_re` | 只靠 `we` 的话外设的粘滞就绪标志永远清不掉 |

---

## 10. 参考文档索引

| 文件 | 内容 |
|---|---|
| `skills/fpga-riscv-a100t/SKILL.md` | **环境事实 / 命令配方 / 12 节 RTL 与工具链经验** |
| `skills/fpga-riscv-a100t/PITFALLS.md` | **错误台账，症状优先，含改动后自检清单** |
| `results/coremark.csv` | 逐轮指标历史（含被否决配置与理由）|
| `results/hw-verified.md` | 上板实测数据 + ILA 抓取方法 |
| `results/gap-analysis.md` | 对照赛题逐项核对的差距清单 |
| `results/baseline-v1.md` | 基线剖析（分支惩罚 29% 的发现过程）|
| `results/branch-pred-v1.md` | 分支预测设计与两个关键 bug |
| `results/branch-pred-v2.md` | RAS/BTB 扩容的被否决实测数据 |
| `results/m-ext-v1.md` | M 扩展实现与三个除法器时序坑 |
| `results/bram-v1.md` | BRAM 转换 + fmax 技术债的根因分析 |
| `results/ila_pipeline.csv` | **分析报告要的 2048 拍流水线波形**（本次实测 stall 11.57%、redirect 0.68%）|
| `results/ila_done.csv` | 上板跑分读回的原始数据（含 tick 与 CRC 判定）|
| `results/p2-timer-irq.md` | 定时器中断实现 + 两个真 bug（mcause 位布局 / csrsi 5 位立即数）|
| `results/p3-fmax.md` `p3-imem.md` `p3-load-result.md` | fmax 还债三个实验的设计与实测 |
| `tools/flash_logs/REPORT.md` | **QSPI Flash 固化的完整报告**（两个根因 / part 对照表 / 端到端命令 / 上电自举步骤）|
| `tools/README.md` | 统一工作流的逐子命令说明（含非 `fpga_workflow` 的辅助脚本登记）|
| `HANDOFF-HW-LOOP.md` | **上板闭环是全自动的** —— 烧录/运行/读回的完整配方 |

---

## 11. 需要用户确认/操作的事

1. ~~上板复跑~~ ✅ **已完成**（2026-10-05 16:43，含 P1+P2+P3，tick 逐位一致、CRC 判定=1）
   —— ⚠️ 但那是**当时**的 RTL；**最后一次上板 = 2026-10-09 21:29**，
   此后的改动（`load_store_unit.sv` + `fpga/build.tcl`，`d6b48fe`）**未上板**。
   **上板复跑不需要用户参与**（`HANDOFF-HW-LOOP.md`：全自动），所以它不该留在"需要用户操作"清单里。
2. **串口不可用** —— 若需要（如现场演示），得装 FTDI 的 VCP 驱动
3. **紫光同创 PDS 尚未安装** —— 迁移工作要等装好（CPU 核零厂商原语，可移植性已保证）
4. 仓库 `fpga/` 目录里有较多 Vivado 日志与备份文件（已被 gitignore），可清理
5. **剩余未做的赛题项**：只剩 **GEMM 加速单元的 C 读回**（Cache 已判定无收益、
   应用场景已完成、分析报告已成文）
6. **QSPI Flash 固化**：已打通（见第 7 节），**只剩"断电再上电看 DONE 灯"这一步要人做**

---

## 12. 建议的接手顺序

```
1. 读 skills/fpga-riscv-a100t/PITFALLS.md   (10 分钟, 能省你几小时; 现已 R1~R51)
2. 读 skills/fpga-riscv-a100t/SKILL.md      (环境与命令配方)
3. 读 HANDOFF-WORKFLOW.md                   (10 轮优化循环 + 判定阈值 + 建议的子命令)
4. 读 tools/README.md                       (统一工作流: doctor/check/verify/profile/synth/metrics/report)
5. 跑 cmd /c tools\doctor.bat               (环境自检 + 漂移检测, 2 秒)
6. 跑 python tools\fpga_workflow.py verify  (确认基线 PASS 12)
7. 按剩余时间取舍: fmax 物理优化 / GEMM 的 C 读回 / ILA 波形与分析报告（P2 定时器中断、
   Cache、RV32A 都已闭环或已判定）
8. 上板复跑 (RTL 定稿后一次做; 凡是变快了的改动都要按 R35 重算 ITERATIONS)
9. 断电自举镜像 (可选交付项): powershell -File tools\flash_boot.ps1 -Iface SPIx4
   (已打通并逐字节校验过, 见第 7 节 + tools/flash_logs/REPORT.md)
```

> ✅ P0（重建评分版）、P1（异常/中断接线）、P2（定时器中断）、P3 实验 A、P4（RAS/gshare 判定）、
> P8（删冗余 `if_id_reg`）**都已完成**；P3 的实验 B/C 曾因宏失效作废，修好宏后已转为默认路径。
> 新优化回合请按 `HANDOFF-WORKFLOW.md` §1.1 的七步循环走，它已固化成
> `skills/fpga-workflow/SKILL.md` 里的标准动作。

**当前三项指标已是可参赛水平（基础任务全完成 + 两级流水 gshare + 完整异常中断）。
最新已上板档 **105 MHz / fmax 106.30 MHz**（对 20 ns 约束下的基线 78.4 是 **+35.6%**，
但跨约束不可直接减）；**当前目标 131.25 MHz 尚未收敛**（WNS −0.963）。**

---

## 13. 本次迭代的完整轨迹（供参考，不必细读）

| 轮次 | 做了什么 | 结果 |
|---|---|---|
| 1-2 | 环境打通、基线剖析、分支预测 | CM/MHz 0.8263 → 1.0274 |
| 3 | RV32M 扩展 + fmax 还债 | → 2.3614，fmax 74.6 |
| 3 | RAS/BTB 扩容实验 | **净亏，回退** |
| 4 | BRAM 存储系统 | LUT 4494 → 2481，CM/LUTs +81% |
| 5-6 | 上板读回基础设施（MMIO + ILA）| — |
| 7-9 | 差距分析、CSR/异常基础、汇编器扩展 | tb_units 通过 |
| 10 | **上板 CoreMark 实测通过** | 10.16s，CRC 判定=1 |
| 11 | 工具化: `check`/`verify`/`synth`/`report` + 技能注册 | 回归 6 PASS + 1 XFAIL → 见下 |
| 11 | **P0** 评分版重建（补 `DMEM_INIT_FILE` + 参数化 `PROG`）| LUT 3679 / fmax 64.0 |
| 11 | **P1** 异常/中断接入 core（Zicsr + 陷阱 + MRET）| **7 PASS**；LUT 3923 / fmax 61.4 |

`PITFALLS` 本轮新增：R4（handler 破坏自己要用的寄存器）、R5（调试标志与事件不同流水级）、
一·五（逐拍诊断: 粘滞标志 + `$fatal` 会让"猜"变成唯一手段）。

git 提交：`e49f801`（原始）→ `97be06f` → `2ca639c` → `9083059` → …（本项目累计 **>130** 次提交，
`git rev-list --count HEAD` 现查 @2026-10-11）

> ⚠️ **上面这张表与本节都是早期轮次的记录**（当时回归 6~7 项）。**当前状态以第 0 节为准**：
> 回归 **PASS 12**（**仿真级**，判据 `fpga_workflow.py verify`）；时钟 `sys_clk_core`；
> 历史已上板档 **105 MHz**（fmax **106.30 MHz**，WNS +0.117 @9.524 ns；LUT 2706 / FF 1290，2026-10-11）；
> 当时目标 131.25 MHz 未收敛（WNS −0.963）；**当前交付档 150 MHz**（2026-10-17）。
> ⚠️ "RTL 已上板验证"这句**必须带时间**：最后一次采集 = **2026-10-11 15:22:41**
> （`results/ila_done.capture.json` + `fpga/cap_done.log`）；本节括号里的 tick 536,943,384 / 10.74 s
> 是 2026-10-08 的历史值。本节保留是为了记录当时的演进过程。