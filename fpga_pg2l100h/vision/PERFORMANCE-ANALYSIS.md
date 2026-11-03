# 性能分析报告 — CoreMark 流水线效率（最终版 PG2L100H）

> **口径（以最终版紫光为准）**：本文所有数据来自**紫光同创 PG2L100H** 最终工程 `fpga_pg2l100h/vision/` 的 RTL 与官方 EEMBC CoreMark 固件；Artix-7 线仅作跨厂商对比，不出现在本文结论中。
> 依据文档：根 `COMPLIANCE.md`（证据分级）、`BOARD_VALIDATION.md`（上板）、`CLOCK_SPLIT.md`（125/50 MHz 双时钟域）。
> 赛题要求：分析 CPU 执行 CoreMark 关键算法时的**流水线效率**（ILA 非强制；本文用周期级仿真计数 + 可选 ILA 流程）。

## 1. 测试平台与方法

| 项 | 配置 |
|---|---|
| 器件/工具 | 紫光同创 PG2L100H（Logos2 / -6 / FBG676），PDS 2022.2-SP6.1 |
| 时钟 | CPU/IMEM/DMEM **125 MHz**（8 ns）；系统/MMIO/采集 **50 MHz**（20 ns）；NPU 50 MHz |
| 基准程序 | EEMBC **CoreMark**，固定 revision `1f483d5b8316753a742cbf5590caf5bd0a4e4777`，逐文件 SHA256 校验（`competition/coremark.py`） |
| 编译 | riscv-none-elf-gcc 15.2.0；`-O2 -march=rv32im -mabi=ilp32 -DPERFORMANCE_RUN=1 -DTOTAL_DATA_SIZE=2000 -DITERATIONS=N`（另有对照配方见 §4） |
| 仿真 | ModelSim SE-64：完整 `vision_soc` RTL + `tb_coremark.v`，CPU 时钟 8 ns、系统时钟 20 ns，UART 提速仅用于仿真打印 |
| 测量口径 | CoreMark 自报 `CM64 ticks=... clock=50MHz cpu=125MHz iterations=N`（测量窗口）；**CPU 周期 = timer_ticks × (125/50)**；`CoreMark/MHz = iterations × clock / ticks / (cpu/1e6)` |
| 周期级计数 | 仿真 TB 分层引用 `dbg_stall` / `dbg_redirect` / `u_hazard.*` / `u_muldiv.busy` / `u_mem_wb.ctrl`，统计停顿、误预测、乘法占用与真退休指令数 |

> 说明：CoreMark 要求单次运行 ≥10 s；短迭代仿真只用于**功能与周期效率**测量（代码会打印"Errors detected: <10s"），不用于宣称正式跑分。正式成绩需在板上按 `competition/coremark.py` 做 ≥10 s 跑分并保留原始串口日志。

## 2. 基线结果

| 配方 | 10 次迭代 timer ticks | CPU 周期/迭代 | **CoreMark/MHz** | CoreMark@125 MHz |
|---|---:|---:|---:|---:|
| `-O2`（基线） | 1,563,830 | **390,958** | **2.5578** | 319.7 |
| `-O2 + -mbranch-cost=1 -fira-loop-pressure` | 1,554,600 | 388,650 | 2.5730（+0.60%） | 321.6 |

- 测量窗口 CPU 周期（10 迭代）= 3,909,575；真退休指令数（全运行）= 3,002,714；**CPI（全运行）= 1.356**，CoreMark 窗口 CPI ≈ **1.30**。
- 结论：最终版 CPU 在当前 RTL 与官方 CoreMark 固件下，架构效率基线为 **≈2.56 CoreMark/MHz**。

## 3. 流水线效率剖析

### 3.1 停顿/误预测总览（10 次迭代 + 启动/打印，总周期 4,072,392）

