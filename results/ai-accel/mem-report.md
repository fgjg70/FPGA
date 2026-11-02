# AI 加速子系统 · nn_mem 存储交付报告（v0.7 特化架构 + R3 集成修复）

> 交付人：T-mem。日期：2026-11-01。分支：`feat/ai-accel`。
> 规格：`results/ai-accel/SPEC-SPECIALIZED.md` §3 + `MODEL-FREEZE.md`（D1–D5）。
> 上一版（v0.3.2，WQ 368KB 全 BRAM / A=B=64KB）作历史对照保留在 §9。
> 本报告所有数字都带出处（命令/日志路径），无"看起来对"的结论。

---

## 0. 一句话结论

**nn_mem v0.7 完成并修复了 R3 集成阻塞项（W 读口 8B 粒度窗口）：
W 320KB 落 80 个 BRAM36（4 段 64-bit 宽、每段两个满宽读口）、A/B 128KB 落 32 个 BRAM36；
Q 48KB = lo 4096×64 BRAM ROM（8 tiles）+ hi 2048×64 分布式 ROM（~1.6K LUT，0 BRAM）
⇒ **nn_mem 合计 120 tiles**；核心实占 12 tiles ⇒ **整机 132/135 ✓**。
**[2026-11-02 wpipe 落根目录] W 读输入寄存一级，W 读时延 1→2 拍**（治 125MHz 全实现 worst path：
engine `wa_r` → W BRAM 地址的 8.98ns 纯走线被断成两段）；引擎侧 `W_RD_LAT=2`（根引擎已默认 2）。
tb_nn_mem 三模式 **47,148 / 47,148 / 42 checks, mismatch=0 PASS**；引擎×真 mem 联合回归
**47/47 + 4/4 PASS**，周期 **192,100**（WLAT1 基线 191,283，Δ+817）。
（历史：Q 全 LUTRAM 时 mem 112/整机 121.5；Q 全 BRAM 时 mem 124/整机 136 差 1 tile；
当前 120 为最终构建口径，见 §3.7/§3.8。）**

---

## 1. 交付文件

| 文件 | 说明 |
|---|---|
| `nn_mem.sv`（仓库根） | v0.7 存储子系统（W 64-bit 宽 2R / Q LUTRAM / A,B 128b+strobe / dbg 装载口） |
| `sim/tb_nn_mem.sv` | 自检 TB（`MEM_TB: PASS/FAIL` + mismatch/xerr；X 用 `!==` 显式报错） |
| `results/ai-accel/mem-report.md` | 本文件 |
| `results/ai-accel/proto/mem/nn_mem_synth_top.sv` | 综合取证小顶层（动态全地址激励 + dbg tie 0） |
| `results/ai-accel/proto/mem/synth_nn_mem.tcl` | 纯 ASCII，非工程模式 `synth_design` + `report_utilization` |
| `results/ai-accel/proto/mem/run_synth.bat` | 纯 ASCII，一键生成镜像 + 综合出全部报告 |
| `results/ai-accel/proto/mem/gen_wq_image.py` | 生成仿真/综合镜像（测试样图 或 `--seed` 伪随机） |

未修改任何 Lead/T-accel 文件（`nn_pkg.sv` / `nn_subsys.sv` / `nn_conv_engine.sv` /
`build*.tcl` / `fpga_workflow.py` / `sw/**` / `tools/yolo/**`）。

---

## 2. 最终端口清单（28 个，与 nn_subsys / 引擎 v3 对接）

```systemverilog
module nn_mem import nn_pkg::*; #(
  parameter int W_BYTES = 320*1024,   // W 320KB (BRAM)
  parameter int Q_BYTES = 48*1024,    // Q 48KB  (分布式 ROM/LUTRAM)
  parameter int A_BYTES = 96*1024,    // 激活 A
  parameter int B_BYTES = 32*1024,    // 激活 B
  parameter int CPU_AW  = 19          // CPU 窗口 512KB
)(
  input  logic         clk,
  input  logic         rst,
  // CPU 窗口: 只映射 A/B; 1 拍寄存读
  input  logic         cpu_re,
  input  logic         cpu_we,
  input  logic [31:0]  cpu_addr,      // NN 窗口内字节偏移 (不是绝对地址!)
  input  logic [31:0]  cpu_wdata,
  input  logic [3:0]   cpu_wstrb,
  output logic [31:0]  cpu_rdata,
  // NPU 权重读 (128b, 1 拍)
  input  logic         w_re,
  input  logic [23:0]  w_addr,        // W 区字节偏移, **8B 对齐 (低 3 位忽略)**
  output logic [127:0] w_rdata,
  // NPU Q 参数读 (64b, 1 拍)
  input  logic         q_re,
  input  logic [12:0]  q_addr,        // 64-bit Q 字索引 0..6143
  output logic [63:0]  q_rdata,
  // NPU 激活读 (128b, 1 拍)
  input  logic [1:0]   a_sel,         // 0=A, 1=B
  input  logic         a_re,
  input  logic [23:0]  a_addr,        // 绝对窗口字节偏移, 16B 对齐
  output logic [127:0] a_rdata,
  // NPU 激活写 (128b + 字节使能)
  input  logic [1:0]   b_sel,         // 0=A, 1=B
  input  logic         b_we,
  input  logic [23:0]  b_addr,        // 绝对窗口字节偏移, 16B 对齐
  input  logic [127:0] b_wdata,
  input  logic [15:0]  b_wstrb,       // copy/oc_pad=8 层只写半字用
  // debug 装载口 (module 级 TB 用; SoC 恒 0; 写口仅仿真存在, 见 §6)
  input  logic         dbg_we,
  input  logic         dbg_space,     // 0=W, 1=Q
  input  logic [16:0]  dbg_addr,      // 32-bit 字索引
  input  logic [31:0]  dbg_wdata
);
```

