# M4 激活 tiling：`nn_tilecache` 分带流式模块 + TB

> 作者：`rtl-stream`（task-9）。日期：2026-11-03（Asia/Shanghai）。状态：**M4 模块 + 单元 TB 完成**（5/5 case PASS，假引擎验证；真引擎对接未做，改动清单见 §7）。
> 里程碑：`PLAN-V1.md` M4 = "激活 tiling：`nn_tilecache.sv`（IBUF/OBUF ping-pong + DMA fill/flush + band 描述符）"。
> 定位：本文是 **M4 的接口契约 + 验证证据 + 与真引擎/ROM 的对接方案**。
> 纪律：只新增 `nn_tilecache.sv`、`sim/tb_nn_tilecache.sv`、本报告；**未修改任何既有 RTL/ROM**。

---

## 0. 结论摘要

| # | 事项 | 结论 | 证据 |
|---|---|---|---|
| 1 | `nn_tilecache` 模块 | 完成：IBUF 2×16KiB + OBUF 2×12KiB（56KiB）、band 描述符寄存器组、DMA fill（DDR→IBUF，逐行 burst，pad 行物化 zp_in）、DMA flush（OBUF→DDR，逐行 burst）、`band_start→band_ready→engine_done→band_done` 握手；引擎 a/b 口位宽/语义与 `nn_mem` 一致（地址=tile 相对） | `nn_tilecache.sv`；§2 |
| 2 | 整张量 == 分带 | **96×96×8 张量 3×3/s1/pad1 conv，整张量 golden == 6 band 分带结果，逐字节 0 mismatch** | case_a；`logs/tb_nn_tilecache.log` |
| 3 | halo/stride/pad | k3s1 halo（重叠 2 行）由 case_a 覆盖；**k3s2 奇偶对齐**（band 起点为奇行）由 case_b 覆盖；上下/左右 pad 用 `zp_in` 由 case_c（zp=-128 极端值）覆盖 | case_b/c |
| 4 | ADD 的 2R1W | **IBUF 双银行解决**：dst band 填进 bank1、src 在 bank0，引擎 `a_sel=0/1` 分别读；16×16×8 ADD 逐字节一致 | case_e；§2.4 |
| 5 | fill 带宽受限不死锁 | `BEAT_GAP=16`（DDR 1 beat/16 拍）下 8×8×8 band 仍正常 fill→run→flush；所有等待都有 watchdog | case_d |
| 6 | TB 结果 | **5/5 PASS，errors=0**，`TILECACHE_TB: PASS` | `logs/tb_nn_tilecache.log` |
| 7 | BRAM 预算 | **56 KiB = 14 tiles**（按 nn_mem 的 4KB/BRAM 口径；P3 的 4.5KB 口径 = 12.4 tiles）。瓶盖模式释放 A/B 32 tiles 后：W 80 + Q 4 + tile 14 + core 12 = **110/135** ✓ | §4 |
| 8 | band 循环驱动（Lead 问） | **推荐 `nn_seq` 每 band 发一次引擎 start**；ROM 存"每 op 的 tile 描述符"，band 循环在 `nn_seq` 内。理由：瓶盖模型 106 op 共 **1,062 band**（max 28/op），若 ROM 每 band 一项会远超 ROM 深度 128；且逐 op 一项与现有 ROM v1 结构一致 | §8 |
| 9 | 真引擎对接 | **未做**（任务允许"若编译代价可接受"）：假引擎已逐位验证 tile 逻辑；真引擎需要 **1 个新描述符字段 + 2 处边界/地址小改**（§7 给出行号级清单），属 M5 引擎任务 | §7 |
| 10 | 与 converter `tile_plan` 的关系 | converter 已产每 op `tile_plan`（band_rows=4、max 28 bands、max IB 8,064B / OB 7,168B，全部 fits）；本模块 v1 支持"整通道 band"（IC/OC 整块），其 **IC/OC tiling 需要描述符扩展**（§7.3） | `results/bottlecap/plan/plan.json` |

---

## 1. 交付物

| 文件 | 说明 |
|---|---|
| `nn_tilecache.sv` | 新模块（IBUF/OBUF + DMA fill/flush + band 描述符 + 引擎 a/b 口） |
| `sim/tb_nn_tilecache.sv` | 新 TB（假引擎 + beh_ddr3；5 个 case；pass marker `TILECACHE_TB: PASS`） |
| `results/bottlecap/reports/logs/tb_nn_tilecache.log` | TB 运行日志（末行 `TILECACHE_TB: PASS`） |
| 本报告 | 接口契约 / BRAM/描述符/验证/对接方案 |

---

## 2. `nn_tilecache` 接口契约（v1）

### 2.1 顶层端口

