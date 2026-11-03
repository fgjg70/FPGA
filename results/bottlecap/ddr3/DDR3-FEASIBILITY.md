# 瓶盖检测模型（2,048,721 参数）在 XC7A100T 上的外部存储可行性 · 终版

> 作者：Agent Team `ddr3-feas`。日期：2026-11-03。任务：task-2。
> 只读本仓库；唯一写入目录 `results/bottlecap/ddr3/`。**未改任何 RTL / xdc / tcl，未跑 Vivado 实现。**
> 数据可复现：`python results/bottlecap/ddr3/gen_budget.py` → `bandwidth_budget.json` + `layers_224.csv`。
> 配套文档：`WEIGHT-STREAMING-DESIGN.md`（权重流式 RTL 设计）、`ROM-V1.md`（微码表 v1）、`bandwidth_budget.json`（机器可读）。
> 引用简写：`P3-TC` = `results/ai-accel/P3-DDR3-TILECACHE.md`；`P3-ARENA` = `results/ai-accel/P3-320-ARENA.md`；
> `CONTRACT` = `results/ai-accel/CONTRACT.md`；`DELIVERY` = `results/ai-accel/DELIVERY.md`；`mem-report`、`engine-report`、`PLAN` 同理。

---

## 0. 结论摘要（TL;DR）

| # | 问题 | 结论 | 关键数字 | 证据 |
|---|---|---|---|---|
| 1 | 板上有 DDR3 吗？仓库里有证据吗？ | **仓库内零证据**：xdc 只有 sys_clk/rst/led/uart 5 类引脚；无 MIG IP、无 xci/bd、无厂商引脚文件、无原理图/PDF。用户口头确认"2 片 DDR3 + 摄像头" | `daVinciPro.xdc:47-56`；`top_a100t.sv:46-54`；`build.tcl:149`；`PLAN.md:20`；用户确认见 `PLAN.md:228`、`DELIVERY.md:82` | R1 |
| 2 | 目标模型能不能塞进现有片上存储？ | **绝对不能**。峰值单张量 1,204,224 B（≈1.15 MB）是 A+B 128KB 的 **9.4×**；权重 2,020,960 B 是 W 320KB 的 **6.2×** | 见 §3.2 | R2 |
| 3 | 走 DDR3 能跑吗？ | **能，但帧率 < 5fps**：NPU 纯计算 40,060,598 拍 @100MHz = **400.6 ms/帧 = 2.50 fps**；@122.22MHz（已验证最高频点）= **3.05 fps** | 见 §3.3 | R3 |
| 4 | DDR3 带宽是瓶颈吗？ | **不是**。band-outer tiling 后 45.31 MB/帧，在 2.5 fps 下 **113.3 MB/s = 理论 1.6GB/s 的 7.08%**；即使按 30fps 也只是 84.96% | 见 §5 | R4 |
| 5 | 权重流式能被计算完全掩盖吗？ | **DDR3：能**（预取缺口合计 6,690 拍 = 0.017%）。**QSPI：不能完全**（缺口 5,407,263 拍 = 13.5%） | 见 §6 | R5 |
| 6 | 激活 arena 要多大 DDR3 窗口？ | 最小 **1,806,336 B（1.72MB）**；P3 定的 2MB/21-bit **勉强够（1.16× 余量）**，建议 4MB/22-bit | 见 §4 | R6 |
| 7 | 微码 ROM 深度 128 够不够？ | **够**：本模型 NPU op 数 = **105**（103 原语 + 2 copy），只需把地址字段加宽；**但 nn_subsys 的 `IC/OC > 256` 合法性检查必须放宽**（33 层超限，最大 864 通道） | `nn_subsys.sv:252-253`；`nn_conv_engine.sv:83,182`；`nn_pkg.sv:103,111-129` | R7 |
| 8 | 权重流式化要改多少？ | W 区 80 tiles 从"只读 ROM"改可写 + 层双缓冲（2×160KB）+ DMA 预取口；**nn_mem/nn_subsys/nn_seq/ROM 四件套有明确最小改动清单** | 见 `WEIGHT-STREAMING-DESIGN.md` §2 | R8 |
| 9 | 最小可行改动集合 | ①DDR3 物理层（MIG 或自写）②nn_tilecache（复用 P3 方案 A）③W 可写化+预取 ④Q 流式 ⑤通道上限/ReLU 模式 ⑥ROM v1 ⑦工具链 plan/arena/rom 生成 ⑧验证 | 12 个文件/模块级任务，见 §9 | R9 |
| 10 | 先做哪个？ | **建议顺序：P1 DDR3 连通性 → P2 权重流式（不动引擎调度）→ P3 激活 tiling**；若无板/无引脚，先做**行为级 DDR3 模型 + 自写控制器**（P3 R7）并行推进工具链 | 见 §8/§9 | — |

**一句话**：DDR3 方案在**带宽/容量上都成立**，真正的天花板是 **NPU 算力**——2.27 GMAC 用现引擎 128 MAC/拍只能到 2.5fps（100MHz）；即便引擎 100% 效率，224 输入的理论上限也只有 **5.63 fps**。要 ≥5fps 必须砍算力（模型瘦身）或加并行（PX16/提频），不是加内存。

---

## 1. 本轮**已实测否决**的方案（避免后续误用）

> 以下方案在前序沟通中出现过，现用本仓实测/逐层扫描数据**明确否决**。请勿再按这些口径排期。