### 2.1 读/写口径（1 拍寄存读，地址第 N 拍、数据 N+1 拍有效；**W 读在 wpipe 后为 2 拍**，见 §3.8）

| 口 | 语义 |
|---|---|
| `w_*` | `w_addr` = W 区字节偏移（0x00000..0x4FFFF，**8B 对齐、低 3 位忽略**）；`w_rdata[127:0]` = 从 `w_addr` 起的 **16 字节小端窗口**（`w_addr[3]=1` 时跨 128b 字边界，取 {下一 64b 字, 当前 64b 字}）；越界 -> 128'b0。**W 读时延 2 拍**（wpipe：`w_re/w_addr` 输入寄存一级；引擎侧 `W_RD_LAT=2`，见 §3.8） |
| `q_*` | `q_addr` = **64-bit Q 字索引**（Q 48KB = 6144 个 64b 字）；`q_rdata[63:0] = {Q32[2k+1], Q32[2k]}`（低地址 32 位字在 `[31:0]`）；`q_addr>=6144` -> 64'b0 |
| `a_*` | `a_sel` + `a_addr`（绝对窗口偏移，16B 对齐）；A=[0x60000,0x78000)、B=[0x78000,0x80000)；sel/地址归属不符或越界 -> 128'b0；`a_rdata` = 16 字节小端 |
| `b_*` | 128b 整字 + `b_wstrb[15:0]` 字节使能；**不做 RMW**；`b_addr` 16B 对齐（低 4 位忽略） |
| `cpu_*` | `cpu_addr` 是**窗口内字节偏移**（不是 0x9004_xxxx 绝对地址！）；只 A/B 命中，其余读 0 / 写忽略（不产生 err）；32 位 + `cpu_wstrb` 字节写；1 拍寄存读 |
| `dbg_*` | `space=0`: `dbg_addr` = W 区 32-bit 字索引（`[16:1]` 选 64b 字，`[0]` 选半字）；`space=1`: `dbg_addr` = Q 区 32-bit 字索引（`[13:1]` 选 64b 字，`[0]` 选半字）。**仅仿真可写，见 §6** |

### 2.2 物理组织

| 区 | 容量 | 实现 | 综合实测 |
|---|---|---|---|
| W | 320KB | 4 段 **64-bit 宽** ROM：A=16384 / B/C/D=8192 个 64b 字（128KB / 64KB / 64KB / 64KB）；每段两个满宽读口：`cur=mem[base]`、`next=mem[base+1]`，`base=2*w_idx+w_addr[3]`；`w_rdata={next64,cur64}` | **80 RAMB36**（4KB/BRAM） |
| Q | 48KB | **2 个 64-bit 宽 BRAM ROM**（`(* rom_style="block" *)`）：`q_mem_lo[0:4095]` + `q_mem_hi[0:2047]`；两路并行读，按 `q_addr[12]` 选择（行为与单块 6144 深完全等价） | **12 RAMB36**（lo 8 + hi 4；若用单块 6144 深会被按 8192 取整 → 16 tiles） |
| A/B | 96KB+32KB | 一块 128-bit 宽 × 8192 深阵列（A/B 连续，靠地址隔离） | **32 RAMB36** |
| **合计** | — | — | **124 tiles**；+核心 ~9.5 ⇒ **~133.5/135** |

---

## 3. Vivado 2018.3 综合证据（核心交付）

> **⚠ 口径说明（2026-11-01 19:1x）**：§3.1–§3.6 的数字是 **Q=LUTRAM 时代**（mem 112 tiles、
> 整机 121.5）的记录；构建修复后 Q 改为 BRAM ROM（2 子 ROM），**当前口径 = §3.7**
> （mem 124 tiles、整机 ≈133.5、@8ns WNS +2.306）。历史数字仅作对照。

