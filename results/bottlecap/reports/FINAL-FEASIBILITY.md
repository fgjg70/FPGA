# 瓶盖检测模型 → 本工程 CPU+NPU 迁移 · 可行性总报告

> 作者：Lead（Agent Team）。日期：2026-11-04（Asia/Shanghai）。状态：**可行性已证实，端到端仿真收尾中**。
> 面向：项目负责人 / 评审。所有数字均给出仓库内可复现的证据路径；未完成项在 §7 单列。
> 关联文档：`PLAN-V1.md`（架构与红线）、`../../ai-accel/CONTRACT.md`（NPU 契约）、`M1~M6B` 分项报告。

---

## 0. 一句话结论

**能迁移，而且两条路线都已走到"数值已证实、硬件链路已搭好"的阶段**：

1. **原 2.05M 参数模型**（保持 224×224 精度）**可以完整表达为本工程 NPU 的 int8 指令流**：106 个 op、2,020,960 B 权重、90,368 B 量化参数、2,007,040 B 激活 arena；**int8 端到端 F1=0.9956（float 1.0）、检测框匹配率 99.60%**。但现片上存储（W 320KB/A 96KB/Q 48KB）装不下，**必须走 DDR3：整层权重流式 + 激活 arena + band tile cache**。NPU 纯计算 **40.05M 拍/帧 ≈ 2.5 fps @100MHz**，按现有 v3 引擎要 **~400 ms/帧**；升级到 PX16 256 MAC 阵列后 **~6.0 fps @122MHz**。
2. **瘦身模型**（136,321 参数，96×96，**F1=0.9984、mIoU=0.9495**，与原 2M 只差 0.0016 F1）**不需要改任何 RTL**：71 op、W 130,448 B、Q 22,784 B、A 峰值 73,728 B，全部在现 NPU 容量内 ⇒ **现 CPU+NPU 可直接跑通**（端到端 ModelSim 验证进行中）。
3. 工程侧已把 NPU 从"YOLO-Fastest 专用"扩成**通用 int8 CNN 加速器**：新增 ReLU 激活、ADD 后置 ReLU、IC≤1023（覆盖 864 通道 expansion 层）、W 双银行可写权重缓存、Q 流式影子缓冲、行为级 DDR3 模型、权重预取引擎、激活分带 tile cache、**Job 级接口（CPU 写 1 个 job → NPU 自主跑完整个 ROM → 结果邮箱）**。回归基线从 PASS 16 升到 **PASS 19**，交付档与 YOLO E2E 逐位不变。

---

## 1. 迁移资产盘点（源 → 目标）

| 源交付包 | 内容 | 迁移落点 |
|---|---|---|
| `04_models_training_code_and_reports(1)` | 坚果/电子器件/日常货物 3 套模型与训练代码 | `tools/bottlecap/model_src/nut_detector/`（模型/训练/评估源码） |
| `bottle_cap_model_training_package_20260819` | 四色瓶盖 2M 模型（.pt/.onnx）+ 3500/500 数据集 + 训练过程报告 | 同上 + `tools/bottlecap/data/`（测试集 500 张）+ `results/bottlecap/reports/四色瓶盖模型训练过程.md` |
| 目标工程 | RV32IM CPU（150MHz 交付档）+ int8 NPU（nn_conv_engine v3，128 MAC/拍） | 新增 11 个文件/模块（见 §5） |

---

## 2. 模型 → NPU 的完整映射（数值可行性）

### 2.1 指令覆盖：106 个 op 全部有对应原语

| NPU 原语 | op 数（2M 模型） | 说明 |
|---|---:|---|
| conv（k1/k3, s1/s2, pad0/1） | 61 | 含 conv0 PACKED3（3B/像素输入） |
| depthwise conv（k3, s1/s2） | 17 | MobileNetV2/IRes 的 3×3 深度卷积 |
| add（ADD_R，per-tensor 源 requant） | 20 | 12 个 shortcut + 5 个残差块 + 3 个 FPN 融合 |
| upsample 2×（4× 拆两次 2×） | 5 | 最近邻 |
| copy（concat 通道偏移） | 3 | 216ch = 3×72 |
| **合计** | **106 ≤ ROM 深度 128** ✅ | ROM v1 = 256 bit/项（含 `wlen/qlen/tile`） |

