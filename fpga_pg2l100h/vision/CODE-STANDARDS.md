# 代码规范（CODE-STANDARDS.md）

> **适用范围**：以**最终版紫光同创 PG2L100H 工程** `fpga_pg2l100h/vision/` 为准（下称"最终版"）。本规范对应赛题"技术实现与文档"评分项：
> (1) **代码规范**：模块化程度、时序约束的合理性、注释的完整性；
> (2) **分析报告**：见 [`PERFORMANCE-ANALYSIS.md`](PERFORMANCE-ANALYSIS.md)。
> Artix-7 线（`fpga/`、根目录 `*.sv`）仅作跨厂商对比，不适用本规范的交付判定。

## 1. 模块化规范

### 1.1 目录与文件
| 位置 | 内容 | 规则 |
|---|---|---|
| `rtl/cpu/` | RISC-V CPU 核（19 个 `.v`） | 一个模块一个文件；文件名 = 模块名（小写下划线） |
| `rtl/` | SoC/视频/NPU/MMIO/时钟顶层（`vision_soc.v`、`vision_npu.v` 等） | 同上；顶层只做连线与例化，不放算法 |
| `sim/` | `tb_*.v` 自检测试台 | 每个模块至少一个 `tb_<module>.v`；打印 `PASS/FAIL` 判据 |
| `firmware/` | 裸机 C/汇编/链接脚本 | 硬件相关地址集中定义，禁止散落魔数 |
| `model/` | 权重/偏置/字体/模型 JSON | 权重文件必须可追溯（SHA256 见 `model/*.json`） |
| `competition/` | 赛题口径脚本（CoreMark 移植/解析） | 官方源固定 revision + 逐文件 SHA256 |

### 1.2 模块接口
- 端口顺序：`clk`, `rst`（或 `cpu_clk`, `cpu_reset`）→ 输入 → 输出 → 双向/调试口；按功能分组并加注释。
- 所有端口显式声明方向与位宽；**禁止**隐式线网（Vivado/PDS 会报 warning 的写法一律不提交）。
- 跨时钟域信号：**只有**专用模块可做 CDC（本工程：`vision_mmio_bridge.v`、`vision_video_bridge.v`、`camera_dvp_capture.v`、`vision_snapshot.v`）；其他模块只接收单一域信号。
- 复位：统一异步置位/同步释放（顶层 `cpu_reset` 由时钟模块产生）；模块内部不得自造复位。
- **零厂商原语**：除顶层时钟模块（PLL/GPLL 原语）与 I/O 缓冲外，RTL 只用可综合行为级描述；BRAM 用"寄存器数组 + 同步读"推断，不例化 IP。
- 禁止 latch、组合环、未初始化寄存器输出；`case` 必须有 `default`；算术/移位显式位宽。

### 1.3 参数与常量
- 位宽/深度/地址/延迟用 `parameter`/`localparam` 表达，禁止重复魔数。
- 地址映射集中在 CPU 包的常量（`rv32_pkg` 等价定义）与 SoC 顶层；模块内不得硬编码 `0xA1000000` 之外的设备地址。
- 所有"周期数/延迟"注释必须与 RTL 实际行为一致（例：`EXTERNAL_WAIT=1` 的外设访问握手）。

## 2. 注释完整性规范

### 2.1 模块头模板（每个 `.v` 必须有）
```verilog
// ============================================================================
// module_name — 一句话功能
// ----------------------------------------------------------------------------
// 功能      : 这个模块做什么（不超过 3 行）
// 时钟/复位  : clk=<name> (<freq>); rst=<同步/异步，极性>
// 延迟/吞吐  : 关键路径拍数、每拍吞吐、是否多周期（与 busy 握手关系）
// 参数      : 每个 parameter 的含义与合法取值
// 端口分组   : 按功能说明各端口语义（尤其是握手/valid-ready）
// 参考证据   : 对应文档/测试/踩坑编号（例：BOARD_VALIDATION.md、tb_muldiv.v）
// ============================================================================
```
- 已有模块若缺头注释，**修改该文件时必须补齐**；不要求一次性回填全部历史文件，但新增/改动文件必须合规。
- 行内注释解释 **为什么**（设计取舍/时序/协议约束），不重复代码字面。
- 数值必须带单位与口径（`cycles`、`ns`、`MHz`、`bytes`）；引用实测数字必须标级别（见根 `COMPLIANCE.md` 的证据分级 A/B/C/D/E），不得把派生/仿真值写成"实测"。
- 注释语言：中文为交付口径（与 `COMPLIANCE.md` 一致）；`timescale`、端口名、参数名保持英文。
- 变更 RTL 时同步更新：模块头、相关行内注释、`BOARD_VALIDATION.md`/`PERFORMANCE-ANALYSIS.md` 中的数字；**不允许注释与代码/文档前后不一致**（赛题评分明确要求）。