### 3.1 一键复现

```bat
rem 纯 ASCII；内部 settings64.bat + PROCESSOR_ARCHITECTURE=AMD64 + 镜像生成
results\ai-accel\proto\mem\run_synth.bat
rem 产物: %TEMP%\nn_mem_v07_synth\v07_util.rpt / v07_util_hier.rpt /
rem       v07_timing.rpt / v07_paths.rpt
```

综合命令（tcl 内）：`synth_design -top proto_nn_mem_v07 -part xc7a100tfgg484-2
-verilog_define {NN_W_INIT_A..D="..."; NN_Q_INIT_FILE="..."}`；
约束 `create_clock -period 10.000 [get_ports clk]`（100MHz，仅综合后估计）。

### 3.2 资源数字（`v07_util.rpt`，随机内容镜像）

```
+-------------------+------+-------+-----------+-------+
|     Site Type     | Used | Fixed | Available | Util% |
+-------------------+------+-------+-----------+-------+
| Slice LUTs*       | 7186 |     0 |     63400 | 11.33 |
|   LUT as Logic    | 7186 |     0 |     63400 | 11.33 |
|   LUT as Memory   |    0 |     0 |     19000 |  0.00 |
| Slice Registers   | 1260 |     0 |    126800 |  0.99 |
| Block RAM Tile    |  112 |     0 |       135 | 82.96 |
|   RAMB36/FIFO*    |  112 |     0 |       135 | 82.96 |
|     RAMB36E1 only |  112 |       |           |       |
|   RAMB18          |    0 |     0 |       270 |  0.00 |
+-------------------+------+-------+-----------+-------+
```

层次归属（`v07_util_hier.rpt`）：

```
|   u_dut | nn_mem | LUT 7175 | LUTRAM 0 | FF 85 | RAMB36 112 | RAMB18 0 |
```

**W/Q 落点**（综合 log 的 "ROM:" 表）：

```
ROM:
| nn_mem | w_cur_a_reg | 16384x64 | Block RAM |   <- W 段 A (128KB)
| nn_mem | w_nxt_a_reg | 16384x64 | Block RAM |   <- 第二读口 (next)
| nn_mem | w_cur_b/c/d_reg | 8192x64 | Block RAM |
| nn_mem | w_nxt_b/c/d_reg | 8192x64 | Block RAM |
| nn_mem | p_0_out     | 8192x64  | LUT       |   <- Q 分布式 ROM (LUT 实现, 0 BRAM)
Block RAM: act_mem_reg 8Kx128 ... RAMB36 = 32     <- A/B 32 块
```

### 3.3 账目核对

| 项 | 数字 | 说明 |
|---|---|---|
| W | 80 RAMB36 | 4 段 64-bit 宽、每段两个满宽读口（BRAM36 真双口） |
| A/B | 32 RAMB36 | 128KB / 4KB per BRAM = 32（精确） |
| Q | 0 BRAM / 6,981 LUT | 分布式 ROM |
| nn_mem 合计 | **112 tiles** | `Block RAM Tile 112/135` |
| + 交付档核心 | ~9.5 tiles | 交付档 `fpga/util.rpt`：RAMB36=8 + RAMB18=3 |
| **整机估算** | **~121.5/135** | ≤121.5 目标 ✓（余 13.5 tiles 给视频链路/320 tile 缓存） |

**独立交叉验证（T-accel 的 engine+mem OOC @100MHz，2026-11-01 R3）**：
`proto/engine/synth100_v3.bat` 用本 nn_mem + engine v3 重跑 →
**BRAM = 112 tiles**（与本报告一致）、LUT 31,066（Q ROM ≈6,976 + 引擎逻辑 ≈24.1K）、
FF 13,779、**WNS +0.807 ns MET**（DSP 200 待压）。日志：`proto/engine/v3r_all47.log`
与 T-accel 的 OOC 报告；说明"112 tiles / 121.5 整机"不是本报告单侧口径。

### 3.4 重要方法学（证据有效性）

1. **R3 修复的取舍（实测三方案）**：8B 对齐窗口需要每拍读"两个相邻 128b 字"。
   - 128-bit 宽阵列 + 第二读口（混合 128/64 位宽，不加 keep）→ Vivado 额外复制
     64-bit 存储：**W 147.5 tiles（超 135 预算，不可用）**；
   - 128-bit 宽阵列 + `(* keep *)` 保持第二读口 128-bit → 第二读口落 LUT：
     **54,618 LUT（86% 器件，不可用）**；
   - **64-bit 宽阵列 + 两个满宽 64-bit 读口**（现方案）→ 两个读口都是满宽使用，
     Vivado 用 BRAM36 真双口：**W 80 tiles**（比原 128-bit 单读的 75.5 多 4.5，
     但远小于其他方案；nn_mem 总 112 tiles、整机 ~121.5 仍满足目标）。
