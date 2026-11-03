# P2（256 MAC）增量修订说明 · 给 rtl-mem / rtl-stream

> 作者：`ddr3-feas`（task-12 item 4）。日期：2026-11-03。**只是修订说明，不改 RTL**。
> 前提：rtl-mem/rtl-stream 当前正在按 `WEIGHT-STREAMING-DESIGN.md` 落地 **2 银行 × 160KiB**。
> 本文**不推翻**这个实现，只列出"若 P2 选 256 MAC 时需要加什么"，并回答"参数化能否零返工"。
> 数字权威：`tools/bottlecap/cycle_model.py`（`--self-check` = 39,891,262 拍）。

---

## 0. 结论摘要

| 问题 | 回答 |
|---|---|
| nn_mem 现在把 bank 数参数化了吗？ | **是（存储维度）**：`nn_pkg.sv:52` `NN_W_BANKS=2`，`nn_mem.sv:179-184` 全部派生（`W_BANK_BYTES/W_BANK_W64/W_BANK_AW`）；改 4 银行只动 1 个常量 + Q 同理 |
| 那 P2 能零返工吗？ | **存储维度能，端口维度不能**：OC32 需要 **W 读 32B/拍**（现 16B/拍），而 `nn_mem` 的 W 读口是 `w_rdata[127:0]` 单宽口 + 2 读口(cur/next) 结构 —— **端口必须加宽** |
| 有没有更省返工的路？ | **有：P2 改选 PX16（16 OC lane × 16 px = 256 MAC）**。它 **W 读仍 16B/拍**（不动 rtl-mem/rtl-stream 的 2 银行实现），只需把 **A 侧 tilecache 读口做成 32B/拍**（新模块，绿field）。且 PX16 的周期还略优：**20.34M 拍 vs OC32 20.43M 拍** |
| 现在就要加的一处参数（零成本） | 在 `nn_mem` 里把 W 读数据宽度参数化为 `W_RD_BITS = 128 * NN_W_BANKS / 2`（2 银行→128b，4 银行→256b），读 mux 用 generate 展开 ⇒ 将来 P2 若选 OC32 只改常量+布局，**读 mux 不用重写** |
| 若选 OC32，权重布局要改 | 同一 (tap,ic) 的 32 OC 字节拆成 **OC 低半 16B → bank A、OC 高半 16B → bank B**（工具链 `gen_weights_image.py` 负责），活动层横跨两个 bank 组 |

---

## 1. 现状（rtl-mem/rtl-stream 已落地部分）

| 项 | 现状 | 证据 |
|---|---|---|
| W bank 常量 | `NN_W_BANKS = 2`、`NN_W_BANK_BYTES = 160KiB`、`NN_W_BANK_W64 = 20,480`、`NN_W_BANK_AW = 18` | `nn_pkg.sv:52-55` |
| Q 影子银行 | `NN_Q_BANK_BYTES = 8KiB`、`NN_Q_BANK_W64 = 1,024` | `nn_pkg.sv:58-59` |
| nn_mem 派生 | `W_BANKS/W_BANK_BYTES/W_BANK_W64/W_BANK_AW/Q_BANK_*` 全部由 pkg 常量派生 | `nn_mem.sv:179-184` |
| W 填充口 | `wfill_we/wfill_addr[?]/wfill_wdata[63:0]`，写**非活动**银行 | `nn_mem.sv:135-141` |
| 引擎 w 读口 | `w_re/w_addr[23:0]/w_rdata[127:0]`，8B 对齐 16B 窗口（2 个 64b 读口 cur/next） | `CONTRACT.md §9.1`；`mem-report.md §3.8` |

**结论**：存储侧（bank 数/容量/地址宽度/Q 影子银行）**已经参数化到位**；缺口在"一次读多少字节"。

---

## 2. P2 两种 256-MAC 变体的需求差异

| 需求 | **OC32**（32 lane × 8 px） | **PX16**（16 lane × 16 px） |
|---|---|---|
| W 读带宽 | **32 B/拍**（32 OC × 1 tap × 1 IC） | **16 B/拍（不变）** |
| A（激活）读带宽 | 16 B/拍（不变） | **32 B/拍**（16 px × 8 IC = 128B / 4 拍） |
| W 侧改动 | `w_rdata` 128→256b、2 银行同时读、fill 目标为"银行组" | **无**（沿用 2×160KiB + 128b） |
| A 侧改动 | 无（tilecache 沿用 16B/拍） | tilecache 读口 128→256b（**新模块，绿field**） |
| acc/FF | 8 px × 32 lane × 32b = **8K FF** | 16 px × 16 lane × 32b = **8K FF**（同） |
| a_pipe | 8×16 = 128B（不变） | 16×16 = 256B（+1K FF） |
| MAC 阵列 | 256 乘（160 DSP + 96 LUT，见 `NPU-PERF-OOC.md`） | 同 |
| **周期（实测模型）** | **20,425,757 拍** = 4.90/5.98/7.34 fps | **20,343,387 拍** = 4.92/6.01/7.37 fps |
| 需改的既有文件 | `nn_mem` + `nn_pkg` + 引擎 + 工具链布局 | **仅 tilecache（新）+ 引擎** |

