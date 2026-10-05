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
| **运行 ≥10 秒** | ✅ | **上板实测 10.16 s**（1200 次迭代, `results/hw-verified.md`）|

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

## 评分三项（当前实测）

| 指标 | 基线 | 当前 | 变化 |
|---|---|---|---|
| CoreMark/MHz | 0.8263 | **2.3611** | +185.8% |
| 最高时钟频率 | 78.4 MHz | **70.9 MHz** | −9.6% |
| CoreMark/LUTs | 2.361e-4 | **9.347e-4** | +295.9% |

资源：LUT 2526 / FF 1377 / BRAM 8 / DSP 8（评分版，含 P1+P2+P3，不含 ILA）
绝对吞吐 = CoreMark/MHz × fmax = **167.5**（基线 64.8，+158.5%）

> CoreMark/MHz 相对基线 **+185.8%**，是本核最强的一项。
> fmax 从 P1 后的 61.4 挣到 **75.0**（P3 三项实验，+22.2%），
> P2 补中断后又回落 5.5% 到 **70.9** —— 那是**用频率换功能完成度**，已留痕。

**fmax 还债全程**（曾是最大失分点）：

| 阶段 | fmax | LUT | 绝对吞吐 |
|---|---|---|---|
| P1 之后 | 61.4 | 3923 | 145.0 |
| 实验 A：跳转目标专用加法器 | 64.4 | 3945 | 152.1 |
| 实验 B：imem 改寄存读进 BRAM | 65.3 | 2656 | 154.2 |
| **实验 C：load 结果走 MEM/WB 寄存器** | **75.0** | **2444** | **177.1（历史最好）** |
| P2：定时器中断 | 70.9 | 2526 | 167.5（换功能）|

详见 `results/p3-fmax.md` / `p3-imem.md` / `p3-load-result.md` / `p2-timer-irq.md`。
**当前关键路径 route 已占 73%** → 设计进入布线受限区间，后续提 fmax 需物理手段。

## 其他评分维度

| 项 | 状态 | 说明 |
|---|---|---|
| 代码规范: 模块化 | ✅ | 19 个独立模块, 职责单一 |
| 代码规范: 注释完整性 | ✅ | 每个模块头部有设计意图 + 踩坑记录 |
| 代码规范: 时序约束合理性 | ✅ | XDC 有 create_clock + 引脚约束 + 约束理由注释 |
| **分析报告 (含 ILA 波形)** | ⏳ | 数据齐全 (`results/*.md` + `ila_pipeline.csv`), **ILA 波形待抓** |
| 应用场景构建 | ❌ 未做 | — |
| AI 模型性能 | ❌ 未做 | — |
| 可移植性 (无厂商 IP) | ✅ | BRAM 行为级推断; 仅顶层需要按厂商重写 |

## 优先级建议（更新）

1. ~~收尾上板闭环~~ ✅ 已上板实测 10.16 s —— **但 P0/P1/P2/P3 之后的新 bitstream 待复跑**
2. ~~异常 / 中断~~ ✅ **已完成**（P1 异常 + P2 定时器中断）
3. ~~fmax 还债~~ ✅ **已完成**（61.4 → 75.0，+22.2%）
4. **上板复跑**（P4）—— 当前 bitstream 未验证, 是唯一的阻塞项
5. **ILA 波形 + 分析报告** —— 数据齐全（`results/*.md` + `ila_pipeline.csv` 2048 拍），
   补波形即可成文；这是"其他评分维度"里唯一还缺的
6. Cache / AI 加速 —— 工作量大；AI 需要先定义应用场景与模型接口

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