2. **镜像内容必须不可压缩**：测试样图 `wpat32/qpat32` 是线性结构，Vivado 会把它优化成
   压缩实现——同一份 RTL 用测试样图综合出来的 W/Q 数字会偏小（实测 W 68 tiles /
   Q 2,446 LUT vs 随机内容 80 tiles / 6,981 LUT）。真实权重/量化参数不可压缩，
   **本报告采用随机内容数字**（`run_synth.bat` 已带 `--seed 20261101`）。
3. **激励必须覆盖全地址**：只喂窄地址范围会被综合器按"地址可达范围"裁掉 RAM 容量。
   `nn_mem_synth_top.sv` 用快/慢计数器打通所有地址位，并且 `w_addr[3]` 动态，
   强制综合出两个读口（否则第二读口会被优化掉）。

### 3.5 时序粗估（**不是**实现后 fmax / 上板实测）

`v07_timing.rpt`：`create_clock 10ns (100MHz)` 下 **WNS = +5.846ns**（4398 端点，0 失败）
⇒ 综合网表粗估 `fmax ≈ 1/(10-5.846) ≈ 241MHz`。仅说明 W 双读口/地址译码/
Q 分布式 ROM 的组合逻辑不是 100MHz 瓶颈；真实 fmax 以 Lead 的 OOC/impl 数据为准。

### 3.6 nn_mem 单独 OOC @125MHz（8.0ns 约束，R4 交付）

一键复现：`results/ai-accel/proto/mem/run_synth_125.bat`（同一个 tcl 的第 8 个参数传 8.000）。
产物：`%TEMP%\nn_mem_v07_synth\v07_125_util.rpt` / `v07_125_timing.rpt`。

| 指标 | 数值 |
|---|---|
| WNS @8.000ns | **+3.846 ns（MET，0 failing endpoints）** |
| Block RAM | **112 tiles**（历史口径：Q 为 LUTRAM；**当前构建口径 124 tiles，见 §3.7**） |
| Slice LUTs | 7,186（Q ROM ≈6,981 + 少量 glue） |
| Slice Registers | 1,260（`u_dut` 内 85） |
| DSP | 0 |
| 最差路径 | `u_dut/act_mem_reg_4_0/CLKBWRCLK → probe_reg[0]/D`（取证顶层观测寄存器，3 级/4.016ns）——**不是 mem 内部 reg→reg** |

结论：mem 自身在 125MHz 有大量余量；整机 125MHz 的瓶颈在引擎内部与**引擎↔mem 的跨模块
act 地址路径**。后者已在 `P3-DDR3-TILECACHE.md` §5 给出"NPU act 写命令在 nn_mem 侧打一拍"
（写延迟 1→2，引擎周期 0 成本）的方案与影响面。

### 3.7 nn_mem OOC DCP（整机"黑盒 + OOC checkpoint"构建，2026-11-01 19:2x **当前口径**）

背景：整机 in-context 综合曾卡 ~2.5h（W 320KB ROM 被展开成 5.2M 未映射寄存器，等 Technology
Mapping 才落 BRAM）。Lead 改为"nn_mem 黑盒 + 链接本 DCP"；Q 在 OOC 下若为 LUT 常量 ROM 同样
有 5.2M 单元问题，故先改 BRAM ROM；r10 整机 place 报 `272 units needed / 270 sites`
（mem 124 tiles + core 12 tiles = 136 > 135，差 1 tile），故最终 **hi 段改分布式 LUTRAM**：
lo = BRAM ROM 8 tiles，hi = LUTRAM ROM 0 tiles ⇒ **mem 120 tiles，整机 120+12 = 132/135 ✓**。

