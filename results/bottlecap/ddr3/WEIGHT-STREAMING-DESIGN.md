# 权重流式化设计（W 区作 L2 cache + DDR3 逐层预取）

> 作者：`ddr3-feas`。日期：2026-11-03。任务：task-2（Lead 2026-11-03 追加口径：主线 = DDR3 + 流式加载跑完整 2.05M 参数原模型）。
> 定位：本文是 `DDR3-FEASIBILITY.md` 的**实现设计篇**；数字与出处见该文 §11 证据索引。
> 纪律：本文**只是设计**，未改任何 RTL。所有"改动点"均给出文件+模块+行号；工作量按"文件/模块级改动数"计。

---

## 0. 结论摘要

| 问题 | 结论 |
|---|---|
| 现 W 区能直接当 L2 cache 吗？ | **能**。320KB（80 tiles）已有 2 个读口结构；加"银行选择 + 填充写口"即可做**层双缓冲**（2×160KiB），最大单层 124,416 B + Q 5,200 B = 129,616 B ≤ 160KiB ✓ |
| 预取粒度？ | **整层**（不是 OC 块）。OC 块粒度会让同一份权重被搬 2~5×，且要改引擎寻址 |
| 预取能被计算掩盖吗？ | **DDR3：是**（缺口 6,690 拍 = 0.017%）。**QSPI：否**（缺口 5,407,263 拍 = 13.5%） |
| DMA 口位宽/深度？ | **128-bit/beat**，异步 FIFO 512B×2（LUTRAM），平均只需 5.05 MB/s |
| 需要多少 BRAM？ | **0 增量**：W 区仍是 80 tiles（2 银行 × 40 tiles）；Q 缓冲 2×8KB=4 tiles（从现 Q 区 8 tiles 里划）；ROM +0~1 tile |
| 权重与引擎 w 读口争用？ | 无结构冲突：引擎读**活动银行**，DMA 写**非活动银行**（物理不同 tiles） |
| 最小改动集合 | **7 个文件/模块**：`nn_mem.sv`、新 `nn_wload.sv`、`nn_subsys.sv`、`nn_seq.sv`、`nn_pkg.sv`、`tools/nn_gen_rom.py`、`sim/tb_nn_wstream.sv`（+ 契约/工具链文档） |

---

## 1. 现状：W 是"综合期烧死的只读 ROM"

| 事实 | 证据 |
|---|---|
| W = 320KB，**4 段 64-bit 宽阵列**（16384/8192/8192/8192 个 64b 字），`$readmemh` 初始化（`NN_W_INIT_A..D`，64-bit/行） | `nn_mem.sv:13,66,132-135,189-192` |
| **只读**：无写口（唯一写路径是 `dbg_we`，且 `ifndef SYNTHESIS` 只在仿真存在） | `mem-report.md §7.2 第 2 条`；`SPEC-SPECIALIZED.md §3`（"W 320KB…CPU 不可访问"） |
| 读口语义：`w_addr[18:4]` 选字 + `w_addr[3]` 选半字；一次读 = **两个 64b 读口** `cur=mem[base]`、`next=mem[base+1]`，**W 读时延 2 拍**（wpipe） | `nn_mem.sv:212-218,242-249`；`mem-report.md §3.8`；`engine-report.md §0.6.1` |
| 段地址映射是**硬编码常量**（`w_base<16384 / <24576 / <32768`） | `nn_mem.sv:220-223` |
| CPU 窗口只映射 A/B，W/Q 不可访问 | `CONTRACT.md §3`、`§12.1`（CPU 窗口只 A/B） |
| 引擎 w 口：`w_re/w_addr[23:0]/w_rdata[127:0]`，8B 对齐 16B 窗口 | `nn_conv_engine.sv`（v3 接口）、`SPEC-SPECIALIZED.md §2` |

**要变成流式 W，本质是三件事**：① W 数组要有**运行期写口**；② 引擎的 `w_addr` 要变成**银行相对地址**（硬件加 bank base）；③ 要有一个**预取引擎**在层边界把下一层从 DDR3 搬进非活动银行。

---

## 2. 最小改动清单（文件 / 模块 / 端口 / 寄存器）

