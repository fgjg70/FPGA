# M2 — `nn_mem`: W 双银行可写 L2 + Q 影子银行 + 流式填充口

> 作者：`rtl-mem`。日期：2026-11-03（Asia/Shanghai）。任务：task-7（M2 里程碑）。
> 规格来源：`results/bottlecap/ddr3/WEIGHT-STREAMING-DESIGN.md` §2.1 M1–M6 + Lead 2026-11-03 消息（localparam 落地 / 黑盒重新生成 / `nn_subsys` 两处集成放宽授权）。
> 纪律：只改了 `nn_mem.sv`、`sim/tb_nn_mem.sv`、`nn_subsys.sv`（u_mem 块 + 2 处授权放宽）、重跑机械生成器 `tools/gen_nn_mem_bb.py` 产出 `fpga/nn_mem_bb.sv`；**未跑 Vivado 实现**（只按 Lead 建议跑了一次 `synth_design -mode out_of_context` 作为 BRAM 推断证据，见 §7）；未改 `nn_pkg.sv`/`nn_conv_engine.sv`。

---

## 0. 结论摘要

| 项 | 结果 |
|---|---|
| W 区 | 运行期可写 **2 银行 × 80 tiles/2 = 40 tiles = 160KiB**（物理仍 4 段 64-bit 阵列，**80 tiles 不变**）；`w_mode=1` 时引擎 `w_addr` = **银行内字节偏移**，`wfill_*` 64b/拍写**非活动银行** `~w_bank_sel` |
| Q 区 | ROM 路径不变（lo 4096×64 BRAM 8 tiles + hi 2048×64 分布式 ROM）；`w_mode=1` 时 lo 前 2048 字 = **2 × 8KiB 可写影子银行**，`qfill_*` 64b/拍写 `~q_bank_sel`，**0 tile 增量** |
| 兼容性硬门槛 | `w_mode=0`（默认）下 W/Q 读数据与读时序**逐拍/逐位不变**：`tb_nn_mem` 原 **47,148 checks**（含 FNV `0x7011972a`/`0xfd77f0ce`）逐项一致；C128 YOLO E2E `hw_bad=0/auto_bad=0`、`npu_cycles=1,191,020` 不变 |
| 新增验证 | `tb_nn_mem` 增加 `w_mode=1` 用例 **773 checks**（双银行填充/翻转/跨段/末字/Q 影子/并发/模式往返），全 `mismatch=0 xerr=0` |
| 回归 | `verify --force` = **PASS 16**（基线 16，未降）；`tb_nn_mem` / `tb_nn_engine` / `tb_nn_seq` / `tb_sw_nn_yolo` 全 PASS。另有 1 项 **队友新增未武装测试** `tb_nn_wstream`（缺它自己的镜像，非 M2 回退，见 §9.2） |
| BRAM | **增量 0（Vivado 2018.3 OOC 综合实测）**：RAMB36 = 119 + RAMB18 = 1 ⇒ Block RAM Tile **119.5**（旧基线 120）；分解 W = 32+16+16+16 = **80**、A/B = 32、Q lo = 7+0.5 = 7.5、LUT-as-Memory = **0**（无 LUTRAM 回退/无复制） |
| 已知约束（M3/M5 必须执行） | **单层权重 wlen ≤ 131,072 B（128KiB）**：bank0 的共享 b 段上 32KiB 在活动 bank=1 时无法经填充口写入（port B 读优先）。瓶盖模型最大层 **124,416 B** ✓（`WEIGHT-STREAMING-DESIGN.md:13,160-163`） |

---

## 1. 交付物与变更概览

