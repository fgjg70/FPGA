# M6b：瓶盖 2M 模型 DDR3 全链路（预取 + tile + 真引擎）仿真集成

> 作者：`rtl-stream`（task-15 / M6b）。日期：2026-11-04（Asia/Shanghai）。
> 状态：**链路/基础设施完成、周期账精确；逐 op 数值尚未位精确（进行中，根因已收敛）**。
> 定位：M6 全模型 E2E 的前置里程碑。本文给出接线图、数据准备、逐 op 周期表、已修复/剩余问题与下一步。
> 纪律：本任务**未修改** `nn_mem`/`nn_conv_engine`/`nn_subsys`/`nn_seq`/`nn_wload`；只改了我自己的 `nn_tilecache.sv`（回退风险已用 M3/M4 TB `--force` 回归证明：**PASS 2**）与我的 TB。

---

## 0. 结论摘要

| # | 事项 | 状态 | 证据 |
|---|---|---|---|
| 1 | DDR3 全链路串通 | ✅ 已完成：`beh_ddr3 → nn_wload → nn_mem(W/Q 双银行) → nn_tilecache(IBUF/OBUF) → 真 nn_conv_engine → flush 回 DDR3`，8 个真实 op 顺序执行 | §2、§4 |
| 2 | 逐 op **周期账** | ✅ **精确**：8 op 引擎实测 3,443,772 拍 vs `cycle_model.py` p0 **3,443,756**（+0.00%；逐 op 均 +2 拍）= 引擎被正确驱动、DMA/调度无饿死 | §4.2 |
| 3 | 金标资产 | ✅ 已接入：converter `opvec/pattern_v1`（23 op 张量 + `manifest.json`）+ `checksums.txt` FNV；输入 pattern_v1 复现 FNV = `0x33c513c5`（与 plan/opvec/checksums 三方一致） | §3 |
| 4 | 逐 op 数值位精确 | ⚠️ **进行中**：修复 3 个根因（附录 E：a 读延迟/BEAT_GAP 首拍/基准锁存顺序）后，**op0（conv0 PACKED3）已 FNV + 张量双判据 PASS**；op1..7 仍 mismatch，但已排除输入/W/Q/周期/写地址全部输入侧原因，嫌疑收敛到多 OC tile requant（附录 E.3） | 附录 E |
| 5 | 缓冲配置 | 采纳 Lead 裁决：瓶盖配置 **IBUF 2×32KiB + OBUF 2×12KiB**，M4 TB 默认仍 16K/12K；M4 新增 32K 配置 case，**7/7 PASS** | M4-TILECACHE 附录 C |
| 6 | 回归 | ✅ `verify --force --only tb_nn_tilecache tb_nn_wstream` → **PASS 2**（改动 `nn_tilecache` 后无回退） | §9 |
| 7 | 注册 | 未注册（TB 仍 FAIL）；PASS 后把 dict 发 Lead | — |

---

## 1. 交付物

| 文件 | 说明 |
|---|---|
| `sim/tb_bottlecap_ddr_chain.sv` | M6b TB（pass marker `BOTTLECAP_DDR_CHAIN_TB: PASS`；当前 FAIL，见 §4.3） |
| `results/bottlecap/proto/nn_ddr_chain.sv` | 接线 wrapper（test-only，不进 SoC 层次）：beh_ddr3 + nn_wload + 真 nn_mem + nn_tilecache + 真 nn_conv_engine + DDR 读通道 owner mux |
| `results/bottlecap/proto/gen_m6b_data.py` | 数据准备脚本（输入 pattern_v1 复现+Fnv 校验、ops 表、cycle_model 期望值、opvec 张量转 64b hex、FNV 交叉校验） |
| `results/bottlecap/proto/m6b_data/` | 生成数据：`arena_input.hex`、`ops.txt`、`golden_opNNN.hex`（23 个）、`golden_ops.txt`、`meta.json` |
| `results/bottlecap/proto/logs/tb_bottlecap_ddr_chain.log` | 最近一次 8-op 运行日志 |
| `results/bottlecap/reports/M6B-DDR-CHAIN.md` | 本文 |

---

## 2. 接线图（`results/bottlecap/proto/nn_ddr_chain.sv`）

```
                       +---------------------------------------------------------------+
                       | nn_ddr_chain (test-only wrapper)                              |
  TB(nn_seq) --pre_*-->|  nn_wload  ---wfill/qfill--->  nn_mem (w_mode=1, 2 banks)     |
                       |      | ddr_rd_*                  | w_re/q_re                  |
                       |      |                            v                            |
                       |  [DDR read owner mux] <-->  nn_conv_engine  <--- eng_desc/start|
                       |      |                            ^ a_*/b_*                    |
                       |  nn_tilecache  ---a_*/b_*--------+                             |
                       |      | dd_rd_* (fill) / dd_wr_* (flush)                         |
                       |      v                                                        |
                       |  beh_ddr3 (8 MiB, READ_LAT=40, BEAT_GAP=1)                    |
                       +---------------------------------------------------------------+
```

- **DDR 读通道 owner mux**：`nn_wload`（权重预取）与 `nn_tilecache`（激活 fill）共用一个 128b 读口；TB 保证二者不重叠（`ddr_rd_owner`：0=wload，1=tilecache）。写通道只由 tilecache flush 使用。
- **引擎端口零改动**：`w_re/w_addr/w_rdata`、`q_re/q_addr/q_rdata` ↔ nn_mem；`a_*/b_*` ↔ tilecache；`eng_desc/eng_start/eng_done/busy/cycles/err_code` ↔ TB。
- **DDR 地址映射（TB）**：W stream @ `0x0000_0000`（2,020,960 B）、Q stream @ `0x0020_0000`（90,368 B）、激活 arena @ `0x0040_0000`（plan 的 `arena_abs − 0x0100_0000`）、golden 张量 scratch @ `0x0070_0000`。
- **M6b v1 = 宽松缓冲**：`IBUF/OBUF = 2 MiB/银行`，**一个 band = 整张量**（fill 整个输入张量 → 引擎按 plan 描符跑整张量 → flush 整个输出张量）。这样 v1 不需要 band 循环，也不触发 M4 的 band 边界条件；banded 56/32 KiB 配置是下一步（§7）。
- **真引擎在 tile 模式的描述符**：`ih/iw/ic/oc/k/stride/pad` = plan 值；`src/dst/woff/qoff` 被替换为**地址基准**（见 §5.1）：src=0x02_0000（< `NN_B_OFF` ⇒ `a_sel=0`），dst=非 ADD 时同上、ADD 时=0x07_8000（≥ `NN_B_OFF` ⇒ `a_sel=1` 读 dst 操作数）；W/Q 用流式层内相对（woff=qoff=0）。

---

## 3. 数据准备（`gen_m6b_data.py`，全部校验通过）

| 项 | 数值/结果 |
|---|---|
| op0 输入 | `pattern_v1`（`(x*13+y*7+c*29+seed)&0xFF`, seed=12345），PACKED3 224×224×3；复现 FNV = **`0x33c513c5`**，与 `plan.input.csum`、`opvec/manifest.json`、`checksums.txt` **三方一致** |
| w/q 流式镜像 | `bottlecap_ddr_stream_w.hex` 2,020,960 B / `_q.hex` 90,368 B（M3 产物），按 plan `w_stream_offsets`/op 顺序偏移预取 |
| op 表 | 106 op 全量写入 `ops.txt`（含 geometry/arena 偏移/w_off/w_len/q_off/q_len/nn_op/nn_flags/csum/exp_cycles）；本批运行 **前 8 op**（op0..7） |
| 张量金标 | converter `opvec/pattern_v1` 共 **23 个 op 张量**，脚本逐块复算 FNV 与 plan csum **全部一致**；转成 64b/行 `golden_opNNN.hex` 供 TB 逐字节比对（arena 布局，含 pad 字节=zp_out） |
| flags 映射 | plan bit0/1/2/3/4（DW/LEAKY/PACKED3/ADD_R/RELU）→ nn_pkg bit0/1/5/6/7（converter 已确认） |
| 周期期望 | `cycle_model.py --packed3 auto` 的 p0 逐 op 值写入 ops.txt（8 op 合计 3,443,756） |

