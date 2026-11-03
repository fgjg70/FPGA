# A7a 保守版交付（dw 16-lane，仅 ic==oc 且 %16==0 的层）

> 作者：`ddr3-feas`。日期：2026-11-04。状态：**已落地，58 case 全 PASS，树绿**。
> 设计：`A7-REVISED-PLAN.md`；补丁：`perf-proto/patch_a7a_full.py` + `patch_a7a_half.py` + `patch_a7a_gate.py`。

## 1. 实现（dense 共用流水零改动）

| 项 | 内容 |
|---|---|
| dw 专用 128b 窗口 | `dwbuf[0:BANDW-1]` / `dwbsh[0:WINW-1]` / `dw_win[0:PX-1]`，仅 `f_dw16` 装载/移位 |
| 16-lane 门控 | `f_dw16 = f_dw && d_oc[3:0]==0 && d_ic[3:0]==0 && d_oc==d_ic`（16B 对齐 ⇒ 无 8B 旋转/无尾 tile） |
| tile 宽度 | `ocw_r`: pool 8 / dense 16 / **dw16 16** / 其它 dw 8（旧路径） |
| tile 数 | `oc_limit_r`: pool `ic8>>3`；其余 `ceil(oc8/16)`（非 dw16 的 dw 用 `oc8>>3`） |
| 写回 | dw16 走 16B/像素单拍（`single16/wr_dense16` 含 `f_dw16`） |
| MAC 输入 | dw16 用 `dw_win[px][oc*8+:8]`（16 lane）；其它 dw 保持旧 `win_sel` |
| **未做** | 8-lane 尾 tile 的 16-lane 等价（24/8 通道 dw 全部回退旧路径）；A7b 行缓冲（Lead 令暂停） |

## 2. 验证证据

### 2.1 `tb_nn_engine`：**PASS 58 cases（total_mismatch=0）**
- 旧 47 manifest + M1 9 + SA 2 全过；其中 **16-lane dw 主路径**测试：`dw3x3_c16`、`dw5x5_c16`、`m1_ic864_dw3x3` PASS；非 16 的 dw（c8/c24 等）走旧路径 PASS。
- 逐 case before/after 周期表：`results/bottlecap/reports/tb_nn_engine_cycles_a7a.csv`
  - **仅 3 个 case 周期变化（都是 dw16）**：`dw3x3_c16 1118→569（-49.1%）`、`dw5x5_c16 3806→1913（-49.7%）`、`m1_ic864_dw3x3 45260→22958（-49.3%）`；
  - **其余 55 个 case 周期逐拍不变**（非 dw16 路径零影响）。

### 2.2 YOLO E2E（红线）
- `hw_bad=0`、`auto_bad=0`、`RESULT PASS`；
- **`npu_cycles = 1,049,089`**（A5e 基线 1,191,020 → **−141,931，−11.9%**）；
- 与 `cycle_model` 对账：模型 A7a 保守版预测节省 **142,765 拍** ⇒ 预期 1,048,255，**误差 +0.08%（+834 拍）** ✓
  （YOLO dw 层中 62% 的周期属于 `ic==oc 且 %16==0` 的层，全部拿到 16-lane 收益）

### 2.3 OOC @122MHz（引擎单独，8.182ns）
- **Slack (MET) +1.048ns**，最差路径 6.846ns（仍是 `c_p → fad_phi` 的 requant/融合路径，**不是 dw 路径**）；
- **LUT 30,700（+1,900 vs A5e 28,801）/ FF 19,731（+4,847，dw 128b 窗口）/ DSP 200（+16）**；
- 资源评估：整机 LUT ≈ +1.9K（≤45K 判据余量内）、FF ≈ +4.8K、DSP 200/240（83%，Step B 的 PX16 还需 +32 → 232/240，仍在预算内但需在 Step B 复核）。

## 3. 周期口径（fused_a 101-op plan，`cycle_model`）

| 口径 | 拍数 | @122.22 fps |
|---|---:|---:|
| p0（fused plan，未融合执行） | 39,722,608 | 3.08 |
| p1_rtl（融合 A4/A5e，A7a 之前） | 39,783,123 | 3.07 |
| **p1_a7a（当前 RTL：融合 + A7a）** | **37,631,729** | **3.25** |
| p1（融合 + bopt + A7a；bopt 未实施） | 34,188,741 | 3.57 |
| p2b（全特性 + PX16） | 21,592,756 | 5.66 |

- A7a 在瓶盖模型上省 **2,151,394 拍（−5.4% vs p1_rtl）**；比原估计 A/2+C/2=1.05M 更大，原因是 **16-lane 后 OC tile 数减半 ⇒ A/B/C 三部分都减半**（YOLO 实测 0.6% 误差印证了 ×0.5 口径）。
- 瓶盖模型 17 个 dw op **全部** `ic==oc 且 %16==0` ⇒ 全部拿到收益；YOLO 是 62% 周期占比的 dw 层拿到收益。

## 4. 待办

- A7b（行缓冲复用）暂停（Lead 指示，等收益数字再定；当前 A7a 已覆盖 dw 主要收益）。
- 8-lane 尾 tile（24/8 通道 dw）16-lane 等价性：留作独立任务。
- M6 E2E 用 fused_a 101-op plan 跑时，当前 RTL 预期从 39,783,123 更新为 **37,631,729**（±2%）。