```
module nn_tilecache #(
  parameter int unsigned IB_BYTES = 16*1024,   // IBUF 每银行
  parameter int unsigned OB_BYTES = 12*1024    // OBUF 每银行
)(
  input  logic         clk, rst,
  // ---- band 描述符（band_start 时锁存，clk 域）----
  input  logic [31:0]  d_in_base,        // 第一条 DDR 读行的字节地址（16B 对齐）
  input  logic [15:0]  d_in_rows,        // IBUF 内总行数（含 pad 行）
  input  logic [15:0]  d_in_row_bytes,   // 每行字节数（16 的倍数）
  input  logic [15:0]  d_in_stride,      // DDR 行间字节跨距（16 的倍数）
  input  logic [15:0]  d_in_pad_top,     // 带首用 d_zp_in 填的行数
  input  logic [15:0]  d_in_rd_rows,     // 从 DDR 读的行数（pad_top 之后）
  input  logic [7:0]   d_zp_in,          // 输入 zero-point 字节（pad 行填充值；pool=max 时引擎自处理）
  input  logic         d_add_mode,       // 1 = 额外填 aux(dst) band（ADD 用）
  input  logic [31:0]  d_aux_base,       // aux band 第一条 DDR 读行地址
  input  logic [15:0]  d_aux_stride, d_aux_pad_top, d_aux_rd_rows,
  input  logic [31:0]  d_out_base,       // 输出 band 第一行 DDR 地址
  input  logic [15:0]  d_out_rows,       // 输出 band 行数
  input  logic [15:0]  d_out_row_bytes,  // 输出每行字节数（16 的倍数）
  input  logic [15:0]  d_out_stride,     // 输出 DDR 行跨距
  // ---- band 握手 ----
  input  logic         band_start,       // 1 拍脉冲；busy=0 时接收
  output logic         band_ready,       // fill 完成，引擎可运行（保持到 engine_done）
  input  logic         engine_done,      // 1 拍脉冲：引擎写完 OBUF
  output logic         band_done,        // 1 拍脉冲：flush 完成（或描述符错误）
  output logic         busy,             // 从 band_start 到 band_done
  output logic [7:0]   err_code,         // 描述符错误（0=OK；E0 对齐/E1 容量/E2 pad 定义）
  output logic [1:0]   cur_bank,         // {out_bank, in_bank}（调试）
  output logic [31:0]  fill_beats, flush_beats,   // 每 band DMA beat 计数（调试）
  // ---- DDR 读（fill）：直连 beh_ddr3 / MIG ----
  output logic         dd_rd_re; output logic [31:0] dd_rd_addr; output logic [15:0] dd_rd_len;
  input  logic         dd_rd_ready; input logic [127:0] dd_rd_data; input logic dd_rd_valid;
  input  logic         dd_rd_last;  output logic dd_rd_rready;
  // ---- DDR 写（flush）：直连 beh_ddr3 / MIG ----
  output logic         dd_wr_re; output logic [31:0] dd_wr_addr; output logic [15:0] dd_wr_len;
  input  logic         dd_wr_ready; output logic [127:0] dd_wr_data; output logic dd_wr_valid;
  input  logic         dd_wr_rready; input logic dd_wr_done;
  // ---- 引擎激活读口（nn_mem a_* 语义，tile 相对地址）----
  input  logic [1:0]   a_sel; input logic a_re; input logic [23:0] a_addr;
  output logic [127:0] a_rdata,
  // ---- 引擎激活写口（nn_mem b_* 语义，tile 相对地址）----
  input  logic [1:0]   b_sel; input logic b_we; input logic [23:0] b_addr;
  input  logic [127:0] b_wdata; input logic [15:0] b_wstrb
);
```

### 2.2 引擎侧端口语义（与 `nn_mem` 逐位一致）

- `a_*`：`a_addr[23:4]` = IBUF 银行内 128b 字索引（tile 相对、16B 对齐）；**读时延 1 拍**（地址第 N 拍、`a_rdata` 第 N+1 拍有效，与 `nn_mem` 相同）。
  `a_sel[0]`：0 = 当前 band 的 src 银行（`in_bank`），1 = aux 银行（ADD 的 dst band）。`a_sel[1]` 忽略。
- `b_*`：`b_addr[23:4]` = OBUF 银行内 128b 字索引；`b_wstrb[15:0]` 字节使能逐字节生效（copy/半字写需要）；`b_sel` 忽略（OBUF 只有"当前 band 写银行"）。
- 引擎端口位宽/时序与现 `nn_conv_engine.sv` 头部一致，**引擎端口不动**。

### 2.3 band 握手时序

```
band_start ──┐
             ▼
          [T_FILL_REQ/T_FILL_RD/T_FILL_PAD]  逐行 DMA fill（src，add_mode 时再 aux）
             ▼
          band_ready ─────────────► 引擎运行（读 a_* / 写 b_*）
             ▼
          engine_done ──┐
                        ▼
                     [T_FLUSH_REQ/T_FLUSH_WR] 逐行 DMA flush（OBUF→DDR）
                        ▼
                     band_done（1 拍）→ busy=0
```
- v1 为**顺序带处理**（fill→engine→flush），`band_start` 仅在 `busy=0` 时接收；跨带 fill/engine 重叠留给 M5（模块已具备双银行结构，扩展点见 §9）。
- 任一等待都有超时 watchdog（TB 侧），fill/flush 不完整不会静默通过。

### 2.4 ADD 的 2R1W 解决（P3 §4.5）

ADD 要同时读 src band 和 dst band，而 nn_mem 的 A/B 阵列是 1R+1W。`nn_tilecache` 用 **IBUF 双银行**：`band_start` 时先填 src→`in_bank`，再填 dst→`aux_bank`（`d_add_mode=1` + aux 描述符）；引擎用 `a_sel=0` 读 src、`a_sel=1` 读 dst，OBUF 只写输出 → 每块 BRAM 保持 1R1W，**不复制 BRAM**。converter 的 `tile_plan` 里 20 个 add op 正是 `"ch-tile(8) + 2 operands"` 模式，与设计一致。