| 事件 | 周期数 | 占全运行 |
|---|---:|---:|
| 流水线停顿合计（`pipe_stall`） | 998,047 | **24.5%** |
| ├ load-use（EX 级 load 依赖） | 218,409 | 5.4% |
| ├ load-use（MEM 级 load 依赖） | 397,174 | 9.8% |
| ├ LSU 拆分/多拍访存（`lsu_stall`） | 95,760 | 2.4% |
| └ EX 忙（乘/除多周期） | 380,550 | 9.3% |
| 　├ **乘法 busy** | **282,174** | **6.9%** |
| 　└ 除法 busy | 4,191 | 0.1% |
| 分支预测错误（`dbg_redirect` 拍数） | 35,807 | 0.88% |

> 解读：① **乘法多周期是最大的单一来源**（282k 周期，全部集中在 matrix 相位）；② load-use 相关停顿合计约 15%，主要集中在 list（链表）相位；③ 分支预测错误率很低（0.88%），不是当前主要矛盾。

### 3.2 分相位效率（按 CoreMark 关键算法 PC 区间统计，10 次迭代）

| 相位（PC 区间） | 周期数 | 占比 | 相位内停顿率 | 误预测数 | 乘法 busy 周期 | load-use(EX/MEM) |
|---|---:|---:|---:|---:|---:|---:|
| list（链表：insert/find/mergesort/bench） | 1,221,637 | **30.0%** | 31.0% | 11,157 | 6 | 185,568 / 194,773 |
| matrix（矩阵：init/mul/add/bitextract/bench） | 1,339,491 | **32.9%** | 29.3% | 3,960 | **282,156** | 0 / 16,240 |
| state（状态机：init/transition/bench） | 963,094 | **23.7%** | 11.4% | **20,009** | 0 | 24,120 / 85,400 |
| CRC（crcu8/16/32、crc16） | 399,464 | 9.8% | 0.6% | 2 | 0 | 0 / 2,284 |
| 启动/打印/其他 | 148,706 | 3.7% | 77.8% | 679 | 12 | — |

**相位结论**
1. **matrix 相位**（32.9% 周期）几乎全部乘法 busy 都发生在这里：矩阵乘/位提取需要大量 RV32M 乘法 ⇒ 乘法器延迟直接决定该相位效率（当前 3 拍 busy）。
2. **list 相位**（30.0%）以 load-use 停顿为主（相位内 31%），链表遍历/插入的 load→use 依赖密集 ⇒ 加载结果前递/减少 load-use 拍数是第二优化方向。
3. **state 相位**（23.7%）分支密度高，20,009 次误预测占全核 56%，但每次代价小、总量占比不高；先不动预测器。
4. CRC 相位效率高（0.6% 停顿），说明基础五级流水在规则计算下 CPI 接近理想。

## 4. 优化实验（当前轮）

> 全部在**最终版 RTL** 上以相同官方 CoreMark 固件（`-O2`，10 迭代）仿真测量；CRC 与官方参考一致（`crclist 0xe714 / crcmatrix 0x1fd7 / crcstate 0x8e3a`）。

| 实验 | 改动 | CPU 周期/迭代 | CoreMark/MHz | 相对基线 | CRC |
|---|---|---:|---:|---:|---|
| 基线 | 乘法 3 拍 busy | 390,958 | 2.5578 | — | ✅ |
| **OPT-1** | 32×32 组合乘（乘法 0 额外拍，busy 仅除法） | 362,770 | **2.7566** | **+7.77%** | ✅ |
| **OPT-2** | 组合乘+寄存（乘法 1 拍 busy，省 2 拍） | 372,216 | **2.6870** | **+5.05%** | ✅ |
| **OPT-3 ✅** | 乘法两级流水（部分积寄存 → 下一拍合并，2 拍 busy） | **381,562** | **2.6208** | **+2.46%** | ✅ |