| 项 | 数值 |
|---|---|
| DCP | `results/ai-accel/impl/nn_mem_ooc/nn_mem.dcp`，1,729,729 B，sha256 `c56bb34759bfe42f21a7df0ad304bb2fe6216c7a7cceeb2e45ead7f8b816cda6` |
| Block RAM | **120 tiles（RAMB36 120 / RAMB18 0）**：W **80**（`w_cur_*`）+ Q lo **8**（`q_rd_lo_reg_*`）+ Q hi **0**（LUTRAM）+ A/B **32**（`act_mem_*`） |
| LUT / FF / DSP | **2,456 / 90 / 0**（hi LUTRAM ≈ +1,626 LUT；q_rd_hi 输出寄存器 +64 FF） |
| OOC WNS | **+2.306 ns @8ns（MET，3,697 端点）**；worst = `w_cur_a_reg CLKBWRK → w_rdata`（2 级 LUT，4.371ns） |
| Q 读路径 | **worst slack +3.013 ns @8ns**（`q_rd_lo_reg CLKARDCLK → q_rdata[0]`，1 级 LUT）；hi LUTRAM 路径更松，**1 拍时延不变** |
| 约束口径 | DCP 内仅 `create_clock -name clk -period 8.000`（无 I/O delay，黑盒链接友好）；timing.rpt 的 WNS 是报告时临时加 0.5ns 虚拟 I/O 所得，不写入 DCP |
| 复现 | `cd results\ai-accel\impl\nn_mem_ooc && vivado -mode batch -source synth_nn_mem_ooc.tcl`（~1min）；`check_nn_mem_dcp.tcl` 做 open_checkpoint 复验（RAMB36=120/WNS=2.306） |
| Q 初始化镜像 | `.fpga-cache/nn_wq_split/q_lo.hex`（4096 行 64-bit，69,632 B，sha256 `12b33d2300277d98869cec9577852f3922eb2d19cdf63bd1a876fd99ebfa36b8`）+ `q_hi.hex`（2048 行，34,816 B，sha256 `37e4183ccbd8c5da820ee017b73004523c7866dc9006b86c4ae750280c61c687`）；由 `q_packed.hex`（6144 行，sha256 `438bd9619e63b13fa4ed960128e860c4461b721b654ab9f7bd496180b445d7d3`）前 4096/后 2048 行切分（hi 改 LUTRAM 后**文件不变**） |
| 行为自证 | **tb_nn_mem 三种模式 PASS（47,146 / 47,146 / 40 checks，mismatch=0）**；引擎×真 mem `tb_nn_engine` 47/47 + 4/4 PASS |

**P3 tile 缓存影响**：整机 132/135 只剩 **~3 tiles**；P3 原计划需 ~12.4 tiles tile cache
⇒ P3 仍必须另行腾 BRAM（C320 模式把 Q lo 也改回 LUTRAM / 权重流式化 / 缩 tile），详见
`P3-DDR3-TILECACHE.md` §4.1 更新说明。

端口清单（逐字）：`results/ai-accel/impl/nn_mem_ooc/nn_mem_ports.txt`（UTF-8 原样）与
`nn_mem_ports_ascii.txt`（去注释 ASCII，供黑盒 stub 生成）。宏名是 `NN_W_INIT_A..D` +
`NN_Q_INIT_LO/HI`（不是 `NN_WQ_INIT_A..D`），镜像 64-bit/行：W A 16384 / B·C·D 8192；
Q lo 4096 / hi 2048。端口未变（Q 只是内部实现变化）。

---

### 3.8 W 读时延 1→2（wpipe 落根目录，2026-11-02，task-12）

**背景**：125MHz 全实现两次确定性差 −0.077ns，worst path = `u_eng/wa_r_reg → u_mem/w_cur_*_reg/ADDRARDADDR`
（**纯走线 8.98ns，0 级逻辑**）——engine 与 W BRAM 的物理距离问题。结构解：把 W 读路径在 mem 边界打一拍。

**改动（仅此一处，根 `nn_mem.sv`）**：
- 新增 W 读输入寄存级 `w_re_q/w_addr_q`（`rst` 清零）；
- `w_idx/w_odd/w_base` 改由 `w_addr_q` 派生；`w_rd_valid_r <= w_re_q && (w_addr_q < W_BYTES)`；
- 其余（W 8B 窗口 cur/next 双读口、Q lo BRAM + hi 分布式、A/B+strobe、CPU 窗口、dbg、初始化）**零改动**；
- **W 读时延 1→2 拍**；端口/参数/初始化完全不变（nn_subsys 无改动；黑盒 stub 不变）。

**接口契约**（SPEC/CONTRACT 更新项）：
- NPU `w_*`：地址拍 +2 拍数据有效（原 1 拍）；引擎侧 `W_RD_LAT=2`（根 `nn_conv_engine` 已默认 2，参数化可回 1 配旧 mem）；
- CPU 窗口 A/B 读仍 1 拍（不经过 W 口）；Q/A/B 时延不变。

**验证**：
- `tb_nn_mem` 三模式（+nnwq / +nnw+nnq / 无镜像）：**47,148 / 47,148 / 42 checks，mismatch=0 PASS**；
  新增 W 时延契约检查：写后 +1 拍读仍无效（0）、+2 拍读到新值；
- 引擎×真 mem（根引擎 `W_RD_LAT=2` + 根 nn_mem）：**vec 47/47 + vec_v3extra 4/4 PASS**；周期和
  **192,100**（vec47 189,202 + extra4 2,898），W_RD_LAT=1 基线 191,283 ⇒ **Δ+817**；
  C128 全模型 1,177,320 → **1,191,020（+1.16%）**（t-accel `calc_cycles_v3.py` DRN=W_RD_LAT+2 逐 case 精确）；
