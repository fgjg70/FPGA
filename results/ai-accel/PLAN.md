# 大 BRAM 存储 + 简单 YOLO 专用加速器 · 方案与计划 v0.2

> 日期：2026-10-31。分支：`feat/ai-accel`（从交付 tag `deliv150-o2ira` = `main` @ d592067 拉出）。
> 接口/数据格式的**唯一事实来源**是 [`CONTRACT.md`](CONTRACT.md)（已迭代到 v0.3，见其文末变更记录）；
> 本文回答"为什么这么选、算得过来吗、怎么分步验收"。
>
> **v0.2 修订**：进入实施后实测/物理约束推翻了 v0.1 的三处估算，已在下面 §8「实施后实测修正」更新：
> ① 可按字节寻址的 BRAM 只有 **4KB/BRAM36**（v0.1 按 4.5KB 算，导致预算超器件）；
> ② YOLO-Fastest v1.1 的实测 MACs/权重量（v0.1 是估算，偏差 20~30%）；
> ③ 输入图按 8 通道分块是 128KB，装不进 A 缓冲 ⇒ 改为 packed 3B/像素 + CPU 跑 conv0。

---

## 0. 仓库审视结论（开始动手前的事实）

| 项 | 现状 | 对本次工作的含义 |
|---|---|---|
| 器件 | XC7A100T-FGG484-2：**LUT 63,400 / FF 126,800 / BRAM36 135（607.5 KB）/ DSP48E1 240** | 现交付档只用 LUT 3098 / FF 1447 / BRAM 9 / DSP 8 ⇒ **有巨大余量**，够放一份 int8 YOLO |
| CPU | RV32IM 五级单发射，IMEM/DMEM 各 16 KB，**均行为级推断为 BRAM**；M 扩展；CoreMark/MHz 2.7063 @150 MHz | 作为"软件基线"和层调度器；不改其微架构 |
| 存储 | **无 DDR/外部存储控制器**（XDC 只有时钟/复位/LED/UART 引脚）；程序靠 QSPI FLASH 掉电自启动 | ⇒ **权重只能放片上 BRAM**（综合时 `$readmemh` 烧进 bitstream）。这也正是"用更大 BRAM"的用武之地 |
| MMIO | `0xA000_0000` 起；**外设读是组合读**（core 再寄存一拍）；dmem 是同步读 | ⚠ 大 BRAM **不能**直接挂 MMIO 总线（会差一拍）。CPU 访问大 BRAM 必须走 core 新增的 `nn_*` 专口（与 dmem 同口径），见 CONTRACT §1/§2 |
| 已有 AI 单元 | `gemm_accel.sv`（int8 GEMM，1 MAC/拍）：机制验证过 42.59×，但 **A/B/C 缓冲落成 1.3 万 FF**（FF +916%）、C 读回有 bug ⇒ 默认 `GEMM_EN` 关闭 | 本次**不修 GEMM**，而是新写正规的卷积引擎；直接吸取"缓冲必须推断成 BRAM、不要寄存器阵列"的教训 |
| Cache | `results/p7-cache-analysis.md` 判定**tag-based I/D Cache 架构性无收益**（存储器本来就是单拍命中的片上 BRAM） | 本次的"大 cache"**不是**那个 Cache：它是 **scratchpad / 权重+激活缓存**，服务于 NPU 的带宽与容量需求；这个区分必须写进文档，别把两件事混为一谈 |
| 工具链 | Vivado 2018.3（非工程模式 build.tcl）、ModelSim SE-64 2020.4、riscv-none-elf-gcc 15.2.0；回归 `verify` = **PASS 12** | 新增 RTL 必须进三处 RTL 清单 + `test_matrix()`；每次改动后 `verify` 全绿才允许综合（仓库纪律） |
| 文档口径 | 上板/仿真/综合三种"验证"严格分开；数字带出处；PITFALLS R1~R60 | 本次交付沿用同一纪律；新增结果写 `results/ai-accel/` |

