# 瓶盖模型 → CPU+NPU 迁移：架构决策与实施计划 v1

> 作者：Lead。日期：2026-11-03（Asia/Shanghai）。状态：**执行中**。
> 输入：`model/MODEL-PROFILE.md`、`spec/NPU-CAPABILITY.md`、`ddr3/{DDR3-FEASIBILITY,WEIGHT-STREAMING-DESIGN,ROM-V1}.md`、`slim/SLIM-REPORT.md`、`plan/`（converter）。
> 纪律：所有结论带证据；每个里程碑必须有**机器可判**的判据；交付档（无 `NN_EN`）与 C128 YOLO 回归不得回退。

---

## 0. 一句话结论

现 NPU（W 320KB/Q 48KB/A 96KB/B 32KB，激活函数只有 linear/leaky，IC/OC 受 `nn_subsys` 256 检查限制）**装不下**四色瓶盖模型（int8 权重 2,020,960 B、单张量激活峰值 1,204,224 B、Q 90,048 B、最大通道 864、58 层 ReLU）。
**可行路线 = DDR3 外部存储 + 整层权重流式（W 区当 L2 双缓冲）+ 激活 arena 放 DDR3 + band tile cache + ROM/引擎小改**；纯计算 **40,060,598 拍 ≈ 400.6 ms/帧 @100 MHz = 2.50 fps**（@122.22 MHz = 3.05 fps），瓶颈是算力/效率而非带宽（DDR3 需求 113 MB/s ≈ 有效带宽 7%）。

---

## 1. 架构决策（v1，已定）

| # | 决策 | 依据 |
|---|---|---|
| A1 | **DDR3 作为唯一外部存储**：权重镜像 2.02MB、Q 镜像 90KB、激活 arena 4MB 窗口（峰值 1.81MB）、输入帧 | ddr3-feas §4/§6 |
| A2 | **权重整层预取 + W 区 2 银行双缓冲**（2×160KiB），预取缺口仅 6,690 拍（0.017%）⇒ 被计算完全掩盖 | WEIGHT-STREAMING §3/§5 |
| A3 | **Q 随层流式**（2×8KiB 影子缓冲），单层最大 Q 5,200 B | WEIGHT-STREAMING §7 |
| A4 | **激活不常驻片上**：band-outer（输出行带）+ IBUF/OBUF tile cache；新模型按 112×112×96 带需 IBUF 2×32KB + OBUF 2×24KB ≈ 112KB | DDR3-FEASIBILITY §4.3 |
| A5 | **ROM v1**：`nn_rom_t` 200→240 bit，深度仍 128（实测 105 op），新增 `NN_F_RELU`、`wlen/qlen/tile`、src/dst 19→22、woff 19→17(层内)、qoff 16→13(层内) | ROM-V1 §4 |
| A6 | **引擎小改**：新增 ReLU 模式、ADD 后置 ReLU、`icb_n` 6→7 bit（IC≤1023）；**端口不动** | npu-spec §0.1/§11 |
| A7 | **`nn_subsys.sv:252-253` 通道上限 256→1024**（两行），使 op 数保持 105、ROM 深度不变 | ROM-V1 §2 |
| A8 | **双模兼容**：新功能一律加模式位/新 flags；`w_mode=0` 时 W/Q/ROM 行为逐位等价，C128 YOLO E2E 必须继续 PASS | DELIVERY §9.5.1 |
| A9 | 瘦身模型（0.16M/71op/160 输入）**并行作为"零 RTL 改动"快速跑通与兜底** | slim/SLIM-REPORT.md |
| A10 | 板卡 DDR3 资料缺失、板子不在位 ⇒ **先用行为级 DDR3 模型在 ModelSim 验证**，MIG/引脚留到拿到资料后（不阻塞主线） | 用户 2026-11-03 决策 |

---

## 2. 分阶段里程碑（每阶段必须有可核对判据）