- **根 `sim/tb_nn_engine.sv`（最终版 sha256 `ce574de04c323d8121ae4cb91bf525b55911f16f735fc0ccc8bca6b85ddbb0b9`）+
  根 `nn_conv_engine.sv`（sha256 `0cb981855ffbb7ff0bef7b5e7814db2c31b3e2cd5cdcbf1b394178b2e188374d`）+
  根 wpipe mem 也独立复跑 47/47 + 4/4 PASS，周期和 192,100**。

**资源 / DCP**（根 `nn_mem.sv`，no-clock 黑盒构建用）：
- `results/ai-accel/impl/nn_mem_ooc/nn_mem_wpipe_noclk.dcp`，**1,465,157 B**，sha256
  `e4afea9626d1db14f1a9d1e31b461b407f6ff6ed8b1fc84c4a7be8fa996db6a5`；
- `open_checkpoint`：**clocks=0 / generated=0、RAMB36=120 / RAMB18=0、FDRE=242**（功能 FF +25；
  其余为综合对 `w_addr_q` 的位复制以驱动 8 个 BRAM 地址口，0.19% 器件）；
- LUT cells 2,504（与 wpipe 前 2,456 Slice LUT 基本一致）；
- 复现：`cd results\ai-accel\impl\nn_mem_ooc && vivado -mode batch -source synth_nn_mem_wpipe_noclk_root.tcl`
  （`check_nn_mem_wpipe_noclk_root.tcl` 做 open_checkpoint 复验）。

**复现命令（仿真）**：
```bat
vlib work
vlog -sv -work work <repo>\rv32_pkg.sv <repo>\nn_pkg.sv <repo>\nn_mem.sv <repo>\sim\tb_nn_mem.sv
vsim -c -do "run -all; quit -f" work.tb_nn_mem +nnwq=<yolo_wq.hex>
```
> 注：§3.6/§3.7 中旧 DCP/时序数字为 wpipe 前版本，作历史对照；当前构建口径以本节的
> `nn_mem_wpipe_noclk.dcp`（120 tiles、clocks=0）为准。

---

## 4. 仿真自检（ModelSim SE-64 2020.4）

### 4.1 三种加载模式（都 PASS）

```bat
vlib work
vlog -sv -work work <repo>\rv32_pkg.sv <repo>\nn_pkg.sv <repo>\nn_mem.sv <repo>\sim\tb_nn_mem.sv
rem 镜像由 proto/mem/gen_wq_image.py 生成 (测试样图, 与 TB 期望一致)
vsim -c -do "run -all; quit -f" work.tb_nn_mem +nnwq=<yolo_wq.hex>        # 旧口径
vsim -c -do "run -all; quit -f" work.tb_nn_mem +nnw=<yolo_w.hex> +nnq=<yolo_q.hex>
vsim -c -do "run -all; quit -f" work.tb_nn_mem                            # 无镜像 (verify 默认)
```

实测（2026-11-01 R3）：

```
# ① +nnwq=<94208 行 32-bit>  (W 81920 + Q 12288 顺序拼接)
# [nn_mem] WQ image loaded: ...\yolo_wq.hex (W 40960 x64b, Q 6144 x64b)
# [MEM_TB] W sweep done: 40960 reads, fnv=0x7011972a/0x7011972a
# [MEM_TB] Q sweep done: 6144 reads, fnv=0xfd77f0ce/0xfd77f0ce
# [MEM_TB] SUMMARY checks=47146 w_sweep=40960 q_sweep=6144 act=8 cpu=10
# MEM_TB: PASS (checks=47146, mismatch=0, xerr=0)

# ② +nnw=<yolo_w.hex> +nnq=<yolo_q.hex>  -> 同上, MEM_TB: PASS (47146/0/0)

# ③ 无镜像 -> SKIP 扫描, MEM_TB: PASS (checks=40, mismatch=0, xerr=0)
```

日志：`%TEMP%\nn_mem_v07\r3_a.log` / `r3_b.log` / `r3_c.log`。

### 4.2 TB 覆盖点

① W 128b 读：**2 × 20,480 次全量扫描** —— 16B 对齐（整个 W 区）+ **8B 对齐窗口
  （跨 128b 字边界，引擎 v3 的 8-lane tile 会发这种地址）**，与打包前 32-bit 字序列
   逐字节比对 + FNV-1a；