- 激活函数：模型是 **ReLU**（非 ReLU6/leaky）。方案双保险：(a) 逐层按 `[min=0, zp=-128]` 的非对称量化，requant 底部饱和即 ReLU；(b) 新 RTL 标志 `NN_F_RELU`（bit7）显式三态。ADD 后置 ReLU 用 ADD op 的 `flags.RELU`（`out=max(q,zp_d)`）。**旧 YOLO 路径逐位不变**（56 case + E2E 双重证明）。

### 2.2 int8 端到端精度（500 张测试图 / 1250 目标）

| 指标 | float 模型 | int8（NPU 精确整数语义） |
|---|---|---|
| P / R / **F1**（vs 真值） | 1.0 / 1.0 / 1.0 | 0.9960 / 0.9952 / **0.9956** |
| mIoU（vs 真值） | 0.9696 | 0.9242 |
| 整图全对率 / 目标数准确率 | 100% / 100% | 98.8% / 99.8% |
| **float↔int8 检测框匹配（IoU≥0.5）** | — | **99.60%**（匹配框 meanIoU 0.9295） |

- **归因实验**：只把权重做 int8（激活保持 float）时 **F1=1.0、匹配率 100%** ⇒ **权重 int8 零损失**；0.40pp 的差距全部来自激活/Q 链路（requant + 原地 add 目标域 + concat 共享 scale），且**已到"只改量化粒度"的理论上限**，无修复价值。
- 证据：`plan/GOLDEN-REPORT.md`、`plan/e2e_metrics.json`、`plan/quant_report.json`（逐层 cos/amax/shift）。字节级独立整数前向 vs 参考实现 **mismatch=0**。

### 2.3 瘦身模型（"零 RTL 改动"路线）

| 项 | 数值 | 判据 |
|---|---|---|
| 精度（int8，500 图） | **F1=0.9976 / mIoU=0.9292 / 匹配率 99.92%**（float F1=0.9984） | vs 2M 仅差 0.0016 |
| 参数量 / op 数 | 136,321（2M 的 6.7%）/ **71 ≤ 128** | ✅ |
| W / Q | 130,448 / 22,784 B | ≤ 320KB / 48KB ✅ |
| A 单张量 / B 并发峰值 | 73,728 / 23,040 B | ≤ 96KB / 32KB ✅ |
| 输入 | 96×96（96×72 + 上下各 12 行 edge pad） | conv0 PACKED3 27,648 B ≤ 96KB ✅ |
| 结论 | **现 NPU 零改动可跑** | `DEPLOY-CHECK.json` 25/25 PASS |

- 为什么不是更大输入：实测证明 **96 是现拓扑+现 NPU 的容量上限**——112 因 FPN 2× 上采样要求输入被 32 整除不成立；128+expansion3 虽 A 峰值=98,304B 但 stage1 dwconv 需 in+out 并发 131,072B > A+B；160 的 A 峰值 204,800B 超限。

---

## 3. 存储与性能（2M 模型走 DDR3）

| 项 | 数值 | 对照 |
|---|---|---|
| int8 权重 | 2,020,960 B（单层最大 124,416 B） | 现 W 320KB 的 6.17× ⇒ **整层流式 + W 双银行(2×160KiB) 双缓冲**，预取缺口仅 6,690 拍=0.017% ⇒ 完全被计算掩盖 |
| Q 参数 | 90,368 B（单层最大 5,200 B） | 现 Q 48KB ⇒ **随层流式（2×8KiB 影子银行）** |
| 激活 arena（生命周期打包） | 2,007,040 B；单张量峰值 1,204,224 B | 片上 A+B 仅 128KB ⇒ **放 DDR3 + band tile cache**（整通道 band，2,391 band；IBUF 2×32KiB / OBUF 2×12KiB，17 个 dwconv 层需 32KiB） |
| 激活流量 | 36.4 MB/帧（理想） | 2.5fps 需 91 MB/s；即使 13fps 也只占 DDR3 有效带宽 ~37% ⇒ **存储不是瓶颈** |
| NPU 纯计算 | **40,051,198 拍/帧** | @100MHz=2.50fps；@122MHz=3.05fps；**升级 PX16 后 20.4M 拍 ⇒ 6.0fps@122** |
| 周期模型可信度 | `cycle_model.py` 跨模型互证：YOLO 预测 1,168,779 vs 实测 1,167,368 = **+0.12%**；M6b 真实链路 8 op：预测 3,443,756 vs 实测 3,443,772 = **+0.00%** | ✅ |

