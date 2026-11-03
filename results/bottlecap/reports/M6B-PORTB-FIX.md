# M6B — portB/并发填充假设的证伪 + 尾部 X 根因（`nn_mem` 零改动）

> 作者：`rtl-mem`（task-19）。日期：2026-11-04（Asia/Shanghai）。
> 结论摘要：**本轮 M6b 的 op1/op3 FAIL 与 `nn_mem` 无关**——ROM 控制实验（`w_mode=0`，无 fill/无 bank）与 stream 模式**逐字节相同**也 FAIL；尾部 X 是**引擎最后一个 b 写拍的数据本身为 X**，不是 `nn_mem` 的 W/Q 读写，也不是 tilecache 落盘丢失。
> 因此按 Lead 2026-11-04 指示：**`nn_mem.sv` 零行为改动**（rtl-stream 正在 debug，不能同时动 `w_mode=0/1` 逐位行为），本报告只交付：① 证伪证据；② 尾部 X 的根因与修复建议（归属引擎/tilecache）；③ 未来 `nn_seq` 边算边填的约束清单。

---

## 0. 一句话结论（三条，全部有实验支撑）

| # | 原假设 | 实验结论 | 影响 |
|---|---|---|---|
| 1 | 并发填充（nn_wload 写 portB）+ 引擎读 → 采样 0/旧值/撕裂 → dense op 数值全错 | **证伪**。M6b 每个 op 的时序是 *prefetch→pre_done→翻 bank→band fill→engine start*，**fill 与引擎读无并发**；且 `+rom_mode`（w_mode=0，完全绕开 portB/bank/fill）与 stream 模式 **FNV 相同、op3 dump 逐字节相同**（op0 两种模式都 PASS） | `nn_mem` 不背锅；portB 仲裁不是 M6b 卡点 |
| 2 | 引擎输出里的 X 来自 RAM read-during-write（同址同拍读写返回 X） | **证伪**。RTL 模型下同址读写是确定的（非阻塞读旧值）。尾部 X 的**最终根因（§8 纯净室实验修正）**：tilecache 对输入 tensor 尾部越界 8B 返回 X（§2.4）→ 引擎最后一个像素的部分通道吃 X → 该像素所有 OC 累加器变 X → 末拍 b 数据全 X；**同一引擎在纯净室（A 由 nn_mem 直接供、无 tilecache）全张量 op3 与 golden 逐字一致（含最后像素）**，证明引擎 b 流水无 bug | 修复归属：`nn_tilecache` a 侧越界钳位/尾拍补 0（P0）；引擎可不做改动 |
| 3 | X 是失配主因（2 word X → 96% 失配） | **证伪**。op3：X 2/200,704 word；op1：X 8/802,816 word；失配 96% | 失配是另一个问题：纯净室 op3（同引擎/W/Q/A 张量）**完全 PASS** ⇒ 剩余差异只在 M6b 的 tilecache A/B 通路（§8.4） |

**`nn_mem` 语义状态**：默认参数/端口/契约**未改**（`tb_nn_mem` + `tb_nn_engine` 回归 PASS）。本轮只为 TB 大张量实验增加了**非常规参数下才生效**的 act 索引分支（默认配置常数剪枝，§8.3），属内部实现，不改变 `w_mode=0/1` 与 A/B 契约。

---

## 1. 关键实验：ROM 控制实验（推翻假设 1）

M6b TB `sim/tb_bottlecap_ddr_chain.sv` 自带 `+rom_mode`：跳过 stream bank，用 dbg 口把本层 W/Q 写进 `nn_mem` ROM 区（`w_mode=0`），引擎读地址不变。**若失配来自 fill/portB/bank，ROM 模式必须 PASS**。

### 1.1 FNV 对照（同一份数据/同一引擎/同一 tilecache）