本批 op（覆盖要求：conv0 PACKED3 / dense k1s1 / dwconv k3s1 / ADD_R）：
`op0 conv k3s2 PACKED3+RELU`、`op1 conv k1s1`、`op2 dwconv k3s1`、`op3 conv k1s1`、`op4 ADD_R`、`op5 conv k1s1`、`op6 dwconv k3s1`、`op7 conv k1s1`。
（Lead 修正：本模型无 dense conv k3s2；stride2 由 op0 PACKED3 与 op10 dwconv k3s2 覆盖，后续批次补 op9/10/21。）

---

## 4. 运行结果（8 op，日志 `proto/logs/tb_bottlecap_ddr_chain.log`）

### 4.1 逐 op 数据流结果

| op | kind | fill cycles | engine cycles（实测/模型） | flush cycles | FNV |
|---:|---|---:|---|---:|---|
| 0 | conv0 PACKED3 | 28,449 | 398,299 / 398,297 | 12,769 | mismatch |
| 1 | conv k1s1 | 29,905 | 357,582 / 357,580 | 50,401 | mismatch |
| 2 | dwconv k3s1 | 105,169 | 853,090 / 853,088 | 50,401 | mismatch |
| 3 | conv k1s1 | 105,169 | 249,339 / 249,337 | 12,769 | mismatch |
| 4 | ADD_R | 59,809 | 125,451 / 125,449 | 12,769 | mismatch |
| 5 | conv k1s1 | 29,905 | 357,582 / 357,580 | 50,401 | mismatch |
| 6 | dwconv k3s1 | 105,169 | 853,090 / 853,088 | 50,401 | mismatch |
| 7 | conv k1s1 | 105,169 | 249,339 / 249,337 | 12,769 | mismatch |

### 4.2 周期账（引擎不被饿死：BEAT_GAP=1）

| 指标 | 实测 |
|---|---:|
| 权重/Q 预取（8 层合计） | 1,903 拍 |
| 激活 fill 合计 | 568,744 拍 |
| 引擎合计 | **3,443,772 拍** |
| cycle_model p0 期望 | 3,443,756 拍 |
| **引擎/model 偏差** | **+0.00%**（逐 op 恒 +2 拍，为 start→busy 的固定开销） |
| flush 合计 | 252,680 拍 |
| 总 band 拍 | 4,265,196 拍 |

**结论**：DDR3 全链路的数据通路、权重/Q 双缓冲切换、band 握手、引擎驱动**全部工作正常**，周期与解析模型一致到 ±2 拍。唯一未过的是数值。

### 4.3 数值判据（当前 FAIL）

- FNV-1a（compact NHWC y,x,c，real channels）**8/8 op 与 plan csum 不一致**；
- 张量级比对（arena 布局整块，含 pad 字节）**8/8 op 有差异**；差异中包含 **X 字节**（`xxxx`），说明部分 OBUF 字从未被引擎写（或写到错误地址），随后被 flush 成 X → 这指向 b 侧写覆盖/地址映射，而非单纯量化误差；
- 已排除：输入张量（FNV 三方一致）、周期（与模型一致）、fill/flush 完成（beats 数正确）、总线/握手（无 timeout/err）。

---

## 5. 根因分析与已修复项

### 5.1 已修复 #1：引擎是 **NN 窗口绝对寻址**，`src=dst=0` 会破坏 pad 基准

- 证据：`nn_conv_engine.sv:927` `base0_a <= d_src − pad*row_step_a − pad*ic8`；`:965` `sel_a_src <= (d_src >= NN_B_OFF)`、`sel_b_dst <= (d_dst >= NN_B_OFF)`；`:958-962` `row_base_w <= d_dst`、`wr_base <= d_dst`。
- 修复（全部在**我自己的** `nn_tilecache.sv` + TB，不动引擎）：
  - tilecache 新增 3 个描述符输入 `d_a_src_base / d_a_aux_base / d_b_base`，分别用于 a_sel=0（src/tile）、a_sel=1（ADD dst/aux）、b 侧的地址基准减法 → 引擎可以继续用非零绝对基准，而 tilecache 仍按 tile 相对索引；
  - TB 给引擎 src=0x02_0000（< NN_B_OFF ⇒ a_sel=0）、非 ADD 的 dst=0x02_0000、**ADD 的 dst=0x07_8000**（≥ NN_B_OFF ⇒ dst 从 a_sel=1/aux 银行读），b 侧基准同步。
  - 向后兼容：M4 TB 这三个输入 tie 0，原 5 项判据不变（回归 PASS）。

### 5.2 已修复 #2：`nn_mem` a 读口是 **8B 粒度窗口**（`a_addr[3]` 旋转）

- 证据：`nn_mem.sv` a/w 读语义「8B 窗口跨 128b 字时 `{下一字低 8B, 当前字高 8B}`」；引擎 v3 的 8-lane tile 会发 `a_addr[3]=1`（`nn_conv_engine.sv` p3/普通通路均有）。
- 修复：tilecache a 读输出按 `a_local[3]` 做 16B 窗口旋转（`a_local[3]=0` 原行为，`=1` 时 `{ibuf[w+1][63:0], ibuf[w][127:64]}`）。M4 回归仍 5/5。

### 5.3 剩余根因（按排查顺序，已缩小范围）

| # | 假设 | 证据/排除方法 |
|---|---|---|
| R1 | **b 写口覆盖不全**：引擎的 b 写可能是 8B 半字（`b_wstrb=00FF/FF00`）且 `b_addr[3]` 有时非 0；我们的 OBUF 按 16B 索引 RMW 应能处理，但**若引擎 b_addr 是 8B 粒度窗口地址（b_addr[3]=1）**，我们按 16B 对齐索引会写错位置 | 检查 `nn_conv_engine.sv` 的 `b_addr_c = {wpx[23:4],4'h0}` 是否恒 4'h0（初步看是），以及 `wpx` 递增是否覆盖全部像素；用最小 op（op3 conv k1s1，无 pad/PACKED3/DW/ADD）单独对照第一行字节 |
| R2 | **PACKED3 tile 路径**：op0 的 p3 逻辑假设"行带流式"（`row_base_a = d_src − pad*(p3_row+3)`），整张量单 band 可能不满足其行流假设 | 先跑 op0 之外的 7 个 op（已失败），故 p3 不是唯一根因；最后单独回归 op0 |
| R3 | **W/Q 时序/银行**：W_RD_LAT=2 与 nn_mem stream 模式；Q 影子银行银行选择 | op3 只用 W/Q，若 R1 排除后仍错，再查 nn_mem bank 内容（TB 可 hier 读 `u_nn_mem.w_mem_*` 与 stream 镜像对比） |
| R4 | 引擎 `b_sel` 选择：tilecache 忽略 `b_sel`，ADD/conv 的输出 bank 由 tilecache 自身 parity 决定 | 与 R1 一起查 |