### 2.2 关键点必须注释
- 流水线冒险/前递/停顿的来源与拍数（hazard_unit、core 停顿逻辑）；
- 多周期部件（乘除、除零/溢出特例、busy/done 协议）；
- 分支预测器结构（BTB 容量/tag/PHT 位宽/更新时机）与已知误判场景；
- 跨时钟域同步器结构（2FF/握手/异步 FIFO）与约束依据；
- 外设寄存器位定义（MMIO 偏移/位域/读写语义），与固件头文件一一对应；
- 内存初始化（IMEM/DMEM/BRAM init 文件）与构建脚本的传递关系。

## 3. 时序约束规范（Pango 最终版）

### 3.1 约束文件
- 最终版约束以 `fpga_pg2l100h/vision` 工程生成/引用的 `.fdc` 为准；板级调试工程参考 `fpga_pg2l100h/camera_lcd_debug/pg2l100h_camera_lcd.fdc` 的写法（时钟、IO、false path 成组、逐条注释）。
- 约束必须与 RTL 同源：`create_clock` 周期、PLL 的 `IDIV/FBDIV/ODIV`、`create_generated_clock -multiply_by/-divide_by` 三者一致；任何频率变更三处同改。

### 3.2 本工程时钟清单（最终版）
| 时钟 | 频率/周期 | 来源 | 约束方式 |
|---|---|---|---|
| 系统时钟 50 MHz | 20.000 ns | 板载晶振 `clk` | `create_clock` |
| CPU / IMEM / DMEM | **125 MHz**（8.000 ns） | GPLL（CPU 域） | `create_generated_clock`（对 PLL 输出） |
| 视频域 | 27 MHz（37.037 ns） | 视频 PLL / GPLL | `create_generated_clock` |
| LCD 像素 | 9 MHz（111.111 ns） | 27 MHz ÷3 | `create_generated_clock -divide_by 3`（对 `lcd_dclk`） |
| 摄像头 MCLK | 12.5 MHz（80 ns） | 分频输出 | 输出时钟约束/IO delay |

### 3.3 约束规则
- 所有时钟必须显式约束；禁止依赖工具自动推导名（历史教训：自动名 `sys_clk_raw` 导致报告对不上）。
- 异步域（视频/摄像头 ↔ CPU/MMIO）：用 `set_clock_groups -asynchronous` 分组，并在 CDC 模块里给出同步器证据；**不允许**用 `set_false_path` 掩盖真实数据通路。
- 静态配置/按键/UART 等慢速 IO：按同步/去抖结构处理，必要时按 IO delay 约束，不滥用 false path。
- 输出接口（LCD、摄像头控制）必须约束 output delay；输入接口（PCLK/DVP、按键）约束 input delay 或按同步域处理。
- 每次 P&R 后检查：`report_timing_summary` 全部时钟 WNS ≥ 0、无 unconstrained endpoints、无组合环、无未约束 IO；结果记入 `BOARD_VALIDATION.md`（含位流 SHA256）。

### 3.4 当前时序基线（2026-11-03，位流 `f179a403…`）
| 时钟域 | 约束 | WNS | 结论 |
|---|---|---|---|
| CPU/IMEM/DMEM | 125 MHz | **+0.609 ns** | MET |
| NPU/采集/MMIO（50 MHz 域） | 20 ns | **+7.052 ns** | MET |

> RTL 优化（如 `PERFORMANCE-ANALYSIS.md` 中的乘法器改动）后必须**重新约束检查并更新本表**；性能提升不能以时序不收敛为代价。

## 4. 提交前检查清单

1. `fpga_pg2l100h/vision/build.py --prepare-only` 固件/工程可生成；严格 Verilog-2005 编译 0 error。
2. 相关 `tb_*.v` 仿真 PASS（含 CoreMark 功能跑通、CRC 与官方参考一致）。
3. PDS 综合/布局布线 0 error、全部约束 MET；记录 WNS/LUT/FF/APM/DRM 与位流 SHA256。
4. 头注释/行内注释与 RTL、`BOARD_VALIDATION.md`、`PERFORMANCE-ANALYSIS.md` 数字一致；无未标注级别数字。
5. `docs/COMPLIANCE.md` §4 边界清单中的未达成项未被写成"已完成"。
6. 新增/修改文件按本规范审查后，在 commit message 写清：改了什么、为什么、证据路径。

## 5. 相关文档

- [`PERFORMANCE-ANALYSIS.md`](PERFORMANCE-ANALYSIS.md) — CoreMark 流水线效率分析（最终版）
- [`BOARD_VALIDATION.md`](BOARD_VALIDATION.md) — 上板验证记录（时序/位流/证据）
- [`CLOCK_SPLIT.md`](CLOCK_SPLIT.md) — 125/50 MHz 双时钟域说明
- 根 `COMPLIANCE.md` — 证据分级、禁用词、交付边界
