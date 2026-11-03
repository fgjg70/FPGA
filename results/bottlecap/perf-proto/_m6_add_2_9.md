## 2.9 A7（dw 专用通路）· 设计 + 周期预期（待实施）

> 现状：融合路径（A4/A5/A5e）已交付；A7 这一步**尚未改 RTL**（保证树绿）。本节是可执行的实施设计 + 改写前后周期预期。
> 基线快照：`results/bottlecap/reports/tb_nn_engine_cycles_before_a7.csv`（58 case 逐 case 周期，改完逐行对比）。

### 2.9.1 为什么要做 / 收益量化（cycle_model 实测口径）

| 档 | dw op 数 | dw 合计拍 | 占全模型 | **A7a（A/2 + C/2）收益** | A7b（B 行缓冲 ×0.62）收益 |
|---|---:|---:|---:|---:|---:|
| 瓶盖模型（106 op） | 17 | 4,785,178 | 11.9% | **-1,049,629（-2.62%）** | -1,365,000（-3.41%） |
| YOLO（112 op） | 28 | 462,102 | 39.1% | **-100,638（-8.51%）** | -131,800（-11.1%） |

> A7a = dw 阵列 8→16 lane（`A` 减半）+ 16B/像素写回（`C` 减半）；A7b = dw 行缓冲复用（每输出行只装一次，`B` ≈ ×0.62）。
> YOLO dw 占比 39%，所以 A7 在 YOLO 上的相对收益远高于瓶盖模型（Lead 要求 A7 后同时报 YOLO 新 npu_cycles）。

### 2.9.2 RTL 改动清单（当前引擎行号为锚，实施时以符号名重定位）

| # | 位置 | 现状 | 改为 | 影响 |
|---|---|---|---|---|
| A7-1 | `S_CPREP`（`ocw_r` 赋值） | `ocw_r <= dense ? 16 : 8` | `ocw_r <= is_pool ? 8 : 16` | dw 用 16 lane tile |
| A7-2 | `S_CPREP`（`oc_limit_r`） | dw 分支 `oc8_r >> 3` | `(oc8_r + 15) >> 4` | dw tile 数 = ceil(oc8/16) |
| A7-3 | `S_BI`（dw 的 `band_base/la`） | `blk_base + (c_ocb << 3)` | `(c_ocb << 4)` | 每 tile 16 通道偏移 |
| A7-4 | P_init 的同类偏移（第二处） | `blk_base + (c_ocb << 3)` | `(c_ocb << 4)` | 同上 |
| A7-5 | MAC `a_pipe` 装载 | dw：`(oc<8) ? win_sel[px][oc*8+:8] : 0` | dw 也取 `win_sel[px][oc*8+:8]` | lane 8..15 参与 MAC |
| A7-6 | MAC `wby_r` 装载 | `(dense || oc<8) ? ... : 0` | 同上放开 | 权重 lane 8..15 |
| A7-7 | 写回模式门控 | `wr_dense16 = dense && act_l==16`；`single16 = dense && ...` | 改为 `act_l==16 && ...`（含 dw） | dw 16B/像素单拍写回（C 减半） |
| A7-8 | Q 偏移推进（`q_bias_w/q_mpos_w`） | 已按 `ocw_r>>1 / >>2` 推进 | 无需改（确认即可） | 每 tile 的 Q 布局一致 |
| A7-9 | padding lane 饱和 | 现有 requant 屏蔽（`oc_base_w + l >= d_oc → zp_out`） | 确认 dw 路径也生效 | dw oc8%16≠0 时尾部 lane 必须写 zp_out |
| A7-10 | 行缓冲复用（A7b） | 每个 kx 重装 band | 行内保留 16B/px，按 ky 复用 | B ≈ ×0.62；只影响 dw |
| A7-11 | TB | 无 dw+16lane case | 新增 2 个：`sa_dw16_ic16`、`sa_dw16_ic72`（16B/像素写 + 尾部 lane padding） | 位精确 + 周期 |

### 2.9.3 周期口径与对账（Lead 红线）

- **数据位精确不变**：58 case `mismatch=0` + YOLO `hw_bad=0/auto_bad=0` 是硬门槛。
- **周期允许下降**，但：
  1. 报告给逐 case before/after 表（基线 CSV 已存）；
  2. `tb_nn_engine` 的期望周期用 cycle_model 公式重算后更新 —— 建议在 TB 里加轻量**周期断言**（`expected = cycles_of(desc)` 与 DUT 输出的 `cycles` 比较，误差 0），这样后续回归能抓非预期周期变化；
  3. YOLO E2E 记录新 `npu_cycles` 并给对账：预期 `new ≈ 1,191,020 − 100,638 ≈ 1,090,000`（A7a）；A7b 再减 ~131,800。
- **对 p1 目标的再基线（重要）**：Lead 采纳的 `p1 = 32,719,099` 里 dwpath 收益按"B,C,D ×0.38"算（2.89M）。按可实施口径：
  - A7a 只做 16 lane：**-1.05M** ⇒ p1 ≈ **34.56M**（3.54fps@122）
  - A7a+A7b：**-2.42M** ⇒ p1 ≈ **33.20M（3.68fps@122）**
  - 与 32.72M/3.74fps 的差 = 模型里 dwpath 把 `D` 也 ×0.38（实际 D 是控制/收尾拍，16 lane 后变化很小）。
  ⇒ 建议：**把 p1 权威值重新基线为 33.20M（A7a+A7b）**，或保留 32.72M 但把差值记进"剩余差距"。

### 2.9.4 实施顺序（下一步）

1. A7-1..A7-7 + A7-9（16 lane 数据通路）→ 跑 58 case + YOLO，出 before/after 周期表；
2. A7-10（行缓冲复用）→ 再跑一遍，更新 `cycle_model` 的 dwpath 分支为"实测口径"（A/2、C/2、B×实测系数），重算 p1/p2b；
3. TB 周期断言（A7-11 的一部分）→ 让回归能自动抓周期漂移。

---

