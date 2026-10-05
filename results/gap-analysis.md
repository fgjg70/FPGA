# 赛题差距分析 — 对照「紫光同创杯 2026 选题一」

> 更新于 2026-10-05（P1 异常/中断接入 + P3 实验 A 之后）。
> 指标数字以 `python tools/fpga_workflow.py report` 从 `results/coremark.csv`
> 重算的结果为准 —— 那是当前唯一可复现的口径。历史行里的 `LUT 2481` 等
> 用当前代码复现不出来，原因见 `HANDOFF.md` 第 6 节 P1 小节末尾。

## 基础任务（必须完成）

| 要求 | 状态 | 证据 |
|---|---|---|
| RV32I 通用处理单元 | ✅ | 9 个 opcode 全部译码: OP/OPIMM/LOAD/STORE/BRANCH/LUI/AUIPC/JAL/JALR |
| **≥3 级流水线** | ✅ | 5 级 IF/ID/EX/MEM/WB |
| 数据冲突处理 | ✅ | EX/MEM + MEM/WB 前递 + load-use 停顿 1 拍 |
| 分支处理 | ✅ | 64 项 BTB + 2 位 Smith 方向预测器, 精度 88.7%（实测) |
| **外设集成 UART** | ✅ | mmio_subsys: 115200 8N1 TX+RX, 回环自测通过 |
| **外设集成 GPIO** | ✅ | MMIO_GPIO_OUT / GPIO_IN |
| 定时器 | ✅ | 64 位自由运行周期计数器 (CoreMark 计时依赖它) |
| 地址译码 | ✅ | DMEM 窗口 -> 内部 dmem; 其它 -> ext_* 总线 |
| 工具链 riscv32-unknown-elf-gcc | ✅ | xpack riscv-none-elf-gcc 15.2.0 |
| 基准 CoreMark v1.0 | ✅ | CRC 逐位匹配官方值 |
| **运行 ≥10 秒** | ✅ | **上板实测 10.16 s**（含 P1+P2+P3 的当前 bitstream 复跑同样 10.16 s）|

## 高阶任务（加分项）

| 要求 | 状态 | 差距 |
|---|---|---|
| **动态分支预测 (BTB)** | ✅ | 已完成, 是 CoreMark/MHz +24% 的主因 |
| **完整异常 / 中断** | ✅ **已完成** | Zicsr 读改写 + ECALL/EBREAK/非法指令异常 + **mtimecmp 定时器中断** + MRET + mstatus 语义; handler 用 mscratch 保存/恢复现场; 回归 **8 PASS**（`tb_core_trap` + `tb_soc_timer_irq`）|
| 2 路组相联 I/D Cache + 总线突发 | ❌ 未做 | BRAM 前置条件已满足 ✅（行为级推断, 8×RAMB36）; 缺突发总线协议 |
| AI 加速单元 | ❌ 未做 | 需要先定义应用场景与模型接口 |

> 「完整异常/中断」**已无缺口**：P1 做同步异常，P2 补定时器中断
> （`irq_timer` 原为硬接 `1'b0` 的死线，现已接到 `csr_file` → `mip.MTIP`）。
> 过程中修掉一个 RISC-V 合规性 bug（`mcause` 中断位错放在 bit4 而非 bit31），
> 详见 `results/p2-timer-irq.md`。

## 评分三项（当前实测 · 四宏全关 · 上板已验证）

| 指标 | 基线 | 当前 | 变化 |
|---|---|---|---|
| CoreMark/MHz | 0.8263 | **2.3611** | **+185.8%** |
| 最高时钟频率 | 78.4 MHz | **61.6 MHz** | −21.4% |
| CoreMark/LUTs | 2.361e-4 | **5.875e-4** | **+148.8%** |

资源：**LUT 4019 / FF 1387 / BRAM 4 / DSP 8**（评分版，不含 ILA）
绝对吞吐 = CoreMark/MHz × fmax = **145.4**（基线 64.8，**+124.4%**）

> ⛔ 此前写的 `70.9 MHz / LUT 2526 / 9.347e-4 / 167.5` **不可复现** —— 那对应
> "架构宏全开"的配置，而该配置**仿真跑不过**（宏在仿真侧从未生效，见 PITFALLS R17）。
> 三个宏（`IMEM_REG_READ` / `LOAD_RESULT_REG` / `BTB_GSHARE`）与 `RAS_EN` 已全部
> 回退为默认关闭，与**上板验证过的配置**一致。完整事故记录见 `results/p4-macro-failure.md`。

