# M6 性能升级实施（NPU v4）· 阶段记要

> 作者：`ddr3-feas`（task-14）。日期：2026-11-03 / 04。
> 目标：**PX16（16 px × 16 OC lane = 256 MAC/拍）@122.22MHz → 6.0fps**；分 **Step A（P1：融合+行缓冲+dw 专用，零阵列改动）** → **Step B（PX16 256MAC）**。
> **当前状态：✅ GREEN LIGHT 已到（rtl-engine M1 complete，引擎归本任务）**。
> **引擎基线（动之前/之后都必须维持）**：`ENGINE_TB: PASS (56 cases, mismatch=0)`、旧 47 case 逐位/逐周期不变、YOLO E2E `npu_cycles=1,191,020` 零回退。
> Lead 三项答复已生效：① `S_ADRD`（每块多 8~16 拍读 dst）**批准**，优先简单/低风险、不做 requant 交错；② P0 权威基线 = `--packed3 auto = 40,051,198`；③ 路径 A（零引擎改动 band 模式）先只估"确认 3 条不改逻辑"的工时（等 rtl-stream M6b 结论）。
> 本文件是活文档：每完成一步追加实测数据。

---

## 0. 现状一页纸

| 项 | 状态 |
|---|---|
| **P0 周期模型** | ✅ 已落地 `tools/bottlecap/cycle_model.py`；**双基线自检通过**（见 §1） |
| **P0 跨模型校验** | ✅ 用**实测 E2E**（YOLO C128）校验：模型 **1,168,779 拍 vs 实测 1,167,368 = +0.12%**（见 §1.2）；另有 rtl-stream M6b 的**全链路实测**互证：8 op 引擎实测 **3,443,772** 拍 vs `cycle_model` **3,443,756** = **+0.00%** |
| **Step A 设计** | ✅ 完成（基于当前 **v0.8 引擎**行号，见 §2）；Lead 已批准 `S_ADRD` 方案 |
| **Step A 专项探针** | ✅ add-mode OOC：**+157 LUT / +35 FF / +0 DSP，fmax 不变**（§4.1） |
| **Step B 设计** | ✅ 完成（PX16，见 §3）；注意 `icb_n` 6-bit 是死代码，**不要在上面浪费工时**（rtl-engine 结论） |
| **路径 A（零引擎改动 band 模式）** | ⏳ 只估"确认 3 条不改逻辑"的工时（§2.5），等 rtl-stream M6b 结论 |
| **OOC 证据** | ✅ 10 配置（128/192/256/PX16 × 100/122/150MHz），见 §4；**PX16 配置已直接覆盖 Step B** |
| **Step A 代码** | ✅ **A1/A2/A4/A5/A5e 全部落地并 PASS**：`ENGINE_TB: PASS (58 cases)`；旧 47+9 不变；YOLO E2E `npu_cycles=1,191,020` 零回退；OOC @122MHz **+1.125ns MET**（见 §2.8） |
| **Step A 剩余** | ⏳ A7（dw 专用）/ A8（行缓冲）+ converter 融合 plan 全模型对账 |

---

## 1. P0 周期模型：双基线 + 跨模型实测校验

### 1.1 两个基线（都已断言）

| 口径 | 拍数 | 说明 |
|---|---:|---|
| `--packed3 off` | **39,891,262** | task-11/12 的历史口径（不复现 PACKED3） |
| `--packed3 auto`（默认） | **40,051,198** | **✅ Lead 2026-11-03 采纳为唯一权威基线**：按 plan flags bit2(=4) 识别 PACKED3，v3 公式的 `load = 3*count+1`；stem 的 B 项 +159,936 拍（+0.40%） |

> **后续所有收益对比统一用 40,051,198**（Lead 决策）；39,891,262 只作为历史对照保留在 `--packed3 off`。

### 1.2 跨模型实测校验（**P0 可信度的关键证据**）

用 `--plan sim/prog/yolo/plan.json`（112 op、dwconv 为主、与瓶盖模型完全不同）跑模型，与仓库里的实测 E2E 比：

| 配置 | 模型 | 实测/报告值 | 误差 | 来源 |
|---|---:|---:|---:|---|
| YOLO C128，`W_RD_LAT=1` | **1,168,779** 拍 | **1,167,368** 拍 | **+0.12%** | `DELIVERY.md §8.1` 的 `npu_cycles=1167368`（MODE_CPU/MODE_AUTO 实测） |
| YOLO C128，`W_RD_LAT=2`（wpipe） | **1,182,479** 拍 | 1,191,020 拍 | **−0.72%** | `mem-report.md §3.8`（wpipe 后 C128 全模型） |

⇒ **模型在"另一套模型 + 真实实测"上误差 ≤0.72%**，"39.89M/40.05M 拍"这个基线与优化收益估算可信。

### 1.3 场景对照表（`m6_cycle_compare.json`，修正口径）

| 场景 | 拍数 | effMAC | @100 | **@122.22** | @150 | 相对 p0 |
|---|---:|---:|---:|---:|---:|---:|
| **p0 现状** | **40,051,198** | 56.7 | 2.50 | 3.05 | 3.75 | 1.00× |
| **p1 融合+LB+dw（Step A）** | **32,719,099** | 69.4 | 3.06 | **3.74** | 4.58 | **1.23×** |
| **p2b P1+PX16（Step B）** | **20,426,805** | 111.2 | 4.90 | **5.98** | 7.34 | **1.96×** |
| p2 P1+OC32（备选，不推进） | 20,587,903 | 110.6 | 4.87 | 5.95 | 7.30 | 1.95× |
| p3narrow（第二阶段，Winograd） | 15,757,583 | 144.6 | 6.37 | 7.78 | 9.55 | 2.55× |

