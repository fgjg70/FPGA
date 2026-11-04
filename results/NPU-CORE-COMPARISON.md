# 库内 NPU / 加速器核对比

> 🔴 **本文已被 [`NPU-INVENTORY.md`](NPU-INVENTORY.md) 取代（2026-11-04 晚）。**
> 已知错误：① GEMM 行数写"220"，实际 **249**；② 把**已判失败并移除**的 `gemm_accel` 与另两族平列（会误导为"三个可用加速器"）；
> ③ 表格里 vision NPU 的"1,769,238 拍"是 **1 lane** 的数，板上实际是 **4 lane / 242,310 拍**（口径混用）；
> ④ 缺利用率、行业标尺、精度与证据级别对比。
> **请以 `NPU-INVENTORY.md` 为准**；本文仅保留作为演进记录。

> 目的：把仓库里**同时存在的多个神经网络加速核**摆在一起对比，明确各自定位、并行度、存储、算力与证据状态。
> 数据来源：RTL 文件本体 + `results/p5-ai-accelerator.md` + `results/ai-accel/*.md` + `build/dual_j11/*`。
> 最后更新：2026-11-04。

---

## 0. 一句话结论

仓库里其实有**三个家族**的加速器，**并行度差三个数量级**：

| 家族 | 峰值并行度 | 代码量 | 目标场景 | 在哪个分支 |
|---|---|---|---|---|
| **① GEMM 加速器** | **1 MAC/拍** | 220 行 | 通用矩阵乘（教学/接口验证） | `main` |
| **② 视觉 NPU（vision_npu）** | **1 MAC/拍**（主 RTL）／**4 MAC/拍**（板上版） | 185 / 199 行 | NUMGUARD 数字/手势六层 CNN | `main`＋`dual_j11` 快照 |
| **③ v0.7 卷积引擎（nn_conv_engine）** | **128 MAC/拍**（16 OC × 8 px） | **1,574 行**（+ 配套 ≈3,400 行） | YOLO-Fastest / 瓶盖检测 | **仅 `feat/ai-accel`** |

---

## 1. 三个家族的横向对比

| 维度 | ① GEMM 加速器 | ② 视觉 NPU（板上 4-lane 版） | ③ v0.7 卷积引擎 |
|---|---|---|---|
| **RTL 文件** | `gemm_accel.sv` | `build/dual_j11/rtl/vision_npu.v`（**板上**）／`vision/rtl/vision_npu.v`（主 RTL，旧） | `nn_conv_engine.sv` + `nn_subsys/seq/mem/wload/tilecache/pkg` |
| **数据类型** | INT8×INT8 → INT32 | INT8×INT8 → INT32 | INT8×INT8 → INT32（定点 + 移位 requant） |
| **峰值并行度** | **1 MAC/拍** | **4 MAC/拍**（`generate for lane<4`） | **128 MAC/拍**（`OC_LANES=16` × 8 px） |
| **乘法器实现** | 纯 LUT（**故意不用 DSP**） | 纯 LUT（4 个 8×8） | APM/DSP（Artix OOC 报告 DSP 200，目标 ≤160） |
| **支持的算子** | 通用 GEMM（M/K/N 软件可配） | **固定 6 层 CNN**（conv+requant，shift 表 6 项） | conv / dwconv / pool / add / copy / upsample / requant（**112-op 计划**，后融合为 101-op） |
| **权重存储** | 片上 A/B/C 缓冲（64/64/256 字，MMIO 直接可写） | 寄存器数组 ROM：**16K×8b**（4 个 bank 文件 `weights_0..3.hex`，共 256 KB） | **320 KB BRAM ROM**（80 tiles）+ Q 48 KB LUTRAM + A 96KB / B 32KB BRAM |
| **控制方式** | MMIO 逐个触发 + `busy/irq` | **固定 7 态 FSM**（IDLE/SETUP/BIAS_REQ/BIAS_LOAD/REQ/MAC/STORE） | **微码 ROM（112 op）+ `MODE_CPU` 逐 op / `MODE_AUTO` 自主执行** |
| **CPU 接口** | MMIO（`sel/we/re/addr/wstrb`） | 专用端口（`input_write/start/acknowledge`），结果走 `result_address/data` | MMIO（46 寄存器）+ 新增 **Job 接口**（20 寄存器 + 2 KB 结果邮箱） |
| **时钟** | Artix 域（150 MHz 交付档内） | **50 MHz** | **100 MHz 交付 / 122.22 MHz 最高已验证** |
| **实测性能** | **4,608 拍 vs 软件 196,264 拍 = 42.59×**（端到端含搬运 5.38×） | **1,769,238 拍 = 35.38 ms**（纯计算，@50 MHz） | YOLO 112-op **1,049,089 拍**（A7a）／slim **653,129** 拍／瓶盖 106-op **37.63 M 拍 ≈2.5 fps@100MHz** |
| **证据状态** | ✅ 仿真 + 软件对照（`results/p5-ai-accelerator.md`） | ⚠️ 周期数来自文档，原始串口/波形未入库 | ✅ 大量 TB/日志在分支内；❌ 未上板 |
| **所在分支** | `main` | `main`（旧版）／`dual_j11` 快照（**板上**） | `feat/ai-accel`（**未并入 main**） |

