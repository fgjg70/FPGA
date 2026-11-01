# 特化架构规格（v0.7 · autonomous mode）

> 依据 [`MODEL-FREEZE.md`](MODEL-FREEZE.md)（D1–D5 决策）。目标：**NPU 自主执行固定模型**，
> CPU 退出推理控制流；硬件对 108 个 op 的序列/形状/权重偏移/量化参数全部硬编码。
> 交付档（无 `NN_EN`）不受影响；旧"CPU 逐 op 驱动"模式（v0.5）保留为**回归对照**（同一硬件双模）。

## 0. 结构

```
        ┌──────────────────────────── nn_subsys (v0.7) ────────────────────────────┐
CPU ───▶│ CPU 窗口: A/B only (1拍读)   MMIO: JOB_START / STATUS / CYCLES / IRQ      │
        │                                        │                                 │
        │   nn_seq (新增) ── 微码 ROM (~1.7KB LUTRAM, 108 entries)                  │
        │     │ 发 per-layer desc / 启动引擎 / 处理 add、copy、conv0(packed3)       │
        │     ▼                                                                    │
        │   nn_conv_engine v3: 128 MAC/拍 (16 OC lanes × 8 px)                     │
        │     + PACKED3 模式 (conv0: 输入 3B/像素 packed) + ADD with per-tensor R   │
        │     ▼                                                                    │
        │   nn_mem v0.7: W 320KB (80 BRAM, 128b 读口)                              │
        │                Q 48KB (LUTRAM 12K×32b, 独立 64b 读口)                     │
        │                A 96KB / B 32KB (激活, 128b 读 + 128b 写)                   │
        └──────────────────────────────────────────────────────────────────────────┘
```

## 1. 微码 ROM 格式（`nn_seq` 读取）

- 深度 **128**（108 有效 + 对齐），每项 **96 bit**（12B），总 1.5KB → LUTRAM/ROM。
- 综合时由 `tools/nn_gen_rom.py` 从 `plan.json` 生成 `nn_rom.svh`（`localparam` 数组），
  流程：`plan.json → gen_rom → nn_rom.svh`（生成物进 git，可复现）。

| 字段 | 位宽 | 含义 |
|---|---|---|
| kind | 4 | 0=conv, 1=dwconv, 2=pool, 3=upsample, 4=add, 5=copy |
| flags | 4 | bit0 depthwise, bit1 leaky, bit2 PACKED3, bit3 ADD_R |
| pad | 3 | 0..4 |
| stride | 2 | 1..3 |
| icb | 5 | 输入通道块数（IC/8）|
| ocb | 5 | 输出通道块数（OC/8）|
| ih, iw | 9+9 | 输入 H/W |
| ohop, owop | 2+2 | 输出块偏移（copy/add 的通道块偏移，8ch 粒度）|
| woff | 18 | W 区字节偏移（≤320KB）|
| qoff | 18 | Q 区字节偏移（≤48KB）|
| csum | 32 | golden FNV（仅 debug 模式用，无则为 0）|
| aux0/aux1 | 16+16 | add 的 R 低 16 位 / add 的 KADD；copy 的源通道偏移 |

> 具体打包在 `tools/nn_gen_rom.py` 里定义并写进 `nn_pkg.sv` 的 `nn_rom_t`；ROM 内容变化必须重跑 E2E。

## 2. 引擎 v3 接口变化（相对 v2）

| 端口 | v2 | v3 |
|---|---|---|
| 权重读 | `w_rdata[63:0]` 1 拍 | **`w_rdata[127:0]`**（每拍 2×64b，供 16 OC lanes）|
| 激活写 | `b_wdata[63:0]` | **`b_wdata[127:0]` + `b_wstrb[15:0]`**（16 lanes 写回；8 通道层/copy 只用半字掩码）|
| Q 读 | 复用 w 口（Q 在 WQ 统一阵列）| **独立 `q_re/q_addr[12:0]/q_rdata[63:0]`**（q_addr = 64b 字索引）|
| desc | 通用描述符 | **不变**（nn_seq 填；引擎语义不变，便于双模对照）|

- 语义/数值公式**完全不变**（requant、floor、leaky、padding 填 zp_in、饱和）；
- `PACKED3`：仅 conv0 用；激活地址 = `y*W*3 + x*3 + c`（c<3，其余 lane 填 zp_in），权重布局同上（IC_pad=8，后 5 个 IC 为 0）；
- `ADD_R`：`out = clamp(q_d + (((q_s - zp_s)*R) >> KADD), -128, 127)`（替代 CPU `cpu_add`，公式见 CONTRACT §11）；
- 时序目标：**OOC @100MHz WNS ≥ +1.0ns；全实现 ≥100MHz**（D4）。

## 3. 存储 v0.7

| 区 | 大小 | 实现 | 端口 |
|---|---|---|---|
| W | 320KB | **80×BRAM36**（$readmemh 4 段初始化，同现有机制）| NPU 128b 读；**CPU 不可访问** |
| Q | 48KB | **分布式 RAM（LUTRAM）** 12,288×32b | NPU 独立 64b 读；CPU 不可访问 |
| A | 96KB | BRAM，128b 读 + 128b 写 | CPU 窗口（读/写）|
| B | 32KB | 同上 | CPU 窗口（读/写）|

- CPU 窗口只映射 A（offset 0x60000）/B（0x78000），其余地址读 0/写忽略；
- 释放出的 12 块 BRAM 留给视频链路帧缓冲 / 320 档 tile 缓存（P3）。

## 4. nn_seq 状态机（P0 范围）

```
IDLE → LOAD_ROM → [for each entry]:
   CFG      : 取 ROM 项 → 填引擎 desc（或 add/copy 自执行）
   RUN      : 启动引擎 / 或 elementwise 处理，等 done
   NEXT     : 检查 csum（debug 模式）→ 下一条
→ DONE: 置 IRQ / STATUS
```
- CPU 只写 `JOB_START`（和可选输入帧长度），然后可睡眠/做别的事；
- debug 模式（`NN_DEBUG_CSUM=1`）保留逐 op checksum，用于 E2E 与 golden 对照；
- demo 模式关闭 checksum（省 ~10–20M 拍）。

## 5. 双模回归（必须）

| 模式 | 控制方式 | 用途 |
|---|---|---|
| **MODE_CPU（v0.5）** | CPU 逐 op 写 MMIO 描述符 + 轮询 | 现有 E2E 基准，保留 |
| **MODE_AUTO（v0.7）** | 写 1 次 JOB_START，nn_seq 自主 | 最终部署 |

同一 128 plan 两种模式各跑一遍，**逐 op checksum 必须完全相同**；这是 v0.7 的验收门槛。

## 6. P3（DDR3 中间激活）预留接口

- `nn_seq` 增加 `TENSOR_SRC` 字段（0=片上 A/B，1=DDR3），MIG 的 AXI 口通过一个
  **tile DMA**（行块搬运，双缓冲）接到 A/B；
- 128 档不启用（全片上）；320 档启用。
- 权重永不进 DDR3（D2）。