> 与 Lead 口径一致：**2.50fps → 3.05fps（Step A）→ 5.99fps（Step B）**；Winograd 第二批 7.78fps。
> （task-12 报的 6.01/3.76 是 39.89M 口径；修正口径下为 **5.99/3.75**，差异 <0.4%，不改变结论。）

### 1.4 实测对照（TBD，green light 后填）

| 场景 | 模型预测 | 实测 | 判据 | 填数命令 |
|---|---:|---:|---|---|
| YOLO C128 现状 | 1,182,479（W_RD_LAT=2） | 1,191,020（历史） | 基线 | `verify --only tb_sw_nn_yolo` → 读 `npu_cycles` |
| Step A 后 YOLO | **待填**（`--scenario p1` 于 YOLO plan） | — | 误差 ≤2% 且 `npu_cycles` 下降 | 同上（融合 plan 版） |
| Step B 后 YOLO | **待填**（`--scenario p2b`） | — | 误差 ≤2%；`hw_bad=0/auto_bad=0` | 同上 |
| 瓶盖模型 Step A/B | 32.63M / 20.40M | — | 误差 ≤2% | `tb_sw_nn_bottlecap`（E2E 落地后） |

---

## 2. Step A 设计（P1：融合 + 行缓冲/地址 + dw 专用；**零阵列改动**）

> 基准版本：当前仓 `nn_conv_engine.sv`（**v0.8 进行中**，已含 `f_relu` 与 ADD/ADD_R 数据通路）。
> 参考规格：`NPU-PERF-P1A-FUSION.md`（融合语义 C1~C5 与 R1~R10 清单）。**下面是落到行号的可执行版。**

### 2.1 现状盘点（v0.8 已有什么）

| 能力 | 现状 | 行号 |
|---|---|---|
| `NN_F_RELU` | **已实现**：ADD/ADD_R 后置 ReLU（下界 = 目标 zp_d） | `:107`（`logic f_relu`）、`:438-441` |
| ADD_R 公式 `out=clamp(q_d+((q_s-zp_s)*R)>>KADD)` | **已实现**（ADD op 专用） | `:388-414`（`ad_pack`）、`:395-404` |
| dst 经 a 口读 | **已实现**（ADD op 的 `S_AD_*` 状态用 `a_re/a_addr=dst_la`） | `:503-504`、`:445`（`ad_src_word`） |
| ADD_R 合法性 | **仅允许 add op**：`ad_r_bad = f_add_r && !is_add` | **`:158`** |
| conv requant 写回 | `out_lo/out_hi` → `b_wdata`，**不读 dst** | `:511-542`（S_REQ）、`:796-811` |
| S_REQ 期间 a 口 | **空闲**（S_REQ 只用 b 口） | `:511-542`（无 `a_re`） |
| conv 装载/地址 | `S_LD/S_LDCAP`、`count=7*st+K` | `:484-511`、`:1052-1105` |
| dw 分支 | 8 lane/OC tile，`per=count+2+K` | `:1137-1180`（S_MAC/S_DRN） |

⇒ **Step A 的核心不是"从零实现 add-mode"，而是"把已存在的 ADD_R 数据通路接进 conv 的 requant 写回路径，并放开 `:158` 的限制"** —— 这比 task-12 规格书里估的工作量小（当时引擎还是 v0.7）。

### 2.2 改动清单（行号为当前 v0.8 快照）

| # | 文件/位置 | 改动 | 规模 | 说明 |
|---|---|---|---|---|
| **A1** | `nn_conv_engine.sv:158` | `ad_r_bad = f_add_r && !is_add` → 允许 `(is_add \|\| is_conv)` | 1 行 | conv 允许 ADD_R |
| **A2** | `:140-161` 合法性 | 新增 `f_add_conv` 组合约束：`f_add_r && is_conv` 时要求 `d_oc == 目标张量通道数`（由 Q 块给出）且 `f_up2x/f_p3` 不同时置位 | ~6 行 | 防非法组合 |
| **A3** | `:107` flags 位域 | 复用 `f_add_r`（bit6）；若与 `f_relu` 联动，仅在 `f_add_r` 时允许后置 ReLU | 0~2 行 | 语义沿用 |
| **A4** | 新增状态 `S_ADRD`（插在 `S_DRN` 之后、`S_REQ` 之前；`:88-89` 状态枚举） | `f_add_r && is_conv` 时：逐 beat 发 `a_re=1, a_addr=dst_la+px*16`，把 dst 字缓冲进 `ad_dst_buf[0:wrbeats-1]`（≤16×16B=256B，FF/LUTRAM） | ~25 行 | **a 口在 S_REQ 前空闲，不新增端口** |
| **A5** | `:511-542` S_REQ 写回 | 若 `f_add_r`：`pay` 不再直写，先过 ADD_R 公式 + 后置 ReLU（复用 `:395-441` 的 `ad_pack` 逻辑，输入换成 `out_lo/out_hi` 与 `ad_dst_buf`） | ~30 行 | 位精确：与"两段式"逐位一致 |
| **A6** | `:695`/`:777-811` requant 相位 | 确认 `S_ADRD` 不打断 requant 流水（dst 读在 requant 完成前进行，`out_lo/out_hi` 已是 int8） | ~5 行 | 时序：dst 读与 requant 并行 |
| **A7** | dw 专用通路（`:1137-1180`） | dw 去掉逐 tap 重装（行缓冲复用），16 lane（`OCB8`→`OCB16`） | ~40 行 | 周期 −2.89M（占 7.2%） |
| **A8** | `S_LD/S_LDCAP`（`:1052-1105`） | 行缓冲/地址预计算：`count` 11→7.7 拍（B×0.7）；跨输出行复用输入行 | ~50 行 | 周期 −3.44M（占 8.6%） |
| **A9** | `sim/tb_nn_engine.sv` | 新增 4 case：conv+add（无激活）/conv+add(relu)/dw+add/多 src conv；并保留旧 47+4 case 逐位不变 | ~150 行 | 判据：`tb_nn_engine: PASS (n cases, mismatch=0)` |
| **A10** | 工具链（converter） | 融合 plan（106→83 op）+ Q 块扩 16B（R/KADD/zp_s/zp_d）+ `--no-fuse` 开关 | 3 文件（converter 侧） | 见 `NPU-PERF-P1A-FUSION.md §8` |