### 2.1 `nn_mem.sv`（T-mem 负责，改动最大）

| # | 改动 | 具体 | 代价 | 为什么必须 |
|---|---|---|---|---|
| M1 | W 拆 **2 银行** | `w_mem_*` 保持 4 段，但地址加 1 位银行选择：`w_bank_sel`（寄存器），`w_base = {bank, w_addr[18:4]}`；两个银行各 40 tiles（160KiB） | 0 tile（80 仍是 80）；+少量 LUT mux | 双缓冲要求两个层同时驻留 |
| M2 | 新增**填充写口**（64-bit/拍） | `input logic wfill_we; input logic [17:0] wfill_addr; input logic [63:0] wfill_wdata;`（地址 = 银行内 64b 字序号 0..20479）；写目标银行 = `~w_bank_sel` | 复用各段 BRAM 的 **port B**（该银行处于非活动态时引擎不读它）→ **0 tile 增量** | 运行期加载权重 |
| M3 | 端口仲裁：port B 在"活动银行=读 next / 非活动银行=写 fill"之间 mux | 按 bank 生成 `portB_we/addr/data` | +1~2 级 mux（LUT） | 保持"活动银行两个读口"语义不变（`next` 读仍然需要） |
| M4 | 新增 **Q 影子缓冲**（可写，2×8KB） | 从现 Q 区（8 tiles BRAM lo）改为写口 + 双缓冲；`q_bank_sel` | 0 tile（复用 Q lo 8 tiles） | 新模型 Q 总量 90,048 B > 48KB，必须随层流式；单层最大 5,200 B |
| M5 | 模式位 `w_mode`（0=ROM 烧死 / 1=流式） | 保持 C128 旧模型零改动（旧路径逐位不变） | 1 寄存器 + ifdef/参数 | **双模兼容**（`DELIVERY §9.5.1` 的 parity 纪律） |
| M6 | 保留 `NN_W_INIT_A..D` 路径（仅 w_mode=0 用） | 综合时若 model 走流式，可把 4 个 init 文件置空/常量 | 综合时间不受影响（`rom_style=block` 已解决展开问题，`DELIVERY §9.3`） | 旧网表/旧 bitstream 可复现 |

**端口增量（nn_mem）**：`wfill_we/wfill_addr[17:0]/wfill_wdata[63:0]`、`wfill_q_we/qfill_addr[12:0]/qfill_wdata[63:0]`、`w_bank_sel/q_bank_sel`（可由 subsys 驱动）、`w_mode`。CPU 窗口与 a/b 口**完全不变**。

### 2.2 新模块 `nn_wload.sv`（预取引擎，Lead/T-mem 均可）

```
输入:  ddr3 读数据口 (从 MIG AXI 或 自写控制器 FIFO)  128bit + valid
       pre_start / pre_src_addr[31:0] / pre_len_bytes[17:0] / pre_bank
输出:  nn_mem.wfill_we / wfill_addr / wfill_wdata   (64bit，按 128b=2×(64b) 拆两拍)
       nn_mem.qfill_*（Q 段，长度来自 ROM 的 qlen）
状态:  IDLE → REQ → XFER → DONE（burst 长度 = 16 拍 = 256B 一次，或按 AXI INCR）
```
- 缓冲：**异步 FIFO 512B × 2**（写侧 ui_clk 100MHz、读侧 NPU 100MHz；两侧同频但相位/来源不同，按异步处理）。
- 一条预取命令 = 一个层的权重 + 该层 Q（`wlen` + `qlen` 都来自 ROM 条目）。
- **不需要 tile 级 DMA**：整层连续搬（权重镜像按 op 执行顺序排布）。

### 2.3 `nn_subsys.sv`

| 改动 | 内容 |
|---|---|
| S1 | 新增 MMIO 寄存器：`NN_WBANK`（当前活动银行）、`NN_WLOAD_ADDR/LEN/GO`（CPU 手动装载，调试用）、`NN_WLOAD_STATUS`（done/err/cur_ptr） |
| S2 | 自动模式：`nn_seq` 发 `pre_start`，subsys 只做 MUX（与 MODE_CPU/MODE_AUTO 双模一致，`SPEC §5`） |
| S3 | **通道上限放宽**（与本设计无关但同一文件必须改）：`nn_subsys.sv:252-253` 的 `ic/oc > 256` → `> 1024`（本模型 33 层超 256，最大 864） |
| S4 | 权重源选择：`NN_WSRC`（0=DDR3 / 1=QSPI），供 R1''/兜底路线复用同一预取引擎 |

