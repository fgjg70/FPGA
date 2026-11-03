# P1a 图级融合规格（add/copy → conv add-mode）· 交 converter 实施

> 作者：`ddr3-feas`（task-12 item 2）。日期：2026-11-03。**本文只是规格，不实现 RTL**。
> 判据基线：`tools/bottlecap/cycle_model.py`（`--self-check` 精确复现 **39,891,262 拍**）。
> 输入实况：`results/bottlecap/plan/plan.json`（106 op，converter 产出）。

---

## 0. 结论摘要

| 项 | 结论 |
|---|---|
| 可融合的 op | **20 个 add + 3 个 copy = 23 个硬件 op**，可全部融进相邻 conv，op 数 **106 → 83** |
| 融合语义 | 复用 `NN_F_ADD`（累加进 DST）的整数公式：`out = clamp(q_d + (((q_s - zp_s)*R) >> KADD))`，**位精确可保**（先 round 到 int8 再算 add，与现两段式逐位一致） |
| 硬约束（可融性 5 条） | ① src 只有 1 个消费者；② add 紧邻 src 的产出 op；③ dst 不 alias src；④ 输出量化参数（s_a_out/zp_out）链一致；⑤ relu/leaky 类 add 必须把激活放到 add **之后** |
| 周期收益 | 全部融合 **净省 ≈0.95M 拍（2.4%）**（毛省 1,138,033，扣融合代价 ~188k）；分阶段：P1a-1 0.45M / P1a-2 0.33M / P1a-3 0.19M / P1a-4 0.17M |
| 流量收益 | 省 **≈2.3 MB/帧**（45.31 → 43.0，-5.1%）：add 每次省 1 趟张量（src 读），copy 省 2 趟（写 concat + 读 concat） |
| 叠加 P1 全量 | `p1` 场景 39.89M → **32.51M 拍 = 3.08/3.76/4.61 fps @100/122/150MHz**（cycle_model.py 实测值） |
| 最大 RTL 风险 | conv 的 **DST 读**（累加源）需要与 MAC 争用 `a_*` 读口；本规格给出"REQ 阶段时分复用"方案（不新增端口） |
| 工作量 | 引擎 3 处 + 契约/工具链 4 处 + TB 2 处，约 **6~8 个文件/模块** |

---

## 1. plan 实况：20 个 add + 3 个 copy 的精确分类

> 数据源：`plan.json` 的 `ops[]`（`kind`/`module`/`ic`/`oh`/`ow`/`src`/`dst`/`flags`/`act`）。
> flags 编码（模型侧）：`8` = ADD_R（per-tensor 源 rescale）；`24` = ADD_R + leaky/relu 位。

| 类 | 数量 | op id | 形状 | flags/act | 生产者（要融进谁） |
|---|---:|---|---|---|---|
| **A. backbone shortcut**（IR 残差，无激活） | **12** | 4, 8, 15, 19, 26, 30, 34, 41, 48, 52, 59, 63 | 112²×16 / 56²×24 / 28²×48 / 14²×72 / 14²×88 / 7²×144 | flags=8, act=none | 各 IR block 的 **project 1×1 conv**（`backbone_stage*.block_*.2`） |
| **B. residual_relu**（ResidualConvBlock 的 `relu(x+conv2)`） | **5** | 67, 73, 79, 85, 94 | 7²×72 / 14²×72 / 28²×72 / 56²×72 / 56²×72 | flags=24, act=relu | 各 ResBlock 的 **conv2**（`refine5/4/3/2.conv2`、`multi_scale_fusion.1.conv2`） |
| **C. fpn_sum**（`lateral + up(p)`） | **3** | 70, 76, 82 | 14²×72 / 28²×72 / 56²×72 | flags=24, act=relu | **lateral conv**（`lateral4/3/2`），需把 upsample 调到 conv 之前 |
| **D. concat copy** | **3** | 88, 89, 90 | 56²，ic=72 → dst 的 ch 偏移 0/72/144 | flags=0 | 消费者 **`multi_scale_fusion.0.0`**（ic=216 的 1×1 conv） |
| 合计 | **23** | | | | |