**结论**：仓库的 CPU/验证/上板链路是成熟的，缺的正是"大容量片上存储 + 卷积算力"。本次不碰 CPU 微架构，
只加一条并行的 NPU 通路；交付档（无 `NN_EN`）必须逐位不变。

---

## 1. 目标模型：YOLO-Fastest v1.1（darknet，int8 PTQ）

选它而不是 YOLOv3-tiny / YOLOv2-tiny 的硬理由：**参数量**。BRAM 总量 607.5 KB，模型权重必须以真实 bitstream
形式常驻片上：

| 模型 | 参数量 | int8 权重 | 320 输入 MACs | 结论 |
|---|---|---|---|---|
| YOLOv3-tiny | 8.7 M | 8.7 MB | ~5.6 G | ❌ 超 BRAM 14 倍 |
| YOLOv2-tiny | 15.8 M | 15.8 MB | ~5.9 G | ❌ |
| **YOLO-Fastest v1.1** | **0.315 M** | **≈308 KB** | **≈94 M** | ✅ 唯一能全量常驻的预训练 YOLO |
| tiny 自研检测网 | 0.05~0.2 M | 50~200 KB | 5~30 M | 备选（需自己训练，见 §7 风险） |

YOLO-Fastest v1.1 的结构（darknet cfg 实测解析）：ShuffleNetV2 风格主干（1×1 + **3×3 depthwise** +
shortcut 残差），三个 stride-2 下采样，SPP 式头（maxpool 3/5/9 + route 拼接），两个检测头
（10×10 与 20×20 网格，255 = 3×85 通道）。算子只需：**conv1×1 / dw3×3 / dw5×5 / maxpool / residual add /
route-concat / upsample2× / leaky ReLU**。

**输入分辨率 vs 存储**（权重 308 KB 为常数；峰值激活按层表实测，见 T-model 交付）：

| 输入 | MACs | 峰值激活/缓冲 | 总 BRAM 估算 | 精度（相对 320 训练） | 取舍 |
|---|---|---|---|---|---|
| 320 | 94 M | ~200 KB | 超预算 | 原始精度 | ❌ 放不下 |
| 160 | ~39 M | ~54 KB | ~117/135 | 中 | 备选 |
| **128** | **~36 M** | **~49 KB** | **~131/135（紧）或 113/135（裁第二头）** | 可接受（演示级） | **首选（待 T-model 实测确认）** |
| 96 | ~35 M | ~28 KB | ~93/135 | 差 | 后备 |

> 注：上面 MACs/激活数是按 cfg 解析的估算，**以 T-model 的层表实测为准**；输入分辨率最终由
> "mAP 掉点 ≤ 可接受 & 总 BRAM ≤ 128"两个门共同决定，由 Lead 拍板。

---

## 2. "大 BRAM 做大的 cache"—— 具体形态

三层存储结构（AI 档）：

```
CPU (RV32)                      NPU
  │ LSU load/store                │ 每拍 8B 权重 + 16B 激活读 + 8B 激活写
  ▼                              ▼
┌──────────────────────────────────────────────┐
│  nn_mem: 512 KB 片上存储（行为级推断 BRAM）      │
│  ├ W 区  : int8 权重 ~320 KB（综合时烧入）       │
│  ├ Q 区  : 量化参数 16 KB                        │
│  ├ A 区  : 激活缓冲 128 KB (NHWC, 8ch 分块)      │
│  └ B 区  : 激活缓冲 128 KB                       │
└──────────────────────────────────────────────┘
       ▲ 专用 nn_* 端口（1 拍读，与 dmem 同口径）
       │
  IMEM 16 KB / DMEM 16 KB（不变）
```

- **"cache"的定位**：它是**软件管理的 scratchpad**（权重常驻 + 激活 ping-pong），不是 tag 比较的
  硬件 cache。前者能实测出收益（YOLO 全模型跑得起来），后者在"存储器本来就是单拍 BRAM"这个架构下
  已被证明无收益（p7 分析）。文档里必须持续区分，避免与赛题 Cache 项混淆。