| 文件 | 变更 | 规模（`git diff --stat`） |
|---|---|---|
| `nn_mem.sv` | 新端口 9 个 + X/Z 归一 + W 双银行/填充写口/读写同址 portB + Q 影子银行 + `ram_style` 属性 | `git diff --stat`：新增 356 行（含中文注释） |
| `sim/tb_nn_mem.sv` | 新 DUT 端口 + `w_mode=1` 用例 S1–S6 + legacy/stream 分开计数 | 199 行变更 |
| `nn_subsys.sv` | 仅 u_mem 实例化块新端口 tie-off + Lead 授权的 2 处合法性放宽 | 32 行变更 |
| `fpga/nn_mem_bb.sv` | **机械重新生成**（`python tools/gen_nn_mem_bb.py`，2026-11-03 23:39:26），55 行，新端口在 45–55 行；端口未再变，sha256 `DC3C77C5…E49D012` | 25 行变更 |

`nn_mem.sv` 关键行号：新端口 134–143；银行常量 174–186；X/Z 归一 188–205；W 阵列（`ram_style`）264–267；双银行地址 244–334；填充解码 335–370；portA/portB（读写同址单口）371–434；输出 mux 436–505；Q 影子 507–572。

---

## 2. `nn_mem` 端口增量表（全部为输入，默认 0 = v0.7 ROM 兼容路径）

| 端口 | 位宽 | 语义 | 有效范围 / 默认 |
|---|---|---|---|
| `w_mode` | 1 | 0 = 综合期 ROM（默认，逐位兼容 v0.7）；1 = 运行期可写流式（双银行） | `nn_pkg::NN_W_MODE_ROM/STREAM` |
| `w_bank_sel` | 1 | 引擎读的**活动银行**（0/1）。`w_mode=1` 时有效；`w_mode=0` 忽略 | 0 |
| `wfill_we` | 1 | W 填充写使能（仅 `w_mode=1` 有效），写**非活动银行** `~w_bank_sel` | 0 |
| `wfill_addr` | 18 | 目标银行内 **64-bit 字序号** 0..20479（[17:15]≠0 时忽略） | 0 |
| `wfill_wdata` | 64 | 填充数据（整 64b 字写，无字节使能） | 0 |
| `q_bank_sel` | 1 | 引擎读的**活动 Q 影子银行**（0/1） | 0 |
| `qfill_we` | 1 | Q 影子填充写使能（仅 `w_mode=1` 有效），写 `~q_bank_sel` | 0 |
| `qfill_addr` | 13 | 影子银行内 **64-bit 字序号** 0..1023（[12:10]≠0 时忽略） | 0 |
| `qfill_wdata` | 64 | 填充数据（整 64b 字写） | 0 |

- 端口追加在 `dbg_wdata` 之后（**不改原有端口顺序**，旧例化位置兼容）。
- **X/Z→0 归一**（`nn_mem.sv:188-205`）：5 个 1-bit 控制输入经 `always_comb` 归一，未接线例化（`sim/tb_nn_engine.sv`、proto 文件、黑盒）自动落到 `w_mode=0/ROM` 路径，**0 LUT 增量**（综合上等价一根线）。
- 设计文档 §2.1 的 `wfill_q_we` 笔误对应实际端口 `qfill_we`；`qfill_addr` 位宽按设计定 13。

---

## 3. 模式位语义与地址口径

| 信号 | `w_mode=0`（默认 / ROM） | `w_mode=1`（STREAM） |
|---|---|---|
| `w_addr[23:0]` | W 区字节偏移 0..0x4FFFF（320KiB，v0.7 语义） | **银行内**字节偏移 0..0x27FFF（160KiB），越界读 0 |
| `w_rdata[127:0]` | v0.7：8B 对齐 16B 窗口 `{next64, cur64}`，读时延 2 拍 | 同窗口语义，但 `next` 按银行内 64b 字序号 +1（银行末字 → 0） |
| `q_addr[12:0]` | 64b Q 字索引 0..6143（lo 0..4095 + hi 4096..6143） | 影子银行内 64b 字索引 0..1023（`{q_bank_sel, q_addr[9:0]}`），越界读 0 |
| W 填充写 | **忽略**（ROM 不可写） | 写 `~w_bank_sel`，64b/拍 |
| Q 填充写 | **忽略** | 写 `~q_bank_sel`，64b/拍 |
| 静态段选择 | `w_base = 2*w_addr[18:4] + w_addr[3]`，按 16384/24576/32768 分 4 段 | `wi = 2*w_addr[17:4] + w_addr[3]`，按银行/段位选 |