> **推荐：P2 选 PX16**（周期略优 + 对 rtl-mem/rtl-stream 的 2×160KiB 实现零返工 + A 侧是新建模块）。
> OC32 保留为"若 A 侧 32B/拍 做不出来"的备选。两者周期差 **0.4%**，不值得为 OC32 去返工 W 读口。

---

## 3. 增量修订清单

### 3.1 若选 PX16（推荐，改动最小）

| # | 文件 | 改动 | 规模 |
|---|---|---|---|
| X1 | `nn_pkg.sv` | 新增常量 `NN_MAC_LANES = 16`（OC lane 不变）、`NN_PX_LANES = 16`；`nn_rom_t`/`nn_desc_t` 无需改（px 由硬件固定） | S（2 行） |
| X2 | 新 `nn_tilecache.sv` | IBUF 读口 **256 bit（32B/拍）**：把 IBUF 组织成两个 128b 宽阵列并行读；OBUF 写口保持 128b | M（新模块内） |
| X3 | `nn_conv_engine.sv` | `PX_LANES` 已是 parameter（`:41` `parameter int PX_LANES = 8`）；把 acc/a_pipe 数组按 PX=16 展开、MAC 阵列 256、requant 16 lane（PX16 的 requant 拍数 +8/块） | L |
| X4 | `sim/tb_nn_mem.sv` | **无改动**（W/Q 端口/时延/银行语义完全不变） | 0 |
| X5 | `sim/tb_nn_wstream.sv` | 新增 IBUF/OBUF 256b 读的 case | S |
| X6 | `tools/bottlecap/gen_weights_image.py` | **无改动**（布局仍按 16 OC 一行） | 0 |

### 3.2 若选 OC32（备选）

| # | 文件 | 改动 | 规模 |
|---|---|---|---|
| Y1 | `nn_pkg.sv:52` | `NN_W_BANKS: 2 → 4`（`NN_W_BANK_BYTES` 自动变 80KiB、`NN_W_BANK_W64` 10,240、`NN_W_BANK_AW` 17） | **1 行** |
| Y2 | `nn_pkg.sv` 新增 | `NN_W_RD_BITS = 128 * NN_W_BANKS / 2`（2 银行→128，4 银行→256） | 1 行 |
| Y3 | `nn_mem.sv` W 读逻辑 | `w_rdata[NN_W_RD_BITS-1:0]`；活动**银行组**（`w_bank_sel` 1 bit → 组选择 1 bit，组内 2 bank 同时读）；cur/next 两读口 × 2 bank = 4 个 64b 读口（generate 按 `NN_W_BANKS` 展开） | M（~40 行，建议现在就参数化，见 §4） |
| Y4 | `nn_mem.sv` fill 口 | `wfill_bank` 由 1 bit 变"银行组"选择；一次 fill 仍写单 bank（工具链把 OC 低/高半分开写两 bank） | S |
| Y5 | `nn_conv_engine.sv` | `w_rdata` 256b；`wby_r[0:32]` 由 256b 装载（32 OC × 8b） | M |
| Y6 | `nn_subsys.sv` | 多一个 `NN_WBANK`（组选择）暴露位 | S |
| Y7 | 工具链 | 权重镜像按 **OC 低半/高半分 bank** 排布（同一层 → bank A 存 OC 0..15 的 16B、bank B 存 OC 16..31 的 16B）；`gen_weights_image.py` 改 | M |
| Y8 | `sim/tb_nn_mem.sv` | W 读口 256b 的宽度/对齐/越界 case；银行组切换 case | M |
| Y9 | `sim/tb_nn_wstream.sv` | fill 到"银行组"的 case | S |

**容量校验（OC32，4×80KiB）**：最大层 124,416 B + 单层 Q 5,200 B = **129,616 B ≤ 2×81,920 = 163,840 B ✓**（活动组 2 bank）；
若某层权重 > 163,840 B 则必须改回 2 银行（本模型最大 124,416，安全）。

---

## 4. 零返工：现在就该加的一处参数（成本 0，收益大）

**建议 rtl-mem 立即做（不影响他们正在写的 2×160KiB 功能）**：

```systemverilog
// nn_pkg.sv
localparam int unsigned NN_W_BANKS   = 2;                       // 现状
localparam int unsigned NN_W_RD_BITS = 128 * NN_W_BANKS / 2;    // 2 banks -> 128b; 4 banks -> 256b

// nn_mem.sv W 读口
output logic [nn_pkg::NN_W_RD_BITS-1:0] w_rdata;
// 读 mux 用 generate 按 NN_W_BANKS/2 展开（现在展开 1 份，将来 2 份）
```