| 运行 | 模式 | FNV（实测） | plan 期望 | 判定 |
|---|---|---|---|---|
| ISO op0（PACKED3 224×224×3→112×112×16） | stream | `0xcb19ba31` | `0xcb19ba31` | **PASS** |
| ISO op0 | ROM（`+rom_mode`） | `0xcb19ba31` | `0xcb19ba31` | **PASS** |
| ISO op1（dense 1×1 112×112×16→64） | stream | `0x99e2f7a2` | `0xe34a56bf` | FAIL |
| ISO op1 | **ROM** | **`0x99e2f7a2`** | `0xe34a56bf` | **FAIL（与 stream 逐位相同）** |
| ISO op3（dense 1×1 112×112×64→16） | stream | `0x80c2ee49` | `0x4c6dd7d1` | FAIL |
| ISO op3 | **ROM** | **`0x80c2ee49`** | `0x4c6dd7d1` | **FAIL（与 stream 逐位相同）** |

### 1.2 更强的一条：op3 dump 逐字节相同

`results/bottlecap/proto/m6b_data/engine_op003_dump.hex`（Lead 的 stream 模式 dump）与本轮 `+rom_mode +dump_out` 产生的 dump 做 `Compare-Object`：**0 处差异**（含两处 `xxxxxxxxxxxxxxxx` 完全相同）。即 stream 与 ROM 两种存储路径下，引擎看到的 W/Q 完全等价、输出完全等价。

### 1.3 端口级核验（`+dbg`）

| 检查 | 结果 |
|---|---|
| op1 W bank 内容 vs W 流镜像（逐 64b 字） | `W words=128 bad=0` |
| op1 Q shadow bank 内容 vs Q 流镜像 | `Q words=50 bad=0` |
| op1 引擎 W 读数据 vs 期望（2 拍延迟采样，前 6 笔） | `[WDBG] #1..#6 … OK`（地址 0,0x40,0x80,0xc0,0x100,0x140，数据逐位对） |
| op3 引擎 Q 读数据（q_addr 0..12） | `[QDBG] … OK`（bias/M_pos/SHIFT/tail 全对） |
| op1 a 侧读（tilecache→引擎） | `a-reads=100352 bad=4`（4 笔全部在 tensor 最后一个 8B 窗口，见 §2） |
| b 写拍数 | op1 `50176`、op3 `12544` = 输出字节/16，**一笔不少** |
| 引擎周期 vs cycle_model | +2 拍固定开销（0.00%），**无 bubble**（内存没插拍） |

⇒ 引擎的 W/Q/A 三个输入都已被独立核验为正确；`nn_mem` 的 stream 路径与 ROM 路径输出等价。**失配发生在 nn_mem 之外**。

---

## 2. 尾部 X：根因 = tilecache a 侧尾窗口返回 X → 引擎最后像素全 X（不是 flush 竞争、不是引擎 b 流水 bug）

### 2.1 现象精确定位

| op | dump 中 X 位置 | 对应字节 | 含义 |
|---|---|---|---|
| op3 | word `25086..25087` | 200,688..200,703 = 输出最后 16B | 最后 1 个像素（oc_pad=16 → 16B/像素） |
| op1 | word `100344..100351` | 802,752..802,815 = 输出最后 64B | 最后 1 个像素 × 4 个 OC-tile 槽（每 pass 末拍一行） |

**ROM 模式 op3 dump 的 X 位置完全相同**（2 个 word，25087/25088 行）→ 与 W/Q 存储路径无关。

### 2.2 监视器实测（临时 TB 副本，放在 `%TEMP%`，**未改仓库文件**）

在 TB 副本里加监视器：记录引擎 `b_we/b_addr/b_wstrb/b_wdata_128` 的最后 8 拍 + OBUF/arena 末尾内容。实测（`+iso_op=3 +dbg`）：

```
# [MON] eng_done_seen=1 b_beats_total=12544
# [MON] last b_we[6] addr=0a8fe0 strb=ffff data=31c21ad7def7d4c3d5af12bef9efee19      <- 有效数据
# [MON] last b_we[7] addr=0a8ff0 strb=ffff data=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx      <- 最后一拍全 X
# [MON] OBUF1 last: 31c2...  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx                        <- OBUF 存的就是引擎给的数据(X)
# [MON] ARENA last: xxxxxxxxxxxxxxxx xxxxxxxxxxxxxxxx
```

op1 同样：`b_beats_total=50176`，`last b_we[7] addr=13bff0 data=xxxxxxxx…`（前 7 拍都是有效数据）。