---

## 4. W 双银行实现（M1/M2/M3/M6）

### 4.1 物理布局与地址映射（0 tile 增量）

物理阵列深度/字宽**与 v0.7 完全一致**（`nn_mem.sv:264-267`）：

| 段 | 全局 64b 字 | 深度 | 容量 |
|---|---|---|---|
| `w_mem_a` | 0..16383 | 16384 | 128KiB |
| `w_mem_b` | 16384..24575 | 8192 | 64KiB |
| `w_mem_c` | 24576..32767 | 8192 | 64KiB |
| `w_mem_d` | 32768..40959 | 8192 | 64KiB |

银行划分（各 160KiB = 20480 个 64b 字）：

```
bank0 = 全局 0..20479      = a[0..16383] + b[0..4095]       （40 tiles）
bank1 = 全局 20480..40959  = b[4096..8191] + c + d          （40 tiles）
```

`w_mode=1` 的读地址全部是**位选、无加法器**（缩短 `w_addr_q → BRAM ADDR` 路径）：

| 段 | bank0（`w_bank_sel=0`） | bank1（`w_bank_sel=1`） |
|---|---|---|
| a | `wi[13:0]`（wi<16384） | 不用 |
| b | `wi[11:0]`（wi≥16384） | `{1'b1, wi[11:0]}`（wi<4096） |
| c | 不用 | `{wi[13], wi[11:0]}` |
| d | 不用 | `{wi[14], wi[11:0]}` |

`next` 地址用 `nwi = wi+1` 的同构位选（与 ROM 路径的 `w_nbase` 同构，跨段/末字由输出 mux 处理，`nn_mem.sv:459-520`）。

### 4.2 填充写口解码

```
wfill_g = w_bank_sel ? wfill_addr              (填 bank0, 活动=bank1)
                      : wfill_addr + 20480     (填 bank1, 活动=bank0)
```
按 `wfill_g` 落段：`<16384 → a[g]`；`[16384,24576) → b[g-16384]`；`[24576,32768) → c[g-24576]`；`≥32768 → d[g-32768]`（`nn_mem.sv:340-361`）。

### 4.3 port A / port B 结构与仲裁（保持每段 2 个 BRAM 访问口 → 不复制存储）

每段实现为 **1 个只读口（port A: cur）+ 1 个读写同址口（port B: next 读 / 填充写）**：

| 段 | 活动 bank=0 | 活动 bank=1 |
|---|---|---|
| a | port B 读 next（bank0 cur/next 都在 a 区） | port B **填充写**（填 bank0 的 a 区） |
| b | port B **填充写**（填 bank1 的 b 区低 32KiB） | port B 读 next（bank1 的 b 区） |
| c/d | port B **填充写**（填 bank1 的 c/d 区） | port B 读 next（bank1 的 c/d 区） |

- port B 编码方式：`pba = 填充写 ? 写地址 : next 读地址`，同一 always 块内 **读该地址** + 条件 **写该地址**（read-write port，写拍读到旧值但被忽略）。
- **这是必须的写法（实测踩坑）**：最初写成 `if (fill) 写  else 读` 且读写地址不同，Vivado 把它当 **3 个访问口** → W 复制成 160 tiles（OOC 综合报 `BRAM overutilized: Used=399 / Available=270`，触发 `implement using LUT-RAM`，最终 RAMB36=128 + **57,622 个 LUTRAM**，整机放不下）。改为"读写同址单口"后 OOC 实测 RAMB36=119+RAMB18=1（见 §7）。

### 4.4 并发约束（重要，M3/M5 必须执行）

`b` 段被两银行共享，`b` 的 port B 只能有一个用途：