- **CPU 也走这条窗口**：CPU 可以直接 load/store NN 窗口 ⇒ ① 软件基线能直接跑同一份模型（公平对比）；
  ② 层调度、route/concat、head decode/NMS 都由软件完成，硬件保持简单。
- **别例化厂商 IP**：权重/激活 RAM 全部行为级推断（`always @(posedge clk) rdata <= mem[addr]`），
  迁移紫光同创 PDS 时只需重写顶层与约束（仓库既有纪律）。

---

## 3. 算力账（为什么 8×8=64 MAC 阵列够用）

**引擎 v1 数据流：output-stationary + 像素并行**
- PE 阵列：`OC_LANES=8`（输出通道）× `PX_LANES=8`（输出像素）= **64 个 int8 MAC/拍**。
- 每拍带宽：权重 8 B（8 个 OC 的同 (kick,ic) 权重，1 个 64 位读）+ 激活 8 B（8 个像素的同 ic 值，
  由 16 通道/128 位读口喂入转置小寄存器阵列）+ 输出 8 B/8 拍。
- 1×1 conv（本模型 MAC 的大头）：`28 M MAC / 64 = 437 K 拍`。
- depthwise：受激活口带宽限制（每拍 8~16 个新激活字节）≈ **8~16 MAC/拍**；按 16 估：
  6.8 M / 16 = 428 K 拍。
- 合计 ≈ **0.9 M 拍**；@131.25 MHz ≈ **7 ms/帧**（不含层间调度/搬运开销，按 ×1.5 估 ≈ 10 ms）。
- 软件基线（CPU 逐 MAC，含取权重/激活窗口访问）：约 36 M MAC × 4~6 拍 = 150~220 M 拍 ≈ **1.2~1.7 s**。
- ⇒ **预期加速比 100× 量级**，且能给出比 GEMM 版更完整的"AI 模型性能"证据。

**资源预算**（AI 档，粗估，综合后回填实测）：

| 资源 | 预算 | 说明 |
|---|---|---|
| BRAM36 | ≈ 113~131 / 135 | 权重 308 KB + 激活 2×~50 KB + A/B 余量；**主风险项** |
| DSP48E1 | 64（MAC）+ 8（requant）= 72 / 240 | 每 PE 一个 8×8 乘法，requant 用宽乘 |
| LUT | +6~10 K / 63.4 K | 转置阵列、地址生成、FSM、requant |
| FF | +8~12 K / 126.8 K | 像素/通道寄存器 + 流水 |
| fmax 目标 | **131.25 MHz**（XDC 21/8 档，仓库已验证过的档位） | 引擎是新的关键路径来源，先按 131.25 收 |

---

## 4. 里程碑与验收门（每步都有可自动判定的判据）

| # | 里程碑 | 交付物 | 验收判据（机器判定，不接受肉眼） |
|---|---|---|---|
| **M0** | 契约 + 基线冻结 | `CONTRACT.md`、`PLAN.md`、`feat/ai-accel` 分支 | `verify` 在分支上 **PASS 12**；交付档 RTL 相对 tag 零差异 |
| **M1** | 模型落地（T-model） | `tools/yolo/*`、层表、量化模型、逐层 golden 与 checksum | ① 浮点重实现与官方权重逐层一致（cos ≥0.9999）② int8 PTQ 后逐层 cos ≥0.99、端到端检测框与浮点参考 IoU≥0.5 ③ 层表参数/权重大小 ≤ 预算 |
| **M2** | 大 BRAM 子系统（T-mem） | `nn_mem.sv` + `sim/tb_nn_mem.sv` | TB 自检通过 + **Vivado 综合报告证明权重/激活落成 RAMB36**（不许 LUTRAM 洪水）+ BRAM 数 ≤ 预算 |
| **M3** | 卷积引擎（T-accel） | `nn_conv_engine.sv` + `sim/tb_nn_engine.sv` | 对 M1 的逐层向量**位精确**（mismatch=0，含 X 检查）；conv1x1 / dw3x3 / dw5x5 / pool / add 全覆盖 |
| **M4** | SoC 集成 + 软件基线 | `nn_pkg.sv`、`nn_subsys.sv`、`core.sv` 端口、`mmio_subsys`、`sw/yolo_demo.c`、`sim/tb_nn_soc.sv` | ① 交付档 `verify` 仍 PASS 12 且资源逐项不变 ② AI 档 `verify` PASS（新增 TB 全绿）③ CPU 软件基线与 golden 逐层 checksum 一致 ④ 硬件加速路径与 golden 逐层 checksum 一致（≤1 LSB 差异必须显式记录） |
| **M5** | 综合/时序/上板 | `synth` 报告、fmax/WNS、上板 UART 输出、`results/ai-accel/*.md` | ① fmax ≥ 131.25 MHz（WNS ≥ 0）② 资源在预算内 ③ 上板检测结果与仿真一致（板载 UART 输出 / 结果寄存器读回）|