---

## 3. band 描述符与 halo/stride/pad 数学

### 3.1 描述符字段（也建议作为 ROM v1 的 tile 字段）

| 字段 | 位宽 | 含义 |
|---|---:|---|
| `n_bands` | 5~6 | 该 op 的 band 数（瓶盖 max 28/op → 5 bit 够，留 6 bit） |
| `band_rows` | 3~4 | 每 band 输出行数（瓶盖固定 4；YOLO-like 可到 16+，留 5 bit 稳） |
| `in_row_bytes` | 12 | 输入行字节数 = `iw * pad8(ic)`（瓶盖 max 1,792） |
| `out_row_bytes` | 12 | 输出行字节数 = `ow * pad8(oc)`（瓶盖 max 1,792） |
| `in_rows`/`pad_top`/`rd_rows` | 由 `nn_seq` 逐 band **算**，不存 ROM | 公式见 3.2 |
| `in_ddr_base`/`out_ddr_base` | 22 | op 的 arena 基址（plan 的 `src_arena_off/dst_arena_off`） |
| `add_mode`/`aux_*` | 1 + 复用 | ADD 的第二个操作数（dst band） |

> 上述 ROM 字段建议与 `results/bottlecap/plan/plan.json` 的 `tile_plan` 一一对应（converter 已产出 `band_rows/n_bands/in_row_bytes/out_row_bytes/ibuf_bytes/obuf_bytes/fits`），Lead 可直接据此定 ROM-v1 tile 字段语义。

### 3.2 逐 band 描述符计算（`nn_seq` 内，纯组合+计数器）

对第 `b` 个 band（输出行 `out_row0 = b*band_rows`），输入跨距 `st`、卷积核 `k`、pad `pad`：

```
band_in_row0 = out_row0*st - pad        // band 缓冲区第 0 行对应的绝对输入行
in_rows      = (band_rows_eff-1)*st + k // 本带有用的输入行数（含 halo）
abs_start    = band_in_row0
abs_end      = band_in_row0 + in_rows
rd_start     = max(abs_start, 0)
rd_stop      = min(abs_end, ih)
rd_rows      = rd_stop - rd_start
pad_top      = rd_start - abs_start
pad_bot      = in_rows - pad_top - rd_rows
in_ddr_base  = src_base + rd_start*in_row_bytes
in_stride    = in_row_bytes
out_ddr_base = dst_base + out_row0*out_row_bytes
```
- **halo**：`k−st` 行重叠自动由 `in_rows = (B−1)*st + k` 与 `band_in_row0 = out_row0*st − pad` 给出（k3s1 重叠 2 行；k3s2 起点为奇行）。case_a/case_b 分别覆盖。
- **上下 pad**：`pad_top/pad_bot` 行由 fill DMA 写 `d_zp_in`（竖直 pad 物化）；**左右 pad** 不需要 fill 处理——引擎自带 x 越界判定（`nn_conv_engine.sv:339-340/1079-1080`），越界读自动替换为 `zp_in`。
- 引擎每个 band 的描符：`ih = in_rows`、`iw = iw`、`src = 0`、`dst = 0`、其余不变 → 引擎算出的 `oh = band_rows_eff`，地址即 tile 相对（**但引擎需要 §7.2 的 band 原点字段，否则 y 越界判定会错**）。

### 3.3 容量公式与 96×96×8 实例

约束（模块内也检查，违反 → `err_code`）：
- `in_rows * in_row_bytes ≤ IB_BYTES`（16,384）
- `out_rows * out_row_bytes ≤ OB_BYTES`（12,288）
- `row_bytes`、`stride` 均为 16 的倍数（16B = 1 个 DMA beat）

96×96×8 3×3 conv（IC=OC=8）实例：

| 量 | 值 | 说明 |
|---|---:|---|
| 行字节 | 96×8 = **768 B** | IB/OB 相同 |
| 每带输出行（受 OB 限制） | **16** | 12,288/768 = 16（OB 打满）；IB 侧 18×768 = 13,824 ≤ 16,384 ✓ |
| 每带输入行 | 18 | (16−1)×1+3 = 18（halo 2 行） |
| band 数 | **6** | 96/16 |
| IBUF 占用 | 13,824 / 16,384 B（84%） | OBUF 12,288 / 12,288 B（100%） |
| DDR 读放大 | 106/96 = **1.104×** | halo 行重复读（case_a 实测一致） |

> 注意：任务描述里的"每带 24 行、4 带"在 **56KiB 预算下不成立**：24 行输出 → OBUF 24×768 = 18,432 > 12,288；IBUF 26×768 = 19,968 > 16,384。本 TB 因此用 **16 行×6 带**完成"整张量==分带"判据（band 大小可自由调，判据等价）。若坚持 24 行带，需 IBUF 2×20KiB + OBUF 2×18KiB（=76KB，19 tiles），超出 Lead 定的 56KB 预算。

---

## 4. BRAM 预算

| 缓冲 | 尺寸 | BRAM（4KB/BRAM 口径） | BRAM（36Kb/4.5KB 口径，P3 使用） |
|---|---:|---:|---:|
| IBUF | 2 × 16,384 B = 32 KiB | 8 tiles | 7.1 tiles |
| OBUF | 2 × 12,288 B = 24 KiB | 6 tiles | 5.3 tiles |
| **合计** | **56 KiB** | **14 tiles** | **12.4 tiles** |