⇒ 观测到的直接现象是"引擎端口最后 b 拍数据全 X"；但 §8 的纯净室实验证明这**不是引擎流水 bug**，而是**下游症状**：a 侧尾窗口读回 X（§2.4）→ 最后一个像素的部分输入通道为 X → 该像素全部 OC 累加器为 X → 末拍 b 数据整 128b 全 X。tilecache OBUF/落盘只是忠实转发（也排除了"flush 提前读"，否则 OBUF 里应是有效数据、只有 DDR 读出 X）。

### 2.3 为什么 X 正好覆盖"最后像素"（op1 出现 4 个 16B 槽）

op1 的 b 写顺序是 **OC-tile-major**（pass tile0 写所有像素的通道 0..15，再 pass tile1 …，`b_addr` 步进 0x40=64B 已由 `[DBG] b_we` 证实）。最后像素要写 4 个 OC-tile 槽（共 64B），所以 X 恰好是 4 个 16B beat（8 个 64b word）。op3 只有 1 个 OC tile → 只有 1 个 16B beat（2 word）X。两者都与"最后像素"对齐，与 pass 次数无关。

机理（与 §2.4 的 a 尾窗口对应）：引擎最后一个像素的高半通道读到 X → 该像素的**所有 16 个 OC 累加器**都含 X 项 → 该像素每个 OC-tile 的 16 字节输出全 X。§8 中同一引擎、同一 W/Q、同一 A 张量（A 由 nn_mem 直接提供、无越界）在纯净室全张量 op3 输出与 golden **逐字一致（mis=0，含最后像素）** ⇒ 引擎/量化语义无 bug。

### 2.4 根因（P0）：a 侧尾部越界读返回 X（tilecache 侧）

`[ADBG]` 在 op1/op3 各报 1 笔坏 a 读（仅此 1 笔，其余 100,348/100,352 全对）：

```
op1: loc=030ff8  tile=xxxxxxxxxxxxxxxx808db686ae80b480 exp=0000000000000000808db686ae80b480
op3: loc=0c3ff8  tile=xxxxxxxxxxxxxxxx9980808088808b8a exp=00000000000000009980808088808b8a
```
即：读地址落在输入 tensor **最后一个 8B 窗口**，窗口高 8B 越过了有效数据末尾，tilecache 返回 X（期望 0/pad）。这正是"最后像素高半通道"的输入来源（§2.3 机理）。这是"IBUF 尾部补齐/越界钳位"问题，属 `nn_tilecache`。

### 2.5 修复建议（归属 rtl-stream；引擎可不改）

| 优先级 | 修复 | 位置 | 判据 |
|---|---|---|---|
| **P0** | tilecache a 读对越界字节返回 0（或 zp_in 语义的 pad 值）；IBUF fill 尾拍把未覆盖字节补 0 | `nn_tilecache.sv`（owner: rtl-stream） | `[ADBG] bad a-read = 0`；M6b dump 中 X word = 0 |
| P1（可选防御） | 引擎对 `la` 越过 ih*iw 的 8B 半窗做屏蔽（当前正确性依赖上游不返回 X） | `nn_conv_engine.sv`（owner: ddr3-feas） | 仅作为防御，不阻塞 |
| — | `nn_mem` 无对应修改点：W/Q 是整 64b 字，不存在"部分字节越界"；b 路径不经过 `nn_mem` | — | — |

---

## 3. 为什么 `nn_mem` 当前架构在"边算边填"下也不需要仲裁（设计论证）

Lead 提出的"读优先 + 2 深 skid FIFO + bank fence"在本架构下**收益为零、风险非零**，本轮不实施。理由：

1. **fill 目标 = `~w_bank_sel`（硬件固定）**；引擎读 = 活动银行。阵列归属：
   - bank0 = `a[0..16383]` + `b[0..4095]`（a 完整 + b 低半）
   - bank1 = `b[4096..8191]` + `c` + `d`
   - fill bank0 只写 a（单层 ≤128KiB 时）；此时引擎读 bank1 的 b/c/d；fill bank1 只写 b 高半/c/d；此时引擎读 bank0 的 a ⇒ **同拍不存在对同一阵列的读写**。