> 交叉验证：12+5+3 = 20 add ✓；`copy` 3 个 dst 偏移相差 72 B（=72 通道 → 9 个 8ch 块）✓。

---

## 2. 可融性判定（5 条硬约束）

| # | 约束 | 由谁保证 | 违反后果 |
|---|---|---|---|
| **C1** | add 的 `src` 张量只有 1 个消费者（就是这个 add），且生产它是 conv/dw | converter 在 plan 阶段做生命周期检查（`tensors[].def_op/last_use`，`plan.json` 已有） | 融合后 src 不再写回，其他消费者读不到 |
| **C2** | add 是 src 产出 op 的**直接后继**（中间不能再有别的 op 改 dst） | converter 排序：A/B 类天然满足；C 类需重排（upsample 前置） | 数值顺序变化（非结合律安全） |
| **C3** | `dst` 不 alias `src`，且 dst 的旧值在 add 之前未被覆盖 | converter 分配器保证（arena 布局已有 `arena_off`） | 累加基准错 |
| **C4** | 输出量化链一致：conv 的 `s_a_out/zp_out` = add 的 `s_a_src/zp_src`；add 的 `dst` 用 `s_a_dst/zp_dst`；rescale 用 `R/KADD`（int16/int8） | 量化报告（`quant_report.json`）+ Q 块生成器 | 逐位不一致 |
| **C5** | 激活在 add **之后**：A 类无激活；B/C 类的 relu 必须作用在 `q_d + rescale(q_s)` 的结果上（引擎现有 requant 在乘加前/后位置需明确） | 引擎 requant 流水改造（§4） | relu 顺序错 → 掉点 |

**位精确性**：现两段式是 `q_s = clamp(round(y))`（int8）→ `out = clamp(q_d + ((q_s - zp_s)*R)>>KADD)`。
融合版必须**保持同一顺序**：requant 先产出 int8 `q_s`（照旧），再做 add 的整数 rescale。**不能**把 rescale 提前到 32-bit acc 上（会改变舍入）。这一条是位精确的充要条件。

---

## 3. 收益估算（三个口径）

### 3.1 op 数

| 阶段 | 融合内容 | 融合后 op 数 |
|---|---|---:|
| 现状 | — | 106 |
| P1a-1 | 12 个 backbone shortcut | 94 |
| P1a-2 | +5 个 residual_relu | 89 |
| P1a-3 | +3 个 fpn_sum（需重排） | 86 |
| P1a-4 | +3 个 concat copy（多 src conv） | **83** |

ROM 深度 128 仍够（83 + 余量），**无需扩 ROM**。

### 3.2 周期（来源：`cycle_model.py --scenario f` 与逐 op 分解）

| 阶段 | 被消除的 op 周期 | 融合代价（估） | 净省 | 累计拍数 | fps@122 |
|---|---:|---:|---:|---:|---:|
| P1a-1（12 shortcut） | 453k | ~75k | **378k（0.9%）** | 39.51M | 3.09 |
| P1a-2（+5 relu add） | 328k | ~55k | **273k（0.7%）** | 39.24M | 3.11 |
| P1a-3（+3 fpn sum） | 185k | ~30k | **155k（0.4%）** | 39.09M | 3.13 |
| P1a-4（+3 copy） | 169k | ~28k | **141k（0.4%）** | 38.95M | 3.14 |
| **全部** | **1,138k** | **~188k** | **≈950k（2.4%）** | **38.94M** | **3.14** |

- **融合代价**来源：融合后的 conv 在 requant 阶段多读一次 dst（每输出块 8~16 拍 128b）= 约 188k 拍（按 12+8 个融合 conv 的总块数估算）。
- 与 `cycle_model.py` 当前口径的差异：模型里 `fusion` 用固定 50,000 拍代价（保守偏乐观 138k = 0.35%）；**建议把常数改为 190,000**（本规格的估算），并在 `--self-check` 保持基线不变。
- 注意：`p1` 场景（融合+行缓冲+dw 通路）在 model 里是 **32,514,547 拍 = 3.76 fps@122**；融合单独只值 **2.4%**，真正的 P1 大头是行缓冲（B×0.7）与 dw 通路。

### 3.3 激活流量（DDR3）

