# M6 E2E 交接 — 2M 融合版 101 op（fused_a）vs 未融合基线 106 op

> 对象：rtl-stream（M6 E2E）/ Lead。作者：converter（task-18）。日期：2026-11-04。
> 融合语义权威：`results/bottlecap/reports/M6-FUSION-CONTRACT.md`；映射明细：本目录 `FUSION-MAP.json`。

## 1. 一句话

融合版 = 106 op 基线删掉 5 个 A 类 residual_relu add（op67/73/79/85/94 融进各自 host conv），**数值逐字节一致**（独立 golden 101 op×3 图 mismatch=0；500 图精度与基线逐项相同）。E2E 可用它跑"融合版"周期/流量，与未融合版对比。

## 2. M6 E2E 需要的文件（全部在 `results/bottlecap/plan/fused_a/`）

| 文件 | 内容 / 用途 |
|---|---|
| `plan.json` | 101 op；每 op 含 `fused_add`(融合时: r/k/zp_s/zp_d/relu)、`tile_zp_in`、`tile_mode`（op0=`whole`，其余 `band`）；`final_ops=[93,97,100]`、`final_tensors=[77,81,84]` |
| `checksums.txt` | **pattern_v1(seed=12345) 输入的逐 op FNV**（op id = 融合后 0..100）+ input FNV + head FNV |
| `opvec/` | 101 op × {`pattern_v1`, 真实图 `0349`}：逐 op int8 张量（arena 布局、u32-LE/行）+ 各自 `checksums.txt`（input + 101 op）+ `manifest.json`/`index.json`（shape/bytes/pad_value/arena_off/fnv） |
| `band_plan.json` | 101 op 的整通道 band 划分（band_rows/n_bands/in_rows/in_row_bytes/out_row_bytes/band_in_base(arena_off)/pad_top/buf_config；17 个 dwconv 大通道层标 32KB IBUF） |
| `w.hex` / `q.hex` | W=2,020,960 B（不变）/ Q=**90,288 B**（比基线少 5×16 B add Q 块）；32-bit LE 字/行；nn_mem 用分开的 `+nnw/+nnq`（勿用合并 `+nnwq`） |
| `nn_rom_pkg_bottlecap_fused_a.sv` + `nn_rom_table_bottlecap_fused_a.json` | Lead 的 `nn_gen_rom.py` 已吃本 plan 生成：**101 项 ≤128**，`sum_wlen=2,020,960`、`sum_qlen=90,288`；conv/dwconv `aux0 = zp_in 符号扩展`（-128→0xFF80）；`tile[7:4]=band_rows-1`、`tile[3]=add_mode(融合)`、`tile[1]=band_en`，op0(whole)→`tile=0`；5 个融合 conv `flags=0xC0`(ADD_R|RELU) |
| `FUSION-MAP.json` | 5 条映射 {add_op, host_conv_op, 形状, R/KADD/zp_d/relu, 残差 tid, 省掉张量} |
| `FUSION-REPORT.md` | 语义/精度/周期/复现全记录 |

## 3. op 序号口径（关键，别混用）

- **融合版** op id `0..100`（101 个）；**未融合基线** op id `0..105`。E2E 逐 op 判据必须与所用 plan 的 `checksums.txt`/`opvec` **同源**：
  - 跑融合版 → 用 `fused_a/checksums.txt`（pattern）或 `fused_a/opvec/0349/checksums.txt`（真实图）；
  - 跑未融合版 → 用 `plan/checksums.txt` / `plan/opvec/0349/checksums.txt`。
- 融合版 id 与基线 id 的映射规则：按基线 op 顺序遍历，**跳过 add_op ∈ {67,73,79,85,94}**，其余依次重新编号 0..100（`FUSION-MAP.json.mappings` 给出每个被删 add → host conv 的对应关系）。**不要**拿基线 id 直接索引融合版。
- M6b 首批 op0..11 在两个版本里**语义相同**（融合都在 op≥66 之后），只有 `tile_zp_in/tile_mode/tile` 字段不同；M6b 现有金标仍可直接用基线版，若切融合版只需按上述规则重取 op 序号（前 12 op 的 id 不变）。