### 2.3 Step A 周期代价/收益（模型口径）

| 项 | 拍数 | 依据 |
|---|---:|---|
| 消除 20 add + 3 copy | −1,138,033 | `cycle_model` 逐 op |
| conv add-mode 的 dst 读代价（`S_ADRD` 每块 +8~16 拍） | +≈188,000 | 块数 × beats |
| **净（融合）** | **−≈950,000（−2.4%）** | 与 `--scenario f` 一致（38.75M vs 40.05M） |
| dw 专用通路 | −2,893,675（−7.2%） | `--scenario dw` |
| 行缓冲/地址（B×0.7） | −3,442,988（−8.6%） | `--scenario lb` |
| **p1 合计** | **−7,424,696（−18.5%）→ 32,719,099 拍 = 3.75fps@122** | `--scenario p1` |

### 2.4 Step A 判据（green light 后执行）

1. `python tools/bottlecap/cycle_model.py --scenario p1 --json` → **32,719,099 拍**（YOLO plan 上另行同法预测）。
2. `tb_nn_engine`：旧 47+4 case **逐位不变**；新 4 case `mismatch=0`。
3. YOLO E2E：`hw_bad=0 / auto_bad=0`，`npu_cycles` 相对 1,191,020 **下降**（预期 −18~20%，以 YOLO plan 的模型值为准）。
4. 瓶盖模型（若 E2E 已就绪）：`hw_bad=0/auto_bad=0` 且逐 op checksum 与未融合版本**逐字节一致**。

---

### 2.5 路径 A（零引擎改动 band 模式）· 只排"确认 3 条"的工时

> 来源：rtl-stream 在 M6b 的发现（见 `M4-TILECACHE.md` 附录 B）；Lead 2026-11-03 指示：**先只排"确认 3 条不改逻辑"的工时**，等 M6b 结论再决定是否需要路径 B。

rtl-stream 的方案：tilecache **物化水平+竖直 pad**，引擎描述符设 `pad=0, iw=iw+2·pad, ih=band 行数, src=dst=0`，让**现有引擎**把整通道 band 当独立小图跑。三条需要确认"不改逻辑"的点：

| # | 需确认 | 我的预判 | 工时（agent 任务数） | 判据 |
|---|---|---|---|---|
| PA1 | `pad=0` 时引擎的 `pad_eff`/边界处理是否与"物化 pad 后"逐位一致（输入已含 pad 行，引擎按 pad=0 不做边界判断） | **应该一致**：`pad_eff` 只用于地址边界；物化后边界不再触发 | 0.5 个预算（读 `:140-161, :484-511` 各一遍） | 单 case 位精确：同一 band 用"原图/物化 pad"两条路径输出一致 |
| PA2 | `ih=band 行数`（非整图）时：`oh/ow` 推导、行计数、y 边界是否自洽 | **应该自洽**：计算公式只用 ih/iw/k/pad/st，band 只是更小的 ih | 0.5 | 同上（多 band 拼接后与整图输出逐字节一致） |
| PA3 | `src=dst=0`（band 内相对地址）时：a/b 地址生成与 tilecache 窗口基址的加法是否冲突 | **潜在风险点**：`la/dst_la` 由 desc.src/dst 派生，tilecache 需要把"tile 基址"加到 mem 侧（而非引擎侧） | 1（需要 tilecache 侧地址基址寄存器） | 同上 + `tb_nn_tilecache` |

- **总工时估计：2 个 agent 任务（PA1/PA2 合并为 1 个仿真确认 + PA3 的接口确认）**；**零引擎 RTL 改动**。
- **该路径与 Step A 的关系**：band 寻址与 add-mode/dw/行缓冲**正交**——即使路径 A 成立，Step A 的 add-mode 融合与 dw 专用仍要做（Lead 明确）。路径 A 只可能省掉"band 原点字段"（`band_in_row0/y_ky0`）这条改动。
- **纪律**：等 rtl-stream 的 M6b 结论（是否已确认三条）后再决定是否追加工作量；在此之前**不排 Step A 的 band 相关工作**。

---

### 2.6 实施进度（Step A，**2026-11-04 起**）

