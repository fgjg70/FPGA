# AI 加速子系统 · nn_mem 大 BRAM 存储交付报告

> 交付人：T-mem。日期：2026-10-31。分支：`feat/ai-accel`。
> 契约：`results/ai-accel/CONTRACT.md` v0.3（§2/§3/§8/§9.1/§10）。
> 方案：`results/ai-accel/PLAN.md` §2。
> 结论一句话：**nn_mem.sv 已实现并 TB 全绿；Vivado 2018.3 综合实测 124 个 BRAM36
> （WQ 92 + 激活 32），加上已交付 CPU 核约 9 块 = 约 133/135，大 BRAM 方案可落地。**
> 旧契约尺寸（Q=16K, A=B=128K）实测**超器件**（需求 148 > 135），已用综合证据封死。

---

## 1. 交付文件

| 文件 | 说明 |
|---|---|
| `nn_mem.sv`（仓库根） | 512KB NN 存储子系统（WQ 32 位字 TDP 阵列拆 4 段 + 激活区 128 位阵列）+ 子模块 `nn_mem_wq` / `nn_mem_act` |
| `sim/tb_nn_mem.sv` | 自检 TB，判据 `MEM_TB: PASS/FAIL` + mismatch/xerr 计数 |
| `results/ai-accel/mem-report.md` | 本文件 |
| `results/ai-accel/proto/mem/nn_mem_synth_top.sv` | 综合取证小顶层（v0.3 与旧 v0.2 两套参数） |
| `results/ai-accel/proto/mem/synth_nn_mem.tcl` | 纯 ASCII，非工程模式综合脚本（`synth_design` + `report_utilization`） |
| `results/ai-accel/proto/mem/run_synth.bat` | 纯 ASCII，一键：生成镜像 + 跑两套综合 |
| `results/ai-accel/proto/mem/gen_wq_image.py` | 生成 WQ 镜像（仿真单文件 / 综合 4 段拆分） |

> 本任务**未修改**任何 Lead 文件（`rv32_pkg.sv` / `nn_pkg.sv` / `build*.tcl` /
> `fpga_workflow.py` / `core.sv` / `mmio_subsys.sv` / `nn_subsys.sv` / `nn_conv_engine.sv`）。

---

## 2. 最终参数与布局（v0.3.2）

```systemverilog
module nn_mem #(
  parameter int W_BYTES = 320*1024,   // 权重区
  parameter int Q_BYTES = 48*1024,    // 量化参数区（紧接 W，变长紧凑布局）
  parameter int A_BYTES = 96*1024,    // 激活 A（128 输入最大单张量 24ch×64×64=96KB）
  parameter int B_BYTES = 32*1024,    // 激活 B（残差/小张量）
  parameter int CPU_AW  = 19          // CPU 窗口 512KB
)(... 12 个端口，见 CONTRACT §9.1 v0.2/v0.3 ...);
```

| 区 | 窗口字节偏移 | 容量 | 物理组织 |
|---|---|---|---|
| WQ | `0x00000..0x5BFFF` | 368KB（W 320K + Q 48K 连续） | 32 位字 TDP 阵列，按 2 的幂拆 **4 段**（65536/16384/8192/4096 words） |
| 空洞 | `0x5C000..0x5FFFF` | 16KB（不分配 BRAM） | 读 0 / 写忽略 |
| A | `0x60000..0x77FFF` | 96KB | 与 B **合并**成一块 128 位宽、8192 字深阵列（A/B 靠地址隔离） |
| B | `0x78000..0x7FFFF` | 32KB | 同上 |

- `B_OFF = nn_pkg::NN_A_OFF + A_BYTES = 0x78000`（与 Lead 改后的 `nn_pkg::NN_B_OFF` 一致，TB 的 CONFIG 打印会核对）。
- **A/B 物理上合并成一块 128KB 阵列**（不是两块独立阵列），原因见 §4.2：独立 96KB + 32KB 阵列
  会被 Vivado 映射成 32+16=48 块 BRAM（每块 128 位宽阵列的映射粒度是 64KB/层），而合并后
  128KB 恰好 32 块 —— 逻辑接口 `a_sel/b_sel` 与 A/B 地址语义完全不变，总 BRAM 与
  "A 24 + B 8" 的账**等价**（都是 32）。

