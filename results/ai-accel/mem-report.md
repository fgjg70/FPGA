# AI 加速子系统 · nn_mem 存储交付报告（v0.7 特化架构）

> 交付人：T-mem。日期：2026-11-01。分支：`feat/ai-accel`。
> 规格：`results/ai-accel/SPEC-SPECIALIZED.md` §3 + `MODEL-FREEZE.md`（D1–D5）。
> 上一版（v0.3.2，WQ 368KB 全 BRAM / A=B=64KB）作历史对照保留在 §9。
> 本报告所有数字都带出处（命令/日志路径），无"看起来对"的结论。

---

## 0. 一句话结论

**nn_mem v0.7 完成：W 320KB 落 75.5 个 BRAM36、Q 48KB 落分布式 ROM（0 BRAM，6,981 LUT）、
A/B 128KB 落 32 个 BRAM36 ⇒ nn_mem 合计 107.5 tiles；加交付档核心约 9.5 ⇒ 约 117/135，
满足"整机 BRAM ≤121.5/135、给视频帧缓冲腾地方"的目标。** tb_nn_mem 三种加载模式全 PASS。

---

## 1. 交付文件

| 文件 | 说明 |
|---|---|
| `nn_mem.sv`（仓库根） | v0.7 存储子系统（Q LUTRAM / W 128b / A,B 128b+strobe / dbg 装载口） |
| `sim/tb_nn_mem.sv` | 自检 TB（`MEM_TB: PASS/FAIL` + mismatch/xerr；X 用 `!==` 显式报错） |
| `results/ai-accel/mem-report.md` | 本文件 |
| `results/ai-accel/proto/mem/nn_mem_synth_top.sv` | 综合取证小顶层（动态全地址激励 + dbg tie 0） |
| `results/ai-accel/proto/mem/synth_nn_mem.tcl` | 纯 ASCII，非工程模式 `synth_design` + `report_utilization` |
| `results/ai-accel/proto/mem/run_synth.bat` | 纯 ASCII，一键生成镜像 + 综合出全部报告 |
| `results/ai-accel/proto/mem/gen_wq_image.py` | 生成仿真/综合镜像（测试样图 或 `--seed` 伪随机） |