2. 唯一共享阵列 b：bank0 读 b 半区只出现在 `wi ≥ 16384`（即层内偏移 ≥128KiB），而 **单层 wlen ≤ 131,072 B** 的约束（M2 已定，瓶盖模型最大层 124,416 B）保证不会走到；`b` 的写读相位由 bank 互斥。
3. 端口数：每段 = 1 只读口 + 1 读写同址口 = **2 个 BRAM 访问口**（OOC 实测 119.5 tiles，见 M2-NNMEM.md §7）；若加"读优先 mux + skid"，多路选择进 BRAM 地址路径，有再次被 Vivado 判 3 端口→复制成 160 tiles 的风险，而 M6b 里并不存在需要仲裁的并发。
4. 本轮不动 `nn_mem` 行为是 Lead 明确要求（rtl-stream debug 期间保持 `w_mode=0/1` 逐位基线）。

### 3.1 未来 `nn_seq`/`nn_wload` "边算边填"必须遵守的约束（交接给 npu-spec / rtl-stream）

| # | 约束 | 原因 |
|---|---|---|
| C1 | 单层 `pre_wlen ≤ 131,072 B`（128KiB），`pre_qlen ≤ 8,192 B` | 共享 b 段 portB；Q 影子银行容量 |
| C2 | `wfill_*` 只写非活动银行（硬件自动 `~w_bank_sel`，调用方**不要**再带 bank 位） | 保证读/写阵列互斥 |
| C3 | bank 翻转（`w_bank_sel`/`q_bank_sel`）只在 `pre_done` 之后；翻转后 ≥2 拍再发本 bank 的引擎读 | 避免填一半的层被读 |
| C4 | **禁止在 fill 进行中翻转 bank** | 否则 fill 目标银行突变，写错 bank |
| C5 | `q_bank_sel` 与 `w_bank_sel` 必须同步翻转（同一拍或 w 先 q 后 ≤1 拍） | Q 与 W 属于同一层 |
| C6 | 若将来出现"必须同 bank 并发 fill+read"的需求（如 P2 OC32 4 银行），必须重做 portB 仲裁（读优先 + 有 backpressure 的 skid），当前 2 银行不需要 | 架构前提 |

---

## 4. 已试/已排除的修复方案（避免后人重踩）

| 方案 | 状态 | 结论 |
|---|---|---|
| 读优先 `wfill_we_eff = wfill_we && !w_re_q` + 2 深 skid FIFO | **未实施**（Lead 指示可只修 X） | 若实施：nn_wload 无 ready 信号，引擎长读期间 >2 拍会丢写，必须同步给 nn_wload 加 backpressure；且 M6b 无并发，收益 0 |
| 地址冲突检测（fill 地址 vs 读 2 拍窗口） | **未实施** | 同上，且 4 段地址映射比较器代价不小 |
| bank 翻转 fence | **未实施（属集成侧 nn_seq）** | 已作为 C3/C4 约束交接 |
| RAM 同址读写 X | **不存在**（RTL 非阻塞语义读旧值；X 实为引擎 b 数据） | 见 §2 |
| 在 `nn_mem` initial 里给 W/Q 补零初始化 | **不需要**（M2 已有 `ifndef SYNTHESIS` 全阵列零初始化；X 不是未初始化 RAM） | 见 §2.2 |

---

## 5. 失配（96%）的剩余线索（**已因 §8 纯净室实验收窄：引擎+W/Q+A 张量本身是正确的**）

§8 的纯净室实验（`tb_nn_engine` + stock `nn_mem` 供 A/B，op3 全张量 A=802,816 B）**输出与 converter golden 逐字一致（mis=0，cyc=249,337=cycle_model）**。因此：
- 引擎 dense 路径（k=1 / ic=64 多 icb / oc=16）**无问题**；
- plan 的 W/Q/量化语义 **无问题**；
- 全量 A 张量数值 **无问题**（nn_mem A 区直接供数）。
⇒ 96% 失配只可能出在 **M6b 的 tilecache A/B 数据通路或该 TB 的地址/时序接线**（A 侧除尾部 1 笔外均已由 `[ADBG]` 验证正确；B 侧 OBUF/flush 的地址映射尚未逐笔核验）。建议 rtl-stream 用纯净室结果做对照：把 tilecache A/B 通路换成"直接 nn_mem"即可复现 PASS，从而把 bug 锁在 tilecache 内。