### 2.1 口口径（给集成/引擎同事，必须按这个理解）

1. **`cpu_addr` 是 NN 窗口内字节偏移，不是绝对地址**（不是 `0x9004_xxxx`）。
   SoC 集成时由 `nn_subsys` 做 `cpu_off = cpu_addr - NN_BASE` 后接给 nn_mem；
   接绝对地址会被判 ≥512KB 越界 → 静默读 0/写丢弃（Lead 已修，见 nn_subsys 注释）。
2. `w_addr` = 全窗口字节偏移（8 字节对齐，低 3 位忽略）；`w_addr < 0x5C000` → 64 位读
   `{WQ32[2k+1], WQ32[2k]}`（低地址字在 `w_rdata[31:0]`）；其余 → 64'b0。
3. `a_addr` = 全窗口字节偏移（16 字节对齐）；`a_rdata = {word[A/8+1], word[A/8]}`
   （低地址 64 位字在 `[63:0]`）；`a_sel` 与地址归属不一致/越界 → 128'b0。
4. `b_addr` = 全窗口字节偏移（8 字节对齐）；64 位整字写，低地址字节在 `b_wdata[7:0]`；
   `b_addr[3]` 选 128 位物理字的低/高 64 位半字。
5. 读延迟：**地址第 N 拍、数据第 N+1 拍有效**（与 dmem 同口径，w/a 口一致）。
6. CPU 与 NPU 同拍访问同一存储体 = 未定义（NPU 优先）；契约 §2 的 busy 门控保证不发生。
   A/B 合并后激活读口由 NPU/CPU 共享，**不存在**"同拍 NPU 读 + CPU 读"的并行用法。

---

## 3. 仿真自检（ModelSim SE-64 2020.4）

### 3.1 跑法 A：带合成镜像（WQ 全量扫描）

```bat
vlib work
vlog -sv -work work <repo>\rv32_pkg.sv <repo>\nn_pkg.sv <repo>\nn_mem.sv <repo>\sim\tb_nn_mem.sv
rem 镜像由 proto/mem/gen_wq_image.py 生成（94208 行 x 8 hex，模式 (i*0x9E3779B9)^0xC0DE0000）
vsim -c -do "run -all; quit -f" work.tb_nn_mem +nnwq=<绝对路径>\yolo_wq.hex
```

实测输出（2026-10-31 22:05）：

```
# [nn_mem] CONFIG W_BYTES=327680 Q_BYTES=49152 A_BYTES=98304 B_BYTES=32768 WQ=368KB (words=94208)
# [nn_mem] CONFIG A_OFF=0x60000 A_END=0x78000 B_OFF=0x78000 B_END=0x80000 CPU_WIN=0x80000
# [nn_mem] WQ image loaded: ...\yolo_wq.hex (94208 / 94208 words)
# [MEM_TB] WQ sweep done: 47104 reads, fnv_read=0x3b1b91d9 fnv_exp=0x3b1b91d9
# [MEM_TB] SUMMARY checks=47157 wq_reads=47104 act_checks=6 cpu_checks=23
# MEM_TB: PASS (checks=47157, mismatch=0, xerr=0)
```

### 3.2 跑法 B：不带镜像（集成/verify 默认；T-model 真实镜像不要往这里塞）

```
vsim -c -do "run -all; quit -f" work.tb_nn_mem
# [MEM_TB] SKIP WQ image sweep (+nnwq not given); WQ-dependent checks skipped
# [MEM_TB] SUMMARY checks=42 wq_reads=0 act_checks=6 cpu_checks=15
# MEM_TB: PASS (checks=42, mismatch=0, xerr=0)
```