**下一步（优先级）**：
1. **引擎独立参考通路**：在 wrapper 里加一条 bypass（引擎 a/b 直连 nn_mem A/B，TB 用 CPU 窗口/A 区后端预装输入），跑 op3 与 golden 对比 → 若 PASS，问题就在 tilecache 的 a/b 地址翻译；若 FAIL，问题在 W/Q/引擎描述符。这是最快的二分。
2. 用 **op3（conv k1s1, oc=16, 无 pad/PACKED3/DW/ADD）** 单 op 定位：打印引擎侧首个 b 写地址/数据与 golden 首个输出字对比。
3. 修好后逐步加回 op0（PACKED3）→ op2/6（dwconv）→ op4（ADD）。
4. 通过后：切 `opvec/0349` 真实图那套（用户可见判据），跑前 12 op → 再上 banded 56/32 KiB 配置（用 converter `band_plan.json`）。

---

## 6. 与冻结输入的对接情况

| 输入 | 状态 |
|---|---|
| `results/bottlecap/plan/plan.json`（106 op, w_bytes=2,020,960, q=90,368） | 已用（op 表/几何/偏移/csum/arena_off） |
| `results/bottlecap/stream/bottlecap/bottlecap_ddr_stream_{w,q}.hex` | 已用（预取源） |
| `results/bottlecap/plan/opvec/`（pattern_v1 + 0349 两套） | pattern_v1 已接入（23 张量 FNV 全部核对通过）；**0349 真实图下一轮接入**（用户可见 E2E 判据） |
| `results/bottlecap/plan/band_plan.json`（v2 整通道 band：2,391 band；B=1 的 30 op；17 op 需 32KiB IBUF，max 32,256 B） | 已读并用于 M4 32KiB 裁决（附录 C）；M6b banded 阶段直接采用 |
| 合并 WQ 镜像 | **不需要**（M6b TB 把 W/Q 放在不同 DDR 基址分别装载；现有两个 64b/行镜像已够） |
| flags 映射（plan↔nn_pkg） | 已实现并核对（见 §3） |

---

## 7. 复现命令

```bat
set LM_LICENSE_FILE=D:/software/tools/Modelsim/win64/LICENSE.TXT
set MGLS_LICENSE_FILE=D:/software/tools/Modelsim/win64/LICENSE.TXT
set PROCESSOR_ARCHITECTURE=AMD64
set MSIM=D:/software/tools/Modelsim/win64

rem 1) 生成 M6b 数据（输入/FNV 校验 + ops 表 + opvec 张量 -> 64b hex）
python results\bottlecap\proto\gen_m6b_data.py --nops 8

rem 2) 编译并运行 DDR 全链路 TB
%MSIM%\vlib.exe work
%MSIM%\vlog.exe -sv nn_pkg.sv nn_mem.sv nn_conv_engine.sv nn_wload.sv nn_tilecache.sv ^
  sim\beh_ddr3.sv results\bottlecap\proto\nn_ddr_chain.sv sim\tb_bottlecap_ddr_chain.sv
%MSIM%\vsim.exe -c -do "run -all; quit -f" work.tb_bottlecap_ddr_chain ^
  +ops=results/bottlecap/proto/m6b_data/ops.txt ^
  +whex=results/bottlecap/stream/bottlecap/bottlecap_ddr_stream_w.hex ^
  +qhex=results/bottlecap/stream/bottlecap/bottlecap_ddr_stream_q.hex ^
  +inhex=results/bottlecap/proto/m6b_data/arena_input.hex ^
  +golden_dir=results/bottlecap/proto/m6b_data +nops=8

rem 3) 已注册回归不回退
python tools\fpga_workflow.py verify --force --only tb_nn_tilecache tb_nn_wstream
```

---

## 8. 证据索引

| 证据 | 内容 |
|---|---|
| `results/bottlecap/proto/logs/tb_bottlecap_ddr_chain.log` | 8 op 运行：逐 op fill/engine/flush 拍数、FNV、tensor 比对、周期汇总（engine/model +0.00%） |
| `results/bottlecap/proto/m6b_data/meta.json` / `golden_ops.txt` | 输入 FNV 校验、23 张量金标 FNV 全对、cycle_model 期望 |
| `tools/bottlecap/cycle_model.py` | p0 逐 op 周期（本 TB 引擎实测与之逐 op 对齐） |
| `nn_conv_engine.sv:927,958-965` | `base0_a`/`row_base_w`/`wr_base`/`sel_a_src`/`sel_b_dst`（§5.1 根因） |
| `nn_mem.sv` a/w 读语义 | 8B 粒度窗口（§5.2 根因） |
| `results/bottlecap/plan/opvec/manifest.json` | 张量金标（arena 布局、shape、bytes、fnv、arena_off） |
| `results/bottlecap/plan/band_plan.json` | v2 band 划分（2,391 band、30 op B=1、17 op 需 32KiB IBUF、32768 档全 fits） |
| `results/bottlecap/reports/M4-TILECACHE.md` 附录 C | IBUF 32KiB 裁决 + BRAM 118/135 + M4 7/7 PASS |

---

## 附录 D：+dbg 定点诊断结果（引擎 b 写序列 / OBUF 覆盖）

TB 加 `+dbg` plusarg 后（`sim/tb_bottlecap_ddr_chain.sv`）：监控 `dut.u_engine.b_we/b_addr/b_wstrb/b_wdata_128`，打印前 32 笔并按 `b_addr − cur_b_base` 建 OBUF 128b 字覆盖位图；日志 `proto/logs/tb_bottlecap_ddr_chain_dbg.log`。

### D.1 b 写序列（op0 前 32 笔，节选）

```
[DBG] b_we #0 addr=020000 local=000000 strb=ffff data=8080a0aea69a9e8eb2809886ab8080af
[DBG] b_we #1 addr=020010 local=000010 strb=ffff data=8080a0aea69a9e8eb2809886ab8080af
[DBG] b_we #2 addr=020020 local=000020 strb=ffff data=808098b39ba18083ba80d890c69080a4
...
```

观察：
1. **b_we 拍数完全正确**：op0 12,544 = 输出 200,704 B / 16B ✓（op1 50,176；op2 双倍 100,352 = 8B 半字写 ×2；op3 12,544）。**引擎确实写满了整个输出张量**，所以 §4.3 的 "X 字节" 主要来自 **flush 读到的 OBUF 位置未被写**（地址翻译）或 **数据本身是 X（a 侧读入 X 参与计算）**，而不是引擎少写拍。
2. `b_addr` 低 4 位恒 0、`cur_b_base = 0x020000` 时 local 连续 0x10 递增 → **普通 conv 的 b 基址减法与引擎 dst 基准一致**（Lead 提示 4 排除：无 off-by-NN_B_OFF）。
3. `b_wstrb = FFFF`（op0/op1/op3 全字），tilecache 的字节 strobe 写语义已实现（M4 默认 case 也覆盖），op2 dwconv 的 8B 半字写在拍数上表现为 2× ✓。
4. **输出数据高度重复/大量 0x80（zp_out=-128）**：相邻像素多个 16B 完全相同，说明**计算结果被饱和到负数端**——更像 **W/Q 读出错误（requant 参数错）或 a 侧读到错数据**，而不是输出地址问题。
5. 覆盖率位图显示 op0 只标到 8,192/12,544 个 128b 字（first unwritten=8,192），与"b_we 拍数正确"矛盾 → 说明**部分 b 写地址落到了同一 16B 字**（写地址翻译/行步进仍可能与 OBUF 期望不一致），需要下一步按行打印 `b_addr` 序列（ROW 步进）核对；也可能是覆盖率位图监控的采样/复位口径问题（仅调试用）。

### D.2 下一步（按此顺序，报告 §5.3 更新）