- 活动 bank=1 时：`b` 的 port B 必须留给引擎 `next` 读 ⇒ **对 bank0 高 32KiB（wi≥16384）的填充写被丢弃**；
- 因此 **单层权重 wlen 必须 ≤ 131,072 B（128KiB）**：这样下一层预取写 bank0 时永远只碰 a 区（<128KiB），引擎读 bank0 也永远不进入 b 区。
- 瓶盖模型最大层 = `stage5_1_block_0_0` 等 1×1 conv，**124,416 B**（`WEIGHT-STREAMING-DESIGN.md:160-163`）✓ 满足（余量 6,656 B）。
- **实测证据（S1b）**：`tb_nn_mem` 用例在活动 bank=1 时刻意对 bank0 的 wi=16384/16385 发填充写，再读回，断言内容不变（写被丢弃），PASS。
- bank1 可用满 160KiB；bank0 有效可写 128KiB。两银行都能完整容纳"单层 ≤128KiB"，双缓冲语义不受影响。
- **行动项（已同步 Lead）**：`nn_wload.pre_wlen ≤ 131072` 检查/断言；converter 逐层权重表加该上界检查。

---

## 5. Q 影子银行（M4 的 Q 侧）

- 物理：复用 `q_mem_lo`（4096×64，8 tiles，从 `rom_style` 改 `ram_style`，容量/字宽不变）；`w_mode=1` 时 `q_mem_lo[0..1023]` = bank0，`[1024..2047]` = bank1（各 8KiB），其余 2048 字保留 ROM 内容不用。
- 读：`q_lo_ra = w_mode ? {1'b0, q_bank_sel, q_addr[9:0]} : q_addr[11:0]`（`nn_mem.sv:532`），`q_rdata` 同拍有效（1 拍延迟不变）。
- 写：`q_lo_wa = {1'b0, ~q_bank_sel, qfill_addr[9:0]}`，仅 `w_mode=1 && qfill_addr<1024` 有效（`nn_mem.sv:538-551`）。
- 越界：`w_mode=1` 时 `q_addr ≥ 1024` 读 0（S4 实测 addr=1024/6143 → 0）。
- 单层最大 Q 5,200 B（`WEIGHT-STREAMING-DESIGN.md:226`）= 650 个 64b 字 ≪ 1024 ✓。

---

## 6. 兼容性设计（`w_mode=0` 逐位不变）

1. **数据/时序**：ROM 路径的地址生成（`w_base` 4 段、`w_nxt_*` 边界、输出 mux）、`w_rd_valid_r` 门控、Q 的 lo/hi 选择全部保留原式；仅把地址表达式等价改写为 `w_base/w_nbase` 的位选（逐项证明见 §4.1 与 `nn_mem.sv:246-320` 注释）。
2. **X/Z 归一**：5 个新 1-bit 控制输入 X/Z→0，未接线的旧例化自动 ROM 路径（`tb_nn_engine` 未改一行仍 PASS 47/47 即证据）。
3. **实测**：带 `+nnwq` 合成镜像时 legacy 全量扫描 **47,148 checks** 与历史完全一致，两条 FNV 也逐位一致：

```
# [MEM_TB] W sweep done: 40960 reads, fnv=0x7011972a/0x7011972a
# [MEM_TB] Q sweep done: 6144 reads, fnv=0xfd77f0ce/0xfd77f0ce
# [MEM_TB] SUMMARY_LEGACY(ROM 路径) checks=47148 w_sweep=40960 q_sweep=6144 act=8 cpu=10
# [MEM_TB] SUMMARY_LEGACY(ROM)=47148 + STREAM(w_mode=1)=773
# MEM_TB: PASS (checks=47921, mismatch=0, xerr=0)
```
（历史 FNV 基线见 `results/ai-accel/mem-report.md:317-318`，数值完全相同。）

---

## 7. BRAM 预算与 Vivado 推断（**OOC 综合实测，增量 0**）

### 7.1 实测（Vivado 2018.3，`synth_design -top nn_mem -mode out_of_context -part xc7a100tfgg484-2`）

