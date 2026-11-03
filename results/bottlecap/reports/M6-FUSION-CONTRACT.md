# 融合语义精确口径（引擎 v0.9 · 给 converter 实现 fused plan）

> 作者：`ddr3-feas`（task-14）。日期：2026-11-04。
> 这是按**已落地的引擎 RTL**（A4/A5/A5e）写的唯一权威口径；converter 的 golden 逐位对账以此为准。
> 相关实现：`nn_conv_engine.sv` 的 `S_ADRD` / `fad_l1a` / `fad_l1b` / `fad_l2` / `fad_add()` / Q tail 扩展。

---

## B.1 Q 块布局（conv + ADD_R 融合）

conv Q 块长度**不变**：`6*OC_pad + 16` 字节（bias int32[OC_pad] → M_pos int16[OC_pad] → tail 16B）。
引擎只读 tail 的前 8 字节（一个 64b Q 字）。

| tail byte | 内容 | 说明 |
|---|---|---|
| 0 | `zp_out` (int8) | conv 输出 zero-point；**融合累加的 zp_s 就是它** |
| 1 | `zp_in` (int8) | conv 输入 zero-point |
| 2 | `leaky` (bit0) | leaky-ReLU 使能 |
| 3 | `SHIFT` (u8) | requant 右移位数 |
| **4** | **`zp_d` (int8)** | 残差/目标张量 zero-point（后置 ReLU 的下界） |
| **5** | **`KADD` (u8，低 4 位有效)** | Δ 的右移位数 |
| **6..7** | **`R` (u16 little-endian)** | Δ 的 rescale 系数 |
| 8..15 | 0 | 引擎不读 |

- **不需要**独立的 add Q 块，也**不需要** add op 的 `aux0/aux1`（那 16B 只给非融合 ADD 路径用）。
- 融合 conv 的 `desc.flags` 置 `NN_F_ADD_R`(bit6)；若还要后置 ReLU 再置 `NN_F_RELU`(bit7)。
- 旧 plan 的 tail byte4..7 恒 0 ⇒ 行为逐位不变（向后兼容）。

## B.2 写回级语义（位精确，golden 必须逐条照抄）

```
acc  = bias_adj[oc] + sum_{tap,ic} a_q*w_q              # int32，不截断
M    = acc >= 0 ? M_pos[oc]
                : (relu ? 0 : (leaky ? (M_pos[oc]*3277+16384)>>15 : M_pos[oc]))
y    = (acc * M) >> SHIFT                                # int64，算术右移（floor，非四舍五入）
q_s  = clamp(y + zp_out, -128, 127)                      # 第 1 次饱和（int8）
# ---- 融合累加（只在 requant 完成之后）----
p    = ((q_s - zp_out) * R) >> KADD                      # zp_s = zp_out（同一张量）
out  = clamp(q_d + p, -128, 127)                         # q_d = dst 残差 int8（读 dst 原值）
if (flags.RELU) out = max(out, zp_d)                     # 第 2 次饱和之后、按 zp_d 夹下界
```

**易错点（务必对齐）**

1. Δ 用**饱和后的 int8 `q_s`**，不是 int32 `acc`；
2. **两次饱和**（q_s 一次、out 一次），顺序不可交换；
3. 全部移位是**算术右移 floor**，不是 round（与 quant_report 的 requant 口径一致）；
4. `zp_s = conv 输出 zp`（即 `zp_out`），**不是**残差张量的 zp；
5. 后置 ReLU 在 out 饱和**之后**、按 `zp_d` 夹下界（int8 域下界，不是数值 0）。

## B.3 可融硬条件

