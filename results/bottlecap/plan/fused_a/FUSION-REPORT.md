# FUSION-REPORT — 2M 模型 add→conv 融合计划（P1a-1：A 类 5 个，106→101 op）

> 生成者：converter（task-18）。日期：2026-11-04。
> 语义唯一来源：`results/bottlecap/reports/M6-FUSION-CONTRACT.md`（ddr3-feas，按已落地引擎 A4/A5e RTL 写死）。
> 未融合基线（M6 E2E 用，**未改动语义**）：`results/bottlecap/plan/`（106 op）。
> 本目录：`results/bottlecap/plan/fused_a/`。

---

## 0. 结论摘要

| 项 | 融合 A 类（本目录） | 未融合基线 `plan/` |
|---|---:|---:|
| op 数 | **101**（106 − 5 add） | 106 |
| 融合 add 数 | **5**（A 类 residual_relu：op67/73/79/85/94） | 0 |
| W 字节（§6 布局） | 2,020,960 B | 2,020,960 B（不变） |
| Q 字节 | **90,288 B**（融合后省 5×16 B add Q 块） | 90,368 B |
| ROM 深度 | **101 / 128** | 106 / 128 |
| 每帧激活流量 | **35.338 MB**（−1.051 MB, −2.9%） | 36.389 MB |
| npu_cycles（v3 公式 p0 口径） | **39,783,123 拍**（−268,075, −0.67%） | 40,051,198 拍 |
| 其中融合代价 | +60,515 拍（13 拍/输出块 × 4,655 块） | — |
| 字节级 golden（独立实现） | **mismatch=0**（101 op × 3 图） | mismatch=0 |
| 与未融合逐 op 输出 | **bit-exact：101/101 op，3 图 0 元素差异** | 基线 |
| int8 vs GT（500 图） | **P/R/F1 = 0.9960/0.9952/0.9956，mIoU 0.9242** | 完全相同 |
| float↔int8 框匹配率（IoU≥0.5） | **99.60%**（1244/1249），meanIoU 0.9295，类别混淆 5 | 完全相同 |
| 精度门槛（F1≥0.9950、匹配≥99.3%） | **PASS** | PASS |

**结论**：A 类 5 个 add 已按引擎 conv add-mode 语义**逐字节无损**融进 conv（工程上等价于"只省 op/流量，不改数值"），精度与未融合基线**完全一致**（因为 bit-exact），可立即作为"引擎融合通路 + 融合 golden"的闭环证据。B/C 类按 M6-FUSION-CONTRACT B.3 与实测 plan 操作数方向**不能 bit-exact**（见 §5），是否按 Lead 的"允许重标定"继续做需裁决。

**周期对比（本轮交付口径，ddr3-feas 复核）**：未融合 106-op p0（v3 公式）= 40,051,198 拍 → **融合 101-op p0 = 39,783,123 拍（−268,075 拍 = −0.67%）**；其中"省 5 个 add"贡献 −328,590，"融合写回代价" +60,515（13 拍/块 × 4,655 块，与契约 B.4 常数一致）。**当前 RTL 只有融合路径（A7/A8 未落地），M6 E2E 预期就是 39,783,123**；全特性（+A7a/A7b/A8）后的最终 p1 = **33,924,318**（ddr3-feas cycle_model 终值；我们分项推算 33,924,135，Δ183=dwpath 取整）；再加 PX16（Step B）**21,450,724 = 5.70fps@122**。旧口径 32.7M 的前提是"20 个 add 全部融合 + 旧 dwpath 模型"，本轮只融 A 类 5 个，**不能直接对账 32.7M**。

---

## 1. 融合映射（FUSION-MAP.json 是机器可读权威版）

| add op | host conv（被融进） | 模块 | 形状(ih,iw,ic,oc) | 残差张量(dst) | R | KADD | zp_s | zp_d | ReLU |
|---:|---:|---|---|---|---:|---:|---:|---:|---|
| 67 | 66 | `refine5.conv2.0+bn` | 7×7×72×72 | tid53（relu 域） | 54489 | 15 | -128 | -128 | 1 |
| 73 | 72 | `refine4.conv2.0+bn` | 14×14×72×72 | tid56 | 14445 | 15 | -128 | -128 | 1 |
| 79 | 78 | `refine3.conv2.0+bn` | 28×28×72×72 | tid60 | 26741 | 15 | -128 | -128 | 1 |
| 85 | 84 | `refine2.conv2.0+bn` | 56×56×72×72 | tid64 | 24605 | 15 | -128 | -128 | 1 |
| 94 | 93 | `multi_scale_fusion.1.conv2.0+bn` | 56×56×72×72 | tid71 | 42498 | 15 | -128 | -128 | 1 |