命令（临时目录，不污染仓库）：
```
read_verilog -sv <repo>/nn_pkg.sv
read_verilog -sv <repo>/nn_mem.sv
synth_design -top nn_mem -part xc7a100tfgg484-2 -mode out_of_context -verilog_define [list SYNTHESIS]
report_utilization -file util.rpt
```
结果（日志 `OOC_*` 行）：

```
Block RAM Tile    | 119.5 |     0 |       135 | 88.52
  RAMB36/FIFO*    |   119 |     0 |       135 | 88.15
  RAMB18          |     1 |     0 |       270 |  0.37
LUT as Memory     |     0 |     0 |     19000 |  0.00      <- 无 LUTRAM 回退
OOC_GROUP RAMB36E1 act_mem_reg   = 32     <- A/B
OOC_GROUP RAMB36E1 q_mem_lo_reg  = 7 + RAMB18 x1   <- Q lo 7.5
OOC_GROUP RAMB36E1 w_mem_a_reg   = 32
OOC_GROUP RAMB36E1 w_mem_b_reg   = 16
OOC_GROUP RAMB36E1 w_mem_c_reg   = 16
OOC_GROUP RAMB36E1 w_mem_d_reg   = 16     <- W 合计 80
```

| 项 | v0.7 旧账 | M2 实测 | 判定 |
|---|---|---|---|
| W | 80 RAMB36（4 段 64-bit 宽、每段 2 个满宽口） | **80**（32+16+16+16） | 不变 ✓ |
| Q lo | 8 RAMB36（4096×64 ROM） | **7 RAMB36 + 1 RAMB18 = 7.5 tiles** | 不增（实际少 0.5）✓ |
| Q hi | 0 BRAM（分布式 ROM） | OOC 未接初始化镜像故被裁掉（真实构建有 `NN_Q_INIT_HI` 时为 LUTROM，0 BRAM） | 不变 ✓ |
| A/B | 32 RAMB36（8192×128） | **32** | 不变 ✓ |
| **合计** | **120 tiles** | **119.5 tiles** | **增量 0 / 实降 0.5** ✓ |

- 旧的"120 tiles"基线出处：`results/ai-accel/mem-report.md:14-15,103-105,168-169`；旧 OOC 证据 `results/ai-accel/impl/nn_mem_ooc/nn_mem.dcp`（`mem-report.md:233`）。
- 说明：本次 OOC 未接 W/Q 初始化镜像（`NN_W_INIT_*`/`NN_Q_INIT_*` 未定义），目的是测**带活写口时的 RAM 推断**；真实构建会把同样几何的阵列初始化成 ROM/RAM，tile 数由几何决定，与是否初始化无关。
- 属性变更：`w_mem_*`、`q_mem_lo` 由 `(* rom_style="block" *)` 改 `(* ram_style="block" *)`（有写口后是 RAM；`ram_style` 同样阻止默认展开成寄存器，见 `nn_mem.sv:260-267,520`）。
- 交付档（无 `NN_EN`）不例化 `nn_mem`，网表不受影响。

---

## 8. `sim/tb_nn_mem.sv` 用例表

**Legacy（`w_mode=0`，保持原样）**：① W 全量扫描（16B 对齐 + 8B 跨字窗口 + FNV）② Q 全量扫描 + FNV ③ dbg 装载口 ③c wpipe 延迟契约 ④ A/B strobe/越界 ⑤ CPU 窗口 ⑥ 复位。**checks 逐项不变**（带镜像 47,148 / 无镜像 42）。

**新增 STREAM（`w_mode=1`，`n_stream` 单独计数）**：