资源：**LUT 4019 / FF 1387 / BRAM 4 / DSP 8**（评分版，不含 ILA）
绝对吞吐 = CoreMark/MHz × fmax = **145.4**（基线 64.8，**+124.4%**）

> CoreMark/MHz **+185.8%** 是本核最强的一项，且**不受本次事故影响**
> （分支预测 / M 扩展都是早期完成、与那三个宏无关）。
> 受损的是资源与 fmax —— 而这两项恰恰取决于取指流水的重排（见下）。

**fmax 还债的进展（只列有效项）**：

| 阶段 | fmax | LUT | 绝对吞吐 | 有效性 |
|---|---|---|---|---|
| P1 之后 | 61.4 | 3923 | 145.0 | — |
| **实验 A：跳转目标专用加法器** | **64.4** | 3945 | **152.1** | ✅ 有效且保留 |
| ~~实验 B：imem 改寄存读~~ | ~~65.3~~ | ~~2656~~ | ~~154.2~~ | ⛔ **作废**（功能不正确）|
| ~~实验 C：load 结果走 MEM/WB~~ | ~~75.0~~ | ~~2444~~ | ~~177.1~~ | ⛔ **作废**（功能不正确）|
| P2：定时器中断 | — | — | — | ✅ 功能项 |
| P4：RAS / gshare | — | — | — | ❌ 实测净亏，默认关闭 |
| **当前（四宏全关）** | **61.6** | **4019** | **145.4** | ✅ 上板已验证 |

> **回退到实验 A 之后的状态**是当前唯一"功能正确 + 上板验证"的配置。
> fmax 要继续提升，必须先做**取指流水重排**（`IMEM_REG_READ`，LUT −1228 = 全核 31%），
> 方案与四轮失败记录见 `results/p4-macro-failure.md` 第 5.1 节。
> **当前关键路径 route 已占 73%** → 设计进入布线受限区间，纯改 RTL 收益有限。

## 其他评分维度

| 项 | 状态 | 说明 |
|---|---|---|
| 代码规范: 模块化 | ✅ | 20 个独立模块, 职责单一 |
| 代码规范: 注释完整性 | ✅ | 每个模块头部有设计意图 + 踩坑记录 |
| 代码规范: 时序约束合理性 | ✅ | XDC 有 create_clock + 引脚约束 + 约束理由注释 |
| **分析报告** | ✅ **已成文** | `results/analysis-report.md`（含 ILA 波形分析、优化全过程、失败记录）|
| 应用场景构建 | ❌ 未做 | — |
| AI 模型性能 | ❌ 未做 | — |
| 可移植性 (无厂商 IP) | ✅ | BRAM 行为级推断; 仅顶层需要按厂商重写 |

## 优先级建议（更新）

1. ~~收尾上板闭环~~ ✅ 已完成（含全部改动的 bitstream 已上板验证）
2. ~~异常 / 中断~~ ✅ 已完成（P1 异常 + P2 定时器中断，回归 8 PASS）
3. ~~分析报告成文~~ ✅ 已完成（`results/analysis-report.md`）
4. ~~预测器调优~~ ✅ 已试过 RAS 与 gshare，**均实测净亏并拒绝**（留痕在 results/）
5. **Cache（2 路组相联 + 总线突发）** ← **当前最高价值的功能缺口**（赛题高阶任务）
6. **AI 加速单元 + 应用场景** ← 第二块功能缺口（需先定义场景与接口）
7. **取指流水重排** —— 能把 LUT −31% 与 fmax 一起拿回来，但零功能收益、风险高，
   排在功能项之后

**结论：基础任务 + 动态分支预测 + 完整异常中断三大块已全部完成并上板验证；
分析报告已成文；性能调优的"低垂果实"已摘尽。剩余是 Cache / AI 两个功能大项。**

## 工程纪律（已固化）

判据与工具不再靠人盯:

```bat
cmd /c tools\doctor.bat                          REM 环境自检 + R1 漂移检测
python tools\fpga_workflow.py verify             REM 增量回归, 期望 8 PASS
python tools\fpga_workflow.py profile            REM 优化前先测量停顿构成
python tools\fpga_workflow.py synth --tag X --record   REM 综合 -> 四项指标
python tools\fpga_workflow.py metrics --vs <tag> REM keep/reject 判定
```

按层次查资源（定位"某模块被实现成了什么"，普通 report_utilization 看不出来）:

```bat
vivado -mode batch -nojournal -log hier_util.log -source tools/hier_util.tcl
```