此前记录的失败特征（仍有效，供定位）：输出从**第一拍 b 写就错**（op1 `b_we #1`）；不是空间置换/平移（转置/翻转/x-shift 0 像素匹配）、不是简单语义 variant（14 种全部 ≥192k/200,704 失配）；op0（PACKED3）两种存储路径都 PASS。

---

## 6. 回归与交付状态

| 项 | 结果 |
|---|---|
| `nn_mem.sv` | 默认参数/端口/契约 **0 语义改动**；新增一条**仅非常规参数生效**的 act 索引分支（§8.3，默认配置常数剪枝） |
| `tb_nn_mem`（带 `+nnwq` 合成镜像，2026-11-04 01:02 复跑） | **PASS**：legacy **47,148 checks 逐项一致**（W FNV `0x7011972a`/`0x7011972a`、Q FNV `0xfd77f0ce`/`0xfd77f0ce` 与历史基线相同）+ stream 773 = 47,921 checks，mismatch=0 xerr=0 |
| `tb_nn_mem`（`verify --force --only tb_nn_mem`，无镜像口径） | **PASS**（815 checks = legacy 42 + stream 773） |
| `tb_nn_engine`（`verify --force --only tb_nn_engine`，参数化后默认配置） | **PASS**（47 manifest + M1 + SA，`ENGINE_TB: PASS`） |
| `tb_nn_wstream`（M3） | **PASS**（`verify --force --only tb_nn_wstream`，3.4 s） |
| M6b op0 | stream/ROM 双 PASS（`0xcb19ba31`） |
| M6b op1/op3 | FAIL，**与 `nn_mem` 无关**（§1/§2/§8.4） |
| 纯净室 op3 全张量（§8） | **PASS**：mis=0，cyc=249,337（= cycle_model） |

复现命令（ModelSim 2020.4，仓库根）：
```
# ISO op3 ROM 控制实验（关键证据）
vlib work
vlog -sv nn_pkg.sv nn_mem.sv nn_conv_engine.sv nn_wload.sv nn_tilecache.sv \
     sim/beh_ddr3.sv results/bottlecap/proto/nn_ddr_chain.sv sim/tb_bottlecap_ddr_chain.sv
vsim -c -do "run -all; quit -f" work.tb_bottlecap_ddr_chain \
  +ops=results/bottlecap/proto/m6b_data/ops.txt \
  +whex=results/bottlecap/stream/bottlecap/bottlecap_ddr_stream_w.hex \
  +qhex=results/bottlecap/stream/bottlecap/bottlecap_ddr_stream_q.hex \
  +inhex=results/bottlecap/proto/m6b_data/arena_input.hex \
  +golden_dir=results/bottlecap/proto/m6b_data \
  +iso_op=3 +iso_src=results/bottlecap/proto/m6b_data/golden_op002.hex +rom_mode +dump_out=<tmp>/op3_rom_dump.hex
# 对照：去掉 +rom_mode 重跑，FnV 与 dump 完全一致
```

---

## 7. 证据索引

| 证据 | 位置 |
|---|---|
| ROM vs stream FNV 对照（op0/op1/op3） | 本报告 §1.1；日志 `%TEMP%/m6b_run/iso1_rom.log`、`iso3_*` |
| op3 ROM dump vs stream dump 逐字节相同 | 本报告 §1.2（`Compare-Object` 0 差异；dump 在 `%TEMP%/m6b_run/`） |
| 引擎末拍 b 数据 X（MON）/ OBUF / a 侧越界 X | 本报告 §2.2/§2.4；临时 TB 副本与监视器在 `%TEMP%/m6b_run/tb_chain_mon.sv`（**未进仓库**） |
| W/Q bank 内容与读序列核验（WDBG/QDBG/DBG） | 本报告 §1.3；`%TEMP%/m6b_run/iso1.log`、`iso3_dbg.log` |
| M6b 失败特征（dump vs golden 分析） | 本报告 §5；分析脚本 `%TEMP%/m6b_analyze2.py` |
| `nn_mem` M2 设计/BRAM 证据 | `results/bottlecap/reports/M2-NNMEM.md` |
| 引擎 mem 契约（W/Q 固定 2 拍、无 backpressure） | `results/bottlecap/reports/M6B-ENGINE-DIAG.md` §1 |
| 纯净室 op3 全张量 PASS（§8） | 命令与输出见 §8.4；`tb_nn_engine` 的 op3iso block + `-gA_BYTES=802816 -gB_BYTES=262144` |