| 编号 | 被否决的方案 | 否决依据（实测） | 数据来源 |
|---|---|---|---|
| **X1** | "单张量激活峰值 ≈225KB（56×56×72），只要把输入降到 128×128 让峰值 ≤96KB" | 225,792 B 只是 **FPN 的 p2 张量**；真正的峰值是 **InvertedResidual 的 expansion 张量**：224 输入时 **96ch × 112×112 = 1,204,224 B**（1.15MB），是 A+B 128KB 的 **9.4×**。降输入到 128×128 后峰值仍是 **393,216 B**（96ch×64×64）；到 112×112 是 **301,056 B**；到 64×64 才 **98,304 B**（刚好 96KiB） | `bandwidth_budget.json` → `per_size`；`gen_budget.py` 逐层扫描；与 Lead 2026-11-03 实测的 1,204,224 / 301,056 B 完全一致（独立互证） |
| **X2** | "输入降到 112×112（112×84 letterbox+pad），A/B 重分为 A=B=64KB 即可跑原模型" | 112 输入时 **arena 峰值 451,584 B**、**单 op 输入+输出对峰值 401,408 B** ≫ 128KB；A=B=64KB 需要"任一 op 的 in/out 各 ≤64KB"，实际 **in 峰值 301,056 B** | `bandwidth_budget.json.per_size["112"]` |
| **X3** | "QSPI XIP 单独即可跑完整 2M 模型（不接 DDR3）" | 权重流式本身可行（§7.3），但**激活仍需要 DDR3**：112 输入下 arena 451,584 B、224 下 1,806,336 B，都远超片上 128KB。QSPI 只能解决"权重放哪"，不能解决"激活放哪" | §4；`per_size` |
| **X4** | "峰值并发 arena 数 MB，P3 的 2MB 窗口肯定不够" | 生命周期打包后 arena 峰值 = **1,806,336 B（1.72MB）**，唯一张量总和 15,212,344 B 只是"不复用"的下界。2MB 窗口可用（余量 1.16×），建议扩到 4MB | §4.2 |
| **X5** | "op 数约 150 > ROM 深度 128，必须扩 ROM" | 实际 105 个 NPU op（`103 原语 + 2 copy`）。**只有**在把 ic/oc 按 248 切分时才变成 213 个（那是 ROM 字段口径的旧假设；实际 `nn_rom_t.ic/oc` 是 10 bit，引擎计数器是 16 bit，无需切分） | §7.1；`nn_pkg.sv:117-118`；`nn_conv_engine.sv:83,182` |

**额外实测结论（本轮新增，重要）**：目标模型 **84% 的 MACs 在 56×56 分辨率的 FPN+头上**（towers 51.5% + fusion 15.0% + fpn 17.5%），backbone 只占 15.8%。所以"砍模型"的第一刀应砍 FPN 通道/塔深度，不是砍 backbone（但 backbone 权重占 1.14MB，也超 320KB，见 §8.3）。

---

## 2. 板级事实（板卡、DDR3、QSPI Flash）

### 2.1 DDR3：**仓库内没有任何证据**，必须向用户索取

| 检查项 | 命令/位置 | 结果 |
|---|---|---|
| 引脚约束里有没有 DDR3/DQS/DQ/DM | `grep -i "ddr3\|DQS\|SDRAM" fpga/*.xdc` | **0 命中**（12 个 xdc 变体全部无） |
| 顶层端口有没有 DDR3 | `fpga/top_a100t.sv:46-54` | 只有 `sys_clk, sys_rst_n, led[3:0], uart_txd, uart_rxd` |
| 仓库里有没有 MIG IP | `grep -ri "mig_7series\|mig_7" .`；`Get-ChildItem -Include *.xci,*.bd` | **0 命中**；唯一的 IP 是 `fpga/ila_proj.srcs/.../ila_0.xci`（ILA，与 DDR3 无关） |
| 有没有厂商原理图/引脚文件 | 全盘搜 `*.pdf/*.sch/*.SchDoc/*.Pin` | 只有 `work/pango_bl/**/demo_cards.pdf`（9609 B，与本板无关）；`daVinciPro.xdc` 头部注释声称"来自厂商 DaVinci_Pro_PIN.xdc"，但**该文件不在工作区** |
| 构建流程是否非 IP 流程 | `fpga/build.tcl:149`（`read_verilog` 显式文件清单）、`:194 read_xdc`、`:484 synth_design` | 非工程模式、零厂商 IP（`top_a100t.sv:17-21` 注释：明确"不例化任何厂商 IP"，MMCM 用原语） |
| 交付文档的口径 | `PLAN.md:20`、`DELIVERY.md:56` | "**无 DDR/外部存储控制器**（XDC 只有时钟/复位/LED/UART 引脚）"；"权重在综合时烧进 BRAM……不依赖 DDR/外部存储；本板没有这两样" |
| 用户确认 | `PLAN.md:228`、`DELIVERY.md:82` | 2026-11-01 用户确认"板上有 **2 片 DDR3** + 摄像头，**接口待定**" |

**⇒ 结论：DDR3 在"物理板卡上可能存在（用户口头确认）"，但在"工程上完全未接入"——没有引脚、没有控制器、没有参考时钟、没有时序参数。** 与用户口径的关系：用户说的是**硬件形态**，仓库交付的是**BRAM-only 形态**，二者之间缺的是 MIG/控制器这一整层。

### 2.2 必须先向用户索取的 6 项输入（拿到才能生成 MIG）

| # | 输入项 | 为什么必须要 | 出处 |
|---|---|---|---|
| 1 | DDR3 **型号**（如 MT41K128M16 / MT41K256M16）与位宽组合（2 片 ×16bit = 32bit？还是每片 ×8？） | 决定 MIG 的 `MEM_PART`/数据位宽/容量（16MB vs 32MB vs 64MB）与 bank/row/col 映射 | `PLAN.md:249-253`（原文 4 项中的 1、2） |
| 2 | DDR3 **引脚 XDC 片段**（DQ/DQS/DM/地址/命令/时钟，含 IOSTANDARD 与端接） | MIG 的 pin assignment；XC7A100T-FGG484 的 DQS 必须是专用差分对，不能猜 | 同上 |
| 3 | DDR3 **参考时钟来源**（板载 200MHz 差分？还是 sys_clk 50MHz 经 MMCM？）与复位极性 | MIG 的 `CLKIN` 需要 ≥200MHz 且必须是 clock-capable 引脚；本板 sys_clk 在 **R4 且已声明 `CLOCK_DEDICATED_ROUTE FALSE`**（`daVinciPro.xdc:59`），不能直接当 MIG 参考 | `daVinciPro.xdc:47,59` |
| 4 | DDR3 期望工作速率（400/533/800 MT/s）与是否 ECC | 决定 ui_clk 与带宽（1.6 vs 3.2 GB/s），也决定 4:1 还是 2:1 模式 | `P3-TC §3.2` |
| 5 | **2 片 DDR3 的用途划分**（是否片上 DDR3 全部给 NPU；视频帧缓冲是否也要占；是否双通道并行） | 决定 arena/权重区放哪、是否要 QoS 仲裁（P3 R3） | `PLAN.md:250-253`、`P3-TC R3` |
| 6 | Vivado 版本是否允许用 MIG IP（"零厂商 IP 可移植"纪律 vs 交付现实） + 是否有厂商参考工程 | 仓库纪律要求零 IP（`PLAN.md:88-90`、`top_a100t.sv:17-21`），MIG 违背；且本机 2018.3 的 IP 流有历史坑（PITFALLS R33） | `P3-TC R2` |