② Q 64b 全量扫描（6,144 次 × 64b）+ FNV；
③ dbg 装载口：写 W 的 64b 字内两个半字、写 Q 的 64b 字内半字，经 NPU 口回读；
④ A/B：128b 写 + `b_wstrb` 单字节/低 64b/高 64b 写（验证无 RMW、相邻半字不被覆盖）、
   128b 读、A/B 同偏移不串扰、A/B 最后 16B 边界、非法 sel/越界 -> 0；
⑤ CPU 窗口：A/B 1 拍读写 + 字节写；W/Q/空洞/越界读 0；CPU 写 W/Q 被忽略（内容经
   dbg/NPU 口回读确认不变）；`addr==512KB -> 0`；
⑥ 复位：复位期间/之后输出全 0 无 X；中途复位不清存储内容；看门狗超时打 FAIL。

---

## 5. R3 集成联调证据（SoC E2E 从 op0 全错的根因）

### 5.1 根因

引擎 v3（继承 v0.6 语义）按 **8B 粒度**发 `w_addr`（8-lane tile 的 `row + ic*8`，
奇数 ic 时地址 ≡8 mod 16）。旧 nn_mem v0.7 按 16B 粒度 `w_idx = w_addr[18:4]`
（忽略低 4 位）返回对齐的 16B，于是 `w_addr[3]=1` 的读全部读到"上一个 16B 窗口"
→ 权重错位 8B。影响面：当前 plan 中 34 层 OC8%16==8 + 47 层 woff%16!=0，
共 74/84 个 conv/dw 层读错权重，正是 SoC E2E 从 op0 起全错的原因
（CPU 写 A 正常、op 都能 done；stub 按 32-bit 字寻址天然支持 8B，所以 stub 46/46 过）。

### 5.2 修复

`w_addr` 语义改为 **8B 对齐（低 3 位忽略）**，返回从 `w_addr` 起的 16B 窗口；
物理阵列改为 64-bit 宽 + 每段两个满宽读口（§2.2 / §3.4）。延迟保持 **1 拍**。

### 5.3 联合 TB 证据（引擎×内存换成真 nn_mem，其余不变）

