# [NPU] v0.7 特化路线跟踪：冻结模型 + 128MAC 引擎 + LUTRAM/BRAM 存储 + 100MHz 时序

> 协作边界：**视频采集 / 显示（HDMI/TFT）由团队其他同学负责，本 issue 只跟踪 NPU 与模型推理链路。**
> 分支：`feat/ai-accel`；交付档（无 `NN_EN`）必须保持 LUT 3098 / FF 1447 / BRAM 9 / DSP 8 / 150.2MHz 不变。

## 1. 目标

| 项 | 目标 | 依据 |
|---|---|---|
| 最终分辨率 | **320×320**（128 仅 bring-up/回归） | 官方指标在 320 才成立 |
| 帧率 | **≥30fps @320**（"勉强流畅"为最低要求） | 125.44M MACs × 30fps = 3.76 GMAC/s |
| NPU 主频 | **全实现 ≥100MHz**（硬下限 50MHz） | 时序验收线 |
| 完整作品 | 摄像头→YOLO→显示（**视频侧不在本 issue**） | 团队分工 |
| 交付档 | 逐位不变 + verify PASS | 竞赛纪律 |

## 2. 已冻结（不可变更）

- 模型：**YOLO-Fastest v1.1（darknet）COCO 80 类 int8 PTQ**；权重 payload 319,792B（≤320KB BRAM 预算）。
- 权重字节：`sim/prog/yolo/yolo_w.hex` **81,920 行**，sha256 `09ce6ffe…`（= 冻结 v0.5 W 区逐字节相同）。
- Q 参数：`sim/prog/yolo/yolo_q.hex` **12,288 行**，sha256 `2be86cb7…`；C320 版本 `3386b084…`。
- 计划：`sim/prog/yolo/plan.json` sha256 `685beded…`，**112 ops、0 个 CPU 执行 op**：
  conv 56（含 conv0）/ dwconv 28 / add 18 / copy 6 / pool 3 / upsample 1。
- 详见 `results/ai-accel/MODEL-FREEZE.md`。

## 3. v0.7 架构（已实现并自证）

```
CPU(RV32) ──A/B 数据窗口(1拍) + MMIO──▶ nn_subsys
                                          ├─ nn_seq：微码 ROM 112 项 × 200bit (~3.2KB LUTRAM)
                                          ├─ nn_conv_engine v3：128 MAC/拍 (16 OC lane × 8 px)
                                          └─ nn_mem v0.7：
                                               W 320KB = 4 段 128b ROM（75.5 tiles）
                                               Q 48KB = 分布式 LUT-ROM（0 BRAM / ~6,981 LUT）
                                               A 96KB + B 32KB（32 tiles，128b 读 + 128b 写+strobe）
```

- 双模：`MODE_CPU`（逐 op 下发，回归基准）/ `MODE_AUTO`（一次启动、NPU 自主跑完）。
- 存储端口口径（集成 bug 修定）：W 读 `w_addr` **8B 粒度**、返回 16B 窗口（双口 cur/next+mux）；Q 为 64b 字索引；B 写带 `b_wstrb[15:0]`；CPU 窗口只映射 A/B。
- 关键文件：`CONTRACT.md`（§12 v0.7）、`SPEC-SPECIALIZED.md`、`nn_pkg.sv`、`nn_seq.sv`、`nn_mem.sv`、`nn_conv_engine.sv`、`nn_subsys.sv`、`tools/nn_gen_rom.py`、`tools/nn_gen_sw.py`。

## 4. 当前实测状态（2026-11-01）