| Case | 内容 | checks |
|---|---|---|
| S1 | 活动 bank1 → 填充 bank0（a 区 + 高段 16368..16383）→ 翻转读 bank0（16B 对齐/8B 奇相位窗口，含 118KiB 附近） | 31 |
| S1b | **文档化约束实测**：活动 bank1 时对 bank0 高 32KiB 填充被丢弃（读前后一致） | 1 |
| S2 | 活动 bank0 → 填充 bank1（b 低区、b→c 跨段 4088..4103、c→d 跨段 12280..12295、d 高区）→ 读 bank1，含银行末字 `next=0` | 61 |
| S3 | 银行翻转：同一银行内地址在 `w_bank_sel` 两种取值下读到不同银行数据；翻回内容保持 | 8 |
| S4 | Q 影子：填/读 bank0（0..15、1010..1023）、填/读 bank1、翻转后 bank0 保持、越界 1024/6143→0 | 65 |
| S5 | **并发**：引擎连续 600 拍读活动 bank1（读时延 2 拍对齐采样）+ 同时每拍填充写 bank0；断言活动读数据全程正确；随后翻转验证 bank0 填充数据正确 | 599+4 |
| S6 | `w_mode` 回到 ROM 路径：dbg 预置 3 个 64b 字后经原 ROM 口读回（2 个窗口）；`w_mode=1` 越界 `0x28000/0x7FFFF → 0` | 4 |
| 合计 | | **773** |

- 三种运行口径（`verify` 默认无镜像 / `+nnwq` / `+nnw+nnq`）全部 PASS；STREAM 用例不依赖镜像（pattern 自写）。
- 看门狗 200,000 → 400,000 拍（带镜像 legacy ≈13.6 万拍 + stream ≈0.4 万拍，仍有 ~2.4× 余量）。
- 命令：
  ```
  python results/ai-accel/proto/mem/gen_wq_image.py --wq-out %TEMP%/yolo_wq.hex --w-out %TEMP%/yolo_w.hex --q-out %TEMP%/yolo_q.hex
  vsim -c -do "run -all; quit -f" work.tb_nn_mem +nnwq=<tmp>/yolo_wq.hex
  vsim -c -do "run -all; quit -f" work.tb_nn_mem +nnw=<tmp>/yolo_w.hex +nnq=<tmp>/yolo_q.hex
  vsim -c -do "run -all; quit -f" work.tb_nn_mem
  ```

---

## 9. 回归证据

### 9.1 `tb_nn_mem` 三模式

| 模式 | legacy checks | stream checks | 总 checks | 结果 |
|---|---:|---:|---:|---|
| `+nnwq`（单镜像） | **47,148（与基线逐项一致）** | 773 | 47,921 | PASS, mismatch=0, xerr=0 |
| `+nnw+nnq`（分镜像） | **47,148** | 773 | 47,921 | PASS, mismatch=0, xerr=0 |
| 无镜像（verify 口径） | 42 | 773 | 815 | PASS, mismatch=0, xerr=0 |

### 9.2 全量回归

`python tools/fpga_workflow.py verify --force`（最终版 RTL，2026-11-03 23:4x，ModelSim 2020.4）：

```
  PASS 16        ← 基线 16，未降（PLAN-V1 §4：只能增不许减）
  tb_units / tb_core_basic / tb_core_trap / tb_soc_timer_irq / tb_core_m_ext /
  tb_core_amo / tb_core_amo_diag / tb_soc / tb_sw_lu_bench / tb_sw_hello /
  tb_sw_coremark / tb_sw_nn_demo / tb_sw_nn_yolo / tb_nn_mem / tb_nn_engine / tb_nn_seq
  FAIL 1: tb_nn_wstream   ← 不是 M2 回退：rtl-stream 本小时新登记进矩阵的 M3 TB，
                            它自己的 +stream_img/+stream_layers 镜像尚未生成
                            （TB 自己打印 "missing +stream_img=..." / "missing +stream_layers=..."），
                            属于 M3 任务未完成态；不涉及 nn_mem 功能。
```
- 我的 16 项基线测试全 PASS：`tb_nn_mem` PASS（815 checks），`tb_sw_nn_yolo` PASS（90.7s），`tb_nn_engine` PASS，`tb_nn_seq` PASS。
- 定点重跑：`verify --force --only tb_nn_mem tb_nn_engine` = PASS 2；`verify --force --only tb_nn_seq tb_sw_nn_yolo tb_nn_mem` = PASS 3。日志：`.fpga-cache/logs/<test>.log`。