### 3.1 性能升级路线（对标 Xilinx DPU 档位）

- 器件 240 DSP ⇒ **DPU 等价档位 ≈240 MAC/拍**；本工程现役 128 MAC/拍 = 该档 53%。
- **P1（不改阵列）**：图级融合（106→83 op）+ 行缓冲 + dw 专用 ⇒ 40.05M → **32.6M 拍（3.75fps@122，+23%）**，零精度风险。
- **P2（256 MAC/拍，PX16 = 16px×16lane）**：⇒ **20.4M 拍（5.99fps@122 / 7.35@150）**；OOC 实测 fmax ≈151MHz（加宽不是时序瓶颈），资源 +4.3K LUT/+1.3K FF/+32 DSP，整机 LUT≈41K(65%)、DSP 200/240。
- **P3（Winograd F(2,3)，只做 12 个 56²/72ch 层）**：⇒ **7.78fps@122**；已验证 int8 Winograd **可逐位精确**（exact 变体 cos=1.000），硬约束是累加器 ≥28-bit。列为第二批。

---

## 4. CPU-NPU 解耦（对齐"盘古"参考架构）

参考本机 `work/pango_bl/vision/`（紫光同创 PG2L100H）：CPU/IMEM/DMEM 独立 125MHz、NPU+相机+MMIO 50MHz、跨域带等待握手、NPU 自主推理期间不停摄像头、忙时丢帧。

本工程落地（`CPU-NPU-DECOUPLE.md` + `M5-JOB-IF.md`）：
- **Job 级接口（S1 已完成）**：14 个 MMIO 寄存器（doorbell/in/out/model/frame/status/ack/err/cycles/counters）+ **2KB 结果邮箱**（LUTRAM，BRAM +0）；CPU 写 1 个 job → NPU 自主跑完整 ROM → done/err。实测 jobA/jobB：`cycles=1,191,020`、`done_ops=112`、邮箱 1024B 与 A/B 窗口**逐字节一致**、busy 时 doorbell 丢弃、ACK 后可起下一 job。
- **双时钟域（S2，设计完成待实施）**：CPU 保持交付档 150MHz、NPU 独立 100MHz（MMCM VCO1050，/7 与 /10.5），10 项 CDC + `nn_cdc_bridge`（对齐盘古 `vision_mmio_bridge` 的 req/ack 翻转位握手）；Option P（posted 写，0 改 core）为第一版。
- **帧流水线（S3，设计完成）**：输入双缓冲 + 忙时丢帧、输出三缓冲 + 帧边界提交防撕裂、job 看门狗超时、NPU 域独立复位。

---

## 5. 工程改动清单（截至本报告）

| 类别 | 文件 | 状态 |
|---|---|---|
| 契约 | `nn_pkg.sv`（flags 8bit+RELU、W/Q 银行常量、ROM v1 256bit/`wlen/qlen/tile`、src/dst 22bit） | ✅ |
| 契约 | `nn_rom_pkg.sv`（YOLO 112 项）、`plan/nn_rom_pkg_bottlecap.sv`（瓶盖 106 项） | ✅ 逐字段校验 |
| 引擎 | `nn_conv_engine.sv`：RELU 三态、ADD 后置 ReLU、`icb_n` 死代码加宽、**plain ADD zp_s 跨 op 泄漏修复**、conv add-mode 合法性放开（A1/A2） | ✅ 56 case 零回退 |
| 存储 | `nn_mem.sv`：W 2×160KiB 可写双银行 + 64b 填充口、Q 2×8KiB 影子缓冲、`w_mode` 模式位 | ✅ legacy 47,148 checks 不变 |
| 流式 | 新 `nn_wload.sv`（整层预取，399MB/s）、新 `sim/beh_ddr3.sv`（行为级 DDR3） | ✅ 102 真实层逐位 0 mismatch |
| Tiling | 新 `nn_tilecache.sv`（IBUF/OBUF + band 描述符 + fill/flush + ADD 双 IBUF） | ✅ 7/7 PASS（含 32KiB 配置） |
| 解耦 | `nn_seq.sv`（job 路径+看门狗）、`nn_subsys.sv`（job 寄存器+邮箱）、新 `sw/nn_job_demo.c`、`sim/tb_sw_nn_job.sv` | ✅ PASS |
| 工具链 | `tools/bottlecap/{extract_graph,quant_npu,golden_npu,gen_npu_artifacts}.py`、`gen_weights_image.py`、`cycle_model.py`、`train_slim.py`、`profile_model.py` | ✅ 固定 seed 可复现 |
| 工具链 | `tools/nn_gen_rom.py`（v1 字段/DDR plan/流式模式）、`nn_gen_sw.py`（`--guard`、YF_RELU） | ✅ YOLO 头文件 diff 仅新增 |
| 流程 | `fpga_workflow.py`：**BOM 编码闸门**、`nn_mem` 黑盒变量补偿、新测试项×3；`build.tcl/build_ila.tcl/run_coremark.py` 同步 | ✅ |
| 回归 | `verify --force` = **PASS 19**（16 基线 + wstream + tilecache + nn_job）；交付档/YOLO 逐位不变 | ✅ |