- 对当前 **2 银行**：`NN_W_RD_BITS=128`，展开 1 份 ⇒ **综合结果与现在完全相同**（可用现有 OOC DCP 的 RAMB36=120 / WNS 复核）。
- 对将来 **OC32**：只改 `NN_W_BANKS=4` + 工具链布局 + 引擎 w_rdata 加宽，**nn_mem 的读 mux 不用重写**。
- 对将来 **PX16**：`NN_W_BANKS` 保持 2，参数不变 ⇒ 同样零返工。

**不做这处参数的代价**：P2 选 OC32 时要重写 `nn_mem.sv` 的 W 读 mux 与 cur/next 生成（~40 行），并且要重跑 `tb_nn_mem` 全量 47,148 checks 回归。

---

## 5. 断言清单（建议现在就写进 `nn_mem`/TB，与 bank 数解耦）

| # | 断言 | 说明 |
|---|---|---|
| A1 | `NN_W_BANKS % 2 == 0` | 读口按"银行对"组织 |
| A2 | `NN_W_BANK_BYTES * NN_W_BANKS == NN_W_BYTES` | 容量闭合（现 160KiB×2=320KiB） |
| A3 | `NN_Q_BANK_BYTES >= 5200`（本模型单层 Q 最大 5,200 = 6×864+16） | Q 影子银行够 |
| A4 | 填充地址越界 → 忽略并置 err（写 `~/w_bank_sel` 的银行内偏移 < `NN_W_BANK_BYTES`） | 防串 bank |
| A5 | 活动银行切换（`w_bank_sel` 翻转）那一拍不得有 `wfill_we` 指向同一银行组 | 防读写碰撞 |
| A6 | 若 `NN_W_RD_BITS=256`：`w_addr[23:0]` 的低 4 位语义仍是 8B 对齐窗口（16B），高半/低半由布局保证 | 防对齐回归 |

---

## 6. TB 影响

| TB | OC32 影响 | PX16 影响 |
|---|---|---|
| `tb_nn_mem`（47,148 checks） | W 读口宽度/银行组切换新增 ~2 组 case；原有 case 语义不变（`w_rdata[127:0]` 是低半） | **无影响** |
| `tb_nn_wstream`（新） | fill 目标组 + 组切换 | IBUF 256b 读 |
| `tb_nn_engine`（47+4 case） | w_rdata 加宽后 case 向量需扩到 32 OC | PX16 case 向量扩到 16 px |
| `tb_sw_nn_bottlecap` | 全模型位精确（权重布局变了，但数值应恒等） | 同 |

---

## 7. 给 rtl-mem / rtl-stream 的 3 条具体 action

1. **现在**：加 `NN_W_RD_BITS` 参数 + generate 展开 W 读 mux（§4）；**不改** 2×160KiB 的功能。
2. **现在**：把断言 A1~A6 写进 `nn_mem` 的 `initial`/`assert` 段与 TB（与 bank 数解耦）。
3. **P2 定案后**：若选 PX16 → 只动 tilecache 读口（§3.1 X2）；若选 OC32 → 按 §3.2 改常量+端口+布局（§4 的参数让读 mux 免重写）。

---

## 8. 与 P2 帧率数字的衔接（修订上一轮报告的乐观值）

`cycle_model.py --scenario all` 的实测模型值（**取代** `NPU-PERF-UPGRADE.md` 上一版的估算）：

| 场景 | 拍数 | effMAC | @100 | @122.22 | @150 | 上一版估算（已作废） |
|---|---:|---:|---:|---:|---:|---|
| p0 现状 | 39,891,262 | 57.0 | 2.51 | 3.06 | 3.76 | 同 |
| p1 融合+LB+dw | 32,514,547 | 69.9 | 3.08 | 3.76 | 4.61 | 3.14/3.84/4.71 |
| **p2b PX16** | **20,343,387** | 111.7 | 4.92 | **6.01** | 7.37 | 5.80/7.09/8.70 |
| **p2 OC32** | **20,425,757** | 111.2 | 4.90 | **5.98** | 7.34 | 6.44/7.87/9.66 |
| p3narrow（OC32+WG） | 15,595,437 | 145.7 | 6.41 | **7.84** | 9.62 | 8.66/10.59/12.99 |

> **为什么下调**：上一版把 OC 加宽当成"A/B 各减半"，但 **OC tile padding** 让 72/88/144 通道层的实际 tile 数只从 5→3（0.6×）而不是 0.5×；REQ/写拍也按物理字节重算。
> 影响：**"P2@122 = 7.87fps" 应修正为 ≈6.0fps**；要回到 ≥8fps 需要 P3（Winograd）或 150MHz。详见 `NPU-PERF-UPGRADE.md` 的修订附录。