### 9.3 C128 YOLO E2E（红线）

`.fpga-cache/logs/tb_sw_nn_yolo.log:55-57`：

```
# [yolo] hw_bad=0 hw_cycles=10469260 npu_cycles=1191020
# [yolo] auto_bad=0 auto_cycles=1191620 auto_npu_cycles=1191020
# [yolo] RESULT : PASS
```

与 `PLAN-V1.md:68` 红线（`hw_bad=0/auto_bad=0/npu_cycles=1,191,020`）**完全一致**。

### 9.4 `tb_nn_engine`（未改一行 TB 的旧例化 → 验证 X/Z 归一）

`.fpga-cache/logs/tb_nn_engine.log:91-96`：`SUMMARY cases=47 pass=47 fail=0 total_mismatch=0`、`ENGINE_TB: PASS (47 cases, mismatch=0)`（含 invalid-desc err case）。

### 9.5 `tb_nn_seq`

`.fpga-cache/logs/tb_nn_seq.log:26`：`NN_SEQ_TB: PASS (starts=113 rom_len=112 cycles=0)`（ROM v1 113 条由 Lead 生成）。

---

## 10. `nn_subsys.sv` 集成改动（Lead 2026-11-03 授权）

1. **u_mem 新端口 tie-off**（`nn_subsys.sv:195-205`）：`w_mode=0`、`w_bank_sel=0`、`wfill_we=0/addr=0/data=0`、`q_bank_sel=0`、`qfill_we=0/addr=0/data=0`。真正的预取/银行翻转接线在 M5 由 rtl-integ 完成；本版不新增 MMIO 寄存器。
2. **通道上限 256 → 1023**（`nn_subsys.sv:272-273`）：瓶盖模型最大通道 864，旧 256 检查会拒掉 106 op 中的 33 个；引擎 `icb_n` 由 rtl-engine M1 补齐到 7 bit。
3. **dst 地址窗口 NN 窗口 512KB → 4MB**（`nn_subsys.sv:288`：`dst >= 32'd4_194_304` 非法）：v1 流式模式 dst 是 DDR3 arena 相对偏移（22-bit/4MB 窗口，ROM-V1）；ROM 模式 YOLO 的 dst < 0x80000 不受影响（§9.3 实测）。
- 判据：`verify --only tb_nn_seq` + `--only tb_sw_nn_yolo` 均 PASS（实际连同 tb_nn_mem 三项一起 PASS，见 §9.2）。

---

## 11. 给 M3/M5 的接线契约（rtl-stream / rtl-integ）

| 项 | 契约 |
|---|---|
| 填充目标 | `wfill_*` 永远写 `~w_bank_sel`；`qfill_*` 永远写 `~q_bank_sel`（调用方**不要**再带 bank 位） |
| 地址口径 | `wfill_addr` = 目标银行内 64b 字序号（0..20479，步长 1，即 8B/拍）；`qfill_addr` = 0..1023 |
| 写数据 | 整 64b 字；无字节使能/无 RMW。128b DDR beat 需拆 2 拍（低 64b 先） |
| 活动银行约束 | `w_bank_sel` 在填充期间不可指向正在被填的银行；翻转必须在 `pre_done` 之后（双缓冲时序见设计文档 §3.2） |
| **wlen 上界** | **≤ 131,072 B**，否则 bank0 高 32KiB 会被丢弃（§4.4）。`nn_wload` 必须检查 `pre_wlen` |
| Q 长度 | ≤ 8,192 B（1024×8B，`qfill_addr` 13-bit 内的有效 10-bit） |
| 引擎侧 | `w_mode=1` 时引擎 `w_addr` 必须是**银行内**偏移；`nn_seq` 的 ROM v1 `woff` 需为层内偏移（ROM-V1 已定） |
| 黑盒 | `fpga/nn_mem_bb.sv` 已按新端口重新生成（23:26:31，55 行）；OOC DCP 需要重综合后才能被 `read_checkpoint -cell u_nn/u_mem` 链接 |