---

## 8. [2026-11-04 追加] `tb_nn_engine` 大张量支持（A/B 参数化）+ op3 纯净室结果

> 背景（Lead 指示）：协助 ddr3-feas 的 op3 仲裁实验；stock `nn_mem` 的 A 只有 96KB，装不下 op3 的 802,816 B 输入。本节给出参数化实现、dbg 口事实、以及纯净室实测结果（**引擎无 bug 的决定性证据**）。

### 8.1 改动清单（TB 侧 + nn_mem 内部非常规参数分支）

| 文件 | 改动 | 默认行为 |
|---|---|---|
| `sim/tb_nn_engine.sv` | ① `module tb_nn_engine #(parameter int A_BYTES=96*1024, parameter int B_BYTES=32*1024)`，`u_mem` 实例参数化；② 新增 `AB_BOFF = NN_A_OFF + A_BYTES`（默认 = 0x78000 = `NN_B_OFF`），op3iso 的 B 基址/回读改用它；③ op3iso 的 `desc.ih` 改用 `+op3rows`（默认 13 不变）；④ 修 op3iso 两个 4 态默认值 bug（不传 `+op3rows/+op3src` 时 `ROWS/srch` 为 X ⇒ 假失败）；⑤ 启动打印 `TB_CFG` 自证参数 | 默认参数下**逐位等价**，`verify --only tb_nn_engine` PASS |
| `nn_mem.sv` | act_mem 索引新增 `ACT_ABS_OK` 条件分支：默认参数走**绝对位选**（与 v0.7 相同）；当 A_BYTES/B_BYTES 覆盖导致 `A_OFF % ACT_BYTES != 0` 时改走**相对偏移** `((addr-A_OFF)>>4)`；启动打印 `ACT CONFIG ... idx=ABS-SLICE(default)/REL-OFFSET(big-A TB mode)` | **端口/契约/默认配置语义不变**；`ACT_ABS_OK` 是 elaboration 常数，默认配置综合时另一分支被剪枝（0 逻辑/0 时序影响） |

**为什么必须动 nn_mem 内部**：stock act_mem 用**绝对地址低位**索引（`addr[ACT_AW+3:4]`），其正确性依赖 `A_OFF(0x60000)` 是 `ACT_BYTES` 的整数倍。A 放大后 `B_OFF=0x124000`、`ACT_BYTES=1,064,960` 不再对齐，若仍用绝对位选会把 A 的高地址映射到数组外 → 读回 X（实测过：`got=xxxxxxxx`）。改成相对偏移后 A/B 任意 16B 对齐尺寸均可。

### 8.2 使用方法（ModelSim 2020.4，仓库根）

```bat
vsim -c -gA_BYTES=802816 -gB_BYTES=262144 -do "run -all; quit -f" work.tb_nn_engine ^
  +vec=results/ai-accel/proto/engine/vec ^
  +op3iso +op3rows=112 +op3src=00060000 ^
  +op3dir=results/bottlecap/proto/m6b_data/op3_iso
```
- 自证两行：`[nn_mem] ACT CONFIG ... idx=REL-OFFSET(big-A TB mode)`、`TB_CFG A_BYTES=802816 B_BYTES=262144 ... B_BASE=0x00124000`。
- **注意（预期副作用）**：放大参数时，stock manifest/M1/SA case 里把 B 放在 `NN_B_OFF(0x78000)` 的会因 B 区起点后移而失配；此时只看 `OP3ISO:` 判据（`ENGINE_TB: PASS` 不适用）。
- 13 行 band（A=93,184 B）在**默认参数**下即可 PASS，不需要覆盖参数（见 §8.4）。

### 8.3 dbg 口能力（回答 Lead 的"能否装载 802KB"）