### 2.4 `nn_seq.sv`

| 改动 | 内容 |
|---|---|
| Q1 | ROM 条目新增 `wlen[17:0]`、`qlen[12:0]`（或从 ROM 的 `prefetch` 字段取） |
| Q2 | 状态机在 **RUN 拍之前**发 `pre_start(next layer)`；进入下一条前检查 `pre_done`（若未完成则等待，即 §5 的缺口拍数） |
| Q3 | 新增 flags：`NN_F_RELU`（激活模式，见 `ROM-V1.md §5`） |
| Q4 | 银行翻转：每条 op 完成后 `w_bank_sel <= ~w_bank_sel` |

### 2.5 `nn_pkg.sv` + 生成器 + TB

| 文件 | 改动 |
|---|---|
| `nn_pkg.sv` | `nn_rom_t` 加 `wlen/qlen`、`src/dst` 加宽到 21~22 bit、flags 加 `NN_F_RELU`（详见 `ROM-V1.md`） |
| `tools/nn_gen_rom.py` | 按新 plan 生成 ROM + **权重镜像的层偏移表**（保证"按 op 顺序连续排布"，使 `ptr += wlen` 成立） |
| `tools/*`（新） | `gen_weights_image.py`：把 2,020,960 B int8 权重 + 90,048 B Q 拼成一/两个 DDR3 镜像（可按层分块，带 16B 对齐） |
| `sim/tb_nn_wstream.sv`（新） | 见 §9 验证 |
| `sim/tb_nn_mem.sv` | 加 w_mode=1 的写口/银行翻转用例（现 47,148 checks 回归不变） |

### 2.6 成本小结

| 资源 | 增量 | 说明 |
|---|---|---|
| BRAM | **0 tiles**（W 80 + Q 8 复用） | 若要 3 银行才 +40 tiles（不推荐） |
| LUT | 约 +800~1,500（DMA 引擎 + FIFO + 银行 mux） | 现整机 LUT 36,985/63,400，余量充足 |
| FF | 约 +400~800 | 现 16,381/126,800 |
| DSP | 0 | — |
| 时序风险 | 低（都在 nn_mem 周边，不在引擎关键路径） | 现 worst path 是 `u_nn/u_eng/wa_r → u_nn/u_mem/w_cur_*`（`DELIVERY §9.2.1`）——**改动正好在这条路径的端点上，需复核**（加银行位到 BRAM 地址 = +1 级 LUT，预计 −0.1~0.2ns） |

---

## 3. 地址映射与双缓冲时序

### 3.1 地址空间

```
DDR3 物理空间（假设 32-bit × 2 片 ≥ 32MB；实际以用户第 1 项输入为准）
0x0000_0000 .. 0x00FF_FFFF   视频/摄像头帧缓冲（P3-ARENA §0 的规划，保留）
0x0100_0000 .. 0x013F_FFFF   激活 arena（4MB 窗口，实测峰值 1,806,336 B）
0x0140_0000 .. 0x015F_FFFF   权重镜像（2MB 窗口，实际 2,020,960 B）
0x0160_0000 .. 0x0161_FFFF   Q 镜像（128KB 窗口，实际 90,048 B）
```
- 权重镜像**按 op 执行顺序连续排布**：第 i 层的偏移 = Σ_{j<i}(wlen_j)，16B 对齐 → 预取引擎只需 `ptr += wlen`，不需要每层地址表。
- 硬件侧：`w_addr` = 银行内偏移（现 24-bit 够用）；ROM 的 `woff` 退化为**层内偏移**（≤124,416 B ⇒ 17 bit），或保留扁平 21-bit 由硬件减去层基址——建议**层内相对**（省位宽，见 `ROM-V1.md`）。

### 3.2 双缓冲时序（层边界）