| 阶段 | 内容 | 判据（机器可判） |
|---|---|---|
| **M0** | 画像/能力矩阵/DDR3 设计/ROM v1/瘦身模型 | 已完成：`model/`、`spec/`、`ddr3/`、`slim/`。converter 的 int8 golden 精度报告（float vs int8 端到端）**待补** |
| **M1** | 引擎：RELU 模式 + ADD 后置 ReLU + `icb_n` 加宽，TB 扩展 | `tb_nn_engine` 新旧 case 全 PASS（mismatch=0）；C128 YOLO E2E `hw_bad=0/auto_bad=0` 且 `npu_cycles` 不变 |
| **M2** | `nn_mem`：W 2 银行 + 填充写口 + Q 影子缓冲（`w_mode=0` 默认关闭） | `tb_nn_mem` 原 47k checks 不回退；新增流式模式 case PASS；**全量 `verify --force` PASS 数不降** |
| **M3** | 权重流式链路：`nn_wload.sv` + 行为级 DDR3 模型 + 权重镜像生成器 | 随机层 写→预取→读回逐位一致；**用 YOLO 权重走流式链路跑同一 E2E，逐 op FNV 与 golden 一致**（把"只有 W 从 ROM 改成从 DDR3"做到位精确） |
| **M4** | 激活 tiling：`nn_tilecache.sv`（IBUF/OBUF ping-pong + DMA fill/flush + band 描述符） | TB：112×112×96 张量的 3×3 conv 分带执行 == 整张量 golden；halo/stride2/pad 边界 case |
| **M5** | 序列器/子系统：`nn_seq` 带循环 + 预取/银行翻转、`nn_subsys` 寄存器、ROM v1 生成 | 微码驱动整模型 105 op 在 MODE_AUTO 下跑通；与 MODE_CPU 周期相等 |
| **M6** | 瓶盖模型端到端（先瘦身 160，再原 224+DDR3） | 逐 op FNV vs converter golden 一致；帧周期与 `40,060,598±2%` 对账；检测结果与 float 一致（IoU≥0.5 匹配率） |
| **M7** | 报告 + 上板清单（MIG 输入项 6 条） | `results/bottlecap/reports/FINAL.md` |

---

## 3. 文件归属（写作用域，**并行纪律**）

| 角色 | 独占文件 |
|---|---|
| Lead | `nn_pkg.sv`、`nn_rom_pkg.sv`（生成）、`tools/nn_gen_rom.py`、`fpga/build*.tcl`、`tools/fpga_workflow.py`、`results/bottlecap/reports/*`、契约文档 |
| rtl-engine | `nn_conv_engine.sv`、`sim/tb_nn_engine.sv` |
| rtl-mem | `nn_mem.sv`、`sim/tb_nn_mem.sv`、`nn_subsys.sv` 中 **仅 u_mem 实例化块** |
| rtl-stream | 新 `nn_wload.sv`、新 `sim/beh_ddr3.sv`、新 `sim/tb_nn_wstream.sv`、新 `tools/bottlecap/gen_weights_image.py` |
| rtl-tile | 新 `nn_tilecache.sv`、新 `sim/tb_nn_tilecache.sv` |
| converter | `tools/bottlecap/{extract_graph,quant_npu,golden_npu,gen_npu_artifacts}.py`、`results/bottlecap/plan/*` |
| slim-train | `tools/bottlecap/train_slim.py`、`results/bottlecap/slim/*` |
| model-profile / npu-spec / ddr3-feas | 各自目录（已完成） |

新 `.sv` 注册（`fpga/build.tcl`、`fpga/build_ila.tcl`、`tools/fpga_workflow.py` 的 `CORE_SV_ORDER`）**只由 Lead 改**；owner 完成后通知 Lead 注册。

---

## 4. 不变性红线（每次提交自检）

1. 交付档（无 `NN_EN`）：LUT 3098 / FF 1447 / BRAM 9 / DSP 8、WNS +0.007、fmax 150.2 不许变。
2. C128 YOLO 112-op E2E：**数据位精确**（`hw_bad=0`、`auto_bad=0`）不许变。
   周期口径（2026-11-04 起）：`npu_cycles` 允许随性能优化下降，但必须 ① 逐 case 给出 before/after 周期表；② `tb_nn_engine` 期望周期按 `cycle_model` 重算更新；③ YOLO 新值与 cycle_model 预期对账。当前值 `npu_cycles=1,191,020`（A5e 融合落地后仍不变：YOLO plan 无融合 op）。