### 2.3 QSPI Flash（**有充分证据**，可作权重源）

| 事实 | 证据 |
|---|---|
| 型号 **Micron MT25QL128 / N25Q128**，**128 Mbit = 16 MB**，3.3V，SPIx1/x2/x4 | JEDEC `20 BA 18` → `tools/flash_logs/REPORT.md:30`；正确 cfgmem part = `mt25ql128-spi-x1_x2_x4`（`:38`） |
| 16MB 容量实测 | `tools/flash_logs/readback.bin` = **16,777,216 B** 全片读回（`:208-212`） |
| 现有镜像占用 | AI 档 bitstream `fpga/cpu_a100t_nn.bit` = **3,825,894 B**（`DELIVERY.md:217`）；SPIx4 启动 `.bin` = **3,825,788 B**（`CODE-REVIEW-PLAN.md` E-01） |
| **放权重后剩余空间** | 16,777,216 − 3,825,894 ≈ **12.95 MB**（若用 .bin 则 12.95 MB）→ 放 **2,020,960 B 权重后仍余 ≈10.9 MB**，**空间完全够** |
| 用户态访问可行性 | 配置完成后 flash 空闲；但用户态读 QSPI 需要 **STARTUPE2 原语驱动 USRCCLKO/CCLK 并复用 DQ[3:0]**（Artix-7 专用配置引脚），本仓库**零经验**（现有流程只有 JTAG 写 flash，`tools/flash_boot.ps1`） |

### 2.4 器件资源余量（决定"加 MIG/tile cache 还能剩多少"）

| 资源 | 100MHz AI 档实测（交付 bitstream） | 余量 | 证据 |
|---|---|---|---|
| LUT | 36,985 / 63,400（58.3%） | 26,415 | `DELIVERY.md §9.2` |
| FF | 16,381 / 126,800 | 110,419 | 同上 |
| **BRAM36** | **132 / 135（97.8%）** | **3 tiles = 12KB** | 同上；`mem-report.md §3.7`（nn_mem 120 + 核心 12） |
| DSP48E1 | 168 / 240 | 72 | 同上 |
| 已验证最高频点 | **122.22 MHz（WNS +0.058）**；125MHz 差 0.077ns | — | `DELIVERY.md §9.2.1` |

> **关键约束**：BRAM 只剩 3 tiles。因此 **激活 arena 不可能留在片上**（1.2MB 需要 300 tiles），必须进 DDR3；tile cache 也只能用"W 流式化后腾出的 80 tiles"来做（见 §6/§8）。

---

## 3. 目标模型画像（逐层扫描，可复现）

### 3.1 模型与算子构成

- 源码：`tools/bottlecap/model_src/nut_detector/enhanced_anchor_free.py:30-148`
  结构 = `EnhancedMobileNetV2Backbone(0.55)` + 4 级语义 FPN(72ch) + 3 个独立 prediction tower(3×3 conv) + 解耦头(1×1×3)。
- 配置：`tools/bottlecap/model_src/run_config.json`（`parameter_count=2048721`，`fpn_channels=72`，`backbone_width=0.55`，`max_detections=4`，4 类）。
- 本报告用 PyTorch `symbolic_trace` + `ShapeProp` 逐 op 扫描；**参数量 2,048,721 与 run_config 完全一致**（脚本自检 `param_match=True`）。
- 通道数（`make_divisible` 后）：c1=16, c2=24, c3=48, c4a=72, c4=88, c5=144；IR 的 expansion hidden = 64/96/144/288/432/528/864。

| 统计项 | 数值 | 说明 |
|---|---|---|
| 参数量 | **2,048,721** | 与 `run_config.json` 一致 |
| **int8 权重（硬件布局）** | **2,020,960 B（1973.6 KiB ≈ 1.93 MiB）** | 按 `CONTRACT §6` 的 `OC_pad×IC_pad×K²`（稠密）/`OC_pad×K²`（dw）；含 pad 开销 |
| **Q 参数（6×OC_pad+16/层）** | **90,048 B（87.9 KiB）** | 84 个 conv/dw 层 |
| **NPU op 数** | **105** = conv 61 + dwconv 17 + add 20 + copy 2 + upsample 5 + pool 0 | copy 是 216=3×72 通道 concat 的 2 次搬运（p2 原位） |
| **MACs** | **2,273.5 M** | 2,273,522,176 |
| **NPU 周期**（公式与 50/50 TB case 实测逐拍相等） | **40,060,598 拍** | 见 §3.3 |
| 唯一张量字节（NHWC pad8，含输入） | 15,212,344 B（15.21 MB） | 不复用总和的"下界" |
| **峰值单张量** | **1,204,224 B**（112×112×96，stage2.0 的 1×1 expand） | =A+B 128KB 的 9.4× |
| **生命周期峰值 arena** | **1,806,336 B（1.72 MB）** | 见 §4.2 |
| **单 op in+out 峰值** | **1,605,632 B**（stage1.0 block1 的 expand：802,816+802,816） | 决定 DDR3 逐 op 落地需求 |
| 输入张量 | 150,528 B（224×224×3 packed3） | PACKED3 模式可直接用（ic=3,k=3,s=2） |

### 3.2 逐阶段 MACs / 权重 / 周期（hw=224）