```
        ┌── 层 L 计算（读 bank0）───────────┐┌── 层 L+1 计算（读 bank1）──
DMA:    [预取 L+1 → bank1][预取 L+2 → bank0][预取 L+3 → bank1]...
引擎:                        [层 L][bank0]                [层 L+1][bank1]
```
- 每条 op 开始前：`pre_start(bank=~活动银行, src=ptr_next, len=wlen_next)`；op 结束翻转 `w_bank_sel`。
- **唯一考虑**：若 `wlen_next / DDR3有效速率 > 本层计算拍数`，则下一条 op 要等（§5 表）。

### 3.3 为什么不用"OC 块粒度预取"

- 16 OC tile 的权重 = `16×IC_pad×K²`（本模型最大 13,824 B）；若按 OC 块预取，每层要搬 `n_oc_tile` 次，且引擎 `w_addr` 需要 tile-relative 映射 → **引擎改动**（P3 方案 B 的教训，`P3-TC §4.5`）。
- 整层预取只动 `nn_mem` + `nn_seq`，**引擎零改动**（w_addr 语义不变，只是加了 bank 基址）。

---

## 4. DMA 口规格

| 项 | 规格 | 依据 |
|---|---|---|
| 数据宽度 | **128 bit/beat** | 与 MIG 4:1（128-bit @ ui_clk）对齐；与 `b_wdata(128b)/b_wstrb(16B)`、P3 tile DMA 契约一致（`P3-TC §4.4`） |
| nn_mem 写口 | 64 bit/拍（128b 拆 2 拍）或 128 bit/拍（W 阵列改 128b 宽则需 80 tiles 而非 75.5，见 `mem-report §3.4`） | 建议 **64b/拍、2 拍写一个 128b beat**（省 tile） |
| 突发长度 | AXI INCR，**16 beat = 256B** 或按层末对齐收尾 | 覆盖 DDR3 行激活开销；DDR3 突发 8 对 32-bit 也够 |
| FIFO | 异步 FIFO，**512B × 2**（= 64 beat），LUTRAM 实现 | 覆盖 MIG 读延迟 ~50~100 拍 |
| 平均带宽 | **5.05 MB/s**（2.5fps） | 2,020,960 B/frame × 2.5 |
| 峰值带宽（单对相邻层） | 28.15 B/cyc（2,815 MB/s）→ **超 DDR3**，但只出现 1 次、代价 6,690 拍 | §5 |
| 持续带宽上限（设计目标） | ≥ **300 MB/s**（远大于需求的 5.05 MB/s，为突发/预取提前量留余量） | DDR3 有效 1,120 MB/s 的 27% |

---

## 5. 逐层"预取字节 vs 计算拍数"对照（核心交付）

> 全表在 `results/bottlecap/ddr3/layers_224.csv`（105 行，列 `w_bytes / cycles / prefetch_B_per_cyc`）。
> 判据：`预取需求速率 = 下一层权重字节 / 本层计算拍数`（1 深双缓冲口径）。

### 5.1 全部 op 的权重/周期画像（Top-12 最大层）

| op（fx 名） | kind | k | ic | oc | 权重 B | 周期 | 权重/周期 (B/cyc) |
|---|---|---:|---:|---:|---:|---:|---:|
| backbone_stage5_1_block_0_0 | conv | 1 | 144 | 864 | **124,416** | 125,288 | 0.99 |
| backbone_stage5_1_block_2 | conv | 1 | 864 | 144 | **124,416** | 117,278 | 1.06 |
| backbone_stage5_2_block_0_0 | conv | 1 | 144 | 864 | **124,416** | 125,288 | 0.99 |
| backbone_stage5_2_block_2 | conv | 1 | 864 | 144 | **124,416** | 117,278 | 1.06 |
| backbone_stage5_0_block_2 | conv | 1 | 528 | 144 | 76,032 | 72,296 | 1.05 |
| refine5_conv1_0 | conv | 3 | 72 | 72 | 46,656 | 35,136 | 1.33 |
| refine5_conv2_0 | conv | 3 | 72 | 72 | 46,656 | 35,136 | 1.33 |
| refine4_conv1_0 | conv | 3 | 72 | 72 | 46,656 | 140,283 | 0.33 |
| refine4_conv2_0 | conv | 3 | 72 | 72 | 46,656 | 140,283 | 0.33 |
| refine3_conv1_0 | conv | 3 | 72 | 72 | 46,656 | 560,871 | 0.083 |
| refine3_conv2_0 | conv | 3 | 72 | 72 | 46,656 | 560,871 | 0.083 |
| refine2_conv1_0 | conv | 3 | 72 | 72 | 46,656 | 1,962,831 | 0.024 |