---

## 12. 未做 / 风险 / 待复核

| # | 项 | 状态 |
|---|---|---|
| 1 | Vivado OOC 综合复核（W 80 / Q lo ≤8 / 总 119.5 tiles） | **已做**（§7，2018.3 OOC 实测；首次发现 3 端口推断导致 W 复制，已修并复测通过）。全实现（时序/整机 place）复核仍由 Lead 在 M5 之后统一做 |
| 2 | 时序影响（`w_bank_sel`/模式 mux 进 BRAM 地址路径） | 未测（只跑 OOC 综合，不跑实现）。设计文档预估 <0.2ns（`WEIGHT-STREAMING-DESIGN.md:217`）；实现上地址全为位选 + 1 级 2:1 mux（port B 地址 mux 在 next 读路径上，非 cur 主路径），建议 P2 实现复核 |
| 3 | 单层 >128KiB 的层 | **不支持**（§4.4）；当前模型不需要。若将来需要，需把 b 段拆成两个 4096 深阵列（会改综合初始化镜像格式，需 Lead 定） |
| 4 | `w_mode` 运行期动态切换 | 支持但未测（模式寄存器在数据/有效拍对齐，理论无毛刺）；当前设计为静态配置位 |
| 5 | 整机 BRAM 只剩 3 tiles | 本改动 **0 增量**（OOC 实测 119.5 vs 旧 120）；`q_mem_hi` 仍分布式 ROM（~1.6K LUT）不变 |
| 6 | `tb_nn_wstream`（M3，rtl-stream）当前矩阵内 FAIL | 与本任务无关（缺其自己的镜像）；rtl-stream 完成镜像生成后应转 PASS |
| 7 | P2 OC32 方案（task-12 问："bank 数参数化能否零返工"） | **不能零返工**。`W_BANKS` 虽从 `nn_pkg` 取，但地址映射/portB 仲裁/填充解码按 **2×160KiB（a\|b 半段共享）** 写死；改 4×80KiB 需重写 §4.1/§4.2/§4.3 的映射与 tb 用例，预估 M 级。当前 2 银行对 106 op 模型足够（单层 ≤128KiB） |

---

## 13. 证据索引

| 证据 | 位置 |
|---|---|
| 端口/模式/映射实现 | `nn_mem.sv`（§1 行号） |
| 双银行 TB 用例 | `sim/tb_nn_mem.sv:516-651`（S1–S6） |
| 三模式运行输出 | 本报告 §6/§9.1；`verify` 缓存日志 `.fpga-cache/logs/tb_nn_mem.log` |
| 全量回归 | `.fpga-cache/logs/*.log`（最终版 RTL）；PASS 16（+1 项队友未武装测试 FAIL，见 §9.2） |
| YOLO 红线 | `.fpga-cache/logs/tb_sw_nn_yolo.log:55-57` |
| 引擎联合回归 | `.fpga-cache/logs/tb_nn_engine.log:91-96` |
| **Vivado OOC 综合（BRAM 实测）** | 本报告 §7；临时目录 `%TEMP%/nnmem_ooc/{ooc.tcl,ooc2.log,util.rpt}`（2018.3，`synth_design -mode out_of_context`） |
| 旧 BRAM 账 | `results/ai-accel/mem-report.md:14-15,103-105,168-169,190,233` |
| 上游设计规格 | `results/bottlecap/ddr3/WEIGHT-STREAMING-DESIGN.md` §2.1/§3.1/§3.2/§7 |
| nn_pkg 新常量 | `nn_pkg.sv:52-60`（Lead 2026-11-03 落地） |
| 黑盒 stub | `fpga/nn_mem_bb.sv`（`python tools/gen_nn_mem_bb.py` 重新生成） |