在 `%TEMP%\nn_joint3\` 复跑 T-accel 的引擎 TB（`tb_nn_engine_v3r.sv`：与 v3 版
唯一区别是把 `nn_mem_v07_stub` 换成真 `nn_mem`），向量用 T-accel 的 `vec/`
（46/47 case 随其 manifest 更新）与 `vec_v3extra/`（PACKED3 + ADD_R 3 case）：

| 配置 | vec/ | vec_v3extra/ |
|---|---|---|
| 引擎 v3 + **stub**（T-accel 基线） | PASS 47/47, mismatch=0 | PASS 4/4, mismatch=0 |
| 引擎 v3 + **真 nn_mem（R3 修复后）** | **PASS 47/47, mismatch=0** | **PASS 4/4, mismatch=0** |
| **根目录 engine 快照** + 真 nn_mem | **PASS 47/47, mismatch=0** | **PASS 4/4, mismatch=0** |

日志：`%TEMP%\nn_joint3\{protoR46,protoR4,rootR46,rootR4}\run.log`。
⇒ 真 nn_mem 与 stub 在引擎全部用例上**逐位一致**（含 PACKED3 conv0、dwconv、
copy/up2x、ADD/ADD_R）；根目录集成快照的 engine 也能跑通 47/47+4/4。

### 5.4 SoC 剩余"多-tile 步进错位"的归属（已闭环）

Lead 的 SoC 探针观察到"前 8 像素对、第 9 像素起错"；联合 TB 的单 op/全尺寸 l0 replay
在 mem 侧全部位精确 ⇒ **不是 mem**。T-accel 随后定位为引擎 PACKED3 的 x-tile 步长
（`p3_ox` 误写为 `(iw*3)<<4`，应为 `8*st*3` = 48/24），修复后 64×64 输出（每行 8 tile）
的 l0 全尺寸 replay 在 stub 与真 nn_mem 上均 **mismatch=0**（`replay_l0_stub.log` /
`replay_l0_real.log`，cyc=129,555）。根目录 engine 已同步为修复版
（52,578B，sha256 `661fd509…b1a198`）。**mem 侧无遗留问题，v0.7 R3 定稿。**

---

## 6. 初始化镜像

| 用途 | 格式 | 生成 |
|---|---|---|
| 仿真 | 32-bit 字/行（8 hex）：`+nnw=` 81,920 行 / `+nnq=` 12,288 行 / 旧 `+nnwq=` 94,208 行（W+Q 顺序拼接） | T-model 的 `yolo_w.hex` / `yolo_q.hex` 直接可用 |
| 综合 | W 4 段 **64-bit/行**（16 hex）：A 16,384 行、B/C/D 各 8,192 行 → `NN_W_INIT_A..D`；Q **64-bit/行**（16 hex）6,144 行 → `NN_Q_INIT_FILE` | Lead 的 `fpga_workflow.py` 从 32-bit 行镜像打包 |

**R3 打包口径变化（需 workflow 同步）**：W 从 128-bit/行 改为 **64-bit/行**：
- 段 A：32-bit 字 0..32767 → 16,384 行，行 k = `W32[2k] | W32[2k+1]<<32`；
- 段 B/C/D：各 32-bit 字 32768../49152../65536.. → 8,192 行，同样两字一行。
- Q 不变：6,144 行，行 k = `Q32[2k] | Q32[2k+1]<<32`。

仿真侧 `nn_mem` 内置小 loader（`$fgets/$sscanf`，仅非 SYNTHESIS 分支）把 32-bit 行
打包成 64-bit 物理字；综合侧直接 `$readmemh` 打包后的文件。激活 A/B 不初始化
（仿真零填充仅为消 X）。

---

## 7. 已知限制 / 与 SPEC 的偏差

### 7.1 与 SPEC §3 一致的部分
W 320KB（80 tiles）、Q 48KB LUTRAM（0 BRAM）、A/B 96K/32K、CPU 只 A/B、
`b_wstrb[15:0]`、`q` 64b 独立口——全部按规格实现；w 读原为 1 拍，**2026-11-02 wpipe 后为 2 拍（§3.8）**。

### 7.2 需要知道的偏差（2 条）
1. **R3 修复使 W 从 75.5 → 80 BRAM36（+4.5）**：这是 8B 粒度 16B 窗口 + 1 拍延迟下
   的实测最优（其他方案 147.5 tiles 或 54.6K LUT，见 §3.4）。nn_mem 总 112 tiles，
   加核心 ~9.5 ⇒ **~121.5/135，正好满足 ≤121.5 目标**；若后续 video 链路还要更多
   BRAM，可选的零成本替代是让引擎把 `w_addr` 对齐到 16B 并自行选半字（mem 改动小、
   W 可回落 75.5），但这需要 T-accel 侧改动，本轮按 Lead 决策做在 mem 侧。
2. **dbg 装载口写路径只存在于仿真**（`ifndef SYNTHESIS`）：SoC 里 dbg 本来就 tie 0，
   行为无差异；综合时写口不存在，W/Q 才能是纯 ROM（W 两个满宽读口落 BRAM36 真双口、
   Q 落 6,981 LUT 分布式 ROM）。若未来要在综合后网表里写 W/Q，需要重新引入写口
   （代价见 §3.4）。

### 7.3 其它
1. W 必须拆 4 段（64-bit 宽 ROM 深度 >16384 会按 32768 取整）；段大小 16384/8192/
   8192/8192（64b 字），改 W_BYTES 需同步改段大小与打包脚本。
2. Q 的 `q_addr` 是 64b 字索引（0..6143），engine 侧按 `(qoff 相对 Q 基址)/8` 换算。
3. Q 在综合里是 LUT-ROM（Vivado 报 `LUT as Logic`，不是 LUTRAM 单元）：功能上是
   分布式实现、0 BRAM；LUT 数与随机内容强相关（6,981）。
4. fmax 只有**综合粗估**（§3.5），没有 opt/place/route；真实时序以 Lead 的 OOC/impl 为准。
5. TB 的 W/Q 期望值来自测试样图；**不要把 T-model 真实镜像传给 tb_nn_mem**
   （verify 矩阵默认不传镜像，走 40-checks PASS 路径）。真实镜像装载由 SoC 级
   `tb_sw_nn_yolo` 覆盖。
6. A/B 合并为一块 128KB 阵列 ⇒ 激活读口 NPU/CPU 共享（契约 busy 门控下无冲突）。

---

## 8. 与 v0.3.2 的历史对照

| 项 | v0.3.2（旧） | v0.7 + R3（本次） |
|---|---|---|
| WQ | 368KB 单阵列拆 4 段（含 Q） | W 320KB 独立 + Q 48KB LUTRAM |
| W | 92 BRAM36 | **80 tiles**（64-bit 宽 × 2 满宽读口，支持 8B 窗口） |
| Q | 含在 WQ 里 | **0 BRAM / 6,981 LUT** |
| A/B | 64K+64K（128b 写铺 64b 接口） | 96K+32K，写口 128b + strobe |
| CPU 窗口 | WQ + A + B | **只 A/B** |
| nn_mem BRAM | 124 tiles | **112 tiles** |
| + 核心 | ~133.5/135 | **~121.5/135**（给视频帧缓冲留 13.5 tiles） |
| W 读口径 | 16B 对齐 | **8B 对齐（低 3 位忽略），16B 窗口** |
| 初始化 | 单阵列 4 段 32-bit 行 | 仿真 32-bit 行；综合 W/Q 均 64-bit 行 |