- 无镜像时**不会 fatal**，镜像相关检查打印 `SKIP`，其余（CPU 读写/激活 A/B/越界/复位）照测。
- **重要口径**：TB 的 WQ 期望值来自它自己的合成模式 `wq_exp(i)=(i*0x9E3779B9)^0xC0DE0000`，
  只能配 `gen_wq_image.py` 生成的**合成镜像**。把 T-model 的真实 `yolo_wq.hex` 传给
  `tb_nn_mem` 会出现 47116 项"不匹配"——那是**测试口径错**，不是 RTL 错。
  `fpga_workflow.py verify` 已改为 **tb_nn_mem 不传 +nnwq**；真实镜像装载由 SoC 级
  `tb_sw_nn_yolo` 覆盖。
- 日志留档：`%TEMP%\nn_mem_dev\tb_final_with_img.log`、`tb_final_no_img.log`。

### 3.3 TB 覆盖点

① WQ `$readmemh` 装载：47,104 次 64 位 NPU 全量扫描 + FNV-1a 校验和独立比对；
② CPU 32 位读（W/Q 区抽查）、WQ 区写/读、W/Q 区**字节写（wstrb 组合）**；
③ 激活 A/B：NPU 64 位写 / 128 位读、A/B 不串扰、CPU 32 位读写/字节写、NPU 读与 CPU 读顺序一致；
④ CPU 窗口：空洞 `0x5C000..0x5FFFF`、`addr==512KB`、远越界 → 读 0 / 写忽略；
⑤ 复位：复位期间/之后输出无 X；中途复位不清存储内容；
⑥ 越界/非法 sel：w 口落在 A/B 区/空洞/越界 → 64'b0；a 口 sel 与地址不符 → 128'b0。
所有比较用 `!==`（X 记为独立 `xerr` 计数）；看门狗超时打 `MEM_TB: FAIL` + `$fatal`。

---

## 4. Vivado 2018.3 综合证据（核心交付）

### 4.1 一键复现

```bat
rem 纯 ASCII；内部会用 settings64.bat + PROCESSOR_ARCHITECTURE=AMD64
results\ai-accel\proto\mem\run_synth.bat
rem 产物在 %TEMP%\nn_mem_synth\：v03_util.rpt / v03_util_hier.rpt / v03_timing.rpt /
rem v03_paths.rpt，以及 v02_*（旧契约对照）
```

综合命令（tcl 内）：`synth_design -top <top> -part xc7a100tfgg484-2 -verilog_define {NN_WQ_INIT_A=...; _B; _C; _D}`，
约束 `create_clock -period 7.619 [get_ports clk]`（131.25 MHz，仅用于综合后估计）。

### 4.2 结论表

| 配置 | WQ | 激活 (A+B) | nn_mem 合计 | 旧配置对照 |
|---|---|---|---|---|
| **v0.3.2（交付）** W=320K/Q=48K/A=96K/B=32K | **92** | **32**（合并 128KB） | **124** | — |
| 旧契约 v0.2 W=320K/Q=16K/A=B=128K | 84 | 64（合并 256KB） | **148（>135 不可实现）** | 实测超限 |

**v0.3.2 实测（`%TEMP%\nn_mem_synth\v03_util.rpt`）：**

```
2. Memory
+-------------------+------+-------+-----------+-------+
|     Site Type     | Used | Fixed | Available | Util% |
+-------------------+------+-------+-----------+-------+
| Block RAM Tile    |  124 |     0 |       135 | 91.85 |
|   RAMB36/FIFO*    |  124 |     0 |       135 | 91.85 |
|     RAMB36E1 only |  124 |       |           |       |
|   RAMB18          |    0 |     0 |       270 |  0.00 |
+-------------------+------+-------+-----------+-------+
```

**层次归属（`%TEMP%\nn_mem_synth\v03_util_hier.rpt`）：**

```
|     u_dut   |   nn_mem   | LUT 588 | FF 10 | RAMB36 124 |
|       u_act | nn_mem_act | LUT 297 | FF  0 | RAMB36  32 |
|       u_wq  |  nn_mem_wq | LUT 290 | FF  4 | RAMB36  92 |
```

