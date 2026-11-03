# 瓶盖模型迁移 —— 进度快照与后续事项（FOLLOWUPS）

> 分支：`feat/ai-accel`（PR [#26](https://github.com/fgjg70/FPGA/pull/26) → `main`）
> 总报告：[`results/bottlecap/reports/FINAL-FEASIBILITY.md`](results/bottlecap/reports/FINAL-FEASIBILITY.md)
> 快照时间：2026-11-04（迁移完成日）

## 1. 结论：可行（两条路线）

| 路线 | 模型 | 精度（int8 vs GT） | 硬件验证状态 |
|---|---|---|---|
| **B 瘦身（推荐先落地）** | SlimMobileNet 96×96，136,321 参数，71 op | **F1=0.9976 / 框匹配 99.92%** | **ModelSim 端到端位精确**（真实图+pattern 各 71/71 op；`npu_cycles=799,520` ≈8.0 ms/帧 @100 MHz；**零 RTL 改动**） |
| **A 原模型（DDR3 流式）** | EnhancedNutAnchorFree 2,048,721 参数，224×224，106 op | **F1=0.9956 / 框匹配 99.60% / mIoU 0.9242** | 数值链 numpy 独立复算 = golden **0 字节差**；引擎/存储/权重流式/tile cache/job 接口/nn_seq band 循环全部落地并回归绿；banded 链路 dense/ADD op 已 PASS；剩 Path A（pad>0）与全模型 E2E |

## 2. 当前基线

- `python tools/fpga_workflow.py verify --force` = **PASS 20**（16 基线 + `tb_nn_wstream` / `tb_nn_tilecache` / `tb_sw_nn_job` / `tb_sw_nn_slim`）
- 交付档（无 `NN_EN`）与 C128 YOLO 112-op E2E **红线未动**：`hw_bad=0`、`auto_bad=0`、`npu_cycles=1,191,020`
- 性能（`cycle_model` 实测口径，fused 101-op plan）：当前 RTL **39,783,123 拍**（3.07 fps@122.22 MHz）→ +A7/A8 **33,924,318**（3.60 fps）→ +PX16 **21,450,724**（5.70 fps）
- BRAM（瓶盖配置）：**122/135 tiles**（W 80 + Q 4 + IBUF 20 + OBUF 6 + core 12）

## 3. 后续事项（GitHub issues）

| Issue | 内容 | Owner | 前置 |
|---|---|---|---|
| [#19](https://github.com/fgjg70/FPGA/issues/19) | **M6b**：tilecache Path A 水平 pad 物化 + banded 8/12/106-op E2E 并注册回归 | rtl-stream | M6c 已完成 |
| [#20](https://github.com/fgjg70/FPGA/issues/20) | **M6**：全模型 E2E + nn_seq 自主执行接线（nn_subsys streaming 端口 + DDR 读仲裁） | npu-spec + rtl-stream | #19、M6c |
| [#21](https://github.com/fgjg70/FPGA/issues/21) | **性能 Step A**：A7a 保守版（dw 16-lane）+ A7b 行缓冲 + A8 地址优化 → 33.92M / 3.60 fps | ddr3-feas | — |
| [#22](https://github.com/fgjg70/FPGA/issues/22) | **性能 Step B**：PX16 256-MAC → 21.45M / 5.70 fps | ddr3-feas | #21 |
| [#23](https://github.com/fgjg70/FPGA/issues/23) | **上板**：MIG/DDR3 接入（需 6 项硬件资料：颗粒型号/引脚 XDC/参考时钟/速度等级/单双片/MIG 许可）+ 交付档回归 | 待资料 | 用户提供 |
| [#24](https://github.com/fgjg70/FPGA/issues/24) | **S2/S3**：双时钟 CPU-NPU 解耦（盘古式）+ 帧流水/显示 | npu-spec + rtl-stream | #20、#23 |
| [#25](https://github.com/fgjg70/FPGA/issues/25) | **剩余融合**：B 类 12 shortcut + C 类 3 fpn_sum（需引擎从 desc.src 读残差 + 重标定） | converter + ddr3-feas | #20、#22 |

## 4. 关键文档索引

| 主题 | 文档 |
|---|---|
| 总报告（结论/证据/路线/风险/上板清单） | [`FINAL-FEASIBILITY.md`](results/bottlecap/reports/FINAL-FEASIBILITY.md) |
| 瘦身模型端到端（路线 B） | [`M6A-SLIM-E2E.md`](results/bottlecap/reports/M6A-SLIM-E2E.md) |
| 引擎 / 存储 / 权重流式 / tile cache / job 接口 | [`M1-ENGINE.md`](results/bottlecap/reports/M1-ENGINE.md)、[`M2-NNMEM.md`](results/bottlecap/reports/M2-NNMEM.md)、[`M3-WSTREAM.md`](results/bottlecap/reports/M3-WSTREAM.md)、[`M4-TILECACHE.md`](results/bottlecap/reports/M4-TILECACHE.md)、[`M5-JOB-IF.md`](results/bottlecap/reports/M5-JOB-IF.md) |
| band 循环（自主执行控制面） | [`M6C-NNSEQ-BAND.md`](results/bottlecap/reports/M6C-NNSEQ-BAND.md) |
| 2M DDR3 链路调试（含最终根因） | [`M6B-DDR-CHAIN.md`](results/bottlecap/reports/M6B-DDR-CHAIN.md)、[`M6B-ARBITRATION-FINAL.md`](results/bottlecap/reports/M6B-ARBITRATION-FINAL.md)、[`M6B-PORTB-FIX.md`](results/bottlecap/reports/M6B-PORTB-FIX.md) |
| 性能（融合/A7/A8/PX16/Winograd/OOC） | [`M6-PERF-IMPL.md`](results/bottlecap/reports/M6-PERF-IMPL.md)、[`NPU-PERF-P1A-FUSION.md`](results/bottlecap/reports/NPU-PERF-P1A-FUSION.md)、[`NPU-PERF-UPGRADE.md`](results/bottlecap/reports/NPU-PERF-UPGRADE.md)、[`A7-REVISED-PLAN.md`](results/bottlecap/reports/A7-REVISED-PLAN.md) |
| CPU-NPU 解耦（盘古式） | [`CPU-NPU-DECOUPLE.md`](results/bottlecap/reports/CPU-NPU-DECOUPLE.md)、[`M5-S2-PREP.md`](results/bottlecap/reports/M5-S2-PREP.md) |
| 计划/权重/ROM/金标产物 | [`plan/`](results/bottlecap/plan/)（106 op）、[`plan/fused_a/`](results/bottlecap/plan/fused_a/)（101 op）、[`plan/slim/`](results/bottlecap/plan/slim/)、[`stream/`](results/bottlecap/stream/) |

## 5. 大产物与复现

以下目录**不入库**（体积大、可由脚本 + 冻结 ckpt 重生成），sha256 记录在各 `plan/*/checksums.txt` 与 `FINAL.json`：

- `results/bottlecap/plan/{opvec/,fused_a/opvec/}`（逐 op 金标张量）
- `results/bottlecap/**/w.hex`、`q.hex`（权重/Q 镜像）
- `results/bottlecap/stream/`（DDR3 流式镜像）
- `results/bottlecap/proto/m6b_data/`（M6b 复现包）
- `results/bottlecap/perf-proto/*work/`（Vivado OOC 临时目录）
- `tools/bottlecap/data/`（测试图，来自原始训练工程）

复现入口：

```bash
python tools/build_sw.py --all                       # 固件镜像
python tools/fpga_workflow.py verify --force          # 全量回归（PASS 20）
python tools/bottlecap/gen_npu_artifacts.py --help    # 计划/ROM/权重生成
python tools/bottlecap/cycle_model.py --self-check    # 周期模型自检
python tools/bottlecap/eval_slim_deploy.py --help     # 瘦身模型 int8 精度复评
```