- 实测收益与 §3.1 的乘法 busy 占比一致：OPT-1 吃掉全部乘法停顿；OPT-2 约 2/3；OPT-3 约 1/3（省 1 拍）。
- **OPT-3 已通过最终版自带单元测试**：`sim/tb_muldiv.v` **2560 条 RV32M 边界/随机用例全 PASS**（含有符号/无符号高位积、混合符号、除零、有符号溢出），CoreMark CRC 与官方参考一致。
- **时序判断（以 Pango 125 MHz 为准）**：OPT-1/OPT-2 把 32×32 乘法放进 EX 组合路径，会显著拉长关键路径；本文只给出**周期收益上限**，能否上板取决于 **PDS 在 125 MHz 下重新综合/布局布线的 WNS**，需由有 PDS 的机器复核后决定。OPT-3 的关键路径改为"部分积寄存器 → 加法树 → product 寄存器"，不经过 EX 组合乘，是**当前推荐**的乘法优化方案。
- 编译配方对照：`-mbranch-cost=1 -fira-loop-pressure` 仅 +0.60%，远小于 RTL 乘法优化，说明继续挖 RTL 的性价比更高。

## 5. 时序可行性与后续优化路线

| 方向 | 预期收益（按 §3 数据） | 代价/风险 | 优先级 |
|---|---|---|---|
| **乘法两级流水（OPT-3，已仿真验证）** | **+2.46% CM/MHz**（2.5578→2.6208） | 关键路径移到"部分积寄存器→加法树"，需 PDS 125 MHz 复核；失败则退回 3 拍 | **P0（已完成 RTL 验证）** |
| ~~乘法器直接组合乘（OPT-1/OPT-2）~~ | +5.0~7.8%（已仿真验证） | 大幅拉长 EX 关键路径，PDS 125 MHz 风险高，仅作理论上限 | 暂不采用 |
| load-use 减少 1 拍（MEM 级 load 结果前递/旁路） | 约 +2~4%（list/state 相位为主） | 需改 hazard/forwarding，功能回归 | P1 |
| 分支预测器微调（state 相位误预测） | ≤1% | 收益有限，先不动 | P3 |
| 编译配方继续 sweep（如 `-O3` 体积允许时） | ≤1~2% | 16 KB IMEM 体积限制 | P2 |
| 取指/发射宽度、双发射 | 大（>10%） | 架构级改动，周期风险高 | 后续 |

**验收口径**：RTL 优化后必须同时满足——① 仿真 CoreMark CRC 与官方一致；② PDS 125 MHz（CPU 域）WNS ≥ 0、50 MHz 域 WNS ≥ 0；③ 板上 ≥10 s 正式跑分并保留原始串口日志（`validation/coremark_hardware.json`）；④ 本文档与 `BOARD_VALIDATION.md` 数字同步更新。

## 6. ILA（可选）

赛题不强制 ILA；本文流水线效率由**周期级仿真计数**给出（可复现、可逐拍归因）。若答辩需要实物波形，可按以下方式补抓（不改变上述结论）：
- 抓取信号：`dbg_pc`、`dbg_stall`、`dbg_redirect`、`id_ex` 的 `mem_read/reg_write/rd`、`u_muldiv.busy`、`u_mem_wb.ctrl`；
- 触发：`dbg_pc` 落入 CoreMark matrix 相位区间（见 §3.2 的地址区间）并持续 1 帧；
- 分析：统计窗口内 `stall/redirect/mul_busy` 占比，与 §3.1/§3.2 表对照（误差应 <2%）。
- 注意：ILA 会增加资源并影响时序，抓取位流需单独记录 SHA256，不得与交付位流混用。

## 7. 复现

1. 构建官方 CoreMark 固件：`fpga_pg2l100h/vision/build.py --prepare-only --profile coremark --iterations 10`（需 GCC 15.2.0；源固定 revision 见 §1）。
2. 用 `sim/tb_coremark.v`（本报告使用其加计数器的变体）在 ModelSim 中仿真 `vision_soc`，CPU 时钟 8 ns、系统时钟 20 ns。
3. 从日志读取 `CM64 ticks`、`CM64` 中的 `clock/cpu` 字段，按 §1 公式计算 CoreMark/MHz；周期级计数取 TB 打印的 stall/redirect/mul_busy。
4. 正式板级跑分：`competition/coremark.py --log <串口原始日志> --output validation/coremark_hardware.json`（要求 ≥10 s、CRC 全对）。

> 版本：2026-11-03 · 对象：`fpga_pg2l100h/vision`（最终版紫光 PG2L100H）· 数据均由仿真/综合实测，未标注来源的数字不得引用。
