# T-accel-R3 v3 状态备忘（第二阶段：时序/资源修法）

更新时间: 2026-11-01 13:50 左右

## 已完成（本轮）
| 项 | 状态 | 说明 |
|---|---|---|
| ① q_re/q_addr 打拍 | ✅ | Q 引擎侧 2 拍有效；S_Q = q_tot+2 拍（公式已同步） |
| ② requant 32×16 拆 2 DSP | ✅ | acc_hi/acc_lo × m16（mneg 改 16 位）；prod64 = hi<<16 + lo |
| ③ 移位拆分 | ✅ | `prod64>>>SHIFT` = (>>16)>>>shift_q[3:0]（SHIFT≥16），否则 4-bit 直接移 |
| ④ requant 16B 单 beat | ✅ | dense16 且 OC8%16==0 且 dst 16B 对齐 → 每像素 1 个 16B beat（REQ 23→16） |
| ⑤ Q 参数寄存器化 | ✅ | q_tot/qb_w/qm_w/bias/mpos/tail 字索引改寄存器（首 tile CPREP，后续 tile wrap） |
| ⑥ ADD/ADD_R 两级切分 | ✅ | S_AD_WR 算 delta/dst 寄存；S_AD_WR2 饱和 pack+写；4 拍/字不变 |
| TB 回归 | ✅ | 46/46 + 4/4 PASS（`v3_t9.log` / `v3_t9e.log`） |
| 周期公式 | ✅ | 50/50 case 实测==公式（`calc_cycles_v3.py v3_t9.log v3_t9e.log`） |
| C128 全模型 | ✅ | **1,167,368 拍** @100MHz = 11.67ms（85.7fps）；`full_model_estimate_v3.md` |
| PX16 研究 | ✅ | `results/ai-accel/PX16-STUDY.md` |

## OOC @100MHz 进展（engine v3 + 真 nn_mem v0.7）
| 迭代 | WNS | LUT(logic) | FF | BRAM | DSP |
|---|---|---|---|---|---|
| 基线 | −6.638 | 43,823 | 14,591 | 112 | 208 |
| 当前 | **−0.651** | **31,691** | 14,237 | 107.5 | 201 |

- LUT 31,691 **含 nn_mem 的 Q ROM ~6,976**（t-mem 注释口径）⇒ **引擎+其余 ≈24.7K，已在 25K 目标内**（交付报告会分列）。
- BRAM 107.5 是 t-mem 13:10 版 nn_mem 口径（W 段 RAMB18 混排），**定稿后复核 112**。
- 最新最差路径：`c_ocb[4] → q_tot_r[4]`（tile 切换时 q 参数乘法/比较）→ 改增量计算（去 ocb*ocw 乘法）。
- DSP 201>160：MAC128 + requant32 + ADD_R delta8 + mneg(mpos*3277)16 + 地址常量乘 ~17。收敛：q 增量去乘法、requant 两相串行（32→16）、32 MAC 改 LUT（~0.8K LUT）。

## 下一步（按优先级）
1. q 参数增量计算（去掉 tile-wrap 乘法）→ 重跑 OOC 冲 WNS≥+1.0；
2. DSP ≤160（requant 两相串行 + 32 MAC LUT 化）；
3. dw 16-lane（Lead 必做项，占 38.6% 周期；C8≥16 层用 128b band word，C8=8 的 2 层降级 8-lane）；
4. conv0 PACKED3 loader 优化（3 拍/位置 → 2 拍）；
5. 新 plan 真实层重放 TB（l0 packed3 / l2 / l7 / l94 copy / l7,l100 add）；
6. 根目录替换（等 Lead 说 t-mem TB PASS）。

## 交付物位置
- 引擎：`proto/engine/nn_conv_engine_v3.sv`（模块 nn_conv_engine，参数 16/8）
- TB：`proto/engine/tb_nn_engine_v3.sv`（46+4 case；+dbgv 调试开关）
- 向量生成：`gen_vectors_v3extra.py`（PACKED3/ADD_R）；46 case 用 `vec/`
- OOC：`synth100_v3.tcl/bat`、`timing_wrap_v3.sv`、`wq_init/`（W 4 段 128b + Q 64b 初始化）
- 报告：`results/ai-accel/PX16-STUDY.md`；engine-report 待根目录替换时统一更新