1. **W/Q 读出验证**（当前最高嫌疑）：在 TB 里对 op3 用 hier 引用读 `u_nn_mem` W bank 前 4 个字与 W 镜像层字节比对；引擎 `q_rdata` 序列（Q 前 4 个字）与 Q 镜像比对。若 W/Q 错 → 查 `nn_wload` 填充目标银行/`w_mode=1` 读语义；若 W/Q 对 → 
2. **a 侧数据验证**：填完后用 tilecache a 口按引擎实际下发的地址序列（TB 记录）读回，与 arena 输入张量逐字节对照（含 8B 窗口/通道）。
3. **b 侧逐行地址序列**：打印 op3 每行首末 `b_addr`，与 `out_row_bytes=1792` 的行步进对照，确认 OBUF 覆盖。
4. 通过后再处理 op0 PACKED3（按 Lead 建议：先"整张量 + 直连 nn_mem"单独跑通，再走 tilecache）。
5. 然后切 `opvec/0349` 真实图判据，再上 banded 32KiB 配置（M6 阶段验证紧配置；M6b v1 保持宽松缓冲）。

---

## 附录 E：调试第二轮 —— 三个根因修复 + op0 首次全链路 PASS

### E.1 本轮修复的 3 个根因（全部在我自己的模块/TB，未动引擎）

| # | 根因 | 证据 | 修复 |
|---|---|---|---|
| R1 | **tilecache a 读延迟 2 拍**（先寄存地址再寄存数据），而 `nn_mem`/引擎语义是 **1 拍**（地址第 N 拍、数据 N+1 拍）→ 引擎每次读拿到"上一条地址"的数据 | 用 `dut.u_tilecache.a_local_q` 对齐后，捕获数据显示 tile(loc)=expected(loc−0x10) | 改为 `a_rdata_q <= ibuf[a_local]`（同一拍寄存），`a_local_q` 仅留作 debug；M4 TB `--force` 仍 **7/7 PASS** |
| R2 | **引擎地址基准 `d_*_base` 在 `band_start` 之后才设置** → tilecache 锁存到 0，引擎绝对地址未减基准 | ADBG 显示 `loc=0x020000`（未减基准） | TB 把 3 个基准的设置移到 `band_start` 之前（descriptor 锁存点） |
| R3 | **`beh_ddr3` BEAT_GAP=1 时首拍错位**：fill 数据整体后移一个 128b 字（ibuf[0]=0，ibuf[k]=input[k−1]） | BEAT_GAP=1 时 ADBG 全 MISMATCH 且固定偏移 16B；改 BEAT_GAP=4 后同一 op 全部 OK | M6b v1 用 **BEAT_GAP=4**（与 M3 基线一致）。BEAT_GAP=1 的模型边界作为已知问题记录：不影响 v1 结论，但 M6 若要多路并行/全速 DDR 需修模型或加约束 |

### E.2 里程碑：op0（conv0 PACKED3，224×224×3 → 112×112×16）**全链路逐字节 PASS**

命令：`+nops=1`（W/Q 流式预取 → DDR arena 输入 → tilecache 整张量 band → 真引擎 → flush → 判据）：

```
[CHAIN] golden .../golden_op000.hex: arena w0=d1808080faac8098 gold w0=d1808080faac8098 nbytes=200704
[CHAIN] op 0 kind=0 FNV=cb19ba31 exp=cb19ba31 fill=46817 eng=398299 (model 398297) flush=12769   FNV_OK
[CHAIN] SUMMARY: 1/1 ops FNV pass, 1 tensor goldens OK (0 bad), errors=0
BOTTLECAP_DDR_CHAIN_TB: PASS
```

- **FNV-1a 逐 op 判据**：`0xcb19ba31` == plan `checksums.txt` / `opvec.manifest.fnv` ✓
- **张量级判据**：与 converter `opvec/pattern_v1/op000.hex` **整块 200,704 B 逐字节一致** ✓（对应 Lead 提示"张量比对更值钱"）
- 引擎周期 398,299 vs cycle_model 398,297（+2 拍固定开销）
- 日志：`proto/logs/tb_bottlecap_ddr_chain_op0.log`

### E.3 8-op 批量现状：op0 PASS，op1..7 仍 mismatch（已排除全部输入侧原因）

| 验证项 | op0 | op1 |
|---|---|---|
| W bank 内容 vs W 镜像 | bad=0（144 words） | **bad=0（128 words）** |
| Q shadow bank vs Q 镜像 | bad=0（14 words） | **bad=0（50 words）** |
| a 侧读数据 vs arena 输入张量 | 158,790 读，bad=5（边界样本） | **100,352 读，bad=4（边界样本）** |
| 引擎周期 vs cycle_model | +2 拍 | +2 拍 |
| b_we 拍数 | 12,544 = 输出/16B ✓ | 50,176 = 输出/16B ✓ |
| b 写地址线性序 | 线性 ✓ | **OC-tile 扫描序**（同一像素 4 个 OC tile 分 4 遍写，步长 64B；最终地址 = pixel·oc8 + octile·16，布局仍是 NHWC） |
| FNV / 张量 | **PASS** | FAIL（arena w0=`b3ade08080808080` vs golden `b986978d808080b7`，在 golden 中搜不到该 24B 模式 → 非排列错位，是数值不同） |

结论：op1 的**输入、W、Q、周期、输出写地址布局全部正确**，差异在引擎 dense k1s1/多 OC tile 的数值结果本身 → 剩余嫌疑收敛到：
1. **多 OC tile 的 requant/尾部处理**（op0 只有 1 个 16-lane tile，op1 有 4 个；op2=4、op3=1 但输入来自前面错误 op）；
2. **`desc.oc` 与 `oc8` 的 Q 尾部布局**（Q 长度 400 = 6·64+16；op0 是 6·16+16）；
3. 引擎在 tile 直连模式下对 `d_ic`/`d_oc` 的非 8 对齐尾部处理（本模型 ic/oc 均是 8 的倍数，暂排除）。
4. 下一轮：**op1 隔离运行**（跳过 op0，把 `golden_op000` 预载到 op1 的 arena 输入区），打印引擎输出前 4 个像素 × 前 16 通道与 golden 对照，判断是"整体 offset/通道置换"还是"数值/requant 差异"。

### E.4 其它

- op2 的 arena w0 与 golden 仅差最后 2 字节（`808080808089808c` vs `8080808080898080`）→ 说明 dwconv 路径主体正确，误差可能来自输入（op1 错误）或尾部。
- `+dbg` 已内置：W/Q bank 全量交叉核对、a 读全量计数/坏读计数、b 写拍数/线性度、OBUF 覆盖位图（覆盖位图统计口径待修，暂不作为判据）。
### E.5 按 Lead 提示的 Q 读序列核对：**per-OC-tile Q 读取正确（排除提示 1/2）**

`+dbg` 增加 `q_re/q_addr/q_rdata` 捕获（引擎 q_re 后 1 拍取 nn_mem q_rdata，与该层 Q 镜像逐字对比）。op0/op1 结果：

```
[QDBG] op0 q_addr=0..12   data==exp 全部 OK        (op0 只有 1 个 16-lane OC tile)
[QDBG] op1 q_addr=0..7    data==exp 全部 OK        (tile0: bias_adj/M_pos 段)
[QDBG] op1 q_addr=32..35  data==exp 全部 OK        (tile0 tail)
[QDBG] op1 q_addr=48      data==exp OK             (SHIFT/tail16B)
[QDBG] op1 q_addr=8..15   data==exp 全部 OK        (tile1 段)
[QDBG] op1 q_addr=16..     ... 继续按 tile2/tile3 段递增
```