未修改任何 Lead 文件（`nn_pkg.sv` / `nn_subsys.sv` / `nn_conv_engine.sv` / `build*.tcl` /
`fpga_workflow.py` / `sw/**` / `tools/yolo/**`）。

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
  input  logic [23:0]  w_addr,        // W 区字节偏移, 16B 对齐 (低 4 位忽略)
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
  // debug 装载口 (module 级 TB 用; SoC 恒 0)
  input  logic         dbg_we,
  input  logic         dbg_space,     // 0=W, 1=Q
  input  logic [16:0]  dbg_addr,      // 32-bit 字索引
  input  logic [31:0]  dbg_wdata
);
```

### 2.1 读/写口径（1 拍寄存读，地址第 N 拍、数据 N+1 拍有效）

| 口 | 语义 |
|---|---|
| `w_*` | `w_addr` = W 区字节偏移（0x00000..0x4FFFF，16B 对齐，低 4 位忽略）；`w_rdata[127:0]` = 16 字节小端；越界 -> 128'b0 |
| `q_*` | `q_addr` = **64-bit Q 字索引**（Q 48KB = 6144 个 64b 字）；`q_rdata[63:0] = {Q32[2k+1], Q32[2k]}`（低地址 32 位字在 `[31:0]`）；`q_addr>=6144` -> 64'b0 |
| `a_*` | `a_sel` + `a_addr`（绝对窗口偏移，16B 对齐）；A=[0x60000,0x78000)、B=[0x78000,0x80000)；sel/地址归属不符或越界 -> 128'b0；`a_rdata` = 16 字节小端 |
| `b_*` | 128b 整字 + `b_wstrb[15:0]` 字节使能；**不做 RMW**；`b_addr` 16B 对齐 |
| `cpu_*` | `cpu_addr` 是**窗口内字节偏移**（不是 0x9004_xxxx 绝对地址！）；只 A/B 命中，其余读 0 / 写忽略（不产生 err）；32 位 + `cpu_wstrb` 字节写；1 拍寄存读 |
| `dbg_*` | `space=0`: `dbg_addr[16:2]` 选 128b 字、`[1:0]` 选 32b lane；`space=1`: `dbg_addr[13:1]` 选 64b 字、`[0]` 选半字。**仿真可用；综合时写路径置常量 0（见 §6.3）** |

### 2.2 物理组织

| 区 | 容量 | 实现 | 综合实测 |
|---|---|---|---|
| W | 320KB | 4 段 128-bit 宽阵列：8192 / 4096 / 4096 / 4096 个 128b 字（128KB / 64KB / 64KB / 64KB），每拍 4 段并行读后按段 mux | **74 RAMB36 + 3 RAMB18 = 75.5 tiles** |
| Q | 48KB | 64-bit 宽 × 6144 深分布式 ROM（`(* ram_style="distributed" *)`），单读口 | **0 BRAM，6,981 LUT**（LUT-ROM） |
| A/B | 96KB+32KB | 一块 128-bit 宽 × 8192 深阵列（A/B 连续，靠地址隔离） | **32 RAMB36** |
| **合计** | — | — | **107.5 tiles**；+核心 ~9.5 ⇒ **~117/135** |

---

## 3. Vivado 2018.3 综合证据（核心交付）

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
| Slice LUTs*       | 6991 |     0 |     63400 | 11.03 |
|   LUT as Logic    | 6991 |     0 |     63400 | 11.03 |
|   LUT as Memory   |    0 |     0 |     19000 |  0.00 |
| Slice Registers   |  774 |     0 |    126800 |  0.61 |
| Block RAM Tile    |107.5 |     0 |       135 | 79.63 |
|   RAMB36/FIFO*    |  106 |     0 |       135 | 78.52 |
|     RAMB36E1 only |  106 |       |           |       |
|   RAMB18          |    3 |     0 |       270 |  1.11 |
+-------------------+------+-------+-----------+-------+
```

层次归属（`v07_util_hier.rpt`）：

```
|   u_dut | nn_mem | LUT 6981 | LUTRAM 0 | FF 71 | RAMB36 106 | RAMB18 3 |
```

**W/Q 落点**（综合 log 的 "ROM:" 表，`%TEMP%\nn_mem_v07_synth\vivado.log`）：

```
ROM:
| nn_mem | w_rd_a_reg | 8192x128 | Block RAM |
| nn_mem | w_rd_b_reg | 4096x128 | Block RAM |
| nn_mem | w_rd_c_reg | 4096x128 | Block RAM |
| nn_mem | w_rd_d_reg | 4096x128 | Block RAM |
| nn_mem | p_0_out    | 8192x64  | LUT       |   <- Q 分布式 ROM (LUT 实现, 0 BRAM)
Block RAM: act_mem_reg 8Kx128 ... RAMB36 = 32     <- A/B 32 块
```

### 3.3 账目核对

| 项 | 数字 | 说明 |
|---|---|---|
| W | 74 RAMB36 + 3 RAMB18 = 75.5 tiles | 128-bit 宽 ROM；单块 20480 深会被按 32768 取整成 128 块，必须 4 段 |
| A/B | 32 RAMB36 | 128KB / 4KB per BRAM = 32（精确） |
| Q | 0 BRAM / 6,981 LUT | 分布式 ROM |
| nn_mem 合计 | **107.5 tiles** | `Block RAM Tile 107.5/135` |
| + 交付档核心 | ~9.5 tiles | 交付档 `fpga/util.rpt`：RAMB36=8 + RAMB18=3 |
| **整机估算** | **~117/135** | ≤121.5 目标 ✓（余 ~18 tiles 给视频链路/320 tile 缓存） |

### 3.4 重要方法学（证据有效性）