| 项 | 现状/帧 | 融合后 | 省 |
|---|---:|---:|---:|
| add 张量（20 个，1 趟读 src） | 0.95 MB | 0 | 0.95 MB |
| concat copy（3 个：读 3 源 + 写 1 目标 + 消费 conv 读） | 2.03 MB | 0.68 MB | 1.35 MB |
| **合计（band-outer 口径 45.31MB/帧）** | 45.31 MB | **≈43.0 MB（-5.1%）** | **≈2.3 MB** |

> 对 DDR3 带宽不敏感（当前帧率下只占 7~9%），但省的是**延迟/事务数**，对 P2 帧率提升后的余量有意义。

---

## 4. 引擎 "conv add-mode" 未实现的 RTL 改动清单（只列，不实现）

**现状证据**：`results/ai-accel/engine-report.md:687`
> "conv 的 add-mode（`NN_F_ADD`）**未实现**（CONTRACT §11 允许 v1 后置，shortcut 用独立 add op 实现）"

`NN_F_ADD` 位本身存在（`nn_pkg.sv:67`，bit2 = "结果累加到 DST 原值"），但引擎只在 **add op** 里用 ADD_R 路径（`nn_conv_engine.sv` 的 `ad_*` 分支），**conv 的 requant/写回路径不读 dst**。

| # | 文件 / 位置 | 改动 | 规模 |
|---|---|---|---|
| **R1** | `nn_conv_engine.sv` 描述符合法性 | `f_add` 现在只对 `NN_OP_ADD` 有意义；放开到 conv/dw（`cr_*_bad` 检查里把 `f_add && f_dw` 等非法组合显式列出） | S（~10 行） |
| **R2** | `nn_conv_engine.sv` S_REQ（requant）阶段 | 新增"读 DST 并累加"支路：`out_q = clamp(q_d + ((q_s - zp_s)*R)>>KADD)`；`R/KADD/zp_s/zp_d` 从该 op 的 Q 块读（Q 块从 16B 扩到 32B，或复用 add 的 Q 布局） | M（~60 行 + 1 级流水） |
| **R3** | `nn_conv_engine.sv` 读口仲裁 | DST 读与 MAC 的 `a_*` 争用：**在 REQ 阶段复用 a 口**（REQ 期间 a 口空闲，16~24 拍足够读 8~16 拍 dst）。需新增"REQ 读地址生成器" + 与 S_LD 的互斥 | M（~40 行） |
| **R4** | `nn_conv_engine.sv` 激活位置 | B/C 类 relu 必须在 add 之后：requant 的负数钳位改成"add 后"再判；配合 `NN_F_RELU`（`ROM-V1.md §5`，新增 flags bit7） | S（~15 行） |
| **R5** | `nn_conv_engine.sv` 多 src（P1a-4） | concat 融合需要 conv 的 ic 块 → 3 个源基址映射：新增 `src2_base/src3_base` 寄存器与 `ch_block → base` 选择（1×1 conv 的 ic=216 = 3×72） | M（~50 行） |
| **R6** | `nn_pkg.sv` / `nn_desc_t` | `flags` 7→8 bit（`NN_F_RELU`）；`nn_rom_t` 增加 `wlen/qlen` 已经要改（`ROM-V1.md §4`）；多 src 时 `src/dst` 之外的 `src2/src3` 由 `nn_subsys` 寄存器提供（不必进 ROM，用 `nn_seq` 预装载） | S~M |
| **R7** | `nn_subsys.sv` | 新增 `NN_SRC2/NN_SRC3`（多 src）、`NN_ADDR_R/KADD`（若 Q 块不扩展则用寄存器）；自动模式由 `nn_seq` 写 | S |
| **R8** | `sim/tb_nn_engine.sv` | 新增 4 个 case：conv+add(无激活)/conv+add(relu)/dw+add/多 src conv；判据 = 与"两段式 golden"位精确 | M |
| **R9** | `tools/bottlecap/gen_plan.py`（converter） | 输出融合后 plan（83 op）、Q 块 32B、生命周期重算；**必须保留 `--no-fuse` 开关**用于 A/B 对比 | M |
| **R10** | `tools/nn_gen_rom.py` / `cycle_model.py` | ROM 生成支持 add-mode flags；cycle_model 的 `fusion` 代价常数 50k→190k（可选参数） | S |