---

## 5. 分工（并行工作流）

| 角色 | 任务 | 写作用域 |
|---|---|---|
| **Lead** | 契约、`nn_pkg`、core 端口、`nn_subsys`、build/工作流登记、集成 TB、综合/上板、最终评审 | 见 CONTRACT §12 |
| **T-model** | YOLO-Fastest v1.1 权重→PyTorch→int8 PTQ→numpy golden→层表/向量/checksum | `tools/yolo/*`、`sim/prog/yolo/*`、`results/ai-accel/model-*.md` |
| **T-mem** | 512 KB 大 BRAM 子系统（权重+激活+CPU 窗口+NPU 端口），BRAM 推断/资源证明 | `nn_mem.sv`、`sim/tb_nn_mem.sv`、`results/ai-accel/mem-*.md` |
| **T-accel** | int8 卷积引擎（8×8 MAC、像素并行、requant/leaky/pool/add） | `nn_conv_engine.sv`、`sim/tb_nn_engine.sv`、`results/ai-accel/engine-*.md` |

依赖关系：T-accel 依赖 `nn_pkg`（Lead 先写）与 M1 的向量（先用手工向量开发，M1 出来再换）；
T-mem 独立；Lead 的集成依赖 T-mem/T-accel 的接口（契约已冻结）。

---

## 6. 本仓库既有红线（必须遵守，全部有代价记录）

1. **交付档逐位不变**：`NN_EN` 未定义时，`core.sv`/`mmio_subsys.sv` 的改动必须被宏完全门控；
   每次改动后 `python tools\fpga_workflow.py synth` 与交付档对比 LUT/FF/BRAM/DSP/fmax。
2. **RTL 清单三处同步**（R1）：`fpga/build.tcl` read_verilog、`fpga/build_ila.tcl`、`tools/fpga_workflow.py` 的 `CORE_SV_ORDER`。
3. **仿真入口唯一**：`python tools\fpga_workflow.py verify`；`sim/run.bat` 是历史留档（iverilog 不存在、只跑 2 项却打印 ALL PASS）。
4. **`.tcl`/`.bat` 纯 ASCII**（R2/R21）；`.sv`/`.md` 可使用中文。
5. **字符串类型不可综合**（R33/SKILL §6）：BRAM 初始化必须 `ifdef SYNTHESIS` 双路径 + `NN_W_INIT_FILE` 宏。
6. **不要用寄存器阵列堆大缓冲**（GEMM 的 FF +916% 教训）：一切大存储都走行为级 BRAM 推断。
7. **数字带出处**：仿真/综合/上板三种证据分开记；fmax 必须带时钟名+周期+运行频率+WNS。

---