> **关键读数**：**所有**层的"权重/自身周期" ≤ **1.33 B/cyc = 133 MB/s**。也就是说，即使**不预取、边算边从 DDR3 取**，DDR3 也只要 133 MB/s（有效带宽 1,120 MB/s 的 12%）。双缓冲的作用是**消灭层间气泡**，不是满足带宽。

### 5.2 相邻层对（唯一的缺口来源）

| 前一 op | 下一 op | 前层周期 | 下层权重 B | 需求 B/cyc | DDR3 够？ | QSPI(0.2B/cyc) 够？ |
|---|---|---:|---:|---:|---|---|
| `add_10` | `backbone_stage5_2_block_0_0` | 4,419 | 124,416 | **28.15** | ✗（需 11,109 拍，缺 6,690 拍） | ✗（需 622,080 拍） |
| `add_13` | `refine4_conv1_0` | 8,829 | 46,656 | 5.28 | ✅ | ✗ |
| `add_8` | `backbone_stage4_4_block_0_0` | 10,789 | 46,464 | 4.31 | ✅ | ✗ |
| `add_9` | `backbone_stage5_0_block_0_0` | 10,789 | 46,464 | 4.31 | ✅ | ✗ |
| `lateral5_0` | `refine5_conv1_0` | 11,826 | 46,656 | 3.95 | ✅ | ✗ |
| `add_7` | `backbone_stage4_2_block_0_0` | 8,829 | 31,104 | 3.52 | ✅ | ✗ |

- **DDR3 累计缺口 = 6,690 拍（0.017% 帧时）** ⇒ 可视为"完全被计算掩盖"。
- **QSPI 累计缺口 = 5,407,263 拍（13.5%）** ⇒ 帧率 2.50 → 2.20fps；且 **30 对相邻层超 QSPI 速率**。
- **缓解手段（若在意那 6,690 拍）**：① 3 银行（+40 tiles，不推荐）；② 把 `add_10` 这种极短 op 与下一个 expand 的预取**提前一个 op 启动**（2 层提前量，需要 3 银行或 1.5 银行轮转）；③ 直接接受（0.017%）。

### 5.3 按阶段汇总的权重

| 阶段 | 权重 | 占总量 |
|---|---:|---:|
| stage5 | 625.5 KiB | 31.7% |
| fpn（lateral+refine） | 385.9 KiB | 19.6% |
| towers | 364.5 KiB | 18.5% |
| stage4 | 362.9 KiB | 18.4% |
| fusion | 106.3 KiB | 5.4% |
| stage3 | 100.0 KiB | 5.1% |
| 其余（stem/stage1/stage2/heads） | 28.4 KiB | 1.4% |
| **合计** | **1,973.6 KiB（2,020,960 B）** | 100% |

> **注意**：backbone（stem+stage1~5）权重合计 **1,141,984 B（1,115.2 KiB）**，FPN+头 **878,976 B（858.4 KiB）**，合计 2,020,960 B。**任何"FPN 瘦身后放进 BRAM"的方案都不成立**——backbone 自己就 1.12MB > 320KB（这也是 `DDR3-FEASIBILITY.md §1 X5/§8.3` 的依据）。

---

## 6. 与引擎 w 读口的争用分析

| 端口 | 需求 | 是否冲突 |
|---|---|---|
| 引擎 w 读（**活动银行** port A/B：cur+next） | **每拍 16B**（128 MAC/拍必需） | — |
| DMA 填充（**非活动银行**） | 峰值 28.15 B/cyc（仅 1 次），典型 ≤1.33 B/cyc，平均 0.05 B/cyc | **不冲突**：物理是不同 bank 的 tiles；活动银行不读非活动银行 |
| Q 读（引擎每 OC tile 一次，`q_re`） | 极低（每 tile 数十拍） | 与 Q 填充同理（Q 也是银行结构） |
| CPU 窗口 | 只 A/B（`CONTRACT §12`） | 不变 |