瓶盖模式整机账（相对现交付档）：W 双银行 80 tiles（不变）+ Q 影子 4 tiles（从现 Q 8 里划）+ **tile cache 14** + 核心 12 = **110 / 135**，余 25 tiles ✓。
（现交付档 132/135 是"W 320KB ROM + A96+B32"；瓶盖模式 A/B 32 tiles 被 tile cache 取代，因此净减 18 tiles。）

---

## 5. TB 用例与结果

`sim/tb_nn_tilecache.sv`，pass marker `TILECACHE_TB: PASS`，日志见 §1。

| case | 内容 | 判据 | 结果 |
|---|---|---|---|
| a | **96×96×8，3×3/s1/pad1**，整张量 golden vs **6 band（每带 16 输出行/18 输入行）**；输入随机 int8，zp_in=−7 | 每带 flush 回 DDR 的输出逐字节 == 整张量 golden（73,728 B） | **PASS** |
| b | **3×3/s2/pad1**（96×96×8 → 48×48×8），6 band×8 行，输入带原点为奇行（halo 奇偶） | 逐字节 == golden（18,432 B） | **PASS** |
| c | **8×8×8 3×3/s1/pad1 单 band**，zp_in=−128（极端值，上下左右 pad 全触发） | 逐字节 == golden（512 B） | **PASS** |
| e | **ADD**：16×16×8，src band 填 bank0、dst band 填 bank1，假 ADD 引擎 `a_sel=0/1` 分别读、饱和相加写 OBUF；2 band | 逐字节 == golden（2,048 B） | **PASS** |
| d | **fill 带宽受限**：第二实例 `BEAT_GAP=16`（DDR 1 beat/16 拍），8×8×8 conv band | fill/ready/flush/done 全流程在 watchdog 内完成（fill 40 beats/755 拍，flush 32 beats/49 拍），`err_code=0` | **PASS** |

汇总：**5/5 PASS，errors=0**；两个实例均打印 `[nn_tilecache] CONFIG IB=16384 B/bank x2, OB=12288 B/bank x2, total=57344 B`。

> 假引擎的算术是"3×3 加权窗口和 → >>5 → int8 饱和"，golden 与分带路径用**同一函数**，因此逐字节相等严格证明了 tilecache 的 fill/flush/地址/halo/pad/双银行逻辑；它不模仿真引擎的 requant 数值。

---

## 6. 与 P3 设计的差异与取舍

| P3 设计 | 本实现 | 理由 |
|---|---|---|
| IBUF 2×16KB + OBUF 2×12KB（12.4 tiles） | 一致（56KB） | Lead 指定预算 |
| IBUF 双银行 ping-pong（fill 下一带 / 引擎读当前带） | **顺序带处理**；双银行用于 src+ADD-dst | v1 先保证正确性；顺序处理下 A/B 银行不冲突。跨带重叠的扩展点见 §9 |
| 方案 A：独立模块、nn_mem 零改动、引擎端口不动 | 一致 | — |
| ADD 的 dst 读走 IBUF（避免 2R1W） | 一致（bank1） | case_e 验证 |
| halo 按行区间重复读 | 一致（`band_in_row0`/`in_rows` 计算） | case_a/b 验证 |
| stride/pad 越界行填 zp_in | 竖直 pad 由 fill 物化；水平 pad 靠引擎 in-bounds 逻辑 | case_c 验证 |
| IC/OC channel tiling（P3 §4.3） | **v1 不支持**（只做整通道 band） | 见 §7.3；描述符可扩展 |
| packed3 conv0 流式 | 不支持（v1） | 沿用 P3：后续 fmt 标志 |

---

## 7. 真引擎对接状态与所需改动

### 7.1 状态

**未对接**（任务允许："若编译代价可接受"）。理由：真引擎需要一个 band 原点语义（见 7.2，约 1 字段 + 2 处小改），属于 M5 引擎任务；本 M4 判据已由假引擎逐位完成。真引擎的 a/b 端口形状在本模块上可直接接（位宽/时序一致）。

### 7.2 真引擎所需的最小改动（M5 清单，行号基于当前 `nn_conv_engine.sv`）

1. **新增描述符字段 `band_in_row0`**（如 16 bit，`nn_desc_t`/`nn_rom_t` 各加一个字段；ROM v1 一并加）。
2. `y_ky0`/`y_ld` 计算：`y_ky0 = band_in_row0 + oy*st - pad`（现 `nn_conv_engine.sv:315-316`）。
3. **y 越界判定的上界改为全张量 `ih`**（现用 `d_ih`，见 `:339`、`:1047-1048`、`:1147`、`:1276` 等）；band 模式下 `d_ih` 传 band 的 `in_rows`、bounds 用全图 `ih` 和 `band_in_row0` 组合。
4. 引擎描述符按 band 配置：`ih = in_rows`（引擎自动算 `oh = band_rows`）、`src=0`、`dst=0`、`woff/qoff` 不变。
5. 地址 base：`a_addr`/`b_addr` 天然变成 tile 相对（`nn_mem` 窗口偏移被 `src=0` 取代），`nn_subsys` 在 tile 模式把引擎 a/b 口 mux 到 tilecache（`nn_mem` 零改动）。