| 阶段 | ops | MACs | 占 MACs | 权重 | 周期 | 时间@100MHz |
|---|---:|---:|---:|---:|---:|---:|
| stem | 1 | 5.42 M | 0.24% | 1.1 KiB | 238.4 k | 2.38 ms |
| stage1 | 6 | 65.83 M | 2.90% | 5.1 KiB | 2,920.0 k | 29.20 ms |
| stage2 | 9 | 80.68 M | 3.55% | 20.6 KiB | 3,141.0 k | 31.41 ms |
| stage3 | 12 | 88.40 M | 3.89% | 100.0 KiB | 2,772.4 k | 27.72 ms |
| stage4 | 15 | 80.97 M | 3.56% | 362.9 KiB | 2,227.4 k | 22.27 ms |
| stage5 | 9 | 38.21 M | 1.68% | 625.5 KiB | 899.1 k | 8.99 ms |
| **fpn**（lateral+refine 3×3） | 12 | 398.52 M | **17.53%** | 385.9 KiB | 5,671.8 k | 56.72 ms |
| **fusion**（216→72 + ResBlock） | 3 | 341.40 M | **15.02%** | 106.3 KiB | 4,883.0 k | 48.83 ms |
| **towers**（8× 72→72 3×3 @56²） | 8 | 1,170.51 M | **51.48%** | 364.5 KiB | 15,702.6 k | 157.03 ms |
| heads（1×1 1/4/4ch） | 3 | 2.03 M | 0.09% | 1.7 KiB | 207.0 k | 2.07 ms |
| elemwise（add/copy/upsample） | 27 | 1.55 M | 0.07% | 0 | 1,397.8 k | 13.98 ms |
| **合计** | **105** | **2,273.5 M** | 100% | 1,973.6 KiB | **40,060.6 k** | **400.6 ms** |

> **这个模型"参数少但算力重"**：2.05M 参数却有 2.27 GMAC，因为 FPN/头工作在 56×56 高分辨率且通道 72（towers 8 个 3×3 稠密卷积 = 1.17 GMAC）。对比：YOLO-Fastest@128 是 20.07 MMAC（`DELIVERY §8.2`），C320 是 125.44 MMAC（`PLAN §8.2`），本模型是 **113× / 18×**。

### 3.3 周期/帧率（用 engine-report §0.6.2 的 v3 公式，DRN=W_RD_LAT+2=4）

| 频点 | 帧时 | fps | 说明 |
|---|---:|---:|---|
| 100 MHz（当前交付主档） | **400.6 ms** | **2.50** | `DELIVERY.md §9.2` 的 100MHz bitstream |
| 122.22 MHz（已验证最高） | 327.8 ms | **3.05** | `DELIVERY.md §9.2.1` |
| 125 MHz（未收敛，差 0.077ns） | 320.5 ms | 3.12 | 同上 |
| **MAC 理论上限**（128 MAC/拍 @100MHz，100% 效率） | 177.6 ms | **5.63** | `tot_macs/128/100e6` |

- 实测口径的引擎效率 = 2,273.5M / 40.06M = **56.8 MAC/cycle**（峰值 128 的 44%），与 224/112/128 各档一致（50~57），**效率结论稳定**。
- **⇒ 224 输入 + 现引擎，5fps 在物理上不可达**（需要 20.03M 拍 ≤ 理论 17.76M 拍的 113%）。要到 5fps 必须：MACs 降到 ≤1.14G（≈2× 削减）或引擎吞吐提到 ~2×（PX16 + 122MHz，风险高，见 `PX16-STUDY.md`）。

---

## 4. 容量预算：片上 vs DDR3

### 4.1 片上（现状，`CONTRACT §3`、`mem-report §3.7`）

| 区 | 容量 | 本模型需要 | 够吗 |
|---|---:|---:|---|
| W（只读 ROM，80 tiles） | 320 KB | **2,020,960 B** | ✗ 6.3× |
| Q（lo BRAM 8 + hi LUTRAM） | 48 KB | 90,048 B | ✗ 1.9× |
| A | 96 KB | 峰值单张量 1,204,224 B | ✗ 12.5× |
| B | 32 KB | 单 op 输入+输出 1,605,632 B | ✗ 50× |
| **整机 BRAM** | **132/135** | 差异量级：需 +300 tiles | **仅余 3 tiles** |

### 4.2 DDR3 侧预算（生命周期打包口径）

| 指标 | 数值 | 说明 |
|---|---:|---|
| 唯一张量总和 | 15,212,344 B | 不做复用的上界（**不是**需求） |
| **arena 峰值（并发）** | **1,806,336 B** | 峰值出现在 `stage1.0 block1` 的 expansion：stem-out 200,704 + 2×802,816 |
| 单张量最大 | 1,204,224 B（112×112×96） | |
| 单 op in+out 最大 | 1,605,632 B | |
| 输入图 | 150,528 B（224×224×3，packed3） | 摄像头帧缓冲另算 |
| 权重镜像 | 2,020,960 B | 放独立区 |
| Q 镜像 | 90,048 B | 可与权重同区 |
| **合计（arena+权重+Q+输入）** | **≈4.07 MB** | 2 片 DDR3（≥16MB）绰绰有余 |
| **建议 arena 窗口** | **4 MB（22-bit 字节偏移）** | 2MB/21-bit（P3 决定）实测**够用但只剩 1.16× 余量**；4MB 给双缓冲/对齐留余量 |
| 建议权重/Q 窗口 | 4 MB（22-bit） | 2.02MB+90KB 需 22-bit 才不擦边 |

> **修正 P3 的一处判断**：`P3-TC R1` 说"若存 DDR3 绝对地址则需 25 bit"。本报告建议的架构是 **"arena 窗口基址寄存器 + 窗口内偏移"**（P3 已拍板的方案），所以 21~22 bit 足够；25 bit 只适用于"ROM 直接存绝对物理地址"的方案，已不采用。

### 4.3 对 P3 结论的"可直接沿用 / 必须重算"清单