3. `verify --force` PASS 数：当前 **20**（16 基线 + `tb_nn_wstream`(M3) + `tb_nn_tilecache`(M4) + `tb_sw_nn_job`(M5-S1) + `tb_sw_nn_slim`(M6a)），只能增不许减。
4. 脚本纯 ASCII（`.tcl`/`.bat`）；中文只写 `.sv`/`.md`。
5. 每个 bug/坑记入 `results/CHANGELOG.md` 或对应报告，不写"看起来对"。
6. **RTL/脚本文件的编码必须是 UTF-8 无 BOM**：2026-11-03 实测用 PowerShell `Set-Content -Encoding UTF8` 改 `rv32_pkg.sv` 会写入 `EF BB BF` BOM，ModelSim 直接报 `Syntax error, unexpected non-printable character with the hex value '0xef'`，**16 项回归全红**。同理 `fpga/build.tcl`/`build_ila.tcl` 带 BOM 会让 Vivado 解析异常。改 RTL 优先用 edit 工具；用 PowerShell 落盘时用 `[System.IO.File]::WriteAllText($f,$t,(New-Object System.Text.UTF8Encoding($false)))`，并在提交前对 `*.sv/*.tcl` 扫一遍前 3 字节。

---

## 5. 待用户输入的 6 项（DDR3 上板前必须）

1. DDR3 型号（MT41K128M16 / MT41K256M16…）与位宽组合；2. 引脚 XDC；3. 参考时钟频率/来源与复位极性；4. 速率档（400/800 MT/s）；5. 2 片的用途划分（NPU 独占 / 是否含视频帧缓冲）；6. 是否允许用 Xilinx MIG IP（项目文档里有"零厂商 IP"纪律，需豁免）。

拿到后：生成 MIG → `nn_ddr_if` 从行为级模型换成 MIG 封装 → 全实现 → 上板 UART 判据。

---

## 6. v2 追加方向（2026-11-03 23:2x，用户两条新指示）

> 用户原话："现在的 NPU 很弱，NPU 性能可以考虑参考 xilinx 的那个档" + "但是要考虑像盘古上面那个一样 CPU NPU 解耦"。

### 6.1 CPU-NPU 解耦（对应 task-10 → `CPU-NPU-DECOUPLE.md`）

参考工程在本机：`work/pango_bl/vision/`（紫光同创 PG2L100H）。其架构要点（`ARCHITECTURE.md`）：
- **CPU/IMEM/DMEM 独立 125MHz 域；NPU + 相机 + MMIO 50MHz 域；跨域用带等待的请求/应答握手**；
- NPU 自主推理（忙/完成/请求启用位 + 结果 RAM），推理期间**不停摄像头与 LCD**，忙时**丢弃**新快照；
- NPU 有**私有存储**（双模型 ROM 64KiB、激活双区 16KiB、结果 2KiB、偏置 2KiB），与 CPU 的 16KiB IMEM/DMEM 分离。

本工程现状差距：CPU 与 NPU 共用 `sys_clk_core`（AI 档同为 100MHz），逐 op MMIO 下发 + CPU 轮询；A/B 由 CPU 窗口直接读写。
目标 v2 接口：`nn_cdc_bridge`（req/ack toggle + 2FF + 超时）+ **job 级门铃**（输入 arena / 模型号 / 输出 / 帧号）→ NPU 自主跑完 ROM → done/err + 可选 IRQ；输入帧双缓冲、输出三缓冲；NPU 私有 DDR3（权重/Q/arena/结果）。
最小第一步（待 task-10 定稿）：① NPU 侧独立时钟域（MMCM 双输出，CPU 150MHz / NPU 100MHz）+ MMIO CDC；② MODE_AUTO 已具备的微码自主执行补"job doorbell + done IRQ + 帧号"；③ 交付档 `NN_EN` 隔离不变。

### 6.2 NPU 性能升级（对应 task-11 → `NPU-PERF-UPGRADE.md`）

现状：v3 = 128 MAC/拍，实测 56.8 MAC/cycle（峰值 44%），2.27 GMAC → 40.06M 拍 ≈ 2.5fps@100MHz。
候选杠杆：**加宽阵列 128→256/512 MAC/拍**（DSP48E1 余 72、LUT 余 26K）、**Winograd F(2×2,3×3)**（3×3 conv 占 MACs 主导：towers 51.5% + refine 17.1% + fusion 15.0%）、**dwconv 16-lane**、**conv0 loader**、**提频**（122.22MHz 已验证，解耦后独立时钟可冲更高）、**行缓冲数据复用**。
目标：在 XC7A100T 资源/时序内把帧率从 2.5fps 拉到 **8~10fps 以上**，并给分阶段落地顺序与每阶段资源/时序判据。