---

## 6. 关键风险与缓解

| 风险 | 现状 | 缓解 |
|---|---|---|
| DDR3 物理层未接入（无 MIG/引脚/原理图） | 仓库零证据；板卡当前不在位 | 已用**行为级 DDR3 模型**完成全部链路；拿到用户 6 项输入后再换 MIG，`nn_ddr_if` 接口不变 |
| 板上 BRAM 只剩 3 tiles | 瓶盖模式需释放 A/B 32 tiles | 流式/tile 模式下 A/B 由 tilecache 复用；整机估算 W80+Q4+IBUF16+OBUF6+core12 ≈ **118/135** |
| 25MHz 时序（150MHz AI 档） | 122.22MHz 已验证；150 是纯 route 问题 | P2/PX16 按 122MHz 承诺；150 需 pblock/floorplan |
| 端到端仿真收尾 | M6a（slim）与 M6b（2M DDR3 链路）进行中 | 见 §7 路线 |
| 并发编辑/编码事故 | 已发生 2 次（BOM、半写文件） | BOM 闸门入 `check`；纪律"根目录 .sv 一次写完整 + 改完先跑自己的 TB" |

---

## 7. 未完成项与后续路线（按优先级）

| # | 事项 | 判据 | 负责 |
|---|---|---|---|
| 1 | **M6a：瘦身模型 ModelSim 端到端**（现 NPU 零改动） | `SLIM_TB: PASS`、71 op 逐 op FNV 全对（金标 `opvec/0349/checksums.txt`）、周期对账 | npu-spec |
| 2 | **M6b：2M 模型 DDR3 全链路前 8~12 op 位精确** | 逐 op FNV/张量全对（金标已就绪）；当前卡在 tilecache 通道 pad/b_wstrb/绝对地址基准三处，已有排查路径 | rtl-stream |
| 3 | **M6：2M 全模型 DDR3 E2E**（106 op） | 逐 op FNV 全对；周期 ≈40.05M 拍 ±2% | Lead + rtl-stream |
| 4 | **NPU v4**：Step A（P1 融合/dw/行缓冲）→ Step B（PX16 256MAC） | cycle_model p1/p2b 对账 ±2%；YOLO E2E 零回退 | ddr3-feas |
| 5 | **S2 双时钟 + S3 帧流水线** | 新 `tb_nn_cdc.sv`；PASS 数不降 | npu-spec（后续） |
| 6 | **上板**：MIG + 摄像头/SD 输入 + UART 判据 | 需用户提供 DDR3 型号/引脚/时钟/速率/用途 + MIG 使用许可 | 用户 + Lead |

---

## 8. 复现命令（关键路径）

```powershell
cd D:\USER\Desktop\FPGA\FPGA
# 0) 环境自检
cmd /c tools\doctor.bat
# 1) 模型画像与浮点基线（精度 1.0 自证）
python tools\bottlecap\profile_model.py
# 2) 2M 模型：图导出 → int8 PTQ → golden → plan/ROM/镜像（含 opvec 金标）
python tools\bottlecap\extract_graph.py --input-size 224
python tools\bottlecap\quant_npu.py --input-size 224
python tools\bottlecap\gen_npu_artifacts.py --input-size 224
python tools\bottlecap\golden_npu.py --input-size 224        # 500 图 e2e + opvec
python tools\nn_gen_rom.py --plan results\bottlecap\plan\plan.json -o results\bottlecap\plan\nn_rom_pkg_bottlecap.sv --table results\bottlecap\plan\nn_rom_table_bottlecap.json
# 3) 流式镜像（W/Q 按 op 顺序）
python tools\bottlecap\gen_weights_image.py --plan results\bottlecap\plan\plan.json --w-hex results\bottlecap\plan\w.hex --q-hex results\bottlecap\plan\q.hex
# 4) 周期模型（权威基线自检 = 40,051,198）
python tools\bottlecap\cycle_model.py --self-check
# 5) 全量回归（期望 PASS 19；新 M6 测试项随落地增加）
python tools\fpga_workflow.py verify --force
# 6) 分项验证
python tools\fpga_workflow.py verify --only tb_nn_engine
python tools\fpga_workflow.py verify --only tb_nn_wstream
python tools\fpga_workflow.py verify --only tb_nn_tilecache
python tools\fpga_workflow.py verify --only tb_sw_nn_job
```