1. **镜像内容必须不可压缩**：测试样图 `wpat32/qpat32` 是线性结构，Vivado 会把它优化成
   压缩实现——实测同一份 RTL 用测试样图只报 68 RAMB36+3 RAMB18（W）/ 2,446 LUT（Q），
   用 `--seed` 伪随机内容则是 74+3（W）/ 6,981 LUT（Q）。真实权重/量化参数不可压缩，
   **本报告采用随机内容数字**（保守、可复现：`run_synth.bat` 已带 `--seed 20261101`）。
2. **激励必须覆盖全地址**：只喂窄地址范围会被综合器按"地址可达范围"裁掉 RAM 容量
   （v0.3.2 取证第一版踩过）。`nn_mem_synth_top.sv` 用快/慢两个计数器打通所有地址位。
3. **dbg 写口在综合时置常量 0**：保留写口会让 Q 从 LUT-ROM（6,981 LUT）变成
   分布式 RAM（12,288 LUTRAM，+76%）。见 §6.3。

### 3.5 时序粗估（**不是**实现后 fmax / 上板实测）

`v07_timing.rpt`：`create_clock 10ns (100MHz)` 下 **WNS = +6.102ns**（2723 端点，0 失败）
⇒ 综合网表粗估 `fmax ≈ 1/(10-6.102) ≈ 256MHz`。仅说明"107.5 块 BRAM 的读口/译码逻辑
不是 100MHz 瓶颈"；真实 fmax 以 Lead 的 OOC/impl 数据为准。

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

实测（2026-11-01）：

```
# ① +nnwq=<94208 行 32-bit>  (W 81920 + Q 12288 顺序拼接)
# [nn_mem] WQ image loaded: ...\yolo_wq.hex (W 20480 x128b, Q 6144 x64b)
# [MEM_TB] W sweep done: 20480 reads, fnv=0x5b283069/0x5b283069
# [MEM_TB] Q sweep done: 6144 reads, fnv=0xfd77f0ce/0xfd77f0ce
# [MEM_TB] SUMMARY checks=26666 w_sweep=20480 q_sweep=6144 act=8 cpu=10
# MEM_TB: PASS (checks=26666, mismatch=0, xerr=0)

# ② +nnw=<yolo_w.hex> +nnq=<yolo_q.hex>  -> 同上, MEM_TB: PASS (26666/0/0)

# ③ 无镜像 -> SKIP 扫描, MEM_TB: PASS (checks=40, mismatch=0, xerr=0)
```

日志：`%TEMP%\nn_mem_v07\tb_a.log` / `tb_b.log` / `tb_c.log`。

### 4.2 TB 覆盖点

① W 128b 全量扫描（20,480 次 = 81,920 个 32-bit 字）+ FNV-1a 校验和；
② Q 64b 全量扫描（6,144 次 × 64b）+ FNV；
③ dbg 装载口：写 W 的 128b 字内不同 lane（含段 B 首字、最后字）、写 Q 的 64b 字内半字，
   经 NPU 口回读；
④ A/B：128b 写 + `b_wstrb` 单字节/低 64b/高 64b 写（验证无 RMW、相邻半字不被覆盖）、
   128b 读、A/B 同偏移不串扰、A/B 最后 16B 边界、非法 sel/越界 -> 0；
⑤ CPU 窗口：A/B 1 拍读写 + 字节写；W/Q/空洞/越界读 0；CPU 写 W/Q 被忽略（内容经
   dbg/NPU 口回读确认不变）；`addr==512KB -> 0`；
⑥ 复位：复位期间/之后输出全 0 无 X；中途复位不清存储内容；看门狗超时打 FAIL。

---

## 5. 初始化镜像

| 用途 | 格式 | 生成 |
|---|---|---|
| 仿真 | 32-bit 字/行（8 hex）：`+nnw=` 81,920 行 / `+nnq=` 12,288 行 / 旧 `+nnwq=` 94,208 行（W+Q 顺序拼接） | T-model 的 `yolo_w.hex` / `yolo_q.hex` 直接可用 |
| 综合 | W 4 段 **128-bit/行**（32 hex）8192/4096/4096/4096 行 → `NN_W_INIT_A..D`；Q **64-bit/行**（16 hex）6,144 行 → `NN_Q_INIT_FILE` | Lead 的 `fpga_workflow.py` 从 32-bit 行镜像打包（已确认口径） |