| # | 项 | 状态 | 证据 |
|---|---|---|---|
| A1 | 放开 `ad_r_bad`：允许 conv 用 `NN_F_ADD_R` | ✅ **完成** | `nn_conv_engine.sv:158` → `f_add_r && !(is_add \|\| is_conv)`（+注释） |
| A2 | 互斥约束：`f_add_r` 时禁 `f_p3` | ✅ **完成** | `nn_conv_engine.sv:151` `cr_p3_bad` 加 `f_add_r` 项 |
| **回归（A1/A2 后）** | **ENGINE_TB PASS (56 cases, mismatch=0)**；47 旧 case + 9 M1 case 全 PASS，无回退 | ✅ **PASS** | `.fpga-cache/logs/tb_nn_engine.log`（`# SUMMARY cases=47 pass=47 fail=0 total_mismatch=0` / `# M1SUMMARY cases=9 pass=9` / `# ENGINE_TB: PASS (56 cases, mismatch=0)`） |
| A3 | flags/RELU 联动（`f_relu` 已在 v0.8 实现，仅确认不冲突） | ✅ 无需改动 | `:107,:440` |
| **A4/A5** | `S_ADRD`（REQ 前读 dst 8~16 拍）+ S_REQ 写回接 ADD_R/ReLU | ⏳ **下一步**（Lead 已批准 S_ADRD 方案） | 设计见 §2.2 A4/A5；新增状态插在 `:1185 S_DRN` 之后 |
| A7 | dw 专用通路（行缓冲 + 16 lane） | ⏳ 待 A4/A5 后 | 注意：会改变 dw case 的**周期期望值**，需同步更新 TB 的周期断言（Lead 的"旧 47 case 逐周期不变"按"未受影响的 case"执行，受影响的 case 以新公式为准并记录） |
| A8 | 行缓冲/地址（B×0.7） | ⏳ | 同上 |
| A9 | TB 新增 4 case + 融合 plan（converter） | ⏳ **需要 converter 的融合 plan/向量**（我这边可以先用 `make_e2e_case.py` 风格自造 2 个 conv+add 向量） | — |

> **下一步（A4/A5）实现要点**：新增 `S_ADRD` 状态（`f_add_r && is_conv` 时进入）：逐 beat 发 `a_re=1, a_addr=dst_la + px*16`，把 dst 字抓进 `ad_cap_lo/ad_cap_hi[0:PX-1]`（PX8 时 8×128b=1KB FF/LUTRAM）；随后 `S_REQ` 的写回在 `pay` 上按 lane 走 ADD_R + 后置 ReLU（复用 `:388-441` 的 `ad_pack` 逻辑）。**每块 +8~16 拍，Lead 已批准。**

---

## 2.7 A4/A5 落地实录（2026-11-04）· 已 PASS

### 2.7.1 改动点（实到行，当前引擎快照）

| # | 位置 | 改动 | 状态 |
|---|---|---|---|
| A1 | nn_conv_engine.sv:158 | ad_r_bad = f_add_r && !(is_add \|\| is_conv) | 完成 |
| A2 | nn_conv_engine.sv:151 | cr_p3_bad 增加 f_add_r（PACKED3 与 add-mode 互斥） | 完成 |
| A4 | 状态枚举 :89 / 声明 :335-372（fad_active,fad_zp_d,fad_kadd,fad_r,ad_cap + fad_word()）/ a 口 mux :552-558 / S_DRN→S_ADRD :1255 / S_ADRD 状态 :1259-1274 / Q tail 参数 :1082-1085 / 复位+latch :706,:890 | dst 字在 REQ 前经 a 口读入（16B/拍，复用现有 a 口、不新增端口），每块 +wrbeats+2 拍 | 完成 |
| A5 | S_REQ 写回 :558-600 | pay_lo/pay_hi 过 fad_word()：out=clamp(q_d+((q_s-zp_s)*R)>>KADD)，f_relu 时再夹下界 fad_zp_d；16B/半字两种写模式都覆盖 | 完成 |
| - | Q 块 tail 扩展（向后兼容） | tail byte4=zp_d、byte5=KADD、byte6..7=R(u16 LE)；旧 op 这 4B 恒 0 => 逐位不变 | 完成 |

### 2.7.2 证据（全部机器可判定）

| 判据 | 结果 | 证据 |
|---|---|---|
| 旧 47 case 逐位/逐周期不变 | PASS：SUMMARY cases=47 pass=47 fail=0 total_mismatch=0 | .fpga-cache/logs/tb_nn_engine.log |
| M1 9 case 不变 | PASS：M1SUMMARY cases=9 pass=9 fail=0 mismatch=0 | 同上 |
| 新增 2 个 conv+add case | PASS：SASUMMARY cases=2 pass=2 fail=0 mismatch=0；sa_cvadd_nr cyc=225、sa_cvadd_rl cyc=589 | 同上 |
| 总判据 | PASS：ENGINE_TB: PASS (58 cases, mismatch=0) | 同上 |
| 有牙齿负向对照 | 用 fad_active<=0（模拟 A1/A2-only）跑同一 TB：SASUMMARY cases=2 pass=0 fail=2 mismatch=292，sa_cvadd_nr 周期 225→185（少 4 块×10 拍，证明新状态真在跑）；旧 47+9 仍 PASS；恢复后复测 PASS | 负向对照运行日志 |
| YOLO E2E 红线 | PASS：hw_bad=0、auto_bad=0、npu_cycles=1,191,020（与基线完全相同）、RESULT : PASS | .fpga-cache/logs/tb_sw_nn_yolo.log（hw_bad=0 hw_cycles=10469260 npu_cycles=1191020） |
| 每块周期代价实测 | +10 拍/块（wrbeats 8 + 2），与 NPU-PERF-P1A-FUSION.md 的每块 +8~16 拍/全模型 ≈188k 拍一致 | 225−185=40 拍 / 4 块 |

### 2.7.3 语义对齐（rtl-engine 的 plain ADD zp_s 修正）

fad_word() 的累加域与 v0.8 的 ADD/ADD_R 语义完全一致：out = clamp(q_d + ((q_s - zp_s)*R)>>KADD)，其中 q_s = conv requant 后的 int8（先 round 再累加，不是 32-bit acc），zp_s = conv 输出 zero-point（Q tail byte0），zp_d = 目标张量 zero-point（tail byte4），KADD/R 从 tail byte5/byte6..7 取。**不复用 zp_s_r**，避免 v0.8 修的跨 op 泄漏问题复发。