| P3 结论 | 新模型是否沿用 | 说明 |
|---|---|---|
| band-outer（输出行带 → OC 块）调度 | ✅ **直接沿用** | 与模型无关的调度范式；`P3-TC §2.2` 已证明"OC 外层"会 4.22× 读放大 |
| 独立 `nn_tilecache.sv` + 不改 nn_mem（P3 方案 A） | ✅ **直接沿用** | `P3-TC §4.5`；推荐继续采用 |
| tile DMA 两条 SDP 通道（fill/flush，128b+16B strobe） | ✅ **直接沿用** | `P3-TC §4.4` 的端口契约可直接复用 |
| halo/stride/padding 的行边界处理 | ✅ **直接沿用** | conv/dw/pool 的 `(B-1)*stride+k` 行带公式通用 |
| **IBUF 16KB / OBUF 12KB（56KB = 12.4 tiles）** | ❌ **必须重算** | 新模型张量更大：按 112×112×96 的 band，需 **IBUF 2×32KB + OBUF 2×24KB = 112KB（28 tiles）**；自适应分布 B=8:35 / B=4:37 / B=2:29 / B=1:4 |
| **1,854 tile / 最大 48 tile 每层** | ❌ **必须重算** | 新模型 **1,325 个 band**（105 op） |
| **15.246 MB/帧、30fps 0.48GB/s** | ❌ **必须重算** | 新模型 band-outer 后 **45.31 MB/帧**（权重 2.02 + 读 25.33 + 写 17.97）；2.5fps 时 113.3MB/s |
| **arena 819,200 B（C320）** | ❌ **必须重算** | 新模型 **1,806,336 B** |
| **21-bit ROM src/dst** | ⚠️ **够但擦边** | 1,806,336 < 2,097,152（1.16×）；建议 22-bit（见 `ROM-V1.md`） |
| **权重永不进 DDR3（MODEL-FREEZE D2）** | ❌ **本模型必须推翻** | 2.02MB ≫ 320KB，权重进 DDR3 是前提；D2 只适用于 YOLO 的 320KB 权重 |
| **conv0 PACKED3 8 行带流式** | ✅ 沿用思路 | 新模型 conv0 是 stem（ic=3,k=3,s=2），同样走 PACKED3 |
| **Q 区留 BRAM（48KB）** | ❌ 重算 | 新模型 Q = 90,048 B；改为**随权重逐层流式**（每层 ≤5,200 B） |

---

## 5. 带宽预算（逐 op 与逐帧率）

### 5.1 三种流量口径（hw=224，字节/帧）

| 口径 | 权重读 | 激活读 | 激活写 | 合计 | 相对最小 |
|---|---:|---:|---:|---:|---:|
| **理想（每张量读 1 写 1，无 tile）** | 2,020,960 | 19,946,920 | 17,966,144 | **39.93 MB** | 1.00× |
| **band-outer + tile（自适应 B）** ← 推荐 | 2,020,960 | 25,325,496 | 17,966,144 | **45.31 MB** | 1.13× |
| 现引擎调度（OC 块外层，无 tile cache） | 2,020,960 | 167,381,256 | 17,966,144 | **187.37 MB** | 4.69× |

- band-outer 的 +5.38MB 是行带 halo 重读（+27%），与 P3 同源（`P3-TC §3.1`：B=4 时 +8%，本模型因为 stage1/2 用 B=1/2，halo 更高）。
- 现调度（OC 外层）读放大 8.4×（`act_read_naive/act_read_ideal`），**必须改 band-outer**（与 P3 结论一致）。

### 5.2 各帧率下的 DDR3 需求（32-bit DDR3-400 理论 1.6 GB/s）

| 帧率 | 权重 | band-outer 合计 | 占 1.6GB/s | 现调度合计 | 占 1.6GB/s |
|---|---:|---:|---:|---:|---:|
| **2.5 fps（实际@100MHz）** | 5.05 MB/s | **113.3 MB/s** | **7.08%** | 468.4 MB/s | 29.3% |
| 3.05 fps（@122.22MHz） | 6.16 | **138.2** | **8.64%** | 571.5 | 35.7% |
| 5 fps | 10.1 | 226.6 | 14.16% | 936.8 | 58.6% |
| 10 fps | 20.2 | 453.1 | 28.32% | 1,873.7 | **117%（超）** |
| 30 fps | 60.6 | 1,359.4 | 84.96% | 5,621.1 | **351%（不可行）** |

**⇒ DDR3 带宽结论**：在本模型实际能达到的 2.5~3.05fps 下，DDR3 占用只有 **7~9%**；天花板是算力，不是带宽。**只有"改成 30fps"这种不现实目标时 DDR3 才会成为瓶颈**。

### 5.3 QSPI x4（若用 flash 作权重源）带宽

| 场景 | 需求 | QSPI x4@50MHz 理论 25MB/s / 可用 15~20MB/s | 判定 |
|---|---:|---|---|
| 224 输入 @2.5fps（实际帧率） | 2,020,960 × 2.5 = **5.05 MB/s** | 25/20 | ✅ 可掩盖（平均） |
| 224 输入 @3.05fps | 6.16 MB/s | | ✅ |
| 224 输入 @5fps（若算力允许） | 10.1 MB/s | | ✅ |
| **112 输入 @8.87fps** | **17.93 MB/s** | 25/20 | ⚠️ **擦边**（已超"可用 15~20"的中位） |

---

## 6. 权重流式化（P3 没做过的新东西）—— 结论

> 详细设计见 **`WEIGHT-STREAMING-DESIGN.md`**；这里只给可行性结论与数字。

### 6.1 容量：现 W 区 320KB 直接当 L2 cache，双缓冲够

| 项 | 数值 | 判定 |
|---|---:|---|
| 最大单层权重 | **124,416 B（121.5 KiB）**：`stage5.1 block0` 的 1×1 expand，ic=144→oc=864（`layers_224.csv` 4 处同值） | — |
| 该层 Q | 5,200 B（6×864+16） | — |
| 单层合计 | 129,616 B | — |
| W 区 320KB 分 2 银行 | 160 KiB/银行 | **129,616 ≤ 163,840 ✅**（余量 34,224 B） |
| 最大层占 W 区比例 | 124,416 / 327,680 = **38.0%** | 双缓冲后仍余 24% |

### 6.2 预取能否被计算完全掩盖？**DDR3：能；QSPI：不能完全**

| 指标 | DDR3（有效 1120 MB/s = 11.2 B/cycle） | QSPI（可用 20 MB/s = 0.2 B/cycle） |
|---|---:|---:|
| 全模型平均权重需求 | 2,020,960 / 40,060,598 = **0.050 B/cyc（5.05 MB/s）** | 同（平均） |
| **最坏相邻层对** `add_10 → stage5.2 expand`：下一层 124,416 B / 本层仅 4,419 拍 | 需 28.15 B/cyc（2,815 MB/s）→ **超 DDR3 有效带宽 2.5×** | 需 28.15 B/cyc（超 140×） |
| **1 深双缓冲累计缺口** | **6,690 拍 = 0.017% 帧时** → **等价于完全掩盖** | **5,407,263 拍 = 13.5%** → 帧率从 2.50 掉到 2.20fps |
| 是否要改预取深度 | 不必（6,690 拍可忽略） | 需要 3 银行（3×160KB > 320KB 放不下）→ 只能接受 13.5% |
| 其他相邻层对 | ≥3.5 B/cyc 的只有 6 对，全部 <11.2 | 30 对超 0.2 B/cyc |