实现方式（与引擎 A4/A5e 完全对齐）：
- host conv 的 `dst` 改为 add 的 dst（= 残差 buffer），`flags |= NN_F_ADD_R(bit6)`（本类还有 `NN_F_RELU(bit7)`，但 zp_d=-128，`max(out,zp_d)` 对 int8 是恒等，故与未融合的"dst 域 relu 饱和"等价）；
- add 的 `R/KADD/zp_d` 写入该层 Q 块 **tail byte4..7**（byte4=zp_d, byte5=KADD, byte6..7=R u16 LE），Q 块长度不变 `6*OC_pad+16`；
- 被融 add 删除，其 src 张量（host conv 原输出）生命周期置空；下游读的仍是 add 的 dst 张量 → 数值链与原两段式逐字节一致。

## 2. 语义实现与 golden

golden 的融合写回严格按 `M6-FUSION-CONTRACT.md` B.2：
```
q_s = clamp(requant_conv(acc), -128, 127)          # 第 1 次饱和（原 conv 输出）
p   = ((q_s - zp_out) * R) >> KADD                 # 算术右移 floor，zp_s == zp_out
out = clamp(q_d + p, -128, 127)                    # 第 2 次饱和；q_d = dst 内存原值
if RELU: out = max(out, zp_d)                      # 饱和之后，按 int8 域 zp_d 夹
```
- 引擎侧独立实现：`tools/bottlecap/golden_npu.py:golden_forward`（字节 arena 读写，从 Q tail byte4..7 反解融合参数，**不依赖 gen 的中间结构**）；
- 参考实现：`tools/bottlecap/quant_npu.py:int8_forward` 新增 conv add-mode 分支；
- 两者对 101 op × 3 图 **mismatch=0**（见 `GOLDEN-REPORT.md` §2）。

## 3. 与未融合逐 op 对账（bit-exact 证明）

`check_fused_vs_unfused.py`（本目录，可直接跑）用同一批 3 张真实测试图（seed 固定）分别跑 106-op 基线与 101-op 融合 plan 的**独立字节前向**，按 `FUSION-MAP` 映射逐 op 比对：

```
img0: ops compared=101 cumulative mismatch=0
img1: ops compared=101 cumulative mismatch=0
img2: ops compared=101 cumulative mismatch=0
A-class fused vs unfused: mismatch_elems=0 max|diff|=0
```
即：融合后**每个 op 的输出张量（含 head）与未融合完全逐字节相同** → F1/匹配率/混淆数必然与基线一致（已由 500 图 E2E 复核）。

## 4. 精度（500 图 test，与基线逐项相同）

| 指标 | 融合 101 op | 未融合 106 op |
|---|---|---|
| float vs GT P/R/F1 | 1.0000 / 1.0000 / **1.0000**，mIoU 0.9696 | 同 |
| int8 vs GT P/R/F1 | 0.9960 / 0.9952 / **0.9956**，mIoU 0.9242 | 同 |
| int8 整图全对 / 目标数准确 | 0.9880 / 0.9980 | 同 |
| float↔int8 匹配率（IoU≥0.5） | **99.60%**（1244/1249），meanIoU 0.9295 | 同 |
| 类别混淆对数 / 数量一致图 / 全等图 | 5 / 499 / 494 | 同 |
| 平均分差 | 0.004 | 同 |

（原始数据：`e2e_metrics.json`；自动报告：`GOLDEN-REPORT.md`——其 §3 逐层表引用的是**未融合 quant_report** 的层号，仅供量化参考，E2E/golden 章节有效。）

**门槛判定**：F1 0.9956 ≥ 0.9950 ✓，框匹配 99.60% ≥ 99.3% ✓，PASS。

## 5. B/C 类为什么没融（与 ddr3-feas 已对齐）

引擎 fused conv 的 `q_d` 只能从 **dst 内存**读（RTL `S_ADRD` 基址 = `d_dst`），因此可融集合必须满足"**残差在 dst 张量里，被加的 conv 结果走 q_s**"：

| 类 | 数量 | plan 实际形态 | 可否 bit-exact | 结论 |
|---|---:|---|---|---|
| A residual_relu | 5 | add.src=conv2 输出，add.dst=残差 x | ✅ | **已融（本目录）** |
| B shortcut | 12 | add.src=block 输入 x（多消费者），add.dst=project conv 输出（线性域） | ❌ | 引擎只读 dst；要融需把 project conv.dst 改指 x 并**重标定 x 组量化域**（非 bit-exact）。ddr3-feas 建议等引擎扩展"从 desc.src 读残差"，本轮不融 |
| C fpn_sum | 3 | add.src=upsample 输出（单消费者），add.dst=lateral conv 输出 | ❌（当前编码） | 契约说"add.dst==conv.dst 时 bit-exact"，但该 buffer 在 conv 前并不含残差（残差在 src 侧）；真要融需 retarget lateral conv.dst := up 张量 + 重排 upsample + 扩 up 组量化域（非 bit-exact）。**待 Lead 裁决** |
| copy(concat) | 3 | 3 源跨张量段 | ❌ | 引擎一个 conv 只有一个 src 张量，当前 RTL 不支持；另立任务 |