- **BRAM 端口预算**：W 每 banking 组 = 2 读口（活动）+ 1 写口（非活动）→ 用真双口 BRAM 的"port B 分时读/写"。实现上以 `w_bank_sel` 为条件复用 port B 的写使能；**不需要复制 BRAM**（这一点与 P3 方案 B 在 A/B 上遇到的 2R1W 问题不同——W 是 1R+1R，银行分时后是 1R+1W）。
- **时序影响**：`w_bank_sel` 进 BRAM 地址 = 在 `w_addr_q` 前多 1 级 LUT 或直接拼到地址高位（不增加逻辑级数，因为 BRAM 地址位多一位）。预估对现 worst path（`u_nn/u_eng/wa_r → u_nn/u_mem/w_cur_*`，`DELIVERY §9.2.1`）**影响 <0.2ns**，需在 P2 全实现复核。

---

## 7. Q 随层流式

| 项 | 数值 |
|---|---|
| 新模型 Q 总量 | 90,048 B（84 层 × (6×OC_pad+16)） |
| 单层最大 Q | **5,200 B**（OC=864：6×864+16） |
| 双缓冲 | 2 × 8KiB = 16KiB = **4 BRAM36**（从现 Q lo 的 8 tiles 中划出，**净增 0**） |
| 预取 | 与权重同一条 `pre_start` 命令（`wlen`+`qlen`），或独立小命令 |
| 读取 | 保持现 `q_re/q_addr[12:0]`（64b 字索引）→ 只需加 `q_bank_sel` 高位 |
| 为什么不合进 W 区 | Q 的访问粒度（bias/M_pos 批量）与 W 的 16B 窗口不同；且 Q 总量 90KB 会挤占 W 银行（160−124=36KiB 只剩 30KiB，塞不下 90KB 中最大的两层的 Q 叠加）→ 独立 4 tiles 最省 |

---

## 8. QSPI 变体（R1''：兜底 / 极小模型）

> Lead 口径：保留但**降级**。结论：**QSPI 单独跑不了 2M 模型（激活放不下，见 `DDR3-FEASIBILITY §1 X3`）**，但可以作为"权重源"替代 DDR3 的前半段（若 DDR3 引脚迟迟拿不到）。

### 8.1 板载 flash 事实

| 项 | 值 | 证据 |
|---|---|---|
| 型号 | **Micron MT25QL128 / N25Q128**（JEDEC `20 BA 18`），128 Mbit = **16 MiB**，3.3V，SPI x1/x2/x4 | `tools/flash_logs/REPORT.md:30,38` |
| 容量实测 | `readback.bin` = 16,777,216 B | `tools/flash_logs/` |
| 现有镜像 | AI 档 bitstream 3,825,894 B；SPIx4 启动 `.bin` 3,825,788 B | `DELIVERY.md:217`；`CODE-REVIEW-PLAN.md` E-01 |
| **剩余空间** | 16,777,216 − 3,825,894 ≈ **12.95 MB** | 放 2,020,960 B 权重后仍余 ~10.9 MB |
| 用户态访问 | 需 **STARTUPE2**（USRCCLKO）驱动 CCLK + 复用 DQ[3:0]/CS；配置完成后 flash 空闲 | 需新增 RTL；仓库现有流程只有 JTAG 写 flash（`tools/flash_boot.ps1`） |

### 8.2 带宽账（对 2M 模型逐档）

| 场景 | 权重/帧 | 帧时 | 需要 | QSPI x4@50MHz 理论 25 / 可用 15~20 | 判定 |
|---|---:|---:|---:|---|---|
| 224 输入 @2.5fps（实际） | 2,020,960 B | 400.6 ms | **5.05 MB/s** | ✅（占可用 25~34%） | 平均可掩盖；突发缺口 13.5% |
| 224 输入 @5fps（若算力达标） | 2,020,960 B | 200 ms | 10.1 MB/s | ✅（50~67%） | 边缘 |
| 112 输入 @8.87fps | 2,020,960 B | 112.7 ms | **17.93 MB/s** | ⚠️（90~120%） | **不可靠** |