打包公式（低字在低 32 位）：
- W 128b 行 k：`W32[4k] | W32[4k+1]<<32 | W32[4k+2]<<64 | W32[4k+3]<<96`；
- Q 64b 行 k：`Q32[2k] | Q32[2k+1]<<32`。

仿真侧 `nn_mem` 内置小 loader（`$fgets/$sscanf`，仅非 SYNTHESIS 分支）把 32-bit 行打包成
物理字宽；综合侧直接 `$readmemh` 打包后的文件。激活 A/B 不初始化（仿真零填充仅为消 X）。

---

## 6. 已知限制 / 与 SPEC 的偏差

### 6.1 与 SPEC §3 一致的部分
W 320KB (80→实测 75.5 tiles)、Q 48KB LUTRAM (0 BRAM)、A/B 96K/32K、CPU 只 A/B、
b_wstrb[15:0]、q 64b 独立口——全部按规格实现。

### 6.2 dbg 装载口（新增，SPEC 文本外，Lead 要求）
端口在仿真/综合都存在；**综合时写路径被 `ifdef SYNTHESIS` 置常量 0**（SoC 本来就 tie 0，
行为无差异），这样 Q 才能落 6,981 LUT 的分布式 ROM，而不是 12,288 LUTRAM（+76% LUT）。
module 级 TB 在仿真里正常用 dbg 初始化/回读。若未来需要在**综合后网表**里写 W/Q，
需要重新引入写口（代价见 §3.4-3）。

### 6.3 其它
1. W 必须拆 4 段（128-bit 宽 ROM 深度 >16384 会被按 32768 取整）；段边界
   `8192/12288/16384` 个 128-bit 字是地址译码的一部分，改 W_BYTES 需同步改段大小与
   打包脚本（RTL 用 localparam 自动算 D 段）。
2. Q 的 `q_addr` 是 64b 字索引（0..6143），engine 侧需按 `(qoff + 字节偏移)/8` 换算。
3. Q 在综合里是 LUT-ROM（Vivado 报 `LUT as Logic`，不是 LUTRAM 单元）：功能上是
   分布式实现、0 BRAM，符合"Q 不占 BRAM"的硬目标；LUT 数与随机内容强相关（6,981）。
4. fmax 只有**综合粗估**（§3.5），没有 opt/place/route；真实时序以 Lead 的 OOC/impl 为准。
5. TB 的 W/Q 期望值来自测试样图；**不要把 T-model 真实镜像传给 tb_nn_mem**
   （verify 矩阵默认不传镜像，走 40-checks PASS 路径）。真实镜像装载由 SoC 级
   `tb_sw_nn_yolo` 覆盖。
6. A/B 合并为一块 128KB 阵列 ⇒ 激活读口 NPU/CPU 共享（契约 busy 门控下无冲突）。

---

## 7. 与 v0.3.2 的历史对照

| 项 | v0.3.2（旧） | v0.7（本次） |
|---|---|---|
| WQ | 368KB 单阵列拆 4 段（含 Q） | W 320KB 4 段（仅权重）+ Q 48KB LUTRAM |
| W | 92 BRAM36 | 75.5 tiles（128b 读口） |
| Q | 含在 WQ 里 | **0 BRAM / 6,981 LUT** |
| A/B | 64K+64K（128b 写铺 64b 接口） | 96K+32K，写口 128b + strobe |
| CPU 窗口 | WQ + A + B | **只 A/B** |
| nn_mem BRAM | 124 tiles | **107.5 tiles** |
| + 核心 | ~133.5/135 | **~117/135**（给视频帧缓冲留 ~18 tiles） |
| 初始化 | 单阵列 4 段 32-bit 行 | 仿真 32-bit 行；综合 W 128b 行 / Q 64b 行 |