- **dbg 口只映射 W/Q**（`dbg_space`: 0=W / 1=Q，写使能分别按 `W_WORDS`/`Q_WORDS` 限幅），**A/B 无法经 dbg 口装载**；dbg_addr 17-bit ⇒ 可寻址 512KB（W 320KB/Q 48KB 足够）。
- **A/B 只能走 CPU 窗口**。nn_mem 的 CPU 判决只有 `A_OFF <= addr < B_END`（**没有** 512KB `WIN` 上限门控；`WIN` 只用于仿真告警显示）。放大 `A_BYTES` 后 `B_END` 随之扩大，因此 CPU 窗口可覆盖并装载 802,816 B A 张量——本轮全张量 op3 case 实测装载 **200,704 个 32-bit 字 = 802,816 B 成功**（`OP3ISO: PASS` 即证明）。

### 8.4 实测结果（决定性）

| 配置（`tb_nn_engine` + op3iso block） | 结果 | 引擎周期 | 判据 |
|---|---|---:|---|
| stock 参数（A=96KB/B=32KB，**默认**）+ 13 行 band（A=93,184B） | **`OP3ISO: PASS`** mis=0 err=0 | 28,963 | 与 `op3_golden.hex` 逐字一致 |
| `-gA_BYTES=802816 -gB_BYTES=262144` + 13 行 band | **PASS** mis=0 | 28,963 | 同上 |
| `-gA_BYTES=802816 -gB_BYTES=262144` + **112 行全张量**（A=802,816 B、输出 200,704 B） | **PASS mis=0（50,176 字全对）** | **249,337** | = plan `exp_cycles` / cycle_model p0 逐位一致 |

⇒ **结论**：引擎 dense 路径（k=1、ic=64 多 icb、oc=16）+ plan W/Q + 全量 A 张量的数值是**位精确**的；M6b 的 op1/op3 失配因此只剩 **tilecache A/B 数据通路 / 该 TB 接线** 一个嫌疑方向（§5）；同时证伪了"引擎 pass 收尾 b 数据流水 bug"的初判——纯净室里同一引擎的末拍 b 数据与 golden 一致（`mis=0` 覆盖最后像素），M6b 的末拍 X 是 a 侧尾窗口 X 的下游症状（§2.4/§2.3）。

### 8.5 补充：Q 读契约排除（回应 ddr3-feas 的"Q 走 W 的 2 拍流水"假设）

ddr3-feas 提出"M6b 的 Q 可能走了 W 的 2 拍流水，导致 bias/M_pos/SHIFT 整体错位一字"。**该假设已被排除**，证据链：

| # | 证据 | 说明 |
|---|---|---|
| 1 | `nn_mem` Q 契约 = **1 拍**（`q_rd_lo <= q_mem_lo[...]`，`q_rd_valid_r <= q_re`），W = 2 拍（wpipe 输入寄存） | 两套流水本来就是分开的，没有共用通路 |
| 2 | 引擎侧：`q_re/q_addr` 是引擎寄存输出，mem 再 1 拍 ⇒ 内部 `q_iss-2`，与 1 拍 mem 精确配套 | `nn_conv_engine.sv:1076-1078` |
| 3 | **纯净室全张量 op3 PASS**：Q 走 `dbg → q_mem_lo → 引擎 qoff=0`（与 M6b ROM 模式**完全相同**的 Q 路径），bias/M_pos/SHIFT 全部来自 Q，输出与 golden **逐字一致** | §8.4 |
| 4 | M6b ROM 模式 Q 路径与纯净室相同却 FAIL ⇒ Q 不是失配原因 | §1.1 |
| 5 | M6b `[QDBG]`：op3 q_addr 0..12、op1 q_addr 0..7/32..35/48 每次读回数据与 Q 镜像**逐位一致** | `%TEMP%/m6b_run/iso3_dbg.log` / `iso1.log` |
| 6 | M6b wrapper 接线核查：`nn_ddr_chain.sv` 中 `w_re/w_addr/w_rdata` 与 `q_re/q_addr/q_rdata` **各自独立、无交叉** | `results/bottlecap/proto/nn_ddr_chain.sv:245-283,372-377` |

⇒ 若 Q 真错位一字，纯净室 op3 会立刻失败（bias 整体偏移），但它 PASS。M6b 剩余差异仍指向 **A/B 经 tilecache 的通路**：A 侧已由 `[ADBG]` 验证（除尾部 1 笔），**B 侧（OBUF 写 / flush 地址映射）尚未逐笔核验**，建议 rtl-stream 优先查 b 侧，并可用纯净室（B 直接写 nn_mem）作为逐拍对照参考。