### 8.3 QSPI XIP 主控工作量与风险

| # | 工作 | 规模 |
|---|---|---|
| 1 | `qspi_xip.sv`：STARTUPE2 + QSPI 读命令（0x6B/0xEB）+ 4-bit 数据对齐 + 命令/数据相位 | M（1 新模块 + 顶层接 STARTUPE2 原语，需谨慎：CCLK 是专用网络） |
| 2 | 预取引擎复用 §2.2 的 `nn_wload`（只换源口） | S |
| 3 | 权重烧写流程：`flash_boot.ps1` 追加一个分区（bitstream 之后写权重镜像，需重算 offset） | S（脚本） |
| 4 | 仿真：行为级 QSPI flash 模型 | M |
| 风险 | ① STARTUPE2 用户态 CCLK 的时序/扇出约束在 2018.3 上无先例；② flash 与配置共用引脚，误操作会破坏自启动；③ 带宽对 2M 模型只是"刚好" | — |

### 8.4 建议

- **不要**把 QSPI 当 2M 模型的主线（激活仍需 DDR3）。
- 可作 **R2 的权重源备选**：若 MIG 迟迟无法落地，先用 QSPI 把"权重流式"链路跑通（引擎/预取/双缓冲全部复用），DDR3 只负责激活 arena——这会把 DDR3 的带宽需求从 113MB/s 降到 ~108MB/s（可以忽略），但**仍需 MIG/控制器**。
- 唯一的"完全不用 DDR3"路线是 **56×56 输入 + 极小模型重训**（arena 112,896 ≤ 128KB，`DDR3-FEASIBILITY §8.1 R1''`），QSPI 只当权重源。

---

## 9. 验证方案（先仿真、后上板）

| 阶段 | TB / 命令 | 判据 |
|---|---|---|
| P2-1 W 写口/银行翻转 | 新 `sim/tb_nn_wstream.sv`：随机写 bank/地址 + 引擎口读回；层边界翻转 | 写读逐位一致；翻转后读到新银行；**对 `tb_nn_mem` 三模式回归 47,148 checks 无回退** |
| P2-2 预取引擎 | `tb_nn_wstream` + 行为级 DDR3 模型（见 `DDR3-FEASIBILITY §9 T2`） | 预取长度/顺序正确；FIFO 不溢出；总等待拍数 ≤ 6,690+ε |
| P2-3 逐层位精确 | 用现 `tb_nn_engine` 的 46+4 向量改造：权重**经预取链路写入**再跑同一 case | mismatch=0（证明"只换存储不换结果"，P3 P2 口径） |
| P2-4 全模型 E2E | 新 `tb_sw_nn_bottlecap`（MODE_CPU/MODE_AUTO 双模） | 逐 op FNV 与 golden 一致；NPU 周期 = 40,060,598（±2%） |
| P2-5 上板 | `python tools/fpga_workflow.py synth --nn ...` + UART | `RESULT : PASS`；实测帧率 ≈ 400ms；DDR3 回环带宽 ≥ 300MB/s |

---

## 10. 工作量（文件/模块级）

| 任务 | 文件/模块 | 规模 | 可并行 |
|---|---|---|---|
| W 可写化 + 双银行 + Q 缓冲 | `nn_mem.sv` | L（1 文件 6 处） | 与预取引擎并行 |
| 预取引擎 + FIFO | 新 `nn_wload.sv` | M | ✅ |
| 子系统寄存器/仲裁/上限 | `nn_subsys.sv` | M（含 256→1024 两行） | ✅ |
| 序列器预取/银行翻转 | `nn_seq.sv` | S~M | 依赖 ROM v1 |
| ROM 加宽 + flags | `nn_pkg.sv`、`tools/nn_gen_rom.py` | M | ✅（最早做） |
| 验证 | `sim/tb_nn_wstream.sv`、`tb_nn_mem.sv` 扩展 | M~L | 依赖上两项 |
| 权重/Q 镜像生成 | 新 `tools/bottlecap/gen_weights_image.py` | S | ✅ |
| **合计** | **7 个文件/模块**（+ 契约 2 篇） | 与 `DDR3-FEASIBILITY §9` 的 T3/T4/T8 对应 | — |