### 2.7.4 下一步（Step A 剩余项）

| 项 | 状态 | 说明 |
|---|---|---|
| A7 dw 专用通路（行缓冲 + 16 lane） | 待做 | 会改变 dw case 周期期望，需同步更新 TB 周期断言 |
| A8 行缓冲/地址（B×0.7） | 待做 | 同上 |
| converter 融合 plan（106→83） | 待 converter | 到了做全模型对账（--scenario p1 = 32.63M 拍） |
| SA case 开关 | 默认启用（已 PASS：ENGINE_TB: PASS (58 cases)） | 若需临时关闭，把 TB 里两行 m1_run_conv_add 用 ifdef 包起来即可 |

---

## 2.8 A5e 最终交付事实（2026-11-04 晚）· 覆盖 §2.7 的早期时序数字

### 2.8.1 最终实现（三级流水，OOC 有余量）

| 项 | 实现 |
|---|---|
| dst 读 | `S_ADRD`：`S_REQ` 前经现有 a 口读 dst 字（16B/拍），`wrbeats+2` 拍/块 |
| delta L1a | `fad_l1a`（c_p 6..13）：`q_s - zp_s` → `fad_dv_lo/hi`（9b，打拍） |
| delta L1b | `fad_l1b`（c_p 7..14）：`* R >> KADD` → `fad_dlo/dhi`（25b，打拍） |
| 累加 L2 | `fad_l2`（c_p 8..15）：`fad_add()` = `clamp(q_d+delta)` + 可选 `max(·,zp_d)` → `fad_plo/phi` |
| 写回 | c_p 9..16：只做寄存器选择 → `b_wdata_q` |
| 写回延后 | `fad_off_w = 3`（fused）/ `0`（非融合，逐周期不变） |
| 融合代价 | **+13 拍/输出块** = `S_ADRD(8+2)` + 写回延后 3；半字尾块最多 +21 |

### 2.8.2 OOC 演进（引擎单独，122MHz = 8.182ns）

| 版本 | 改法 | slack | 关键路径 | LUT | FF | DSP |
|---|---|---|---|---|---|---|
| v1 (A5) | 乘法直接在写回路径 | **-6.494ns** | `c_p→ad_cap/out_lo→DSP→b_wdata_q` 14.6ns | 25,663 | 14,110 | 192 |
| v2 (A5b) | delta 打一拍 (+1/块) | -3.344ns | 11.5ns | 27,250 | 14,780 | 184 |
| v3 (A5c) | 两级流水 (+2/块) | -0.213ns | 8.36ns | 28,806 | 15,114 | 176 |
| **v4 (A5e，交付)** | **三级流水 (+3/块)** | **+1.125ns MET** | 6.77ns（`c_p→fad_phi`） | **28,801** | **14,884** | **184** |

> 结论：**Step A 的融合路径在 122MHz 有余量**（+1.125ns）；资源相对引擎 v0.8 基线约 +3.1K LUT / +0.8K FF / **0 DSP**（三级流水把乘法从 DSP 路径挪走，DSP 反而少 8）。
> 证据：`perf-proto/eng_a5_a5{,b,c,f,g}_122_{util,paths}.rpt`。

### 2.8.3 功能/回归证据（最终版）

| 判据 | 结果 |
|---|---|
| `tb_nn_engine` | **PASS 58 cases**（旧 47 + M1 9 + SA 2，total_mismatch=0） |
| SA 实测周期 | `sa_cvadd_nr cyc=237`、`sa_cvadd_rl cyc=601`（相对非融合 185：4 块 × 13 拍 ✓） |
| 有牙齿负向对照 | `fad_active<=0` 时 SA 2 case FAIL（mis=292），旧 47+9 PASS ✓ |
| YOLO E2E | `hw_bad=0 / auto_bad=0`，**`npu_cycles=1,191,020` 逐位不变** ✓ |
| 多 op 序列 | `tb_sw_nn_slim` 真实图阶段 71/71 逐 op FNV 全对（Lead 复核） |

### 2.8.4 融合收益/代价（模型口径，实测校准后）

| 项 | 数值 | 说明 |
|---|---:|---|
| 消除 20 add | -1,138,033 拍 | add/copy 的模型周期 |
| 融合代价 | **+142,597 拍** | 13 × 10,969 块（17 个融合 conv） |
| **净收益** | **-995,436 拍（-2.49%）** | p0 40,051,198 → **p1 32,719,099** |
| p1 帧率 | **3.06 / 3.74 / 4.58 fps** | @100/122.22/150MHz |
| P1+PX16 | **20,426,805 拍 = 5.98 fps@122** | 主目标 |

> 与早期假设的差异：融合代价从"假设 50,000 拍"修正为**实测 13 拍/块 = 142,597 拍**（`S_ADRD` 10 拍 + 写回延后 3 拍），因此 p1 从 32.61M 修正为 **32.72M**（仍 -18.3% vs p0）。
> 融合语义的精确口径（给 converter）见独立文档 `M6-FUSION-CONTRACT.md`。

---

## 2.9 A7（dw 专用通路）· 设计 + 周期预期（待实施）

> 现状：融合路径（A4/A5/A5e）已交付；A7 这一步**尚未改 RTL**（保证树绿）。本节是可执行的实施设计 + 改写前后周期预期。
> 基线快照：`results/bottlecap/reports/tb_nn_engine_cycles_before_a7.csv`（58 case 逐 case 周期，改完逐行对比）。

### 2.9.1 为什么要做 / 收益量化（cycle_model 实测口径）