> **总计**：引擎 4 处（R1~R4，约 125 行）、多 src 1 处（R5，P1a-4 才需要）、契约/工具链 3 处、TB 1 处 ⇒ **6~8 个文件/模块**，规模 M。

---

## 5. 契约变更（需 Lead 批准后改 `CONTRACT.md`）

| 契约位置 | 现状 | 改为 |
|---|---|---|
| §4 `NN_FLAGS` bit2 | "add-mode（输出累加到 DST 原值）"，**仅 add op** | 对 conv/dw 也有效；语义 = 先 requant 到 int8，再执行 ADD_R 整数公式 |
| §5 量化 | add 的 `R/KADD` 在 Q 块 16B | 融合 conv 的 Q 块前 16B 相同结构；`qlen` 相应增加 |
| §8 激活布局 | — | 明确 add-mode 的 dst 读地址生成规则（与输出同坐标、同通道块） |
| §11 op 支持范围 | add-mode 未实现（v1 后置） | 标注 P1a 实现后关闭该限制 |

---

## 6. 验证判据

1. **单 case 位精确**：`tb_nn_engine` 新 4 个 case（conv+add / +relu / dw+add / 多 src）与"两段式 golden"`mismatch=0` —— golden 由 numpy 用同一整数公式两次调用（conv→int8→add）生成。
2. **全模型逐 op 位精确**：融合 plan 的 83 op 版本跑 `tb_sw_nn_bottlecap`（MODE_CPU/MODE_AUTO），输出与未融合 106 op 版本**逐张量逐字节一致**（融合是纯调度变换，数值必须恒等）。
3. **周期**：`cycle_model.py --scenario f --json` 的预测拍数 ±2% 内；实际 E2E 拍数写回报告。
4. **回归**：`python tools/fpga_workflow.py verify --force` PASS 数不降（现 PASS 16）；C128 旧模型零影响（融合只是新 plan 生成选项）。
5. **交付档 parity**：无 `NN_EN` 网表不变（门控纪律，`DELIVERY §9.5.1`）。

---

## 7. 风险

| # | 风险 | 影响 | 缓解 |
|---|---|---|---|
| F1 | 融合代价估低（DST 读拍数随块数线性） | 净收益从 2.4% 降到 1.5% | 先做 P1a-1（12 shortcut）实测，再决定后续 |
| F2 | C 类（fpn_sum）需要重排 upsample | plan 顺序变化 → 生命周期/arena 可能变 | P1a-3 单独一阶段，重跑 arena 生成器 |
| F3 | 多 src conv（P1a-4）改动大 | 4 个文件、TB 扩展 | 放到最后；先用"copy 保留"版本跑通 |
| F4 | relu 位置错（C5） | 掉点但位精确测试能抓 | golden 用两段式（conv→int8→add→relu）对齐 |
| F5 | 与 rtl-stream/rtl-mem 的 DDR3 主线并行改动冲突 | 文件冲突 | 融合只动 `nn_conv_engine` + 工具链；tilecache 接口不变（除 R5 多 src） |

---

## 8. 实施顺序（交 converter + rtl-eng）

| 步 | 内容 | 依赖 | 验收 |
|---|---|---|---|
| 1 | converter：plan 生命周期检查 + 输出融合 plan（A 类 12 个） | 无 | 83→94 op、arena 重算、golden 位精确 |
| 2 | rtl-eng：R1+R2+R3（conv add-mode，无多 src/无 relu） | 步 1 | `tb_nn_engine` 2 新 case 位精确 |
| 3 | 全模型 P1a-1 E2E + 实测拍数 | 步 2 | 与 cycle_model 预测 ±2% |
| 4 | R4 + B 类 5 个 relu add | 步 3 | 4 个 case 位精确 |
| 5 | R5 + C/D 类（fpn_sum 重排、多 src conv） | 步 4 | 全部 23 个融合、83 op、位精确 |
| 6 | `cycle_model.py` 回归：`--scenario f` 与实际对比，更新代价常数 | 步 5 | 模型误差 ≤2% |