- `add.dst(buf,off) == conv.dst(buf,off)`（同 buffer 同偏移）；`add.src` = 被跳过的残差张量；add 通道数 = conv.oc、spatial = conv.oh × conv.ow。
- conv 侧：`is_conv && !f_dw && !f_p3 && !f_up2x`（dw 有独立写回路径，不支持；PACKED3 stem 无残差）。
- add 侧：统一用 ADD_R 语义（R/KADD）。plain ADD 只在 `zp_s=0 且 R=2^KADD` 时等价 ⇒ 建议 converter 全部输出 ADD_R 口径（当前 plan 的 20 个 add 都是 ADD_R）。
- **copy（concat）不融**：一个 conv 只能有一个 src 张量；融掉 3 个 concat copy 需要引擎支持"src 跨张量段读"（IC 边界切地址），当前 RTL **不支持**。
  ⇒ **融合后 op 数 = 106 − 20 = 86**（不是 83）。若最终要 83，需另立 RTL 任务（记录在 M6-PERF-IMPL §6 的剩余差距）。
- 20 个可融 add = 12 backbone shortcut + 5 residual_relu + 3 fpn_sum（converter 按层名确认映射）。

## B.4 周期公式增量与对账口径

- 每个融合 conv 输出块（8 px × 16 lane、16B 写模式）**+13 拍**：
  - `S_ADRD` 读 dst 字：`wrbeats + 2 = 10` 拍/块（16B 模式；8-lane 半字尾块最多 +21）；
  - 写回三级流水整体延后 **3 拍**：L1a 减法 → L1b ×R>>KADD → L2 +q_d/饱和/ReLU → 写回。
- 非融合 op：**0 拍**（`fad_off_w = 0`，时序逐周期不变；YOLO E2E `npu_cycles = 1,191,020` 逐位不变已证）。
- `cycle_model --scenario p1` 已用此口径：融合代价 = 13 × Σ(blocks×tiles) = **142,597 拍**（17 个融合 conv / 10,969 块）。
- **权威预期（fused plan 到位后的对账值）**：
  - p0 = **40,051,198** 拍（2.50 / 3.05 / 3.75 fps @100/122.22/150MHz）
  - **p1 = 32,719,099 拍**（3.06 / 3.74 / 4.58 fps）
  - **p1 + PX16 = 20,426,805 拍 = 5.98 fps@122.22**
- 判据：fused E2E 的 `npu_cycles` 与 `cycle_model --scenario p1` 预测误差 **≤2%**；且逐 op 输出与"非融合两段式"**逐字节一致**（融合只省 op，不改数值）。

## B.5 引擎侧已实现事实（供 converter 对照 RTL）

| 项 | 实现 |
|---|---|
| dst 读 | 新增 `S_ADRD` 状态，`S_REQ` 前经**现有 a 口**读 dst 字（16B/拍，不新增端口） |
| 累加 | `fad_add()`：`clamp(q_d + delta)` + 可选 `max(·, zp_d)`，在写回级（`S_REQ`） |
| delta | 三级流水 `fad_l1a`（q_s−zp_s）→ `fad_l1b`（×R>>KADD）→ `fad_l2`（+q_d/饱和/ReLU） |
| 写回延后 | `fad_off_w = 3`（fused）/ `0`（非融合） |
| Q 参数来源 | conv Q tail byte4..7（见 B.1） |
| 回归 | `ENGINE_TB: PASS (58 cases, mismatch=0)`；旧 47 case 逐位/逐周期不变 |

## B.6 引擎变更记录（A4/A5/A5e）

| 版本 | 改动 | OOC @122MHz | 说明 |
|---|---|---|---|
| A4/A5 v1 | `fad_word()` 直接在写回路径做乘法 | **-6.494ns**（14.6ns 路径） | 不可接受 |
| A5b | delta 打一拍（+1 拍/块） | -3.344ns（11.5ns） | 仍不够 |
| A5c | 两级流水（+2 拍/块） | -0.213ns（8.36ns） | 几乎 MET 但无余量 |
| **A5e（交付）** | **三级流水（+3 拍/块）** | **+1.125ns MET**（6.77ns） | 资源：LUT 28,801 / FF 14,884 / DSP 184 |

> 教训（写进 M6 §5 方法论）：三级流水第一次实现失败**不是流水本身**，而是 `fad_add()` 里 `(qd_w[l*8+:8]) + dv` 漏了 `$signed()`，Verilog 把负 q_d 当无符号 → 全部饱和到 127；补 `$signed()` 后逐位精确。