> 若不想改引擎，替代方案是 tilecache 内做地址/边界转换（把 band 原点加回 y 并对 tile 地址加 pad 偏移）——但需要引擎把 y 越界信息透出，成本更高；**推荐改引擎**（P3 §4.4 也写了"行有效标志位"需引擎配合）。

### 7.3 IC/OC channel tiling（gap，需 Lead 决定）

converter 的 `tile_plan` 当前用 IC/OC tiling：`n_ic_tiles` 最大 **108**、`n_oc_tiles` 最大 **54**，全模型 **118,046** 次"band×IC×OC"引擎运行（106 op 共 1,062 band）。本模块 v1 只支持整通道 band。若采用 IC/OC tiling：
- 描述符需扩展 `in_ch_off/in_nch`（fill 按 8/16 通道切片做**跨行 stride 读取**）与 `out_ch_off/out_nch`（flush 按通道段写回）；
- 每次引擎运行对应一个 (band, ic_tile, oc_tile)，`band_ready/engine_done/band_done` 握手不变（只是次数增加）；
- 118,046 次运行 × 每次握手/命令开销需要 M5 评估（若 ~50 拍/次 ≈ 5.9M 拍 ≈ 15% 帧时——建议 M5 重新评估 tile_plan 的 IC/OC tiling 粒度）。

---

## 8. "band 循环由谁驱动"——决策：`nn_seq` 每 band 发一次引擎 start

**选择：ROM 每 op 一项（含 tile 描述符），`nn_seq` 内部循环 band，每个 band 发一次 `band_start` + 一次引擎 `start`，等 `band_done` 后进入下一 band。**

| 方案 | ROM 深度 | 优点 | 缺点 |
|---|---|---|---|
| A. `nn_seq` 每 band 发一次引擎 start（**选它**） | 106 项（现 ROM v1 够） | ROM 不膨胀；与现有"一条 op 一项"结构一致；band 循环状态机在 `nn_seq` 内（几行计数器）；tile 描述符可复用 | `nn_seq` 需要 band 循环/多周期 op 状态 |
| B. tilecache 内部循环 band | 106 项 | `nn_seq` 简单 | tilecache 要自己算 halo/描述符/输出行号，把调度逻辑塞进数据通路；且仍需每 band 与引擎握手，没有省 |
| C. ROM 每 band 一项 | **1,062 项** ≫ 128 | 无 | **ROM 深度不可能** |

给 ROM v1 的 tile 字段建议（每 op）：`n_bands[5:0]`、`band_rows[4:0]`、`in_row_bytes[11:0]`、`out_row_bytes[11:0]`、`add_mode/aux 描述` + 复用现有 `src/dst` 作 arena 基址；`in_rows/pad_top/rd_rows/in_ddr_base` 由 `nn_seq` 按 §3.2 公式逐 band 算出（**不占 ROM**）。

---

## 9. 已知限制与未做项

1. **顺序带处理**：v1 fill→engine→flush 串行，无跨带 fill 重叠。扩展点：把 `T_READY` 中的 `band_start` 也接收（填另一银行 + 第二个描述符槽），flush 与 fill 已用独立 DDR 读写通道可并行 —— M5 视缺口再定。
2. **真引擎未接**（§7.2 清单）。
3. **IC/OC tiling 不支持**（§7.3）；**packed3 conv0 不支持**。
4. 行字节/跨距必须 16B 倍数（16B = 1 DMA beat）；plan 的 `in_row_bytes/out_row_bytes` 均为 8 的倍数，需 M5 确认全部 16B 对齐（瓶盖 max 1,792 是 16 的倍数 ✓）。
5. 每行一条 DDR burst（band 内行连续时可合并为整带 burst 以减少 latency 开销，v1 未做；瓶盖 band 行跨距=行字节时可优化）。
6. OBUF 写口按字节使能实现（RTL 用逐字节写；综合上 BRAM 的字节写使能足够，或 4×32b 拆分）。
7. TB 假引擎不模仿真引擎 requant 数值（只验证数据通路/几何）。

---

## 10. 复现命令

```bat
set LM_LICENSE_FILE=D:/software/tools/Modelsim/win64/LICENSE.TXT
set MGLS_LICENSE_FILE=D:/software/tools/Modelsim/win64/LICENSE.TXT
set PROCESSOR_ARCHITECTURE=AMD64
set MSIM=D:/software/tools/Modelsim/win64

%MSIM%\vlib.exe work
%MSIM%\vlog.exe -sv nn_tilecache.sv sim\beh_ddr3.sv sim\tb_nn_tilecache.sv
%MSIM%\vsim.exe -c -do "run -all; quit -f" work.tb_nn_tilecache
```
通过判据：输出 `SUMMARY: 5/5 cases pass, errors=0` 且最后 `TILECACHE_TB: PASS`。

---

## 11. 证据索引

| 证据 | 内容 |
|---|---|
| `results/bottlecap/reports/logs/tb_nn_tilecache.log` | 5/5 PASS、每 case 结果、慢速 fill/flush 拍数、`TILECACHE_TB: PASS` |
| `nn_tilecache.sv` | 端口/描述符/握手/BRAM 预算注释（头部） |
| `results/bottlecap/plan/plan.json` → `ops[].tile_plan` | 每 op band 计划：band_rows=4、max 28 bands、max IB 8,064B/OB 7,168B、106 op 共 1,062 band、20 个 add 为 "2 operands" |
| `results/ai-accel/P3-DDR3-TILECACHE.md §4` | 方案 A、缓冲预算、halo/stride/pad、ADD 2R1W、DMA 口契约来源 |
| `nn_conv_engine.sv:339-340,1079-1080` | 引擎 in-bounds/zp_in 替换逻辑（水平 pad 不需要 tilecache 处理）|
| `nn_conv_engine.sv:315-316,1047-1048,1147,1276` | `y_ky0` 计算与 y bounds（§7.2 改动点） |
| `results/bottlecap/reports/M3-WSTREAM.md §2.2` | `beh_ddr3` 接口（本 TB 复用） |