**关键洞察**：权重流式的吞吐要求**不是**"每拍 16B"（那是片上 BRAM 读口的要求），而是 **"每层权重 / 本层计算拍数"**。除 `refine5`（46,656B/35,136 拍 = 1.33 B/cyc）外全部 ≤1.33 B/cyc = **133 MB/s**，即**从 DDR3 现算现用都够**（1120MB/s），双缓冲只是为了消除层间气泡。

### 6.3 DMA 口建议（详见设计文档）

| 项 | 建议 | 理由 |
|---|---|---|
| 数据位宽 | **128 bit / beat（16B）** | 与现有 `b_wdata/b_wstrb`、P3 tile DMA 契约一致（`P3-TC §4.4`） |
| 时钟域 | MIG `ui_clk`（DDR3-400 32bit 建议 4:1 模式 = ui_clk 100MHz，用户口 128bit）→ 与 NPU 100MHz **异步**，需异步 FIFO | 避免跨时钟域假设同源 |
| FIFO 深度 | **512B×2（~1KB，可放分布式 RAM/LUTRAM，不吃 BRAM）** | 覆盖 MIG 读延迟（~50~100 拍）×16B + 突发对齐 |
| 预取粒度 | **整层**（≤129,616 B/银行） | 层内 woff 直线寻址，不改引擎寻址逻辑；OC 块粒度会引入 4~5× 重复搬运 |
| 平均带宽 | 5.05 MB/s（2.5fps）；**突发 2.8 GB/s 只在一个相邻层对上出现 6,690 拍** | — |

---

## 7. ROM / 描述符升级（详见 `ROM-V1.md`）

### 7.1 op 数与 ROM 深度：**128 够用（105 op）**

- 现 `NN_ROM_DEPTH = 128`（`nn_pkg.sv:103`），`nn_rom_t` = **200 bit**（`nn_pkg.sv:111-129`）。
- 本模型 NPU op = **105** ⇒ **深度 128 仍够（余 23 项）**；无需扩到 256。
- **但有一个必须先修的硬限制**：`nn_subsys.sv:252-253` 的描述符合法性检查是
  `if (desc_next.ic == 0 || desc_next.ic > 256) desc_ok = 0;`（oc 同）→ 本模型 **33 层** ic 或 oc >256（最大 864）会被拒（err 0xE1）。
  - 引擎侧本身没有 256 限制：`d_ic/d_oc` 是 16 bit（`nn_conv_engine.sv:83`），循环计数器 16 bit（`:182`），`nn_rom_t.ic/oc` 是 10 bit（`nn_pkg.sv:117-118`，≤1023）⇒ **把 256 改成 1024（2 行）即可**，不需要切分 op。
  - 若不动这 2 行，则必须按 248 通道切分 → op 数变 **213**（>128），ROM 要扩到 256（+2 tiles）；**两条路成本对比见 ROM-V1.md §4，推荐改 2 行**。

### 7.2 字段加宽需求

| 字段 | 现状 | 新模型需求 | 建议 |
|---|---|---|---|
| src/dst | 19 bit（A/B 窗口 ≤512KB） | arena 1.81MB + 基址寄存器 | **22 bit**（4MB 窗口；21-bit 也够但擦边） |
| woff | 19 bit（W 区 320KB） | 权重镜像 2.02MB / 层内偏移 124,416 B | **21 bit**（扁平镜像）/ 17 bit（层内相对） |
| qoff | 16 bit（Q 区 48KB） | 层内 Q ≤5,200 B（随层流式） | **13 bit**（层内相对）或 17 bit（扁平） |
| ic/oc | 10 bit | 864 | **10 bit 不变 ✅** |
| ih/iw | 9 bit | 224 | **9 bit 不变 ✅** |
| 新增 tile 字段 | — | band 行数(1~16)/OC 分块/银行选择 | **+8 bit** |
| **合计** | 200 bit | 约 **213~224 bit** | 128 项 × 224 = 28.7 Kb ⇒ **1 BRAM36 或 ~450 LUT6（LUTRAM/常量 ROM）** |

### 7.3 ReLU 不兼容（**必须先解决**，否则逐层数值全错）

- 模型激活是 **`nn.ReLU`**（`model.py:8-30` 的 `ConvBNReLU`：conv→BN→**ReLU**；`ResidualConvBlock` 末尾也是 `F.relu`）。
- 现引擎只支持 **leaky（斜率 0.1，用 `M_neg=(M_pos*3277+16384)>>15` 现算）** 或 **linear（`M_neg=M_pos`）**（`CONTRACT §5`；`engine-report §0.6`）。
- **ReLU（负支输出 0）无法用现有 flags 表达**。两条路：
  - (a) **改 RTL 加 1 个 flags 位 `NN_F_RELU`（M_neg=0）**：`nn_pkg.sv` +1 位 flags、引擎 requant 负支改 0（约 5~10 行）、`nn_desc_t.flags` 7→8 位、ROM/flags 生成器同步。**推荐**，工作量小且数值精确。
  - (b) 用 leaky 代替 ReLU 重训/PTQ：数值语义变了，需要重训验收，成本更高。

---

## 8. 四个方案对比（量级工作量 / 风险 / 性能）

> 工作量单位 = **"文件/模块级改动数"**（不是人日）。风险 = 该方案最可能翻车的点。

### 8.1 方案总表

| 方案 | 内容 | 帧率@100MHz | DDR3 需求 | 工作量（文件/模块级） | 主要风险 | 判定 |
|---|---|---:|---|---|---|---|
| **R2（主线）** | 完整 2.05M 模型 + DDR3 权重流式 + DDR3 激活 arena + tile cache | **2.50 fps**（3.05@122MHz） | 需要（arena 1.81MB + 权重 2.02MB） | **12~15** | MIG 未知、BRAM 只剩 3 tiles、算力不足 | **可行但 <5fps**，唯一能跑原模型的路线 |
| **R1'（降档）** | QSPI XIP 权重流式 + 112×112 输入 + A=B=64KB | — | 不用 DDR3（但**激活放不下**） | 6~8（但做完也跑不了） | **已实测否决（X2）** | ✗ |
| **R1''（兜底/极小模型）** | QSPI 权重 + 56×56 输入（arena 112,896 ≤128KB，全片上） | **31.5 fps** | 不需要 | 5~7（QSPI 主控）+ 重训 | 56×56 精度未验证，多半不可用 | 只作"无 DDR3 兜底"演示 |
| **R3（模型瘦身）** | 重训到 ≤320KB 权重 + 输入 128 + 峰值 ≤96KB | 可 ≥5fps（看瘦身幅度） | 不需要 | 工具链 4~6 + 训练（不可估） | 精度/工作量 | **最快能上板的"能跑到"路线**，但要重训 |
| **R4（QSPI 单独跑 2M）** | QSPI 权重 + DDR3 激活？ | 不成立 | 仍需 DDR3 | — | 已否决（X3） | ✗ |