结论：
- 4 个 OC tile 的 `q_addr` **确实分别指向 Q 块内不同 OC 起点**（tile0=0..7/32..35/48，tile1=8..15/36..39/48，tile2=16.. 等），**没有"4 个 tile 读同一段"的问题**；
- 每个 q 读数据与 Q 镜像 **逐字相等**；
- ⇒ Lead 提示 1（qoff 口径差）、提示 2（M_pos/SHIFT 取错 tile）**均排除**。

op1 剩余嫌疑（更新）：Q/W/a/周期/写地址全部核验证正确后，问题落在"引擎多 OC tile 计算内部"或"b 写数据在 tile>0 时被写错位置/被 tile0 覆盖"两处之一。下一步：
1. **op1 隔离运行**：跳过 op0，把 `golden_op000.hex` 预载到 op1 的 arena 输入区（避免链式污染），只跑 op1；
2. 用 `+dbg` 把 op1 的 b 写按 `(y,x,octile)` 展开（当前已打印前 20 笔：stride=64B、16B/拍，符合 `pixel·oc8+octile·16`），**核对 tile1..3 的写是否落在 `octile*16` 偏移**，并检查是否有 tile0 数据覆盖 tile1 位置（`b_ooo` 只统计顺序，不判别覆盖）；
3. 若写位置正确，则导出 op1 输出前 64B 与 golden 的 pixel0 64 通道对比，判断是否 tile0 的数值本身就错（那就是引擎 dense k1s1 的 Q/requant 内部问题，需 engine owner 介入）。

---

## 附录 F：dense 路径 vs PACKED3 路径判别（ISO 单 op 模式）

为排除"链式污染/执行顺序/bank 历史"影响，TB 新增 **ISO 单 op 模式**：
`+iso_op=<n> +iso_src=<该 op 输入张量 64b hex>` —— 只跑该 op，输入张量由 golden 直接预载到其 arena 区（跳过前序 op）。

| ISO 实验 | op 类型 | OC tile 数 | 结果 |
|---|---|---:|---|
| `iso_op=0` + `arena_input.hex` | conv0 **PACKED3** k3s2 224×224×3→112×112×16 | 1 | **PASS**（FNV `0xcb19ba31` + 张量逐字节，errors=0） |
| `iso_op=1` + `golden_op000.hex` | dense k1s1 112×112×16→64 | 4 | FAIL（与链式跑法 byte 完全相同） |
| `iso_op=3` + `golden_op002.hex` | dense k1s1 112×112×64→16 | **1** | **FAIL**（arena w0=`ecf8fbc3...` vs golden `e70209e0...`） |

**结论：op1+ 的 mismatch 不是"多 OC tile"造成**（op3 单 tile 也全错），也不是链式/顺序/bank 历史问题（ISO 与链式输出 byte 相同），而是 **dense 卷积路径（`f_p3=0`）与 PACKED3 路径（`f_p3=1`）的差异**。

### F.1 已逐笔核验正确的引擎输入侧（op1/op3，ISO 模式）

| 项 | 方法 | 结果 |
|---|---|---|
| W 读 | 抓引擎 `w_addr/w_rdata`（W_RD_LAT=2 对齐），与 W 镜像 `layer_off + w_addr` 逐字对比 | **OK**；W bank 内容 128/144 words bad=0 |
| Q 读 | 抓引擎 `q_re/q_addr/q_rdata`，与该层 Q 镜像逐字对比 | **OK**，且 4 个 OC tile 各读各的 bias/M_pos/SHIFT 段 |
| a 读 | 抓引擎 `la/y_ld/x_ld/c_ld`：`la` 相对地址 = `x*16`（第二遍 `+8` 覆盖 ic8=16），读回数据与 arena 输入张量逐字节对比 | **OK**（仅末尾越界 read 的 4 个边界样本为 X/0） |
| b 写 | 抓 `b_addr/b_wstrb/b_wdata`：`local = pixel·oc8 + octile·16`、`b_wstrb=FFFF`、拍数 = 输出/16B | **OK** |
| 描述符 | op/ks/stride/pad/ih/iw/ic/oc/flags 与 plan 对照；woff=qoff=0 | 与 plan 一致；dst 改 B-window 约定（≥NN_B_OFF）输出 byte 不变 |
| 周期 | 引擎 cycles vs cycle_model | 逐 op +2 拍 |

### F.2 待 engine owner 确认的问题（M6b 是第一次把真引擎跑在 w_mode=1 流式 W 下）

`tb_sw_nn_job` 等既有 E2E 走的是 ROM 模式（w_mode=0，woff=层绝对偏移）；M6b 是**首次真引擎 + nn_mem 流式银行**组合。因此怀疑存在一条 **stream 模式下的 dense 路径附加契约**（PACKED3 路径恰好不触发）。已请 Lead 转 engine owner 确认：
1. dense 路径是否要求 `desc.src/dst` 为真实 A/B 窗口偏移（如 0x6_0000 / 0x7_8000），而不是任意基准 + 外部减法；
2. dense 路径的 a 读对 `a_addr[3]`/`rd_half_s` 的组合要求（当前按 nn_mem 8B 窗口语义实现，PACKED3 对齐路径通）；
3. stream 模式下 `W_RD_LAT` 是否仍为 2（与 nn_mem wpipe 一致）、`w_addr` 的 bank 相对语义是否与 ROM 模式完全一致。
4. 可以导出 op3 ISO 的引擎端口 VCD（w/q/a/b 全部通道）供 engine owner 对照。

### F.3 当前判据状态

| 模式 | 结果 |
|---|---|
| `+nops=1` / `+iso_op=0`（conv0 PACKED3 全链路） | **PASS**（可复现，日志 `tb_bottlecap_ddr_chain_op0.log`） |
| `+iso_op=1`、`+iso_op=3` | FAIL（dense 路径，见上） |
| 8-op 批量 | 1/8（仅 op0） |
| M4 TB（`--force`） | **7/7 PASS** |
| 注册回归（`--force`） | **PASS 2**（tb_nn_tilecache / tb_nn_wstream） |

---

## 附录 G：numpy 独立复算 + ROM 对照 + 引擎内部 dump（定位收敛）

### G.1 numpy 独立复算（新工具 `results/bottlecap/proto/recompute_op.py`）

从**冻结 plan 文件**（`plan.json` + `w.hex` + `q.hex` + 输入张量 arena 字节）按 CONTRACT §5/§6/§7/§8 **独立 numpy 实现**卷积+requant：

```
[recompute] op 3: conv k1 s1 p0 112x112x64->16 flags=0x0 act=none
[recompute] Q parse: zp_out=-27 zp_in=-128 leaky_en=0 SHIFT=23 bias[0..3]=[16718,-31563,9376,18847] M_pos[0..3]=[21336,15101,26002,21955]
[recompute] vs golden: mismatch 0/200704 bytes (0.00%)   ← numpy == converter golden
[recompute] engine dump: X words = 2 (treated as 0)
[recompute] vs engine(non-X ref): mismatch 192802/200704 bytes (96.06%)
```

**结论 1：converter 的 w/q/plan/golden 语义与 CONTRACT 完全一致（逐位），已排除 converter 侧。**

### G.2 ROM 模式对照实验（`+rom_mode`）

TB 新增 `+rom_mode`：`w_mode=0`，把**该层 W/Q 字节经 nn_mem dbg 口装入 ROM 区**（W 1024 B / Q 112 B，ROM 偏移 0），descriptor `woff=qoff=0`，其余与 ISO op3 完全相同（a/b 仍由 tilecache 提供）：