| 项 | 结果 |
|---|---|
| 引擎功能（stub 与**真 nn_mem**） | **46/46**（v2 语义）+ **4/4**（PACKED3/ADD_R）mismatch=0 |
| 周期公式 | **50/50 case 实测 == 公式（0 误差）**；C128 全模型 **1,167,368 拍** @100MHz = 11.67ms（≈85.7fps 理论） |
| OOC @100MHz | **WNS +0.607ns（MET，未到 +1.0 验收线）**；LUT 33,730（Q ROM ≈6,976，引擎+其余 ≈26.75K）；FF 13,810；**DSP 200（目标 ≤160）**；BRAM 107.5（W75.5+A/B32） |
| nn_mem 资源 | W 75.5 + A/B 32 = 107.5 tiles；+核心 9.5 ≈ **117/135**（给视频链路留 ~18 tiles）|
| SoC E2E（112 op 双模） | ⚠ 正在重测（W 读 8B 对齐 bug 刚由 nn_mem 双口读修复；此前 op0 起全错已定位为该 bug）|
| 交付档回归 | 待 NPU 集成完成后跑全量 `verify --force`（矩阵含 16 项 NN 测试）|

## 5. 待办（按优先级）

1. **时序收敛**：WNS ≥ +1.0；logic LUT ≤25K（当前 ~26.75K）；DSP ≤160
   （requant 两相串行 32→16、mneg 4-lane 串行、地址小乘 LUT 化）。
2. **SoC E2E 双模 PASS**：112 op 逐 op checksum == golden；MODE_AUTO final == MODE_CPU。
3. **性能优化**：dw 16-lane（C128 阶段 dw 占 38.6% 周期）；requant 16B 单 beat（已做）；conv0 loader 3→2 拍；新 plan 真实层重放 TB（l0/l2/l7/l94）。
4. **C320 评估**：当前粗推 ≈7.3M 拍 ≈73ms@100MHz ≈13.7fps；目标 30fps 需 dw16+优化后约 20–22fps，再往 30fps 需 PX16（256 MAC，DSP 超 240）或提频——评估见 `results/ai-accel/PX16-STUDY.md`，**待拍板**。
5. **全实现**：`synth --nn --nn-clk-div N` 冲 BUILD_TIMING=PASS（≥100MHz）+ 资源/时序报告 + bitstream。
6. **视频/显示集成**：另由团队同学负责（不在本 issue）。

## 6. 风险与待决策

- **30fps@320 vs 128MAC@100MHz 的差距**：需 PX16（256 MAC，DSP 超 240，需 LUT MAC 或更高频）或 ≥140MHz 全实现，两者均有时序/资源风险 → 需在完成 100MHz 交付后决策。
- **dbg 装载口综合时置常量 0**（仿真可用）：保持 Q 为 ~7K LUT 分布式 ROM；若需综合后网表可写 W/Q，需 +~5.3K LUT 或改 BRAM。
- W 初始化必须 4 段（128b 宽 ROM 深度 >16384 会被取整到 32768 → 128 块 BRAM），已写入代码注释与 CONTRACT。
- 计时口径：本 issue 所有性能数字均为 **实测/公式对照**，非估算；估算处已标注。

## 7. 关键文档与复现

- 冻结/契约/规格：`results/ai-accel/MODEL-FREEZE.md`、`CONTRACT.md`（§12）、`SPEC-SPECIALIZED.md`
- 报告：`DELIVERY.md`、`engine-report.md`、`mem-report.md`、`model-report.md`、`PX16-STUDY.md`
- 复现命令：
  ```powershell
  python tools/nn_gen_rom.py --plan sim/prog/yolo/plan.json -o nn_rom_pkg.sv --check-table sim/prog/yolo/nn_rom_table.json
  python tools/nn_gen_sw.py --plan sim/prog/yolo/plan.json -o sw/yolo_plan.h
  python tools/fpga_workflow.py verify --force
  python tools/fpga_workflow.py synth --nn --nn-clk-div 12 --prog yolo_board ...
  ```

## 8. 协作请求

- 本 issue 只讨论 **NPU/模型/时序/资源**；视频链路另开 issue。
- 需要拍板：**30fps@320 的实现路线**（PX16 vs 提频 vs 接受 20fps 级），以及最终 AI 档主频档位。
- 任何反例/失败日志请直接贴评论（附复现命令与 sha256）。