---

## 附：证据索引

| 主题 | 文件 |
|---|---|
| 架构决策与红线 | `results/bottlecap/reports/PLAN-V1.md` |
| 模型画像/浮点基线 | `results/bottlecap/model/{MODEL-PROFILE.md, model_profile.json}` |
| NPU 能力矩阵（含全部硬限制） | `results/bottlecap/spec/{NPU-CAPABILITY.md, npu_capability.json}` |
| DDR3 可行性/权重流式/ROM v1 | `results/bottlecap/ddr3/{DDR3-FEASIBILITY.md, WEIGHT-STREAMING-DESIGN.md, ROM-V1.md, bandwidth_budget.json}` |
| 2M int8 精度 | `results/bottlecap/plan/{GOLDEN-REPORT.md, e2e_metrics.json, quant_report.json, opvec/}` |
| 瘦身模型精度/容量 | `results/bottlecap/slim/{SLIM-REPORT.md, FIT-CHECK.json, EXPORT.json, ref_heads.npz}` + `results/bottlecap/plan/slim/{GOLDEN-REPORT-SLIM.md, DEPLOY-CHECK.json, E2E-HANDOFF.md, FINAL.json}` |
| 引擎/存储/流式/tiling/Job 分项 | `results/bottlecap/reports/{M1-ENGINE.md, M2-NNMEM.md, M3-WSTREAM.md, M4-TILECACHE.md, M5-JOB-IF.md, M6B-DDR-CHAIN.md}` |
| 解耦架构 | `results/bottlecap/reports/{CPU-NPU-DECOUPLE.md, cpu_npu_interface.json}` |
| 性能升级 | `results/bottlecap/reports/{NPU-PERF-UPGRADE.md, NPU-PERF-P1A-FUSION.md, NPU-PERF-WINOGRAD.md, NPU-PERF-OC32-REVISION.md, NPU-PERF-OOC.md, M6-PERF-IMPL.md}` + `tools/bottlecap/cycle_model.py` |


---

## [M6a ???] ???? ModelSim ??? ?? **PASS**

> ?????2026-11-04 00:2x??????`.fpga-cache/logs/tb_sw_nn_slim.log`??? `SLIM_TB: PASS`??
> ????`tb_sw_nn_slim`???????????????? `results/bottlecap/plan/slim/TB_READY`??

| ? | ?? |
|---|---|
| ??? 0349?96?96 PACKED3?27,648 B? | ?? FNV `0xbb23c676` == ???**71 op ???23 ??? op ? op FNV ??** ? `real_hw_bad=0` |
| pattern_v1 ?? | ?? FNV `0xe40efcc5` == plan?**71 op ? op FNV ??** ? `pattern_hw_bad=0` |
| MODE_AUTO??? ROM ????? | `auto_final_fnv=0xd93e3569` == ???`auto_bad=0`?`auto_npu_cycles == hw npu_cycles` |
| NPU ?? | **799,520 ?**?conv 447,935 / dwconv 294,042 / add 49,959 / upsample 7,584??? v3 ???? **0 delta** |
| RTL ?? | **?**?`nn_*.sv` ???ROM ? slim ?????? `nn_rom_pkg`? |
| ??????500 ?? | int8 **F1=0.9976 / ??? 99.92%**?float F1=0.9984? |

**??**???"?????????? RV32IM CPU + int8 NPU ?????"????????ModelSim?????? RTL ???????MODE_CPU ? MODE_AUTO ?????? op ????


---

## [P1 ????] ?????2026-11-04 00:5x?ddr3-feas A5e ???