| 模式 | op3 输出 arena w0 | 与 golden |
|---|---|---|
| stream（w_mode=1, nn_wload fill） | `ecf8fbc3eedce1ee` | FAIL（与 stream 模式 **byte 完全相同**） |
| **ROM（w_mode=0, 无任何 fill）** | `ecf8fbc3eedce1ee` | **同样 FAIL，输出与 stream 逐字节相同** |

**结论 2：W/Q 读出口径与 fill 写仲裁都不是当前 FAIL 的原因**（ROM 模式没有 fill 写，结果仍相同；且 M6b TB 中预取在 `band_done` 之前早已完成，引擎运行期间**没有** fill 并发）。
⚠️ 因此 rtl-mem 的 portB 修复对 M6b 当前现象**不是必要条件**（但对未来 nn_seq 边算边填仍是必要的，建议保留 task-19）。

### G.3 引擎内部 descriptor/派生量 dump（`+dbg`，EDBG）

```
[EDBG] desc: op=0 flags=00 ks=1 pad=0 ih=112 iw=112 ic=64 oc=16
[EDBG] derived: pad_eff=0 dense=1 f_dw=0 f_p3=0 ic8_r=64 oc8_r=16 row_step_a=7168 ...
```
（`band_step_a=0` 是采样时刻过早，后续状态机才置值；`row_step_a=7168 = 112*64` 与 CONTRACT §8 一致。）

### G.4 引擎端口数据逐笔核验（全部正确）

| 通道 | 结果 |
|---|---|
| W 读 | `w_addr` 序列 0,0x10,0x20,...（dense k1 的 `[tap][ic][oc]` 每 ic 行 16B，符合 §6）；`w_rdata`（按 W_RD_LAT=2 对齐）与 W 镜像**逐字节一致** |
| Q 读 | `q_addr/q_rdata` 逐笔与 Q 镜像一致；bias/M_pos/tail 段偏移符合 §7 |
| a 读 | `la/y_ld/x_ld/c_ld` 与 arena NHWC C8 布局一一对应；读回数据与输入张量逐字节一致 |
| b 写 | `b_we` 拍数 = 输出/16B、地址 `pixel·oc8+octile·16`、`b_wstrb=FFFF` |
| X 计数 | 输出 dump 25,088 个 64b 字中只有 **2 个 X**（末尾 word 25,086/25,087，为 flush 与最后一次写竞争）——**不足以解释 96% 失配** |

### G.5 引擎输出 vs numpy 变体搜索（`probe_op3_variants.py`）

尝试 15 种重解释（W 转置、A=0、A 8B 半字交换、W/Q 偏移错位、relu/leaky M_neg、bias int16、SHIFT 覆盖等），**没有任何变体能逼近引擎 dump**（最好仍 194k/200k 失配）：
```
baseline(CONTRACT)             vs engine 192802/200704
A=zeros (bias only)            vs engine 200294/200704
W transposed                   vs engine 200194/200704
...
```
⇒ 引擎消费的数据不是"任何单一重解释"能解释的，说明差异在引擎 dense 路径的内部数据组合（或外部接口的某个未发现约定）。

### G.6 交给 engine owner 的复现物（`results/bottlecap/proto/m6b_data/op3_iso/`）

| 文件 | 内容 |
|---|---|
| `op3_W.hex` | 1024 B 该层 W（u32-LE，CONTRACT §6 dense 布局） |
| `op3_Q.hex` | 112 B 该层 Q（§7：bias int32×16 → M_pos int16×16 → tail16B） |
| `op3_A.hex` | 802,816 B 输入张量（NHWC C8=64） |
| `op3_golden.hex` | 200,704 B 期望输出（converter golden，numpy 独立复算 0 失配） |
| `README.txt` | descriptor（op=0 flags=0 ks1 st1 pad0 112×112×64→16, src=0x60000/dst=0x78000, woff=qoff=0）+ Q 参数解析 |
| `op3_iso_window.vcd` | ISO op3 `eng_start` 后 **2000 拍**窗口，含 u_engine/u_nn_mem/u_nn_wload/u_tilecache 全部内部信号（361 KB） |

**建议 next step**：engine owner 用 ENGINE_TB 以这 5 个文件跑 op3（A 装 A 窗口 0x60000、W/Q 装各自区 0），若 PASS ⇒ 问题在 M6b 的 a/b 提供方（tilecache 接口语义）；若 FAIL ⇒ 引擎 dense 路径在该配置下的 bug，可直接在 ENGINE_TB 里定位。

### G.7 其它

- `recompute_op.py` 已做 X 容错（X→0 并单独计数），可作为修复前后对照判据（X 计数 + 非 X 失配数）。
- M4 报告附录 A 已补 `tile[1]=band_en` 修订说明。
- M6b v1 现状：`+nops=1`/`+iso_op=0` 仍 **PASS**；op1/op3 ISO FAIL；M4 7/7、注册回归 PASS 2 未变。

---

## 附录 H：合成裁剪阈值实验（否证"262,144 位宽阈值"假设）

按 Lead 提出的"PASS/FAIL 界线 ≈ 200,704 vs 802,816（~2^18）"假设，TB 新增**合成几何模式**（`+syn_ih/+syn_iw/+golden_file`）：同 op 的 W/Q 不变，只把输入张量裁成 H×H（k1/s1/p0 时输出同尺寸），用 `recompute_op.py --ih/--iw` 生成裁剪输入 + **独立 numpy golden**，再跑 ISO 单 op。

| case | op | ih=iw | 输入 A 字节 | 输出 B 字节 | 结果 |
|---|---|---:|---:|---:|---|
| 1 | op3 (64→16) | 56 | 200,704 | 50,176 | **FAIL** |
| 2 | op3 (64→16) | 64 | 262,144 | 65,536 | **FAIL** |
| 3 | op3 (64→16) | 72 | 331,776 | 82,944 | **FAIL** |
| 4 | op1 (16→64) | 56 | 50,176 | 200,704 | **FAIL** |
| 5 | op1 (16→64) | 72 | 82,944 | 331,776 | **FAIL** |

（对照：全尺寸 op3 = 输入 802,816/输出 200,704 FAIL；op0 PACKED3 输入 150,528/输出 200,704 **PASS**。）

**结论：FAIL 与张量尺寸/2^18 阈值无关** —— 输入输出都远小于 262,144 的合成 case 仍然全错。结合附录 G（所有引擎端口数据逐笔核验正确、ROM 模式同样 FAIL、numpy=golden），问题域进一步收敛为：
- **PACKED3（f_p3=1）路径正常；dense（f_p3=0）路径在 M6b 环境下 100% 错误，与尺寸无关**；
- 现有证据无法再用"位宽/阈值/流式/portB"解释；
- 最有效裁决仍是 **ENGINE_TB（stock nn_mem 供 A/B）跑 op3_iso 复现包**（已交 ddr3-feas）：若 PASS ⇒ 差异在 M6b 的 a/b 提供方接口；若 FAIL ⇒ 引擎 dense 路径 bug。

### H.1 TB 新增能力（本轮）

| plusarg | 作用 |
|---|---|
| `+iso_op=N +iso_src=<64b hex>` | 只跑第 N 个 op，输入张量预载到其 arena 区（跳过前序） |
| `+syn_ih=H +syn_iw=W` | 合成几何：k1/p0 的 op 描述符 ih/iw/oh/ow 覆盖为 H×W |
| `+golden_file=<path>` | 覆盖 golden 张量文件（默认按 op id 找 `golden_opNNN.hex`） |
| `+dump_out=<path>` | 把 flush 后的输出张量（arena 布局）dump 成 64b/line hex |
| `+rom_mode` | W/Q 装 nn_mem ROM（dbg 口）+ `w_mode=0` 控制实验 |
| `+vcd=<path>` | eng_start 后 2000 拍 VCD 窗口（engine/mem/wload/tilecache 内部信号） |
| `+dbg` | W/Q bank 全量核对、a 读计数/坏读、b 写拍数/线性度、Q 读序列、引擎内部 desc dump、per-OC-tile golden 差异统计 |