---

## 2. 版本演进（同一家族内部的多份）

### 2.1 GEMM 加速器：3 份副本（逻辑相同，编码/EOL 漂移）
| 副本 | 行数 | 说明 |
|---|---|---|
| `gemm_accel.sv`（根） | 220 | 主版本（UTF-8） |
| `fpga_pds_1_0_9/src/gemm_accel.sv` | 249 | PDS 移植副本（注释编码不同，行数差异来自换行/编码） |
| `fpga_mes50hp/src/gemm_accel.sv` | 193 | MES50HP 早期副本 |

### 2.2 视觉 NPU：**两版并存，主 RTL 落后于板上**
| | 主 RTL `vision/rtl/vision_npu.v` | 板上 `build/dual_j11/rtl/vision_npu.v` |
|---|---|---|
| 行数 | 185 | **199** |
| `model_select` | **1 bit**（2 模型） | **2 bit**（`< 2` 有效） |
| 权重 ROM | `weights[0:65535]` = 64K | `weights[0:16383]` = **16K**（每 lane 一份，4 bank 文件） |
| biases | 512 | 128 |
| MAC 结构 | **单累加器 1 MAC/拍** | **4 lane 并行 4 MAC/拍** |
| 结论 | **旧版**，主 RTL 树未跟上 | **板上实际跑的版本** |

> ⚠️ 这意味着：**仓库主 RTL 不能重建板上的位流**。`core.v`（单发射 17.6KB vs 双发射 33.4KB）也是同样情况。

### 2.3 v0.7 卷积引擎：4 代（**仅 `feat/ai-accel`**）
| 代号 | 行数 | 关键变化 | 全模型周期 |
|---|---|---|---|
| `nn_conv_engine_v2b` | 1,102 | 基线 v2 | — |
| `nn_conv_engine_v3` | 1,402 | 128 MAC/拍 + 独立 Q 口 + PACKED3/ADD_R | **1,290,062** @150MHz = 8.60 ms/帧 |
| `nn_conv_engine_A5_ok` | 1,556 | 融合（fused plan 101-op） | **1,167,368** |
| `nn_conv_engine_A7a_ok` | 1,574 | dw 16-lane 保守版（**当前**） | **1,049,089**（−11.9% vs 1,191,020） |

配套模块：`nn_subsys`(672) / `nn_mem`(867) / `nn_seq`(540) / `nn_tilecache`(503) / `nn_wload`(638) / `nn_pkg`(191)。

---

## 3. 三个家族的设计取舍解读

| 取舍点 | ① GEMM | ② 视觉 NPU | ③ v0.7 引擎 |
|---|---|---|---|
| **为什么是这个并行度** | 先把**接口/时序/正确性**做扎实；`results/p5-ai-accelerator.md` 明写"1 MAC/拍 → 约 48×，16 MAC/拍 → 约 766×"，选了保守档 | 六层小模型、50 MHz、要**确定性延迟**；4 lane 是"够用且能塞进 50 MHz 时序"的折中 | 竞赛/加分目标要 **fps**；`NPU-PERF-UPGRADE.md` 拆解显示瓶颈不在 MAC 阵列（只占 50.9% 拍），故先做融合/行缓冲再做 PX16 |
| **存储策略** | 片上小缓冲 + MMIO 搬运（零访存冲突、易验证） | 权重留**寄存器数组**（综合成 LUT/Distributed RAM），无 BRAM 压力 | W 用 **BRAM ROM**（80 tiles）+ Q 用 **LUTRAM**（~7K LUT）+ A/B BRAM |
| **控制复杂度** | 极简（MMIO 触发一次算完） | 固定 FSM，**无微码** | 微码 ROM 112 op + 双模（逐 op / 自主），复杂度最高 |
| **失败边界** | 只支持 GEMM，不支持卷积 | 模型固定 6 层，换模型要重综合 | 模型超大（2M 参数）需 DDR3 流式，MIG 未接入 |

---

## 4. 从对比能看出的三个问题

1. **主 RTL 与板上构建脱节**（视觉 NPU 1 MAC vs 4 MAC；`core.v` 单发射 vs 双发射）——
   仓库目前**无法从主 RTL 重建板上位流**。
2. **GEMM 有三份副本**，虽然逻辑相同，但编码/EOL 漂移，后续维护有踩坑风险。
3. **最强的 v0.7 引擎不在 `main`**（它和瓶盖模型迁移、A7a 优化一起留在 `feat/ai-accel`，未合入），
   从 `main` 看仓库只能看到 1 MAC 与 4 MAC 两个"小核"。