| 档 | dw op 数 | dw 合计拍 | 占全模型 | **A7a（A/2 + C/2）收益** | A7b（B 行缓冲 ×0.62）收益 |
|---|---:|---:|---:|---:|---:|
| 瓶盖模型（106 op） | 17 | 4,785,178 | 11.9% | **-1,049,629（-2.62%）** | -1,365,000（-3.41%） |
| YOLO（112 op） | 28 | 462,102 | 39.1% | **-100,638（-8.51%）** | -131,800（-11.1%） |

> A7a = dw 阵列 8→16 lane（`A` 减半）+ 16B/像素写回（`C` 减半）；A7b = dw 行缓冲复用（每输出行只装一次，`B` ≈ ×0.62）。
> YOLO dw 占比 39%，所以 A7 在 YOLO 上的相对收益远高于瓶盖模型（Lead 要求 A7 后同时报 YOLO 新 npu_cycles）。

### 2.9.2 RTL 改动清单（当前引擎行号为锚，实施时以符号名重定位）

| # | 位置 | 现状 | 改为 | 影响 |
|---|---|---|---|---|
| A7-1 | `S_CPREP`（`ocw_r` 赋值） | `ocw_r <= dense ? 16 : 8` | `ocw_r <= is_pool ? 8 : 16` | dw 用 16 lane tile |
| A7-2 | `S_CPREP`（`oc_limit_r`） | dw 分支 `oc8_r >> 3` | `(oc8_r + 15) >> 4` | dw tile 数 = ceil(oc8/16) |
| A7-3 | `S_BI`（dw 的 `band_base/la`） | `blk_base + (c_ocb << 3)` | `(c_ocb << 4)` | 每 tile 16 通道偏移 |
| A7-4 | P_init 的同类偏移（第二处） | `blk_base + (c_ocb << 3)` | `(c_ocb << 4)` | 同上 |
| A7-5 | MAC `a_pipe` 装载 | dw：`(oc<8) ? win_sel[px][oc*8+:8] : 0` | dw 也取 `win_sel[px][oc*8+:8]` | lane 8..15 参与 MAC |
| A7-6 | MAC `wby_r` 装载 | `(dense || oc<8) ? ... : 0` | 同上放开 | 权重 lane 8..15 |
| A7-7 | 写回模式门控 | `wr_dense16 = dense && act_l==16`；`single16 = dense && ...` | 改为 `act_l==16 && ...`（含 dw） | dw 16B/像素单拍写回（C 减半） |
| A7-8 | Q 偏移推进（`q_bias_w/q_mpos_w`） | 已按 `ocw_r>>1 / >>2` 推进 | 无需改（确认即可） | 每 tile 的 Q 布局一致 |
| A7-9 | padding lane 饱和 | 现有 requant 屏蔽（`oc_base_w + l >= d_oc → zp_out`） | 确认 dw 路径也生效 | dw oc8%16≠0 时尾部 lane 必须写 zp_out |
| A7-10 | 行缓冲复用（A7b） | 每个 kx 重装 band | 行内保留 16B/px，按 ky 复用 | B ≈ ×0.62；只影响 dw |
| A7-11 | TB | 无 dw+16lane case | 新增 2 个：`sa_dw16_ic16`、`sa_dw16_ic72`（16B/像素写 + 尾部 lane padding） | 位精确 + 周期 |

### 2.9.3 周期口径与对账（Lead 红线）

- **数据位精确不变**：58 case `mismatch=0` + YOLO `hw_bad=0/auto_bad=0` 是硬门槛。
- **周期允许下降**，但：
  1. 报告给逐 case before/after 表（基线 CSV 已存）；
  2. `tb_nn_engine` 的期望周期用 cycle_model 公式重算后更新 —— 建议在 TB 里加轻量**周期断言**（`expected = cycles_of(desc)` 与 DUT 输出的 `cycles` 比较，误差 0），这样后续回归能抓非预期周期变化；
  3. YOLO E2E 记录新 `npu_cycles` 并给对账：预期 `new ≈ 1,191,020 − 100,638 ≈ 1,090,000`（A7a）；A7b 再减 ~131,800。
- **对 p1 目标的再基线（重要）**：Lead 采纳的 `p1 = 32,719,099` 里 dwpath 收益按"B,C,D ×0.38"算（2.89M）。按可实施口径：
  - A7a 只做 16 lane：**-1.05M** ⇒ p1 ≈ **34.56M**（3.54fps@122）
  - A7a+A7b：**-2.42M** ⇒ p1 ≈ **33.20M（3.68fps@122）**
  - 与 32.72M/3.74fps 的差 = 模型里 dwpath 把 `D` 也 ×0.38（实际 D 是控制/收尾拍，16 lane 后变化很小）。
  ⇒ 建议：**把 p1 权威值重新基线为 33.20M（A7a+A7b）**，或保留 32.72M 但把差值记进"剩余差距"。

### 2.9.4 实施顺序（下一步）

1. A7-1..A7-7 + A7-9（16 lane 数据通路）→ 跑 58 case + YOLO，出 before/after 周期表；
2. A7-10（行缓冲复用）→ 再跑一遍，更新 `cycle_model` 的 dwpath 分支为"实测口径"（A/2、C/2、B×实测系数），重算 p1/p2b；
3. TB 周期断言（A7-11 的一部分）→ 让回归能自动抓周期漂移。

---

## 3. Step B 设计（PX16：16 px × 16 OC lane = 256 MAC/拍）

### 3.1 改动清单（行号为当前 v0.8 快照）