### H.2 文件

`results/bottlecap/proto/recompute_op.py`（支持 `--ih/--iw/--export-input/--export-golden` + X 容错）、`probe_op3_variants.py`、`export_op3_iso.py`、`m6b_data/syn/*`（5 组合成裁剪输入+golden）、`m6b_data/op3_iso/*`（engine owner 复现包+VCD）。

---

## 附录 I：stock-address 对照 + 尺寸二分 + 双方结论 —— 根因指向"整张量单 band 不是引擎 dense 的合法模式"

### I.1 stock-address 对照实验（tilecache 完全模仿 nn_mem 绝对窗口映射）

TB 新增 `+stock_addr`：`nn_tilecache` 新增 `d_in_word_off/d_out_word_off`（fill 写入/ flush 读出 128b 字偏移），把输入张量放到 **IBUF 0x60000 偏移**、输出 flush 从 **OBUF 0x78000 偏移**读出，引擎 desc 用真实窗口偏移 `src=0x60000/dst=0x78000`、所有基准=0 —— 即 tilecache 的地址映射与 stock nn_mem **完全等价**。

| 实验 | 结果 |
|---|---|
| op0 PACKED3（stock-address） | **PASS**（FNV `0xcb19ba31`、张量逐字节，与普通模式相同） |
| op3 dense（stock-address） | **FAIL，FNV `0x80c2ee49` 与普通模式完全相同** |

⇒ **tilecache 的地址映射/接口不是原因**（映射与 stock nn_mem 等价时结果 byte 完全相同）。

### I.2 尺寸二分（同 op3 的 W/Q，只裁 ih/iw；stock-address 模式）

| ih=iw | 输入 A 字节 | 结果 |
|---|---:|---|
| 32 | 65,536 | **FAIL** |
| 40 | 102,400 | **FAIL** |
| 48 | 147,456 | **FAIL** |
| 56 | 200,704 | **FAIL** |
| 64 | 262,144 | **FAIL** |
| 72 | 331,776 | **FAIL** |
| 112（全尺寸） | 802,816 | **FAIL** |

⇒ **没有尺寸/位宽阈值**；即便 64KB 的 dense 也全错。

### I.3 双方结论（交叉验证）

- **rtl-mem**（`M6B-PORTB-FIX.md`）：`nn_mem` 本轮 0 改动；portB/并发填充假设证伪（ROM/stream dump 逐字节相同）；"尾部 X"根因 = **引擎最后一拍 `b_wdata_128` 本身全 X**（op3 第 12,543 拍、op1 第 50,175 拍），tilecache 只是忠实存储；建议 tilecache a 侧越界读钳位（1 笔/10 万，不影响 96%）。
- **ddr3-feas**（task-20）：引擎 dense 路径在**纯净室 wall 模式**逐字节正确：op3 用 **13 行 band** 跑 `OP3ISO: PASS rows=13 cyc=28963 mis=0`（与 golden 5,824 word 全对）；`vary-src`（src 0x60000→0x70000，A 数据同步搬）仍 PASS ⇒ 引擎对合法窗口内任意 base 不敏感；wall 模式复现不出末拍 b_wdata 全 X ⇒ X 来自上游 a 数据；并指出 **stock nn_mem A 窗口受 96KB 硬限**（`nn_mem.sv:508`），整张量 op3（802KB）**不可能**在 stock A/B 里跑，**band 模式才是合法裁决方式**。

### I.4 结论与 M6b 路线修正

**M6b v1 的"1 band = 整张量"（loose buffers）不是引擎 dense 路径的合法执行模式**：引擎 dense 路径只在 **banded** 形式（每 band 输入行数受限、由调用方切 band 并处理 halo/pad）下被验证正确；`desc.ih` 直接给整图 112 时 dense 计算错误（PACKED3 路径恰好不受影响）。

**M6b 下一版（v2）改为 banded 执行**（这也是 Lead 既定 M6 形态）：
1. 用 `band_plan.json` 的 per-op `band_rows / n_bands / in_rows / in_row_bytes / out_row_bytes / band_in_base / pad_top / buf_config`；TB 按 band 循环（引擎 desc `ih` = 本 band 输入行数，`src/dst` 仍用窗口偏移，A/B 提供方仍是 tilecache）；
2. 先按 Lead 裁决的 **IBUF 2×32KiB / OBUF 2×12KiB** 紧配置跑（正好匹配 band 尺寸），band 边界/`pad_top`/`add_mode` 由 `tile_plan` 给出；
3. 判据：逐 op FNV（plan/fused checksums 同源）+ opvec 张量；先 op0..7 再全量。
4. M6b v1 TB 的 whole-tensor 模式保留为**已知限制**记录（PACKED3 only），不注册。

### I.5 本轮 RTL/TB 变更（均已回归）

| 文件 | 变更 | 回归 |
|---|---|---|
| `nn_tilecache.sv` | 新增 `d_in_word_off/d_out_word_off`（stock-address 调试用，默认 0 行为不变）；修正 `aux_beats_row <= d_aux_stride>>4` | M4 TB **7/7 PASS** |
| `sim/tb_nn_tilecache.sv` | 两个实例 `d_in_word_off/d_out_word_off` tie 0 | 同上 |
| `sim/tb_bottlecap_ddr_chain.sv` | `+stock_addr`、`+syn_ih/+syn_iw`、`+golden_file`、`+dump_out`、`+rom_mode`、`+vcd`、`+iso_op`、`+dbg` | — |
| `recompute_op.py` / `probe_op3_variants.py` / `export_op3_iso.py` | numpy 独立复算、变体搜索、engine owner 复现包 | — |

---

## 附录 J：M6b v2 banded TB 上线 + 首轮结果（tilecache 供 A/B 仍 FAIL）

### J.1 新文件 `sim/tb_bottlecap_ddr_banded.sv`（pass marker `BOTTLECAP_DDR_BANDED_TB: PASS`）

按 ddr3-feas task-20 的最小差异集实现 **banded 执行**：
- `results/bottlecap/proto/gen_bands_txt.py` 把 `band_plan.json` 摊平成 `m6b_data/bands.txt`（**2,391 band**，字段：op/band/in_off/in_rows/pad_top/rd_rows/out_off/out_rows/in_row_bytes/out_row_bytes/add_mode）；
- 每个 op：W/Q 预取一次 → 翻 bank → **逐 band** fill→engine→flush（引擎 desc `ih = band in_rows`、`pad=0`，banded 形式）；
- 判据：op 全部 band 跑完后 FNV（plan csum）+ golden 张量整块比对。

### J.2 首轮结果（op0..4，2MB 宽松 bank，tilecache 供 A/B）

| op | kind | band 数 | FNV 结果 |
|---|---|---:|---|
| 0 | conv0 PACKED3 k3s2 pad1 | 19 | FAIL（预期：pad>0 需 Path A 水平 pad 物化） |
| 1 | conv k1s1 pad0 | 112 | **FAIL**（预期应 PASS） |
| 2 | dwconv k3s1 pad1 | 112 | FAIL（预期：pad>0） |
| 3 | conv k1s1 pad0 | 56 | **FAIL**（预期应 PASS） |
| 4 | ADD_R | 19 | FAIL |