### 8.2 关键量化对比

| 指标 | R2（DDR3 完整模型） | R1''（56×56 全片上） | R3（瘦身） |
|---|---:|---:|---:|
| MACs | 2,273.5 M | 144.6 M | 目标 ≤~1,100 M |
| 权重 | 2,020,960 B（DDR3） | 2,020,960 B（QSPI） | ≤320 KB（BRAM 可装） |
| 激活 arena | 1,806,336 B（DDR3） | 112,896 B（片上 ✓） | ≤96 KB（片上 ✓） |
| 帧率@100MHz | 2.50 fps | 31.48 fps | 取决瘦身幅度 |
| 精度 | **保持**（原模型原输入） | **未知/多半不可用**（16× 分辨率下降） | 需重训验证 |
| 是否改引擎调度 | 要（band-outer + tilecache） | 不要 | 不要 |
| 是否改存储 | 要（DDR3+MIG+W可写） | 只加 QSPI 主控 | 不要 |
| 阻塞项 | **DDR3 引脚/型号/MIG（6 项待用户）** | QSPI 用户态访问（STARTUPE2，零经验） | 训练资源/精度 |

### 8.3 "瘦身"到底要砍多少（如果选 R3）

- 权重必须砍 **6.3×**（2.02MB→320KB）。注意 **backbone（stem+stage1~5）权重本身就有 1,141,984 B（1,115.2 KiB = 1.12MB）**，FPN+头 878,976 B（858.4 KiB）⇒ **只砍 FPN/头不够，必须砍 backbone 宽度**（0.55→~0.30）或砍 stage5。
- MACs 要砍 **≥2×**（2,273M→≤1,100M 才能 ≥5fps）；而 **84% MACs 在 FPN/头**（towers 1,170M）⇒ 把 towers 从 8 个 3×3@56² 改成 1×1 或降通道到 32，可砍掉 ~1.0G，正好达标。
- ⇒ 建议瘦身目标：**backbone width 0.55→0.35 + FPN 72→40 + towers 8×3×3→4×3×3 或 3×3→1×1 深度减半**；预估权重 ~300KB、MACs ~800M~1.0G ⇒ 8~10fps@100MHz。**属于重训任务**。

---

## 9. 排期级任务分解（R2 主线，12~15 个任务）

> 标注：`[阻塞]` = 必须先拿用户/硬件输入；`[可并行]`；`[串行]`；规模 = 改动文件/模块数（S≤2、M=3~5、L≥6）。

| # | 任务 | 改哪些文件/模块 | 依赖 | 验证判据 | 规模 |
|---|---|---|---|---|---|
| **T0** | **[阻塞] 向用户索取 DDR3 6 项输入**（§2.2） | 无代码 | 用户 | 拿到型号/引脚/参考时钟/速率/用途/Vivado 版本 | S |
| **T1** | DDR3 物理层选型：MIG 7-series vs 自写控制器 | `fpga/build.tcl`（IP 或 read_verilog）、`fpga/top_a100t.sv`、新 `ddr3_phy.*`、新 xdc 片段 | T0 | 综合出 MIG、时序收敛；或自写控制器行为级验证 | L |
| **T2** | **行为级 DDR3 模型 + 自写简易控制器**（无板时先做，P3 R7） | `sim/ddr3_model.sv`（新）、`sim/tb_ddr3_loop.sv`（新） | 无（可与 T0 并行） | 写-读回环 1,000 次随机地址 mismatch=0 | M |
| **T3** | **W 区可写化 + 层双缓冲 + 预取 DMA** | `nn_mem.sv`（W 口改可写、加 fill 口）、`nn_subsys.sv`（银行/基址寄存器）、`nn_seq.sv`（预取指令）、`nn_pkg.sv`（新增 flags/字段） | T2 | `tb_nn_mem` 三模式回归 + 新 `tb_nn_wstream`（权重逐位对比） | L |
| **T4** | **Q 随层流式**（小 Q 缓冲 2×8KB） | `nn_mem.sv`（Q 区改可写/双缓冲）、`nn_subsys.sv` | T3 | Q 读回逐位等于 golden（`tb_nn_mem` 扩展） | M |
| **T5** | **nn_tilecache（复用 P3 方案 A）** | 新 `nn_tilecache.sv`、`nn_subsys.sv`（a/b 口 mux）、`nn_pkg.sv`（tile 描述符） | T2 | `tb_nn_tilecache`（fill/flush/双缓冲/halo） | L |
| **T6** | **引擎 band-outer 调度改造** | `nn_conv_engine.sv`（外层循环改为 行带→OC 块，地址改 tile-relative） | T5 | `tb_nn_engine` 47 case 位精确不回退 + 新 band 模式 case | L |
| **T7** | **通道上限放宽 + ReLU 模式** | `nn_subsys.sv:252-253`（256→1024）、`nn_pkg.sv`（flags+1bit `NN_F_RELU`）、`nn_conv_engine.sv`（requant 负支置 0） | 无（可最早做） | 单 case 位精确：ic/oc=864 的 1×1 conv；ReLU 层 cos=1.0 | S |
| **T8** | **ROM v1 + 生成器** | `nn_pkg.sv`（nn_rom_t 加宽）、`tools/nn_gen_rom.py`（新 plan 格式）、`nn_rom_pkg.sv`（重生成） | T7 | 重生成后 C128 旧模型 E2E 仍 PASS（回归不变）+ 新模型 ROM 长度/字段断言 | M |
| **T9** | **工具链：plan/arena/权重镜像生成**（新模型） | 新 `tools/bottlecap/gen_plan.py`、`gen_arena.py`、`gen_wq.py`、`gen_sw.py` | T8 | golden mismatch=0；arena 峰值 ≤4MB；逐 op checksum | L |
| **T10** | **CPU 输入通路**（摄像头/图片 → DDR3 arena） | `nn_subsys.sv`（CPU→DMA 通道）、`sw/*.c` | T5 | CPU 写 96KB staging → DMA 落 DDR3 → engine 读回逐字节一致 | M |
| **T11** | **SoC E2E：新模型 MODE_AUTO 逐 op 位精确** | `sim/tb_sw_nn_bottlecap.sv`（新）、`sw/bottlecap_demo.c`（新） | T9,T10 | `RESULT : PASS` + gold per-op checksum + 周期 = 公式值 | L |
| **T12** | **上板：MIG 回环实测带宽 + NPU 帧率** | `results/bottlecap/ddr3/`（只报告）、`fpga/build.tcl`（bitstream） | T1,T11 | 实测 DDR3 带宽/帧率/与仿真一致 | M |
| **T13** | **文档契约更新** | `CONTRACT.md`（§3/§4/§12）、`SPEC-SPECIALIZED.md`、`PLAN.md`、`DELIVERY.md`、PITFALLS | 全程 | 契约与 RTL 一致；回归 PASS 数不降 | S |
| **可选** | QSPI XIP 权重源（替代/补充 DDR3） | 新 `qspi_xip.sv`（STARTUPE2）、`tools/flash_*` | T0/T3 | 用户态读 flash 逐位比对 + 5MB/s 实测 | L |