| ? | ?? |
|---|---|
| ???????conv add-mode? | `nn_conv_engine.sv` ?? `S_ADRD`???? a ?? dst ???+ ?????`fad_off_w=3`(fused)/`0`(???) |
| ?? | `ENGINE_TB PASS 58 cases`?? 47 ??/???????YOLO `hw_bad=0/auto_bad=0`?`npu_cycles=1,191,020` ?? |
| OOC @122MHz | v1 ?6.494ns ? v2 ?3.344 ? v3 ?0.213 ? **v4(??) +1.125ns MET**?6.77ns ???LUT 28,801 / FF 14,884 / DSP 184? |
| ???????? | **+13 ?/??? ? 10,969 ? = 142,597 ?**???? 50,000 ??????? |
| **p0 ? p1** | 40,051,198 ? **32,719,099 ???18.3%?= 3.74 fps@122**?@100=3.06 / @150=4.58? |
| **P1 + PX16 256MAC** | **20,426,805 ? = 5.98 fps@122**????? |
| fused plan | **106 ? 86 op**?copy/concat ????????? RTL ???83 ???? |

> ?????? M6-PERF-IMPL ?5??`use_dsp` ? function ?????Verilog ?? signed/unsigned ?????????????"????"???????????????? OOC?


---

## [M6b 根因诊断] 引擎输出出现 X ← nn_mem portB "读写同址单口"的 read-during-write（2026-11-04 01:2x）

**证据链**：
1. ISO 单 op：`iso_op=0`（conv0 PACKED3，1 OC tile）PASS；`iso_op=1`（dense 1x1 16->64，4 tiles）FAIL；`iso_op=3`（dense 1x1 64->16，**1 tile**）FAIL ⇒ 与 OC tile 数无关。
2. 引擎端口逐笔核验（w/q/a 读序列与数据、b 写地址/拍数/strobe、描述符、A/B 两种 dst 约定）全部"对" ⇒ 典型"序列对、采样错"。
3. **独立 numpy 复算**（`results/bottlecap/proto/recompute_op.py`，从 plan.json/w.hex/q.hex/arena 按 CONTRACT §5/§6/§7/§8 重实现）：**op3 numpy vs converter golden = 0/200704 字节不匹配** ⇒ 排除 converter/plan/W/Q 语义。
4. **引擎输出 dump 含 `xxxxxxxxxxxxxxxx`** ⇒ 引擎采样到 X。
5. engine owner 契约分析：引擎 W/Q 读**固定 2 拍延迟且无 backpressure 输入**；`nn_mem` M2 为省 BRAM 把 portB 做成"读写同址单口" ⇒ 同一拍同址 fill-write 与 engine-read 时推断 RAM **read-during-write 返回 X**。PACKED3 op0 的 W 读窗口短（未撞上 fill 期），dense op1/op3 的 W 读贯穿长 MAC 期（必然撞上）——完美解释"PACKED3 通、dense 不通"。

**修复（task-19，rtl-mem 执行中）**：读优先 + 2 深 64b fill skid FIFO（同拍绝不写正在被读的地址）、Q 侧同样、bank 翻转 fence（翻转前后 >=2 拍无引擎读）、确认未填充读返回 0 而非 X。
**判据**：ISO op1/op3 X 计数=0 且 FNV 全对；legacy `tb_nn_mem` 47,148 checks 逐项一致 + stream 773 PASS；BRAM 仍 119.5/120；YOLO `npu_cycles=1,191,020` 逐位不变。


---

## [P1a 融合交付] 101-op bit-exact 融合版（2026-11-04 01:2x，converter task-18）

| 项 | 数值 |
|---|---|
| op 数 | **106 -> 101**（融掉 5 个 A 类 residual_relu：op67/73/79/85/94） |
| 权重 / Q | 2,020,960 B 不变 / 90,368 -> **90,288 B**（省 5x16B add Q 块） |
| ROM | **101 / 128 项**（独立校验：tile 字段 0 mismatch、5 个融合 conv flags=0xC0=ADD_R\|RELU、op0(whole) tile=0） |
| 每帧流量 | 36.389 -> **35.338 MB（-2.9%）** |
| 周期 @p0 | 40,051,198 -> **39,783,123（-268,075，-0.67%）**；其中省 5 个 add -328,590、融合代价 +60,515（13 拍/块 x 4,655 块） |
| 数值 | 独立 golden 3 图 x 101 op **mismatch=0**；`check_fused_vs_unfused.py` 101 op 逐张量 **0 元素差异**；500 图 int8 **F1=0.9956 / 匹配 99.60%**（与未融合逐项相同） |
| 产物 | `results/bottlecap/plan/fused_a/`（plan/model/ROM/table/w/q/checksums/band_plan/FUSION-MAP/opvec 101op/FUSION-REPORT/E2E-HANDOFF-FUSED/FINAL.json） |