## 7. 风险登记

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| 128 输入 mAP 掉太多 | 中 | 演示效果差 | T-model 先在 96/128/160 三点实测精度，Lead 按"精度 vs BRAM"拍板；必要时只保留第一检测头省 65 KB |
| 权重 308 KB + 激活塞不进 135 BRAM | 中 | 方案要缩 | 砍第二检测头（−65 KB）或降到 96 输入；`nn_mem` 参数化，尺寸可调 |
| depthwise 吞吐只有 8~16 MAC/拍 | 高 | 端到端慢 2× | 先做对再优化；后续可加"2 像素/拍"或通道并行模式 |
| 大 BRAM 拖累 fmax | 中 | 需降频 | AI 档固定 131.25 MHz（已验证档位）；关键路径先量 `synth` 的 top-N 再动手 |
| int8 PTQ 精度不达标 | 中 | 需 QAT | 先用 PTQ；不达标则对 head 层或全模型做 QAT（GPU 可用） |
| 与"Cache 任务"口径混淆 | 高 | 评审扣分 | 明确写：scratchpad ≠ tag cache；p7 结论仍成立，本文不推翻它 |

---

## 8. 实施后实测修正（v0.2，2026-10-31 晚）

> 这一节只写**与 v0.1 估算不同**的实测事实，以及由此拍板的口径。数字出处见括号里的命令/文件。

### 8.1 BRAM 物理容量：4KB/BRAM36（决定性约束）

行为级推断下可按字节寻址的 BRAM 容量是 **4KB/BRAM36**（32 位宽用 1Kx36、64 位用 512x72；
parity 位不能当字节数据用）。XC7A100T = 135 块 ⇒ 全部可寻址容量约 540KB；
交付档核心已用 9 块（imem 4 + dmem 4 + bht 1）⇒ **NPU 只剩 126 块 ≈ 504KB**。

拍板布局（`nn_pkg.sv` v0.3）：
| 区 | 大小 | 块数 | 说明 |
|---|---|---|---|
| WQ | 368KB | 92 | W 320KB（实际权重 319,792B，余 7,888B）+ Q 48KB（变长紧凑） |
| A / B | 各 64KB | 16+16 | 激活 ping-pong；窗口 0x60000/0x70000，正好卡满 512KB |
| 合计 | 464KB | **124** + 核心 9 = **133/135**（**余量只有 2 块**） | |

Q 区压缩（v0.1 的 16KB/固定 0x1000 层是算术错的：84 层要 344KB）：
每层 `6*OC_pad+16` 字节（bias int32 + M_pos **int16** + tail），全模型约 43.2KB；
**M_neg 不存**，引擎用 `(M_pos*3277+16384)>>15` 现算（golden 同式）。

### 8.2 模型实测（T-model，命令见 model-report）

| 项 | v0.1 估算 | **实测** |
|---|---|---|
| 权重（§6 含 padding） | ≈308KB | **319,792 B = 312.3KB** |
| MACs @320 | 94M | **125.44M** |
| MACs @160 / 128 / 96 | 39M / 36M / 35M | **31.36M / 20.07M / 11.29M** |
| 输入图（8 通道分块） | — | **131,072 B（128 输入）= A 缓冲的 2 倍** ⇒ 装不下 |

**拍板**：输入分辨率 **128×128**；输入图改 **packed 3 字节/像素（49,152B）**；**第 0 层 conv 由 CPU 执行**
（`cpu_conv0`，约 0.88M MAC），此后全部层走硬件。Q 区/激活缓冲按 8.3 的实测峰值配置。

### 8.3 阶段进度（截至 2026-10-31 22:25；完整证据见 [DELIVERY.md](DELIVERY.md)）

