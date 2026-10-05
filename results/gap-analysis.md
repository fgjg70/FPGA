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
| **完整异常 / 中断** | ✅ **已完成** | `csr_file.sv` 已接入 `core.sv`: Zicsr 读改写 + ECALL/EBREAK/非法指令异常 + MRET + mstatus 语义; `tb_core_trap` 由 XFAIL 转为 PASS, 全套回归 7 PASS |
| 2 路组相联 I/D Cache + 总线突发 | ❌ 未做 | BRAM 前置条件已满足 ✅（行为级推断, 4×RAMB36）; 缺突发总线协议 |
| AI 加速单元 | ❌ 未做 | — |

> 异常/中断**只差定时器中断**（P2）：`irq_timer` 目前硬接 `1'b0`，
> 需在 `mmio_subsys.sv` 实现 mtimecmp 后接过来（`csr_file` 那一侧已就绪）。

## 评分三项（当前实测）

| 指标 | 基线 | 当前 | 变化 |
|---|---|---|---|
| CoreMark/MHz | 0.8263 | **2.3614** | +185.8% |
| 最高时钟频率 | 78.4 MHz | **64.4 MHz** | −17.9% |
| CoreMark/LUTs | 2.361e-4 | **5.986e-4** | +153.5% |

资源：LUT 3945 / FF 1333 / BRAM 4 / DSP 8（评分版，含 P1，不含 ILA）
绝对吞吐 = CoreMark/MHz × fmax = **152.1**（基线 64.8，+134.7%）

**fmax 是三项里唯一大幅退步的**，也是当前最大失分点。已完成的还债：
- P1 带来的 −4.1%（61.4）已由 **P3 实验 A**（跳转目标专用加法器）挣回到 **64.4**
- 距基线 78.4 还差 17.9%；剩余根因与方案见 `results/p3-fmax.md` 与 `HANDOFF.md` P3

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

1. ~~异常 / 中断~~ ✅ **已完成**（原为"高阶任务里最接近完成的一项")
2. ~~收尾上板闭环~~ ✅ 已上板实测 10.16 s（P0/P1 的新 bitstream 待复跑）
3. **fmax 还债** —— 三项指标里唯一大幅退步的; 实验 A 已挣回 +4.9%,
   下一步的盈亏平衡账已算清（见 `results/p3-fmax.md`）
4. **P2 定时器中断** —— 低难度, 补齐"完整中断"的最后一块
5. **分析报告** —— 数据齐全, 补 ILA 波形即可成文
6. Cache / AI 加速 —— 工作量大, 视剩余时间决定

## 工程纪律（本轮新增）

判据与工具已固化, 不再靠人盯:

```bat
cmd /c tools\doctor.bat                          REM 环境自检 + R1 漂移检测
python tools\fpga_workflow.py verify             REM 增量回归, 期望 7 PASS
python tools\fpga_workflow.py profile            REM 优化前先测量停顿构成
python tools\fpga_workflow.py synth --tag X --record   REM 综合 -> 四项指标
python tools\fpga_workflow.py metrics --vs <tag> REM keep/reject 判定
```