**挂起**：B 类 12 shortcut（需引擎"从 desc.src 读残差"扩展，另立任务）/ C 类 3 fpn_sum（需重标定+重排 upsample，仅 ~0.17M 拍，不划算）。周期口径：未融合权威 p1=32,719,099（前提 20 add 全融）；**本 101-op 版 p1 估算=33,446,460**；`cycle_model --plan fused_a --scenario p1` 的 32,693,164 是"剩余 add 也可融"的乐观假设，不可直接对账。


---

## [最新状态 2026-11-04 01:1x] M6c 完成 + M6b 根因最终定位

**M6c（nn_seq band 循环 + 流式预取控制）= PASS**（npu-spec，报告 `M6C-NNSEQ-BAND.md`）：
- `tb_nn_seq` 分路径 PASS：legacy `starts=112 cycles=336`（严格断言不变）；合成 band ROM `bands=4242 pre=112 eng=4242 cycles=72114`；错误注入（wlen>128KiB / pre_err）→E6 PASS；
- 实现：`tile[1]=band_en` 语义、`zp_in` 取自 `rom.aux0[7:0]`、per-op->per-band 引擎启动、W/Q 指针累加 + bank 翻转（pre_done 后）、`nn_subsys` u_seq 新端口 tie-off；
- 106-op band 数 vs `band_plan.json`：**104/106 精确一致**（2 个 upsample 按 even-B 规则）；
- 全量 `verify --force` **PASS 20**（旧 19 项不变）。

**M6b 根因最终定位（rtl-stream + ddr3-feas 交叉验证）**：
- 引擎 dense 路径在**纯净室 banded 模式**下逐字节正确：op3 用 13 行 band 跑 `OP3ISO: PASS rows=13 mis=0`（与 golden 5,824 word 全对）；vary-src（0x60000→0x70000）亦 PASS ⇒ 引擎对合法窗口内任意 base 不敏感；
- **M6b v1 的"1 band = 整张量（`desc.ih`=112）"不是引擎 dense 路径的合法执行形态**（PACKED3 路径恰好不受影响）；且 stock `nn_mem` 的 A 窗口被 `nn_mem.sv:508` 硬卡 96KB ⇒ 整张量 802KB 在 wall 模式结构性不可行；
- ⇒ **M6b v2 / M6 一律按 banded 执行**（TB 按 `band_plan.json` 逐 band 发起，IBUF 2×32KiB + OBUF 2×12KiB 紧配置），这也是既定的 M6 形态；
- 尾部 X：banded wall 模式无 X；X 出现在 M6b v1 的 band 收尾处（`a_rdata` 上游），banded 重构后需用 `$isunknown` 断言清零。


---

## [A7a 落地 2026-11-04 01:3x] dw 16-lane（保守版，dense 共用流水零改动）

| 项 | 结果 |
|---|---|
| 实现 | dw 专用 128b 窗口 `dwbuf/dwbsh/dw_win` + `f_dw16 = f_dw && d_oc%16==0 && d_ic%16==0 && d_oc==d_ic`；非 16 通道 dw 回退旧 8-lane 路径逐位不变 |
| 回归 | `ENGINE_TB: PASS (58 cases)`；只有 3 个 dw16 case 周期变化（1118→569、3806→1913、45260→22958，≈-49%），其余 55 case 逐拍不变 |
| YOLO E2E | `hw_bad=0/auto_bad=0`；`npu_cycles = 1,049,089`（基线 1,191,020，**-11.9%**）；与 cycle_model 对账误差 **+0.08%** |
| slim E2E | `hw_bad` 全 0；`npu_cycles = 653,129`（原 799,520，**-18.3%**）；固件期望窗口已同步（640,066~666,192） |
| OOC @122MHz | **Slack (MET) +1.048ns**；LUT 30,700 / FF 19,731 / DSP 200（+16） |
| 周期口径（fused_a 101-op） | 融合 39,783,123 → **当前 RTL（+A7a）37,631,729（3.25fps@122）** → +bopt 34,188,741（3.57） → +PX16 21,592,756（5.66） |