| 件 | 状态 | 证据 |
|---|---|---|
| 交付档回归（无 NN_EN） | ✅ **PASS 15**（12 原 + NN 新增 3 项；交付分支 main 仍是 12） | `verify --force`；`.fpga-cache/logs/` |
| 交付档资源/时序不变性 | ✅ **LUT 3098 / FF 1447 / BRAM 9 / DSP 8 / fmax 150.2 / WNS +0.007**，与交付行逐项相同 | `synth --tag ai-nn-parity`；`.fpga-cache/reports/20261031-*/` |
| `nn_mem.sv` 大 BRAM 子系统 | ✅ 自检 PASS + **Vivado 实测 BRAM 124/135**（WQ92+激活32）；旧尺寸 296/270 超限已封死 | `mem-report.md`；`proto/mem/` |
| `nn_conv_engine.sv`（64 MAC/拍） | ✅ `ENGINE_TB: PASS (46 cases, mismatch=0)`；46/46 cycles 与公式完全相等；LUT 15.2K / FF 8.0K / DSP 52 / BRAM 0 | `engine-report.md`；`proto/engine/` |
| NN_EN SoC 通路 | ✅ tb_sw+NN_EN hello PASS；CPU 窗口/寄存器/中断全通 | `tb_sw.sv` ifdef 段 |
| YOLO 模型流水线 | ✅ 权重 319,792B；golden mismatch=0；yolo_wq.hex 94,208 行；MACs@128=20.07M | `model-report.md` |
| **端到端逐 op 位精确** | ✅ **`RESULT : PASS`（108 ops，hw_bad=0）**；**NPU 实测 `npu_cycles=1,216,578`**（@150MHz = 8.11ms/帧），与引擎周期公式**完全相等**（独立互证） | `logs/tb_sw_nn_yolo.log` |
| AI 档实现 | ✅ **87.5MHz 全实现 PASS**：`BUILD_TIMING=PASS`，**WNS +0.135 / fmax 88.5MHz**，LUT 25,212 / FF 12,782 / BRAM 133 / DSP 47；bitstream `fpga/cpu_a100t_nn.bit`（sha256 `489510b8…`）。150MHz 全实现实测 fmax 95.6（v2 引擎），瓶颈已变为**集成路径** `u_core/u_ex_mem/alu_out → u_nn/u_mem/u_wq ADDRARDADDR`（10.87ns，route 占 71.8%）| `results/ai-accel/impl/ai875_*.{rpt,json}`；DELIVERY §6 |
| int8 精度判据 | ❌ **判据本身不可达（已证明）**：per-tensor int8 理想 QDQ 上限 cos 均值 0.9889/最小 0.9670（<0.99）；交付实测 0.9742/0.9174，端到端框匹配 128=81.8%。要过 0.99/90% 需改量化粒度（per-channel 激活/关键张量 16-bit），本轮决策不做 | `model-report.md` §0/§6.2/§6.5 |
| 上板验证 | ⏳ **只差烧写**：bitstream 已 board-ready（87.5MHz, WNS +0.135），但 2026-11-01 JTAG 探测板卡不在位 | 板子接上后按 BOARD-RUN.md 执行 |

### 8.4 口径提醒

1. 本文 §3 的 7ms/帧与 100× 加速比是 v0.1 粗估；**实测值以 `tb_sw_nn_yolo` / 上板 UART 输出为准**。
2. "大 cache"仍指 **scratchpad**（权重常驻 + 激活 ping-pong），不是 tag-based I/D Cache；
   `results/p7-cache-analysis.md` 的"Cache 无收益"结论**不被本次工作推翻**。
3. BRAM 余量 2 块：任何"再多存一份权重/加一块缓冲"的方案都要先核算，否则会撑爆器件。

---

## 9. 演进路线（2026-11-01 用户确认：板上有 **2 片 DDR3** + 摄像头，接口待定）

> 当前 v0.4/v0.5 交付是 **BRAM-only**：权重 368KB 综合时烧进 BRAM、输入图公式生成、无外部存储。
> 这条路径**不依赖 DDR3**，仍然是"上电即跑、可复现"的演示基座。DDR3/摄像头的加入是**后续形态**，
> 不推翻本轮任何结论。

### 9.1 DDR3 带来的形态变化