---

## 附录 A：ROM-v1 `tile` 字段语义定稿（8-bit，可直接写进 `nn_pkg.sv` 注释）

> Lead 裁决（2026-11-03）：tiling 口径 = **M4 v1「整通道 band」**；否决 converter 的 IC/OC tiling（118,046 次引擎运行 ≈5.9M 拍/帧 ≈15%，量级不可接受）。引擎本身已有 IC block/OC lane 循环，tilecache 不再切。大层用自适应 `band_rows`（例：112×112×64→96 用 B=1：in 7,168 B / out 10,752 B ≤ 16K/12K ✓）。

### A.1 字段表（`nn_rom_t.tile[7:0]` / `nn_desc_t.tile[7:0]`，8 bit）

| bit | 名称 | 语义 |
|---|---|---|
| `[7:4]` | `band_rows_code` | `band_rows = band_rows_code + 1`，即 1..16 行/band（0→1 行，15→16 行）。`n_bands = ceil(oh / band_rows)` **由 nn_seq 运行时算，不存 ROM** |
| `[3]` | `add_mode` | 1 = 该 op 是 ADD/ADD_R：tilecache 同时填 src band（IBUF bank0）与 dst band（IBUF bank1），引擎用 `a_sel=0/1` 分别读（M4 case_e 已验证） |
| `[2]` | `packed3_stream` | 1 = 输入是 PACKED3（仅 conv0）；fill 行字节 = `(iw+2*pad)*3`，引擎带 `NN_F_PACKED3`。**M6b 未覆盖（op0 除外，见报告）** |
| `[1]` | `band_en` | 1 = band 模式使能（**Lead 2026-11-04 修订**：band 模式判定用 `rom.tile[1]`，**不再依赖 `tile[7:4]!=0`**——否则 B=1 会编码成 0 与 whole/直通撞车；B=1 -> 0x02, B=2 -> 0x12, B=6 -> 0x52, whole -> 0x00） |
| `[0]` | `rsvd` | 保留（0） |

**不需新增的字段**（全部由现有描述符 + tile 推导）：
> **[M6c 现状（task-17）]** `nn_seq` 已按本附录实现 band 循环: `tile[1]=band_en`,
> `n_bands=ceil(oh/band_rows)`, 逐 band 发 `band_start`/引擎 start/等 `band_done`;
> 预取与 W/Q bank 翻转见 `results/bottlecap/reports/M6C-NNSEQ-BAND.md`。
> 与本文的一个差异: M6c 路径 A 的 `in_row_bytes=(iw+2*pad)*ic_pad`（水平 pad 物化），
> 而 `band_plan.json` 的容量口径是 `iw*ic_pad`（不含水平 pad），两者在 n_bands/
> in_rows/pad_top/in_base/out_base 上一致（upsample 的偶数 B 例外，见报告）。

- `in_rows / pad_top / rd_rows / in_base / out_base / band_in_row0`：nn_seq 按 A.2 公式逐 band 算；
- `in_row_bytes = (iw + 2*pad) * ic_pad`（水平 pad 物化后的 tile 行字节；见 A.3）；`out_row_bytes = ow * oc_pad`；
- `wlen/qlen`：由 kind/flags/oc/ic/k 公式算（M3 §4.4 已定）；W/Q 地址用 M3 流式镜像的运行指针 `w_ptr/q_ptr`；
- `band_rows` 与 converter `tile_plan.band_rows` 对应（bottlecap 当前统一 B=4，可保持；大层按容量自适应到 B=1/2）。

### A.2 nn_seq 伪代码（逐 op × 逐 band，约 20 行）

```text
# 流式指针（M3 流式镜像，两者都从 0 开始）
w_ptr = 0; q_ptr = 0
for op i in 0 .. n_ops-1:
  w_len = wlen_of(op_i); q_len = qlen_of(op_i)
  wait pre_done                                   # 上一层权重/Q 已就位（双缓冲）
  br_rows = tile_i.band_rows                       # 1..16
  n_bands = ceil(op_i.oh / br_rows)
  for b in 0 .. n_bands-1:
     out_r0   = b*br_rows
     br       = min(br_rows, op_i.oh - out_r0)     # 末带可能更小
     band_row0 = out_r0*op_i.st - op_i.pad         # band 缓冲区第 0 行对应的绝对输入行
     in_rows  = (br-1)*op_i.st + op_i.k
     abs0 = band_row0; abs1 = band_row0 + in_rows
     rd0  = max(abs0, 0); rd1 = min(abs1, op_i.ih)
     tile.in_base      = op_i.src_arena + rd0*op_i.iw*ic_pad
     tile.in_core_row  = op_i.iw*ic_pad            # DDR 侧行字节
     tile.in_pad_lr    = op_i.pad*ic_pad           # 左右各补多少字节 zp_in
     tile.in_rows      = in_rows
     tile.in_pad_top   = rd0 - abs0
     tile.in_rd_rows   = rd1 - rd0
     tile.in_row_bytes = (op_i.iw + 2*op_i.pad)*ic_pad
     tile.out_base     = op_i.dst_arena + out_r0*op_i.ow*oc_pad
     tile.out_rows     = br
     tile.out_row_bytes= op_i.ow*oc_pad
     tile.add_mode     = (op_i.kind == add)
     tile.aux_base     = op_i.src_arena(ADD 的 dst 同形) + rd0*op_i.iw*ic_pad
     tile_start(); wait band_ready                 # DMA fill src(+aux)
     engine_desc = {op, flags, ks, st, pad=0,       # 水平/竖直 pad 都在 tile 内物化
                    ih=in_rows, iw=op_i.iw+2*op_i.pad,
                    ic, oc, src=0, dst=0, woff=0, qoff=0,
                    band_in_row0 = 0}               # 路径 A 不需要该字段（见附录 B）
     engine_start(); wait engine_done
     wait band_done                                 # DMA flush OBUF -> DDR
  w_ptr += w_len; q_ptr += q_len                   # 下一层预取
  pre_start(W_DDR_BASE+w_ptr, w_len, Q_DDR_BASE+q_ptr, q_len, bank=~w_bank_sel)
```