## 4. 融合 conv 的硬件行为（E2E 判据提示）

- 5 个融合 conv 的 `dst` = 残差张量（host conv 原输出张量已死、不生成）；执行时**先读 dst 原值（残差）再写回**，Q 块 tail `byte4=zp_d`、`byte5=KADD`、`byte6..7=R(u16 LE)`（旧 106-op plan 这 4B 恒 0）。
- 数值：`q_s = clamp(requant(conv))` → `p = ((q_s-zp_out)*R)>>KADD`（floor）→ `out = clamp(q_d+p)` → `RELU 时 out=max(out,zp_d)`（本类 zp_d=-128，恒等）。与"conv→int8→add→relu"两段式**逐字节相同**。
- 输入加载与检查口径同未融合版：PACKED3 224×224×3（可用 `opvec/0349/input.hex` 6,912? 注意 2M 是 u32-LE 150,528 B 原样写 A 区 offset 0；pattern_v1 公式 `q=(x*13+y*7+c*29+seed)&0xFF`, seed=12345）。

## 5. 预期数字（v3 公式 / cycle_model 对账，ddr3-feas 2026-11-04 终版）

| 阶段（按 RTL 落地） | 融合版 101 op | 未融合 106 op | 差异 |
|---|---:|---:|---:|
| **当前 RTL（只有 A4/A5e 融合；cycle_model `--scenario p1_rtl`）** | **39,783,123（两侧 0 差 ✓）** | 40,051,198 | **−268,075（−0.67%）** |
| +A7a（dw 16 lane，≈−1.05M） | ≈38,733,123 | — | 引擎未实现 |
| +A8+A7b（bopt + dw 行缓冲；`--scenario p1`） | **33,924,318**（cycle_model 终值；我们分项推算 33,924,135，Δ183 拍 = dwpath 取整 0.0005%） | — | 引擎未实现 |
| +PX16（`--scenario p2b`） | **21,450,724 拍 = 5.70 fps@122.22MHz**（4.66/6.99 @100/150MHz） | — | Step B 未实现 |
| 其中融合代价 | +60,515（13 拍/块 × 4,655 块） | — | 契约 B.4 |
| 每帧激活流量 | **35.338 MB** | 36.389 MB | −1.051 MB（−2.9%） |

**对账建议**：
- **现在跑 M6 E2E 请按 39,783,123（±2%）**（`cycle_model --plan fused_a/plan.json --scenario p1_rtl` 与我们的 v3 公式**逐拍 0 差**）；
- 不要用 32.72M/32.69M（旧口径前提 = "20 add 全融 + 旧 dwpath 模型"）；融合只省 268k，PX16 阶段融合代价按块数放大，**Step B（全特性+PX16）终值 = 21,450,724（5.70fps@122）**，此前"≈20.9M/5.85fps"已作废；
- 每落地一项对一次：融合→39.78M；+A7a→38.73M；+A8+A7b→33.92M；+PX16→21.45M。融合 op 识别：`plan.json: ops[].fused_add`（cycle_model 已按此读，无需额外格式）；
- 全场景明细见 `results/bottlecap/reports/m6_cycle_compare_fused_a.json`（p0/p1_rtl/p1/p2b）。

## 6. 已知限制

- B 类 12 shortcut / C 类 3 fpn_sum / 3 concat copy **未融**（引擎 q_d 仅能从 dst 读；B 需"src 读残差"扩展；C 需重编码+重标定；copy 需多 src），等 M6 绿 + PX16 后另立任务。
- 未融合基线目录 `results/bottlecap/plan/` 仍为 **106 op**，本轮只加了 `tile_zp_in`/`tile_mode` 字段（无语义变化）；M6 对比请保持"两个目录各自一套 op 序号"。