- **阻塞链**：T0 → T1 → T12（没有板/引脚就到这里为止）；但 **T2/T3/T5/T6/T7/T8/T9 全部可以在无板情况下推进**（行为级 DDR3 模型 + 仿真），这是建议的并行策略。
- **最早能出成果的 3 件事**（不依赖用户）：T7（2 行 + 1 bit，半天量级）、T8（ROM v1 + 生成器）、T9（工具链 golden）。

---

## 10. 建议顺序与决策问题

1. **先做 T7 + T8 + T9 + T2**（全部无阻塞，且是后面一切的地基）。
2. **同时向用户索取 6 项输入**（T0）。拿到后 T1/T3/T4 并行。
3. **不建议先碰 T6（引擎 band-outer）**：它最重且最容易破坏现网 112-op E2E；先用"整层权重流式 + 逐 op 激活在 DDR3（无 tile cache，靠读放大）"跑通一个 **"能跑但慢"** 的版本，再上 tile cache 提速。理由：现调度读放大 8.4× → 187MB/帧，在 2.5fps 下也只有 **468 MB/s（29%）**，**DDR3 撑得住**，所以可以先不做 band-outer！（这是与 P3 不同的结论：P3 要 30fps 才必须 band-outer，本模型 2.5fps 不需要。）

**给 Lead 的 3 个决策问题**：
1. 是否接受 **2.5fps@100MHz / 3.05fps@122MHz** 作为"完整 2M 模型"的验收指标？（还是要 ≥5fps → 必须走 R3 瘦身或 PX16+提频）
2. DDR3 用 **MIG IP** 还是**自写控制器**？（MIG 违背"零厂商 IP"纪律但是唯一现实解；自写 DDR3 控制器工作量 ≥ 6 个模块且 DQS 训练风险高）
3. 是否允许把 **"逐 op 激活直落 DDR3（无 tile cache）"** 作为第一阶段里程碑（先跑通再提速）？

---

## 11. 证据索引（本报告所有数字的出处）

| 类别 | 文件 / 命令 | 用到的内容 |
|---|---|---|
| 板级引脚 | `fpga/daVinciPro.xdc:47-59` | 只有 sys_clk/rst/led/uart；R4 非专用时钟 |
| 顶层端口 | `fpga/top_a100t.sv:46-54` | 无 DDR3 端口 |
| 构建流程 | `fpga/build.tcl:149,194,484` | 非 IP 流程、显式 read_verilog 清单 |
| 无外部存储 | `PLAN.md:20`、`DELIVERY.md:56` | "本板没有 DDR/外部存储" |
| 用户确认 | `PLAN.md:228,249-253`、`DELIVERY.md:82` | 2 片 DDR3 + 摄像头、6 项待确认 |
| DDR3 带宽表 | `P3-DDR3-TILECACHE.md §3.2` | 1.6/3.2 GB/s 理论、1.1~2.7 有效 |
| tile cache 设计 | `P3-DDR3-TILECACHE.md §4, §4.5, R2/R7` | 方案 A、DMA 端口契约、MIG 风险、仿真路线 |
| arena/21-bit | `P3-320-ARENA.md §1,§4`、`plan/…` | arena 口径、ROM 位宽决定 |
| 存储布局 | `CONTRACT.md §3,§4,§6,§8` | W320K/Q48K/A96K/B32K、IC/OC≤256、权重布局、NHWC |
| ROM | `nn_pkg.sv:103,111-129`、`nn_rom_pkg.sv:10-12` | NN_ROM_DEPTH=128、nn_rom_t=200bit、LUTRAM 实现 |
| 通道上限 | `nn_subsys.sv:252-253` | ic/oc > 256 → err 0xE1 |
| 引擎容量 | `nn_conv_engine.sv:83,182` | d_ic/d_oc 16 bit、计数器 16 bit |
| 周期公式 | `results/ai-accel/proto/engine/calc_cycles_v3.py` | v3 公式（50/50 case 实测相等） |
| BRAM 余量 | `mem-report.md §3.7`、`DELIVERY.md §9.2` | 整机 132/135；LUT 36,985/FF 16,381/DSP 168 |
| 频点 | `DELIVERY.md §9.2.1` | 100MHz 主交付、122.22 最高、125 差 0.077ns |
| QSPI Flash | `tools/flash_logs/REPORT.md:30,38`、`readback.bin` 大小 | MT25QL128 16MB、part 名 |
| 镜像占用 | `DELIVERY.md:217`、`CODE-REVIEW-PLAN.md` E-01 | 3,825,894 B / 3,825,788 B |
| 模型结构 | `tools/bottlecap/model_src/nut_detector/enhanced_anchor_free.py`、`model.py:8-30` | 层结构、ReLU |
| 模型参数 | `tools/bottlecap/model_src/run_config.json` | 2,048,721 / fpn 72 / width 0.55 |
| 本报告数字 | `results/bottlecap/ddr3/gen_budget.py` → `bandwidth_budget.json`、`layers_224.csv` | 全部逐 op/逐阶段数字（可重跑复现） |