因此本轮正确 op 数 = **101**（106 − 5），与 ddr3-feas 的"98 op = A+C"结论相比：C 类需先解决上述操作数/量化域问题；若 Lead 接受非 bit-exact + 精度门，可再做 P1a-2/3（预估再省 ~0.5M 拍，但需重标定 x/up 组的 scale 并重跑 500 图精度）。

## 6. tile_zp_in / tile_mode（M6c 输入约定）

- 每 op 均带 `tile_zp_in`（int8，= 该 op 输入张量 zero-point；conv0=0）与 `tile_mode`：**op0 = `whole`**，其余 100 op = `band`；
- `nn_rom_table.json` 每项同样带这两个字段，conv/dwconv 的 `aux0[7:0] = tile_zp_in & 0xFF`（与 Lead 的 `nn_gen_rom.py` 口径一致；最终以 Lead 生成的 `nn_rom_pkg_bottlecap.sv` 为准）；
- 融合 op 的 `tile_zp_in` 取的是 host conv 的输入张量 zp（融合不改 conv 输入）。

## 7. 周期对账（v3 公式 + ddr3-feas `cycle_model` 终版，2026-11-04）

| 场景（cycle_model 场景名） | 拍数 | 说明 |
|---|---:|---|
| 未融合 106 op（p0） | 40,051,198 | v3 p0；与契约 B.4 的 p0 一致 |
| **融合 101 op（当前 RTL = 只有 A4/A5e 融合；`--scenario p1_rtl`）** | **39,783,123** | =40,051,198−328,590（5 add 消除）+60,515（13 拍/块×4,655 块）；**与我们 v3 公式逐拍 0 差 ✓**（M6 E2E 当前预期） |
| +A7a（dw 16 lane，≈−1.05M） | ≈38,733,123 | 引擎尚未实现 |
| +A7b（dw 行缓冲 B×0.62，≈−1.37M） | ≈37,363,123 | 引擎尚未实现 |
| **全特性（融合+A7a+A7b+A8 bopt；`--scenario p1`）** | **33,924,318** | cycle_model 终值；我们分项推算 33,924,135，**Δ183 拍（dwpath 取整 0.0005%）** |
| **全特性 + PX16（`--scenario p2b`，Step B）** | **21,450,724 = 5.70 fps@122.22MHz** | 4.66/6.99 fps @100/150；PX16 未实现 |

**对账建议**：现在跑 M6 E2E 按 **39,783,123（±2%）**；每落地一项对一次：融合 39.78M → +A7a ≈38.73M → +A8+A7b 33.92M → +PX16 21.45M。旧口径 **32.72M/20.9M(5.85fps) 已作废**（前提是 20 add 全融 + 旧 dwpath 模型；融合只省 268k，PX16 下融合代价按块数放大）。融合 op 由 `plan.json: ops[].fused_add` 标记识别，`cycle_model` 已完成改造；全场景明细 `results/bottlecap/reports/m6_cycle_compare_fused_a.json`。

## 8. 复现

```powershell
# 1) 生成融合 plan(101 op) + FUSION-MAP
python tools/bottlecap/gen_npu_artifacts.py --fuse-add a `
  --outdir results/bottlecap/plan/fused_a --label fused_a
# 2) 独立字节 golden + 逐 op 金标(opvec, 101 op × pattern/真实图)
python tools/bottlecap/golden_npu.py --fuse-add a `
  --outdir results/bottlecap/plan/fused_a --golden-images 3 --opvec-all-ops `
  --export-opvec results/bottlecap/plan/fused_a/opvec --opvec-only
# 3) 500 图 E2E（约 5 分钟，含 float 基线 + W-only QDQ 上限）
python tools/bottlecap/golden_npu.py --fuse-add a `
  --outdir results/bottlecap/plan/fused_a --golden-images 3
# 4) 与未融合逐 op bit-exact 对账
python results/bottlecap/plan/fused_a/check_fused_vs_unfused.py
```

## 9. 本目录产物

`plan.json`（101 op，含 `fused_add`/`tile_zp_in`/`tile_mode`）、`model.json`、`nn_rom_table.json`（101 项，aux0=zp_in）、`w.hex`、`q.hex`、`checksums.txt`（pattern 输入逐 op FNV）、`band_plan.json`、`FUSION-MAP.json`、`opvec/`（101 op × pattern_v1/真实图 0349，含逐 op checksums）、`e2e_metrics.json`、`GOLDEN-REPORT.md`（自动生成）、**`nn_rom_pkg_bottlecap_fused_a.sv` + `nn_rom_table_bottlecap_fused_a.json`（Lead 的 nn_gen_rom.py 生成，已校验）**、**`E2E-HANDOFF-FUSED.md`**（M6 E2E 交接一页）、`FINAL.json`（产物 sha256）、本报告、`check_fused_vs_unfused.py`、`graph.json`/`quant_report.json`（量化基准，op 编号为未融合口径）。

**未改动**：`results/bottlecap/plan/` 未融合基线目录（除 Lead 要求的 `tile_zp_in`/`tile_mode` 字段外无语义变化）；slim 冻结产物未动。