### A.3 两条实现路径（关键：M4 v1 之后发现"零引擎改动"路径）

| | 路径 A（**M6b 优先验证**） | 路径 B（原 §7.2，备选） |
|---|---|---|
| 水平 pad | **tilecache fill 把左右 pad 列物化进 IBUF 行**（`in_row_bytes=(iw+2pad)·ic_pad`；pad 列填 `zp_in`） | 不物化，靠引擎 x 越界判定 |
| 垂直 pad | tilecache fill 物化 pad 行（M4 已实现） | 同 |
| 引擎描述符 | `pad=0`、`iw=iw+2*pad`、`ih=in_rows`（band 行数）、`src=dst=0` | `pad=pad`、`ih=in_rows`、`src=dst=0`、**+`band_in_row0` 字段** |
| 引擎改动 | **无**（现有 `nn_conv_engine` 直接可用） | +1 字段 `band_in_row0`；`y_ky0` 加原点；y 越界上界改全图 `ih`（§7.2 清单） |
| 约束 | IBUF 行字节 +2·pad·ic_pad（k3pad1 → +16B/行，可忽略）；行字节需 16B 对齐（iw 偶数即满足） | 无 pad 物化开销 |
| 验证状态 | M6b（task-15）正在验证 | 若 A 失败再用 |
| 结论 | **推荐**：引擎 owner 的改动可降到"零"（只剩 nn_subsys 的 a/b mux） | 保留为 fallback |

> 附录 B 的引擎交接一页按"路径 B 改动清单 + 路径 A 的验证结论占位"书写；M6b 结论出来后只需删掉路径 B 或标注"不需要"。

---

### 附录 A 修订（Lead 2026-11-04）：`tile[1]=band_en`

`tile[7:4]=band_rows-1` 在 `band_rows=1` 时会编码成 0，与"不做 tiling"撞车；而 converter 的 plan 里 **band_rows=1 有 30 个 op**。**修订后语义**：`[7:4]=band_rows-1`、`[3]=add_mode`、`[2]=packed3_stream`、**`[1]=band_en`**、`[0]` 保留；**band 模式判定 = `tile[1]==1`**（不再用 band_rows 是否为 0 判定）。已在 `nn_pkg` 注释与 `nn_gen_rom.py` 落地，瓶盖 ROM 已重生成并校验（op1=0x02、op3=0x12、op4=0x52、op0(whole)=0x00）。本附录其余字段说明不变。

## 附录 B：给引擎 owner 的一页交接（task-14 用）

**背景**：瓶盖模型激活放不下片上 A/B（峰值 1.2MB），M4 的 `nn_tilecache` 按"输出行带"把激活从 DDR3 流进 IBUF、引擎算完写 OBUF、再 flush 回 DDR3。引擎**端口不动**（`a_*/b_*` 位宽/时序与现在一致，地址改为 tile 相对）。每 band 一次 `engine start`（`nn_seq` 驱动，见附录 A.2）。

**引擎 owner 当前可选的两条路（优先 A）**：

### 路径 A（零改动，M6b 验证中）
- tilecache 物化竖直+水平 pad（行字节 `(iw+2·pad)·ic_pad`），引擎描述符改为 `pad=0、iw=iw+2·pad、ih=band 行数、src=dst=0`。
- 引擎现有逻辑即可正确工作：`x_ld/y_ky0`（`nn_conv_engine.sv:315-316`）落在 tile 相对坐标；`oh/ow` 由 `ih/iw/pad/k/st` 自动算对；`b_addr` 写 tile 相对地址。
- **对引擎的要求：无改动**。只需确认：
  1. tile 模式下 `desc.pad=0` 时 `pad_eff`=0、`ow/oh` 公式仍正确；
  2. `b_addr` 计算对 `d_ow` 的依赖正确（输出行跨距 = `ow*oc8`，与描述符一致）；
  3. W/Q 用流式层内相对地址（`woff=qoff=0`，`nn_mem w_mode=1`）。