⇒ **banded 形式本身没有让 dense 转绿**（op1/op3 pad=0 仍 FAIL），说明"整张量 vs banded"不是全部原因；**tilecache 作为 A/B 提供方与 stock nn_mem 之间仍存在未对齐的行为**。

### J.3 与 ddr3-feas PASS 配置的已知差异

| 项 | 我的 banded TB | ddr3-feas task-20 PASS |
|---|---|---|
| A/B 提供方 | **nn_tilecache（2MB bank + 基准减法）** | **stock nn_mem（A 窗口 0x60000/96KB，B 窗口 0x78000/32KB）** |
| W/Q | nn_mem 流式 bank（w_mode=1） | nn_mem ROM（dbg 口写入，w_mode=0） |
| op3 band | 2 行（band_plan 的 band_rows=2） | 13 行（`+op3iso +op3rows=13`） |
| 其余 | 相同（desc op=0 flags=0 ks1 st1 pad0，woff=qoff=0） | 相同 |

### J.4 下一步（按优先级）

1. **在 banded TB 里加 `+stock_ab`**：engine 的 a/b 直连 stock `nn_mem`（A/B 窗口），TB 用 CPU 窗口把 band 数据写入 A 窗口、从 B 窗口读回判据；W/Q 用 ROM 模式（dbg 口）——即**完整复刻 ddr3-feas 的 PASS 配置**。若复刻后 op3 PASS ⇒ 差异被钉死在 tilecache 的 a/b 端口行为（继续逐拍对 a_rdata/b 写）；若 FAIL ⇒ 我们 TB 还有别的环境差异（如时钟/复位/start 时序）。
2. 用同一份 op3 band 数据（13 行）分别跑"stock nn_mem"与"tilecache"两种提供方，**逐拍 dump a_addr/a_rdata/b_we/b_addr** 对比（ddr3-feas 可直接在他 PASS 的 TB 里加同样监视器，两边对齐时间轴）。
3. pad>0 的 op（op0/op2/dwconv 系）需要把 M4 **Path A 水平 pad 物化**实现进 `nn_tilecache`（`d_in_pad_lr`/行首尾 pad 字节由 fill 写入 zp_in），这是 banded 全量 106 op 的前置条件。

### J.5 回归状态

- M4 TB **7/7 PASS**、注册回归 `verify --force --only tb_nn_tilecache tb_nn_wstream` → **PASS 2**；
- v1 TB（whole-tensor）保留为已知限制记录；v2 banded TB 未注册（当前 FAIL）。

---

## 附录 K：**根因定位与修复** —— A 读语义（16B 窗口 / 低 4 位忽略）+ 尾部钳位；banded op1/op3/op4 双判据 PASS

### K.1 根因（用 ddr3-feas 的 `op3_stock_trace.log` 逐拍对拍定位）

对同一份 op3 数据（13 行 band、W/Q 层内偏移 0）把我们的端口 trace 与 stock 配置 trace 逐事件比较：

```
[cmp] port q: 13/13 beats identical                ← Q=1 拍，完全一致（排除 Lead ② 的 Q 假设）
[cmp] port a: first divergence at beat 8
      ours : addr=0x60008 data=... 888a808580b98080 8e809fc6be888080   ← 8B 旋转后的窗口
      stock: addr=0x60008 data=... 8e809fc6be888080 8080808080898080   ← 16B 对齐窗口（低 4 位忽略）
```

**根因：`nn_tilecache` 的 A 读误用了 W 读口的 8B 粒度语义**（`{next8B, cur8B}` 旋转），而 stock `nn_mem` 的 A/B 读是 **16B 窗口、`a_addr[3:0]` 全部忽略**：
`nn_mem.sv:599` `act_rd_idx = a_addr[ACT_AW+3:4]`（无 half 选择；仅 W 读口有 `w_wi={addr[17:4],addr[3]}`）。
- PACKED3（op0）的 a_addr 恒 16B 对齐 ⇒ 8B 旋转不触发 ⇒ 侥幸 PASS；
- dense 的 a 读存在 `a_addr[3]=1`（ic8≥16 时 icb 切换 +8）⇒ 高 8B 错位 ⇒ **整层错误**，与尺寸/banded/ROM/stream 均无关——完美解释此前所有现象。
- 同时它也是**尾部 X 的上游来源**（最后像素高半窗口读偏 → 该像素累加器 X）；修复 + 越界钳位后消除。

### K.2 修复（都在 `nn_tilecache.sv`，引擎 0 改动）

1. **A 读改回 16B 窗口、低 4 位忽略**（删除 8B 旋转；`a_rdata <= ibuf[bank][a_local[IB_AW+3:4]]`），仍保持 **1 拍延迟**；
2. **越界钳位（Lead P0）**：band_start 锁存 `ib_words = in_rows*in_beats_row`、`aux_words = (aux_pad_top+aux_rd_rows)*aux_beats_row`；`a_word >= words` 时 `a_rdata <= 0`（不再返回 X）；
3. bottlecap 配置按 Lead 裁决改为 **IBUF 2×40KiB / OBUF 2×12KiB**（M4 TB 慢实例 40K；M4 默认仍 16K/12K），整机 BRAM **122/135**。

回归：M4 TB **7/7 PASS**；`verify --force --only tb_nn_tilecache tb_nn_wstream` → **PASS 2**。

### K.3 banded 验证结果（单 op 隔离，输入用 golden 预载，避免前序 op 污染）

| op | 类型 | band 数 | FNV | 张量 golden | TB |
|---|---|---:|---|---|---|
| 1 | dense k1s1 16→64 | 112 | `0xe34a56bf` = plan | **0 bad** | **PASS** |
| 3 | dense k1s1 64→16 | 56 | `0x4c6dd7d1` = plan | **0 bad** | **PASS** |
| 4 | ADD_R 16→16 | 19 | `0x62bb140d` = plan | **0 bad** | **PASS** |
| op3(13 行 band, 与 ddr3-feas 同配置) | dense k1s1 | 1 | —（iso 判据） | **0 bad（23,296 B 全对）** | — |

日志：`results/bottlecap/proto/logs/tb_bottlecap_ddr_banded_{op1,op3,op4}.log`（均 `BOTTLECAP_DDR_BANDED_TB: PASS`，errors=0）。

### K.4 剩余工作（按优先级）

1. **pad>0 的 op 需要水平 pad 物化（M4 Path A）**：`nn_tilecache` fill 增加 `d_in_pad_lr`（左右 pad 列数，单位通道像素）——每行把核心 `iw*ic_pad` 字节写到 IBUF 行内偏移 `pad_l*ic_pad`，左右 pad 列填 `zp_in`，行字节 = `(iw+2*pad)*ic_pad`；引擎 desc 用 `pad=0, iw=iw+2*pad, ih=band in_rows`。覆盖 op0（PACKED3 行宽 `(iw+2)*3`）、op2/6/10/…（dwconv k3s1 系）。
2. 全 8-op banded 链（op0..7）→ 前 12 op → 106 op（fused_a 101-op 亦可）。
3. 完成后把 `tb_bottlecap_ddr_banded` 的注册 dict 发 Lead；opvec `0349` 真实图判据切换。

### K.5 事实修正记录

- Lead ②（Q 接错 2 拍）**已排除**：trace 中 q 事件 13/13 与 stock 完全一致（Q 延迟=1 拍早已满足）。
- Lead ①（IBUF 40KiB）**已落地**（M4 7/7）。
- "整张量单 band 非法"结论**被推翻**（ddr3-feas 纯净室 big-A 112 行 PASS）：真正原因就是 A 读 8B 旋转，与 band 形态无关。