| 维度 | 现状（BRAM-only） | DDR3 形态（下一阶段） |
|---|---|---|
| 权重 | 368KB 全量烤进 BRAM（92/135 块） | 权重放 DDR3，BRAM 缩小为**权重/激活缓存**（"大 BRAM 做 cache"从比喻变成真实结构） |
| 激活 | A/B 各 96/32KB | DDR3 帧缓冲 + BRAM 行缓存；可支持 320×320、更大 batch |
| 模型上限 | YOLO-Fastest v1.1 @128 | 可尝试 320 输入 / YOLOv3-tiny / YOLOv2-tiny 等（15.8M 参数 = 15.8MB int8 也可放下） |
| 带宽 | 片上 64B/拍级 | 需评估 DDR3 实际带宽（位宽×频率×效率）与 NPU 需求（当前 64 MAC/拍只需 ~16B/拍权重+激活）匹配 |
| 代价 | 0 厂商 IP | **MIG IP 或自写 DDR3 控制器**（前者违背"零厂商 IP 可移植"纪律，后者工作量大）；时序/引脚/DQS 训练风险 |

**为什么先评估再动手**：本项目已验证过 Vivado 2018.3 的 IP 流有坑（R33）；且 MIG 会吃 BRAM/LUT
（当前 BRAM 只剩 ~1.5 块）。所以 DDR3 阶段必须先做**带宽/资源预算 + 接口选型**，再决定是否值得。

### 9.2 需要你（用户）提供的接口信息（拿到就能开工）

**DDR3（2 片）**：
1. 板卡原理图里 DDR3 的**型号**（如 MT41K128M16 / MT41K256M16）与**位宽组合**（2 片 ×16bit = 32bit 总位宽？）
2. 厂商提供的 **DDR3 引脚 XDC 片段**（DQ/DQS/DM/地址/命令/时钟，含电平标准与端接）
3. DDR3 参考时钟来源（板载 200MHz 差分？还是由 sys_clk 经 MMCM 产生）与复位极性
4. 期望容量/带宽目标（例如"能放 16MB int8 权重 + 320×320 帧缓冲"）

**摄像头**：
1. 接口类型（DVP 并口 / MIPI CSI-2 / SPI？）与引脚
2. 分辨率/像素格式/帧率（YUV422/RGB565/RAW？）
3. 主控侧时钟（PCLK/XVCLK）与 I2C 配置需求（是否需要 SCCB 初始化寄存器表）
4. 数据通路期望：**摄像头→DDR3 帧缓冲→NPU 预处理（resize/量化）**，还是先固定 1 帧做演示

### 9.3 分阶段建议（拿到接口信息后）

1. **P0（不依赖 DDR3，继续收尾）**：引擎时序收敛 → int8 精度修复 → 上板跑通 128×128 YOLO（见 BOARD-RUN.md）
2. **P1（DDR3 连通性）**：先用 MIG/自写控制器跑**写-读回环自测**（地址走线 / DQS 训练），给出实测带宽
3. **P2（权重流式）**：NPU 权重从 BRAM 改为 DDR3 + BRAM 权重缓存（双缓冲），跑同一模型做**逐位对比**，确认只换存储不换结果
4. **P3（大模型/高分辨率）**：把 320×320 或 YOLOv3-tiny 端到端跑起来（此时 BRAM 是 cache，DDR3 是容量）
5. **P4（摄像头）**：DVP/MIPI → 帧缓冲 → resize/量化 → NPU → 检测框叠加（需要板上有视频输出或 UART/ILA 读数）


---

## 10. v0.7 特化进度（2026-11-01 晚）

- **112-op 双模 E2E PASS**：MODE_CPU `hw_bad=0`、MODE_AUTO `auto_bad=0`，两者 NPU 周期 = 1,167,368。
- 引擎 v3（128 MAC/拍）47 case + 4 模式 PASS（真 nn_mem）；nn_mem v0.7 R3 = W80 + A/B32 = 112 BRAM（+核心 ≈121.5/135）；Q 0 BRAM/6,981 LUT。
- OOC @100MHz WNS +0.807（MET，目标 ≥+1.0）；DSP 200（目标 ≤160）。
- 剩余：时序/DSP 收敛 → dw16 + conv0 loader → C320（DDR3 中间激活）→ 全实现 bitstream。
- 协作：GitHub issue #6（https://github.com/fgjg70/FPGA/issues/6）跟踪 NPU；视频/显示由其他同学负责。