| # | 位置 | 改动 | 规模 |
|---|---|---|---|
| **B1** | `:41-42` | `PX_LANES` 8→16（`OC_LANES` 保持 16）；`PIPE` 相关 localparam 复核 | 2 行 |
| **B2** | `:219-226,243-257` | `acc/a_pipe/a_pipe1/a_pipe2/prod/mx` 数组按 PX=16 展开（acc 16×16×32b = 8K FF）；`out_lo/out_hi` 保持每像素 16B（PX=16 → 16 个像素字） | ~10 行（参数化已具备） |
| **B3** | `:417-425` `win_sel`/`abuf`/`bshift` | 像素窗口 16 px：`abuf[0:15]`、`bshift` 2·16=32 深度；`p3_*` 步长按 `PX` 重算（`8*st*3` → `16*st*3` 相关项） | ~20 行 |
| **B4** | `:484-511` S_LD / `:1052-1105` | 每块装载拍 ×2（px 翻倍），地址按 16 px 推进；`band_step_a` 相关步长复核 | ~25 行 |
| **B5** | `:1137-1180` S_MAC | MAC 阵列 8→16 px（每拍 256 MAC）；`wby_r` 仍 16 lane（**W 读口 16B/拍不变**） | ~10 行 |
| **B6** | `:777-811` requant | **保持 16 lane 时分复用**（不要 32-lane）；PX16 下每块 requant 拍数 ×2（`wrbeats` 8→16 或 16→32） | ~15 行 |
| **B7** | `:511-542` S_REQ | 写回 beat 数 ×2；`wrs16_r`/半字逻辑复核 | ~10 行 |
| **B8** | `nn_tilecache`（新模块，rtl-mem/rtl-stream） | IBUF 读口 **32B/拍（256b）**；W 口不变 | 见 `NPU-PERF-OC32-REVISION.md §3.1 X2` |
| **B9** | `sim/tb_nn_engine.sv` | case 向量扩到 16 px；旧 case 逐位不变 | ~100 行 |

### 3.2 资源/时序（已有 OOC 直接证据，见 §4）

- **PX16 配置实测（OOC，150MHz 约束）**：LUT **6,468** / FF **3,027**（下界）/ DSP **192** / BRAM 0 → **fmax ≈150.9MHz，WNS@150 = +0.039 MET**。
- 相对 128 基线探针：**+4,281 LUT / +1,274 FF / +32 DSP**。
- 外推整机（当前 LUT 36,985 / FF 16,381 / DSP 168）：**LUT ≈41K（65%）/ FF ≈21~22K / DSP 200/240（83%）** ⇒ 满足 task-14 判据（LUT ≤45K、DSP ≤200）。
- **W 读口 16B/拍不变** ⇒ rtl-mem 的 2×160KiB 双银行、rtl-stream 的 `nn_wload` **零返工**（Lead 已确认）。

### 3.3 Step B 判据

1. OOC @122MHz **WNS ≥ +0.2**（探针在 150MHz 都 +0.039，122MHz 有余量；若不足，按 §4 的 requant 路径治理）。
2. 整机 LUT ≤45K、DSP ≤200、BRAM 不变（132）。
3. `cycle_model --scenario p2b` → **20,426,805 拍**；实测误差 ≤2%。
4. YOLO E2E `hw_bad=0 / auto_bad=0`（位精确）；瓶盖 E2E 同。

---

## 4. OOC 证据（已有，`perf-proto/`）

| 配置 | LUT | FF | DSP | fmax_est | WNS@150 |
|---|---:|---:|---:|---:|---:|
| p128 基线 | 2,187 | 1,753 | 160 | 151.2 | +0.055 |
| p192 OC24 | 5,036 | 2,413 | 152 | 150.9 | +0.039 |
| **p256 PX16（Step B 对应）** | **6,468** | **3,027** | **192** | **150.9** | **+0.039** |
| p256 OC32 | 6,951 | 3,606 | 192 | 150.9 | +0.039 |
| p256 OC32 + 32-lane requant | 8,077 | 3,742 | 224 | 151.2 | +0.055 |

- **结论**：MAC 加宽不是时序瓶颈；最差路径是 **requant 17×16 DSP 输出（6.596ns/6 级）**。若 Step B 后 122MHz 仍紧张，优先把 requant 的移位/饱和再切一级（+1 拍/块）。
- **注意**：探针无控制逻辑，fmax 为乐观上界；真实 150MHz 风险在 route（`wa_r→W` 8.88ns，`DELIVERY §9.2.1`）。

---

### 4.1 Step A 专用：conv add-mode 数据通路探针（新增，2026-11-04）

`perf-proto/addmode_probe.sv` + `run_addmode.tcl`（16 lane 时间复用；`use_dsp="no"` 的 ADD_R 乘，与引擎现状一致）：

| 配置 | LUT | FF | DSP | fmax_est | WNS@122 | WNS@150 | 最差路径 |
|---|---:|---:|---:|---:|---:|---:|---|
| `addmode_top_noadd`（现状 requant 直写） | **121** | 198 | 32 | 157.5MHz | +1.832 | +0.317 | `qs_reg`（requant 后级） |
| `addmode_top_add`（ADD_R 累加 + 后置 ReLU） | **278** | 233 | **32** | **157.5MHz** | +1.832 | +0.317 | `qs_reg`（同上） |
| **增量（Step A 硬件代价）** | **+157 LUT** | **+35 FF** | **+0 DSP** | **0（不变）** | 0 | 0 | add 逻辑不在关键路径 |

- 结论：**conv add-mode 的硬件代价可以忽略（+157 LUT / +35 FF / 0 DSP，fmax 不变）**——因为 v0.8 引擎已有 ADD_R 数据通路（`:388-441`），实际增量只是"接进 conv 写回 + 放开合法性"。
- 探针证据：`perf-proto/addmode_*_{util,paths}.rpt`、`addmode_results.json`、`addmode_*.log`。