⇒ **WQ 92（65536+16384+8192+4096 words 四段分别为 64/16/8/4 块）+ 激活区 32 = 124 块**，
与设计预期完全一致；`Block RAM Tile 124/135 = 91.85%`。

**旧契约 v0.2 对照（`%TEMP%\nn_mem_synth\v02_util.rpt` + `vivado.log`）：**

```
WARNING: [Synth 8-5835] Resources of type BRAM have been overutilized.
         Used = 296, Available = 270. Will try to implement using LUT-RAM.
```

（296 个 BRAM18 单位 = 148 个 BRAM36 > 器件 135；综合器被迫回退 LUT-RAM
—— 旧尺寸不可实现，**这是"必须缩 A/B 并改 Q 布局"的直接综合证据**。）

**与已交付 CPU 核合计（AI 档）**：交付档核心 `fpga/util.rpt` 为 `Block RAM Tile 9.5`
（RAMB36=8 + RAMB18=3，即 imem 4 + dmem 4 + 3×RAMB18）。AI 档核心结构不变，因此
`124 + 9.5 ≈ 133.5`，即 **≤135，余 1~2 个 tile**。Lead 侧"92+24+8+9=133"的账与实测总数
一致（差异只在 A/B 的 24+8 是逻辑容量账，物理上合并成 128KB 一块阵列后恰好 32 块）。

### 4.3 映射规律（为什么参数要这么定 —— 实测归纳，不是猜）