### 6.3 对既有 M0–M7 的影响

- M1–M4 与 6.1/6.2 **互不阻塞**（引擎/存储/流式的单元级改造继续）；
- M5（序列器/子系统）需要吸收 6.1 的 job 接口与 CDC（`nn_subsys` 是主要改动点）；
- 6.2 的阵列加宽属于"引擎 v4"，单独分支/OCC 验证，不影响当前 M1 的 ReLU/IC 修复；
- 所有新增工作仍然受 §4 四条不变性红线约束。

---

## 7. 进度快照（2026-11-03 24:00 前后）

| 里程碑 | 状态 | 关键证据 |
|---|---|---|
| M0 画像/能力矩阵/DDR3 设计/ROM v1 草案 | ✅ | `model/`、`spec/`、`ddr3/` |
| 转换器 + int8 golden（2M 模型） | ✅ | **F1=0.9956（float 1.0）、float↔int8 框匹配 99.60%、mIoU 0.9242**；`plan/GOLDEN-REPORT.md` |
| ROM v1 生成（2M 模型） | ✅ | `plan/nn_rom_pkg_bottlecap.sv` 106 项、sum_wlen=2,020,960 / q=90,368、逐字段校验 0 mismatch |
| M1 引擎（RELU/ADD 后置/packed3 修正/ADD zp_s 泄漏修复） | ✅ | `ENGINE_TB: PASS (56 cases)`、旧 47 case 逐位不变、YOLO `npu_cycles=1,191,020` 不变；`M1-ENGINE.md` |
| M2 nn_mem（W 双银行/填充口/Q 影子） | ✅ | legacy 47,148 checks 逐项一致 + 773 新 checks；BRAM OOC 119.5（0 增量）；`M2-NNMEM.md` |
| M3 权重流式（beh_ddr3 + nn_wload + 流式镜像） | ✅ 回归项 | 四配置 PASS、102 真实层逐位 0 mismatch、399MB/s；`M3-WSTREAM.md` |
| M4 激活 tiling（nn_tilecache） | ✅ 回归项 | `TILECACHE_TB: PASS 5/5`；`M4-TILECACHE.md`（tile 字段定稿 + 引擎交接附录） |
| M5-S1 Job 接口 | ✅ 回归项 | `tb_sw_nn_job PASS`：cycles=1,191,020、done_ops=112、邮箱 1024B 逐字节一致、busy 丢 doorbell；BRAM +0；`M5-JOB-IF.md` |
| P0 周期模型 + 性能方案 | ✅ | `cycle_model.py --self-check`（新基线 40,051,198 拍，YOLO 互证 +0.12%）；P1=3.75 / P2-PX16=5.99 / P3narrow=7.78 fps @122 |
| 瘦身模型（零 RTL 改动路线） | ✅ | 96×96、136,321 参数、**F1=0.9984 / mIoU=0.9495**、容量全 PASS；ckpt sha256 `7A1417E0…F9E` |
| 回归基线 | ✅ | `verify --force` = **PASS 19**（16 基线 + wstream + tilecache + nn_job） |
| M6a slim ModelSim E2E | ⏳ | 等 converter 的 slim 最终产物 + E2E-HANDOFF |
| M6b 瓶盖 DDR3 链路（前 8~12 op 位精确） | ⏳ | rtl-stream 进行中（先 FNV，opvec 到位后切逐字节） |
| M6 2M 全模型 DDR3 E2E | ⏳ | 依赖 M6b + nn_seq band 循环/预取接线 |
| NPU v4（P1 融合 + PX16 256MAC） | ⏳ | ddr3-feas task-14 已 green light |

> 变数：`rv32_pkg.sv` 曾被 PowerShell 写入 UTF-8 BOM 造成 16 项回归全红（已修，并已给 `check` 增加 BOM 闸门）；agent 并发编辑根目录 `.sv` 会造成瞬时编译失败（要求"一次性写完整 + 改完先跑自己的 TB"）。


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