### 路径 B（fallback，若 A 的某层数值不对）
最小改动（行号基于当前 `nn_conv_engine.sv`）：
1. `nn_desc_t`/`nn_rom_t` 新增 `band_in_row0`（16 bit；ROM v1 一并加）。
2. `y_ky0 = $signed(band_in_row0) + oy*st - pad`（`:315-316`），`y_ld` 初值同源（`:1047`、`:1276`）。
3. y 越界判定改用**全图 `ih`**：现 `y_ok_r = (y_ky0 >= 0) && (y_ky0 < $signed(d_ih))`（`:339`、`:1047-1048`、`:1147`、`:1276`）→ 改为 `abs_y = band_in_row0 + oy*st - pad`，判定 `0 <= abs_y < ih_full`；band 模式下 `ih_full` 用描述符的全图 ih（可新增字段或复用）。
4. 其他（W/Q/输出地址/requant/ADD/RELU）不动；`desc.pad` 保持原值。

### 接口约束（两条路都一样，别改）
- 端口列表、位宽、读时延（W 2 拍、a 1 拍、q 1 拍）、`b_wstrb` 字节使能语义**不变**；
- 不依赖 tile cache 内部状态，只按描述符计算；
- `PACKED3 tile 模式` 暂不支持（M6b 不覆盖），保留现有 PACKED3 行带路径。
- 交付判据（引擎侧）：现有 `tb_nn_engine` 46+4 case 逐位不回退（Lead 已有门槛）；tile 模式的数值正确性由 M6b 的 `tb_bottlecap_ddr_chain` 判。

**M6b 结论占位**：路径 A 若 PASS → 本页只剩"确认 3 条 + 不改逻辑"；若 FAIL 且定位在引擎地址/边界 → 按路径 B 执行。M6b 完成后我会把结论直接回填到这里并同步 Lead。

---

## 附录 C：缓冲配置裁决 —— 瓶盖配置 IBUF 2×32KiB（Lead 2026-11-03 拍板）

### C.1 背景

converter 的 `tile_plan` v2（整通道 band）显示：**17 个 dwconv 大通道层即使 `band_rows=1` 也超 16 KiB IBUF**（需 21,504 ~ 32,256 B；最大者 op10 = 112×112×96 dwconv，`in_row_bytes=10,752` × 3 行 = **32,256 B**）。若维持 16 KiB IBUF，这 17 层只能回退 IC-block tiling（引擎侧再做一次通道切分，与"整通道 band"裁决冲突）。

### C.2 裁决（已实现）

| 配置 | IBUF | OBUF | 用途 |
|---|---|---|---|
| 默认（M4 TB / 小模型） | 2 × 16 KiB | 2 × 12 KiB | `nn_tilecache` 参数默认值，M4 TB 主实例 |
| **瓶盖配置（采用）** | **2 × 32 KiB** | 2 × 12 KiB | 覆盖全部 106 op（`band_plan.json`：`ibuf_tiers["32768"].n_fits = 106`，`n_overflow=0`） |

- `nn_tilecache.sv` 的 `IB_BYTES/OB_BYTES` 本来就是参数（v1 起），**本次只改 TB 实例参数与新增验证 case，RTL 接口零变化**；M4 TB 主实例仍保持 16 KiB/12 KiB 默认（不回退 5 项原判据）。
- band 划分随 IBUF 32 KiB 变为：`band_plan.json` 共 **2,391 band**，`band_rows` 分布 1:30 / 2:33 / 3:7 / 4:6 / 6:10 / 9:7 / 12:9 / 16:4；**30 个 op 用 B=1**（含上述 17 个）。

### C.3 BRAM 账（4 KiB/BRAM 口径，与 nn_mem 一致）

| 项 | tiles |
|---|---:|
| W 双银行（80 KiB×2 = 160 KiB ×2） | 80 |
| Q 影子银行 2×8 KiB | 4 |
| **IBUF 2×32 KiB = 64 KiB** | **16** |
| **OBUF 2×12 KiB = 24 KiB** | **6** |
| tile cache 合计 | **22** |
| 核心（实测口径） | 12 |
| **整机** | **80+4+22+12 = 118 / 135 ✓**（余 17 tiles） |

对照：若用 16 KiB IBUF 则 tile cache 14 tiles、整机 110/135，但 17 个 dwconv 层需要 IC-block 回退（引擎二次切分）——Lead 裁决选 32 KiB IBUF/22 tiles，换取"引擎零改动 + 不用 IC-block"。

### C.4 新增验证（`sim/tb_nn_tilecache.sv`，现 **7/7 PASS**）

| case | 内容 | 结果 |
|---|---|---|
| f | `band_rows=1` 数值正确性：8×8×8 conv3×3/s1/pad1 拆成 **8 个单行 band**（每带 3 输入行），逐 band 与整张量 golden 逐字节一致 | **PASS** |
| g | **32 KiB IBUF 配置**容量证据：112×112×96 dwconv 形状、B=1 band（`in_rows=3 × 10,752 B = 32,256 B ≤ 32,768`），在第二实例（IBUF 32 KiB / BEAT_GAP=16）上 fill→(engine_done)→flush：`fill_beats=2016`（3×672）、`flush_beats=672`（1×672）、`err_code=0`、`busy` 正常撤销 | **PASS** |

回归：`python tools/fpga_workflow.py verify --force --only tb_nn_tilecache tb_nn_wstream` → **PASS 2**（M4 主配置 5 项原判据 + 新增 f/g 共 7/7 无回退；M3 wstream 6/7 项无回退）。