---

## 5. 方法论固化（Lead 要求）

**后续所有 RTL 改动的第一步 = 跑 `cycle_model` 四分法，再动手。**

```
1) python tools/bottlecap/cycle_model.py --self-check          # 基线未被破坏（两个基线都断言）
2) python tools/bottlecap/cycle_model.py --scenario all --json out.json
   → 看 A/B/C/D 四分量：改动打的是哪一项？预期的 Δ 是多少？
3) 只做"Δ/代价 比"最高的一项；每落地一项就重跑模型并与实测 E2E 拍数对账（±2%）
4) 若实测与模型差 >2%：先怀疑模型的假设（如 padding/beats/PACKED3），不要先怀疑 RTL
```
**A5e 实战教训（RTL 侧，务必固化）**：
1. `(* use_dsp = "no" *)` 写在 **function 内部变量**上 Vivado 2018.3 不认，乘法仍进 DSP48 且变成关键路径；要么写模块级 always_comb + 属性，要么流水化。
2. Verilog 的 `+`/`*`/`>>`：**只要有一个操作数是 unsigned，整个表达式按 unsigned 算**。`(qd_w[l*8+:8]) + dv` 漏 `$signed()` 会把负 q_d 当无符号 → 全部饱和到 127；这次三级流水"功能失败"的真正根因就是这个（不是流水本身），补 `$signed()` 后逐位精确。
3. 关键路径优化顺序：**先拆流水级（+1 拍/块）再看 OOC**，比在单拍里改结构收益大得多（-6.494ns → +1.125ns，代价仅 +3 拍/块）。

本次的三个"模型先行"收益：① 拆出 B 占 33.9%（于是行缓冲优先级 > 加宽阵列）；② 修正 OC padding（于是 PX16 反超 OC32）；③ 修正 PACKED3（基线 +0.40%，并用 YOLO 实测互证 +0.12%）。

---

## 6. 剩余差距 / 风险

| # | 项 | 影响 | 计划 |
|---|---|---|---|
| R1 | `engine green light` 未到 | Step A/B 代码不能动 | 本文档 + `perf-proto` 原型就绪；green light 后按 §2.2/§3.1 顺序落地 |
| R2 | v0.8 引擎正在被 rtl-engine 改（`f_relu`/ADD 路径已变） | 行号会漂移 | 落地时以"函数/状态名"为锚（S_REQ/S_ADRD/S_MAC），行号仅作当前快照 |
| R3 | 探针无控制逻辑 | OOC fmax 偏乐观 | 全实现（`DELIVERY §9.2.1` 方法）复验；必要时先补"带控制的最小引擎"探针 |
| R4 | Step A 的 dst 读代价可能被低估 | 融合净收益 2.4% → 可能 1.5% | A1~A4 先做"单 op 原型 + `tb_nn_engine` 测周期"，再全量 |
| R5 | 瓶盖模型 E2E 尚未就绪 | 只能用 YOLO E2E 做判据 | YOLO 位精确 + 周期对账已足够作为 Step A/B 门槛 |
| R6 | 权重/Q 银行（M2）与引擎并行改动 | 冲突 | 引擎改动只在 `nn_conv_engine.sv`；`nn_mem/nn_pkg/nn_seq/nn_subsys` 不碰（task-14 纪律） |

---

## 7. Green light 后的执行顺序（已排好）

1. **A1+A2+A3**（放开合法性，~10 行）→ 编译通过 + 旧 case 回归。
2. **A4+A5**（S_ADRD + S_REQ 累加，~55 行）→ `tb_nn_engine` 新增 conv+add case 位精确。
3. **A7 dw 专用** → `--scenario dw` 对账。
4. **A8 行缓冲/地址** → `--scenario lb` 对账；此时 p1 应到 **32,719,099 拍**。
5. **A9 TB + 融合 plan（converter）** → YOLO E2E `npu_cycles` 对账；**send_message 报 Step A 完成**。
6. **B1~B7**（PX16 数据通路）→ OOC @122MHz WNS 检查 → **B8** tilecache 32B/拍 → **B9** TB → 瓶盖/YOLO E2E 对账（20,426,805 拍）→ **send_message 报 Step B 完成**。

## 附录 C · fused_a（101 op）plan 的周期口径（已与 converter 对齐，2026-11-04）

cycle_model 已支持**按 plan 的 used_add 标记**识别融合（不再靠 add 映射猜测），--scenario p1_rtl = 当前 RTL 特性集（只有融合）。

| 口径 | 命令 | 拍数 | @122.22 fps |
|---|---|---:|---:|
| 未融合原 plan p0 | --plan plan.json --scenario p0 | 40,051,198 | 3.05 |
| **fused_a plan（101 op）p0** | --plan fused_a/plan.json --scenario p0 | 39,722,608 | 3.08 |
| **当前 RTL（A4/A5e 融合，A7/A8 未落地）** | --plan fused_a/plan.json --scenario p1_rtl | **39,783,123** | 3.07 |
| 全特性（融合 + A7a + A7b + bopt） | --plan fused_a/plan.json --scenario p1 | **33,924,318** | **3.60** |
| 全特性 + PX16 | --plan fused_a/plan.json --scenario p2b | **21,450,724** | **5.70** |

- 与 converter 独立算的 39,783,123 / 33,924,135 一致（差 183 拍 = dwpath 模型取整，0.0005%）。
- **Step B 口径修正**：P1+PX16 由早期 20.9M → **21.45M（5.70fps@122）**（因为 fused plan 只有 5 个 add 可融，且 PX16 下融合代价随块数变化）。
- --self-check 仍 PASS（原 plan p0 = 40,051,198 不变）。