用独立小实验（`%TEMP%\nn_ram_lab\`，纯输入端口、地址全域可达，避免综合器按
"地址可达范围"裁剪 RAM）测得 Vivado 2018.3 对本器件的行为级 RAM 映射规律：

| 实验 | 容量/组织 | 实测 BRAM36 | 结论 |
|---|---|---|---|
| 32 位扁平 TDP, depth 4096/8192/16384 | 16/32/64KB | 4/8/16 | ≤16384 words 时精确 4KB/BRAM |
| 32 位扁平 TDP, depth 28672 | 112KB | 32（非 28） | >16384 words 按 32768 words 取整 |
| 32 位扁平 TDP, depth 47104 / 61440 / 94208 | 184/240/368KB | 64 / 64 / 96 | 同上（94208→98304 →96） |
| **23 段 × 4096 words 拆分** | 368KB | **92** | 拆成 ≤16384 且 2 的幂的段 → 精确 |
| 128 位宽 SDP, depth 4096 / 8192 | 64KB / 128KB | 16 / 32 | 128 位宽映射粒度 64KB/层 |
| 单独 96KB 128 位阵列 | 96KB | **32**（非 24） | 独立 A/B 阵列会浪费（96→2 层=32） |
| A+B 合并 128KB 128 位阵列 | 128KB | **32** | 合并后精确，等价于"24+8" |
| 2D 数组 + 逐行 generate（想省 init 文件） | 368KB | 综合报错 | `variable 'mem' too large (>1,000,000 bits)`，不可行 |

> 附注：这几个实验还发现"只给窄地址范围做激励"会把 RAM 裁小、得出虚假偏小的 BRAM 数
> （proto 第一版就踩了）—— 综合取证的激励必须让**所有地址位动态可达**，否则数字无效。
> 这也是为什么 `nn_mem_synth_top.sv` 用快/慢两个计数器覆盖全地址。

### 4.4 综合后时序粗估（**不是**实现后 fmax，也不是上板实测）

`v03_timing.rpt`：`create_clock 7.619ns (131.251MHz)` 下 **WNS = +2.662ns**（4049 个端点，
0 失败）⇒ 综合网表粗估 `fmax ≈ 1/(7.619-2.662) ≈ 201.7MHz`（无布局布线、无 IO 约束，
仅说明"134 块 BRAM 的读口/译码逻辑不会成为 131.25MHz 的瓶颈"；真实 fmax 以 Lead 的
impl/上板数据为准）。

---

## 5. 初始化镜像（集成必读）

- **仿真**：单个 `+nnwq=<file>`（契约 §10 格式，每行 8 hex = 32 位字，默认 94208 行）。
  `nn_mem_wq` 内部用 `$fgets/$sscanf` 逐行分派到 4 段（`$readmemh` 无法对 4 段分别给文件偏移）。
- **综合**：`$readmemh` 只能按"数组起点"装载，4 个子阵列需要**最多 4 个镜像文件**：
  `NN_WQ_INIT_A`（65536 行）/ `_B`（16384 行）/ `_C`（8192 行）/ `_D`（4096 行，v0.3 需要；
  旧 Q=16K 配置下 C=4096、D 不需要）。由 build flow 从单一 `yolo_wq.hex` **顺序切分**得到
  （`gen_wq_image.py --split-prefix` 已实现并用于本次综合取证）。
  → **Lead/build.tcl 侧需按这 4 个宏传 define**；若只给单文件，则综合只能得到 96 块 WQ
  （多 4 块，预算不够），因此这 4 个宏是"92 块"的必要条件。
- 激活 A/B **不初始化**（v0.3 取消 `NN_ACT_INIT_FILE`）。

---

## 6. 已知限制 / 风险

1. **BRAM 余量只剩 1~2 个 tile**：`124 + 核心 9.5 = 133.5/135`。任何"再加一块缓冲/双份权重"
   都会失败；后续若 T-model 峰值激活超过 A=96KB/B=32KB，必须先报 Lead，**不要偷偷缩小模型**。
2. **WQ 是 4 段拆分结构**：段边界 `65536/81920/90112` words 是地址译码的一部分；若
   `W_BYTES/Q_BYTES` 再变，需要同时改 `gen_wq_image.py` 的拆分点和 build flow 的宏
   （RTL 内部用 localparam 自动算 C/D 段大小，但"2 的幂 + ≤16384"的约束必须满足）。
3. **A/B 合并成一物理阵列** ⇒ 激活读口 NPU/CPU 共享，不存在同拍并行读；与契约 §2 的
   busy 门控一致。若未来需要"NPU 读 + CPU 读同拍"，需要把 A/B 再拆开（**+16 块 BRAM，预算不允许**）。
4. **综合初始化需要 4 个宏/文件**（见 §5），这是单镜像契约在综合侧的已知偏离；仿真侧
   仍严格吃契约的单文件格式。
5. **fmax 只有综合粗估**（§4.4），没有跑 opt/place/route；真实时序以 Lead 的 impl 为准。
6. TB 的 WQ 期望值是合成模式，**不能**拿真实 `yolo_wq.hex` 去跑 `tb_nn_mem`（见 §3.2）；
   真实镜像由 SoC 级 `tb_sw_nn_yolo` 验证。
7. `cpu_addr` 是**窗口内偏移**（见 §2.1），集成层已修；此处再留一条给下一个人。
8. 本报告所有 `%TEMP%` 路径是本次取证机的临时路径；`run_synth.bat` 每次会重新生成，
   报告里的数字可由该 bat 一键复现。

---

## 7. 与 Lead 预算表的对照

| 项 | Lead 预期 | 实测 | 说明 |
|---|---|---|---|
| WQ | 92 | **92** | 需 4 段拆分 + 4 个综合镜像宏 |
| 激活 A+B | 24+8 = 32 | **32**（合并 1 块 128KB 阵列） | 分开做会变 32+16=48；合并后才 32 |
| nn_mem 合计 | 124 | **124** | `Block RAM Tile 124/135` |
| + 核心 | 9 | ~9.5（RAMB36 8 + RAMB18 3） | 交付档 `fpga/util.rpt` |
| **总计** | **133/135** | **≈133.5/135** | 余 1~2 tile |
| 旧契约 | 148（不可行） | 综合实测超限（296/270 BRAM18 单位） | 强制回退 LUT-RAM |
