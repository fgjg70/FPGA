> **范围/口径声明（证据/迭代文档）**：本文是开发迭代记录或证据文档，"实测"特指上板实测（附日志/清单路径），"派生/仿真"已分别标注。**Artix-7 XC7A100T 的所有数据按赛题规则仅作跨厂商对比**，交付主体为紫光同创 PG2L100H；完整边界见根 [`COMPLIANCE.md`](COMPLIANCE.md)。

# 基于 RISC-V 指令集的高性能软核处理器设计与实现

**设计报告 · 2026 紫光同创杯 · 赛题一「基于 RISC-V 处理器的软硬件系统设计」**

| 项 | 内容 |
|---|---|
| 作品名 | RV32IM 五级流水 RISC-V 软核处理器（含分支预测、精确异常/中断、原子扩展、QSPI 自启动） |
| 目标平台 | 现场可编程门阵列（FPGA），**最终交付需在紫光同创器件上复现**（见 §6.4 迁移状态） |
| 当前实测平台 | Xilinx Artix-7 XC7A100T-FGG484-**2**（达芬奇 Pro，板载 50 MHz 晶振 + MMCM） |
| 交付档 | **150 MHz**，fmax **150.2 MHz**（WNS **+0.007 ns**），CoreMark **324.19**（规范口径），CoreMark/MHz **2.1613** |
| 文档日期 | 2026-10-17 |
| 数据纪律 | 本报告所有数字均标注来源文件/行：`results/coremark.csv`（逐档台账）、`results/uart_*.txt`（上板原始输出）、`results/ila_done.*`、`fpga/timing.rpt`、`fpga/util.rpt`。**无一数字来自记忆或转述。** |

> **阅读提示（口径声明，务必先读）**
> 1. **fmax 必须带"时钟名 + 周期 + 运行频率 + WNS"**。本设计主时钟为 `sys_clk_core`（频率无关命名），
>    交付档周期 **6.667 ns**（运行 **150.00 MHz**）。历史文档中的 `1000/(20−WNS)` 是 MMCM 之前的失效口径，已废弃。
> 2. **CoreMark 分数有两个口径**：规范口径 **324.19**（全精度时间）；CoreMark 核心自身打印的
>    `Iterations/Sec 328` 是**整数秒截断**值（+1.3% 虚高），**不能**作为宣称分数。详见 §4.3。
> 3. **"仿真通过" ≠ "上板验证"**：前者判据是 testbench 打印 `RESULT : PASS`；后者判据是
>    采集清单（`*.capture.json`）+ 原始输出，**CSV 文件时间戳不是证据**。
> 4. 本报告**包含负结果**（§3.3/§3.4）。6 次"墙转移"与 8 组"留余量"失败实验全部照实记录 ——
>    它们是本设计最重要的工程方法证据。

---

## 1. 摘要

本作品在 FPGA 上实现了**五级流水 RISC-V（RV32IM + Zicsr + M-mode 异常/中断 + RV32A 原子扩展）处理器**，
目标是把"**架构效率（CoreMark/MHz）**"与"**可达频率（fmax）**"这两条常常互斥的曲线同时推高，
并以**可复核的实测**证明每一次收益与每一次代价。

**关键结果**（全部可在 `results/` 中逐条复核）：

| 指标 | 基线（5 级、无前递、无预测） | **本作品（150 MHz 交付档）** | 提升 | 源 |
|---|---|---|---|---|
| CoreMark/MHz | 0.8263 | **2.1613** | **+161.6%** | `coremark.csv` 行 `baseline-v1` / 上板输出 |
| fmax | 78.4 MHz（20 ns 约束口径） | **150.2 MHz**（`sys_clk_core` @6.667 ns，WNS +0.007） | **+91.6%**（跨约束，见注） | `coremark.csv` 行 `legal150-final` |
| CoreMark 分数（规范口径） | — | **324.19** | — | `uart_flash_boot_final.txt` |
| 绝对吞吐（CM/MHz × fmax） | 64.8 | **≈324** | **+400%** | 派生（§4.3） |
| 面积 | LUT 3499 / FF 732 / BRAM 0 / DSP 0 | **LUT 3098 / FF 1447 / BRAM 9 / DSP 8** | LUT −11%，BRAM/DSP 用于存储器与乘法 | `coremark.csv` 行 `legal150-final`、`baseline-v1` |
| 上板 | 50 MHz、1200 迭代、10.16 s | **150 MHz、4600 迭代、tick 2,128,330,453、14 s、CRC 四件套全对** | 墙钟缩短且完成自启动 | `uart_flash_boot_final.txt` |

> 注：基线 78.4 MHz 是 **20 ns 约束**下的测量，与 `sys_clk_core` 域**不可直接相减**（跨约束比大小会误导）。
> 本报告在 §4.1 给出**同约束族内**的演进链；跨约束只用于"量级"说明。

**三条最能代表工程深度的结论**：

1. **瓶颈是"族"，不是"某一条路径"**。本设计在冲频过程中累计遇到 **6 次"墙转移"**（消掉一族，另一族接班），
   每次都是"机制成功、时序净负"。真正的突破来自**一次砍掉一族共享的根源**（候选 E′：`!pipe_stall → !hold_mem`，
   一次治好三个 trap 族），而不是逐条死磕 top-1。方法论见 §3.5。
2. **"验证手段"本身要算进时序预算**。带 ILA 的网表在 150 MHz 过不去（−0.293~−0.514 ns），
   而评分流只差 0.172 ns ⇒ 不是核不够快，而是**用来观察它的调试核**吃掉了那 0.17 ns。
   打通 **UART 回读通道**（用评分流网表上板）后，150 MHz 才成为"只差 0.172 ns 的工程问题"。见 §5.2、§6.1。
3. **150 MHz 是压线交付，没有余量**（8 组"留余量"实验全部判负），因此**同时保留 138.75 MHz 退路**，
   并给出完整的两档证据。见 §4.4。

**交付物**：完整可综合 RTL（21 个 SystemVerilog 文件、5115 行）、裸机软件与 CoreMark 移植层、
自动化工具链（一条命令完成 环境自检/一致性检查/回归/综合/指标/上板解析）、
**ILA + UART + FLASH 三通道证据链**、以及本报告与 26 篇实测记录。

---

## 2. 系统架构

### 2.1 总体框图

```
                    ┌──────────────────────────── MMIO / 外设（fpga/mmio_subsys.sv）────────────────────────────┐
                    │  UART 115200 (TX/RX) │ GPIO │ 64-bit mtime 计数器 │ mtimecmp 定时器中断 │ 跑分上报寄存器 │
                    └───────────────────────────────────▲──────────────────────────────────────────────────────┘
                                                        │ ext_* 总线（core 内地址译码）
   ┌────────────────────────────────────────────────────┴──────────────────────────────────────────────────────┐
   │                                      core.sv（五级流水线，1748 行）                                         │
   │                                                                                                             │
   │  IF ──────────► IF/ID ──────► ID ───────► ID/EX ─────► EX ──────► EX/MEM ─────► MEM ─────► MEM/WB ──► WB    │
   │  pc_reg          imem 输出    译码/regfile  流水寄存器   ALU/分支/    流水寄存器    LSU/dmem   流水寄存器   wb mux  │
   │  pc_next        寄存器即      imm_gen       (id_ex_reg)  muldiv       (ex_mem_reg)  AMO/拆分    (mem_wb_reg) 写回    │
   │   ▲   │          IF/ID        ctrl_s                     branch_unit                MMIO                    │
   │   │   └── imem（16 KB BRAM，寄存读）                                                                        │
   │   │                                                                                                        │
   │   └── 分支预测（两级流水 gshare）：btb.sv（512 项 BTB）──► bht.sv（8192 项 × 2 位 PHT，1 块 RAMB18）        │
   │        · T 拍用 pc_next 查表 → T+1 拍 q_* 已是寄存器输出（零气泡）                                          │
   │                                                                                                             │
   │  冒险/重定向：hazard_unit.sv（前递选择 + load-use 停顿 + 重定向门控）                                        │
   │  精确异常/中断：csr_file.sv（mstatus/mie/mip/mtvec/mepc/mcause/mtval/mscratch）+ core 内陷阱仲裁             │
   │  可选协处理：gemm_accel.sv（GEMM_EN，默认关）；ras.sv（RAS_EN，默认关）                                      │
   └─────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 五级流水与"4 个流水寄存器 ⇒ 5 级"

流水级为 **IF / ID / EX / MEM / WB**，但**只有 3 个显式流水寄存器模块**
（`id_ex_reg.sv`、`ex_mem_reg.sv`、`mem_wb_reg.sv`）：**IF/ID 由 IMEM 的输出寄存器直接承担**。

> **这是最容易被误读的口径**：`imem` 采用**寄存读**（`always @(posedge clk) rdata <= mem[addr]`），
> 该输出寄存器本身就"装"着 IF/ID 的内容 ⇒ 全设计共 **4 个流水寄存器**（IMEM 输出 + ID/EX + EX/MEM + MEM/WB），
> 因此是 **5 级**，不是 4 级。历史文档曾把它写成"4 级流水"，是**把寄存器个数当成了级数**，已在
> `results/p8-ifid-elide.md` 与 `core.sv` 分节注释中双重更正。

寄存读的"零周期代价"来自一个关键技巧：**取指地址接组合推出的下一拍 PC**（`pc_next`），
于是 `imem_rdata(N) == mem[pc(N)]` 与组合读逐位同口径 —— 既拿到了 BRAM 推断（省 ~1228 LUT），
又不改变重定向代价（仍 2 拍）与 CoreMark ticks。

| 级 | 主要工作 | 关键实现 |
|---|---|---|
| IF | 取指 | `pc` 寄存器（优先级 flush > stall > pc_src）、`pc_next` 组合、IMEM 寄存读、BTB/BHT 查表（用 `pc_next` 提前一拍给地址） |
| ID | 译码 + 读寄存器 + **前递预选** | `control_unit`（三段控制束 `ctrl_s`）、`imm_gen`、`regfile`（组合读 + 写旁路）、`id_ex_fwd_a/b` 4 位预选寄存器 |
| EX | 运算 + 分支判定 + 乘除 | `alu`、`branch_unit`、跳转目标**独立加法器**、`muldiv`（DSP 乘法 + 32 步恢复余数除法）、JALR 目标单链比较 |
| MEM | 访存 + 原子 + MMIO | `load_store_unit`（非对齐跨字 2 拍自动拆分、AMO 三相位、字节提取/符号扩展）、`dmem`（16 KB BRAM）、MMIO 地址译码 |
| WB | 写回 | `wb_data` 三选一（ALU/MEM/PC+4）→ `regfile` 写口 |

**一拍之内的时序（稳态、无停顿、无重定向）**：

| 时刻 | IF | ID | EX | MEM | WB |
|---|---|---|---|---|---|
| 本拍组合逻辑 | `pc_next` 计算 → BTB/BHT 查表地址 | 译码 → `ctrl_s` → 读 regfile → `id_ex_fwd_*` 预选 | ALU/分支/`muldiv` → `ex_mem` 输入 | LSU 地址/数据 → BRAM 读（寄存） | `wb_data` mux → regfile 写口 |
| 本拍上升沿 | `pc` ← `pc_next` | `id_ex_*` ← ID 结果 | `ex_mem_*` ← EX 结果 | `mem_wb_*` ← MEM 结果 | regfile ← `wb_data` |
| 关键不变量 | IMEM 输出寄存器 = **IF/ID** | `id_en` 门控（启动完成后才使能） | 分支误判**寄存一拍**才冲刷 | `mem_wb` **不 flush**（必须提交） | 同拍写读走写优先旁路 |

> 这张表解释了"为什么分支误判代价是 2 拍"：误判在 EX 判定 ⇒ N 拍寄存 ⇒ **N+1 拍**才能冲刷 IF/ID 与 ID/EX
> ⇒ 正确路径从 N+2 拍开始取指。历史上曾试图把冲刷做成"组合"，结果是**把整条重定向锥挂到使能端**，
> 反而更难收敛（C-15 的教训）。

### 2.3 分支预测：两级流水 gshare（512 项 BTB + 8192 项 PHT）

**结构**（`btb.sv` + `bht.sv`，由 `btb.sv` 例化 `u_bht`）：

- **BTB 512 项**，两级流水预测口：T 拍把 `pc_next` 作为**查表地址**送给 BTB/PHT，T+1 拍 `q_hit/q_target/q_taken`
  已是**寄存器输出**；
- **PHT 8192 项 × 2 位饱和计数器**，索引 `idx = PC[13:1] ^ (GHR & mask)`，`ram_style="block"` ⇒ **1 块 RAMB18**；
- 关键不变量：**`q_taken` 刻意不再打拍** —— 若再寄存一拍，预测就会晚于对应 PC，每个 taken 分支多 1 个气泡，ticks 必崩。
  "哪里必须打拍、哪里不能再打拍"同等重要。

**效果**（CSV 行 `deliv117` / `cB-128`，详见 `results/p4-c1-2stage-gshare.md`）：

| 指标 | 改造前 | 改造后 | 变化 |
|---|---|---|---|
| CoreMark ticks | 460,311 | **453,942** | **−1.38%** |
| 分支误判次数 | 11,530 | **8,020** | **−30.4%** |
| 预测精度 | 88.43% | **91.95%** | +3.5 pt |
| JAL 误判 | 1,102 | **190** | −83% |
| 代价 | — | LUT +181 / FF +91 / BRAM +1 | 可接受 |

**为什么这次能成（而历史上 P4 那次 gshare 失败）**：P4 把 6 位历史异或进 **64 项**表，同一分支被摊到 64 个计数器上，
每个都学不到（"冷却效应"）。**根因是表容量，不是 gshare 方法错** —— 8192 项后精度反而超过纯局部 2 位
（89% → 92%）。这条教训写在 `bht.sv` 文件头。

**RAS（返回地址栈）**：`ras.sv` 已实现并保留 `RAS_EN` 开关，**默认关闭**。
当年的否决理由是"8:1 栈顶 mux 落在 `pc_target` 最紧路径上"；C-1 之后该理由很可能已失效
（实测 `--ras` 使 ticks 453,942 → 452,288，JALR 误判 3,650 → 2,796），但**尚未重测 fmax**，
因此本报告**不把它计入已交付收益**（诚实口径，见 `results/p4-c1-2stage-gshare.md`）。

### 2.4 前递与冒险控制

| 机制 | 做法 | 收益（实测） |
|---|---|---|
| **load-use 2 拍**（C-2） | load 数据**移出** WB→EX 前递路径；依赖时插 2 拍气泡（`load_use = ex ∪ mem`）；EX 副作用门控由 `!pipe_stall` 改 `!hold_mem` | fmax **76.2 → 83.6**（+9.7%），LUT −203，ticks +8.905%，**绝对吞吐仍净赚**（盈亏平衡 82.98 MHz） |
| **前递预选**（C-10） | 把"生产者位置判定"提前到 ID 段，用 4 位并行寄存器 `id_ex_fwd_a/b` 输出 2 位 one-hot；EX 的 mux 选择端改为寄存器输出 | fmax **83.6 → 87.8**（+5.0%），ticks 逐位不变 |
| **重定向寄存**（C-11/C-15） | 分支误判**寄存一拍**（trap/mret 保持组合以保证精确性）；N+1 拍用 `br_redir_r` 冲 ID/EX 与 EX/MEM，并门控错路影子 X0 在 EX 的全部副作用 | fmax **87.8 → 92.6**（+5.5%）；断言 `if (id_ex_valid && (br_redir_r||br_redir_r2)) $error` 全回归 **0 次触发** |
| **JALR 单链**（C-14） | `A == B ⟺ (A−B)` 高位为 0：在 ID 段预算 `id_jr_p`，EX 只做 31 位 OR 归约 | ticks 逐位不变，纯结构收益 |
| **muldiv 操作数直取**（C-12a） | `u_muldiv` 的 `.a/.b` 从 `ex_a/ex_b` 改为 `ex_rs1/ex_rs2`（M 扩展恒为 R 型 ⇒ 逐位等价） | @131.25 档 WNS **−0.437 → −0.077**，吞吐 +4.6% |

**等价性纪律**：每一项结构改动都配**机器化断言**（不是"跑过没坏"），例如
"错路指令不得提交"、"预测目标必须 2 字节对齐"，全部在**每一拍**上检查。

### 2.5 精确异常与中断

- **CSR**：`mstatus / mie / mip / mtvec / mepc / mcause / mtval / mscratch`（Zicsr 读改写）；
- **同步异常**：ECALL / EBREAK / 非法指令，`mcause` 与 `mtval` 按规范填写，**非法指令严格无副作用**；
- **中断**：`mtime >= mtimecmp` ⇒ `mip.MTIP`（**mcause 中断位在 bit31**，曾错放 bit4 并修复）；
- **精确性两处硬需求**（R-01 / R48）：① ID/EX 增加显式 `valid` 位（中断不得落在气泡上）；
  ② `ex_mem_reg` 增加 `flush`（陷阱当拍把**被抢占的指令**冲成气泡，否则会**双执行**）；
  而 `mem_wb_reg` **刻意没有 flush** —— 那一拍是更老的指令，必须提交。这个"刻意不对称"在代码里写明了原因。
- **同拍优先级**：同一拍既有 trap/mret 又有分支误判时，trap/mret 优先并抑制误判登记。

### 2.6 RV32A 原子扩展

实现 **9 个 AMO（swap/add/and/or/xor/max/min/maxu/minu）+ LR.W**；**SC.W 按规范允许恒失败**
（`rd=1`，不写内存，单核无 Cache ⇒ 无需预约寄存器，这是**合法实现**而非"未实现"）。
多周期"读-改-写"走 LSU 三相位状态机。曾有一个**只在 AMO 后紧跟 `lw` 时暴露**的 bug：
AMO launch 拍漏拉 `lsu_stall`，导致后续 WB 相位与 `amo_mode_r` 错开一拍、读到旧值；一行修好后 `tb_core_amo` 由 XFAIL 翻 PASS。
另一处 **LR.W 把目标字清零**的 bug（多周期状态机"写相与算子无关"）已修。`A_EN` 默认关闭（对 CoreMark 三项零贡献）。

### 2.7 GEMM 协处理器（可选，默认关闭）

`gemm_accel.sv`（249 行）实现 int8 GEMM，实测 **42.59×** 计算加速且结果与独立参考实现逐元素一致；
但**面积代价不可接受**（FF +916%，缓冲落成触发器阵列）且 C 读回未完成 ⇒ `GEMM_EN` **默认关闭**，不计入成绩。

### 2.8 存储与外设

| 项 | 实现 | 说明 |
|---|---|---|
| IMEM | 16 KB，寄存读 → 行为级推断 BRAM | 零厂商原语；`IMEM_COMB_READ` 可回退组合读做 A/B 对照 |
| DMEM | 16 KB，字节写使能 + 寄存读 | 同上 |
| 合计 | **Block RAM Tile 9.5** = RAMB36 ×8 + RAMB18 ×3 | `fpga/util.rpt`（含 PHT 的 1 块 RAMB18） |
| UART | 115200 8N1，`BAUD_DIV = CLK_HZ ÷ 115200`（150 MHz → **1302** ⇒ 115,207 baud，误差 **+0.0064%**） | 回环自测通过；**上板跑分日志走此通道** |
| GPIO / 定时器 | 32 位 GPIO、64 位周期计数器、mtimecmp | CoreMark 计时依赖周期计数器 |
| 跑分上报 | `MMIO_MARK`（触发点）/`MMIO_RESULT`（结果 + CRC 判定位） | ILA 通道的判据来源 |
| 可移植性 | **CPU 核零厂商原语**（BRAM 全行为级推断，不例化 IP） | 迁移只需重写顶层 + 约束 + 时钟原语 |

### 2.9 模块清单（21 个 `.sv`，合计 5115 行，2026-10-17 现查）

| 文件 | 行 | 角色 |
|---|---:|---|
| `rv32_pkg.sv` | 408 | 全局包：类型/枚举/参数/地址映射（**单一事实来源**） |
| `core.sv` | 1748 | 五级流水顶层：例化 + 预测校验 + 重定向 + 陷阱整合 + MMIO 译码 |
| `control_unit.sv` | 372 | 主译码器（RV32IM + Zicsr + RV32A，三级合法性检查） |
| `load_store_unit.sv` | 382 | 访存：非对齐拆分 FSM / AMO 三相位 / 字节通道 |
| `btb.sv` | 250 | 512 项两级流水 BTB（内部例化 `bht`） |
| `gemm_accel.sv` | 249 | int8 GEMM 协处理器（门控默认关） |
| `muldiv.sv` | 236 | RV32M：DSP 乘法 + 32 步恢复余数除法 |
| `csr_file.sv` | 211 | Zicsr + M-mode CSR + 陷阱状态机 |
| `ex_mem_reg.sv` | 178 | EX/MEM 流水寄存器（**含 R48 flush 口**） |
| `bht.sv` | 167 | 8192 项 × 2 位 PHT（gshare，1 块 RAMB18） |
| `hazard_unit.sv` | 161 | 前递选择 + load-use 停顿 + 重定向门控 |
| `id_ex_reg.sv` | 144 | ID/EX 流水寄存器（**含 R-01 valid 位**） |
| `alu.sv` | 105 | ALU（含 9 个 AMO 算符） |
| `ras.sv` | 87 | 8 项返回地址栈（`RAS_EN`，默认关） |
| `dmem.sv` | 76 | 数据存储器 |
| `regfile.sv` | 67 | 32×32 寄存器堆（写优先旁路 + 调试读口） |
| `pc.sv` | 50 | PC 寄存器（flush > stall > pc_src） |
| `imm_gen.sv` | 49 | I/S/B/U/J 立即数 |
| `mem_wb_reg.sv` | 49 | MEM/WB 流水寄存器（**刻意无 flush**） |
| `branch_unit.sv` | 43 | 6 种分支判定（3 个比较） |
| `imem.sv` | 83 | 指令存储器（寄存读 → BRAM） |
| `fpga/mmio_subsys.sv` | 373 | 外设子系统（UART/GPIO/定时器/上报寄存器） |
| `fpga/top_a100t.sv` | 254 | 板级顶层（MMCM + 复位同步 + ILA 隔离） |

### 2.10 时钟与复位

| 项 | 实现 | 关键点 |
|---|---|---|
| 时钟源 | 板载 50 MHz 晶振（`sys_clk`，`create_clock -period 20.000`） | 引脚约束 + `CLOCK_DEDICATED_ROUTE FALSE` |
| 倍频 | **MMCME2_BASE**：`CLKFBOUT_MULT_F=21`、`DIVCLK_DIVIDE=1`、`CLKOUT0_DIVIDE_F=7` | VCO = 50×21 = **1050 MHz**（600~1200 合法）；输出 1050/7 = **150.000 MHz** |
| 约束写法 | `create_generated_clock -name sys_clk_core -source [get_ports sys_clk] -multiply_by 21 -divide_by 7` | **必须用 `-source [get_ports ...]`**：用 `[get_clocks ...]` 会被 Vivado 拒绝（`18-611/18-612`）并**静默退回**自动推导名 |
| 时钟命名 | **`sys_clk_core`（频率无关）** | 名字里带频率会"每换一档就过期一次"，历史上有过 `sys_clk_75`/`clk_75_raw` 的命名漂移（已改） |
| **三处同源** | `top_a100t.sv` 的 `.CLKOUT0_DIVIDE_F` + `.xdc` 的 `-multiply_by/-divide_by` + `.CLK_HZ`（给计时器/UART） | 换档必须**同时**改三处；工具用 `sweep_clk.py` 加断言（每处恰好命中 1 次 + 自证同源），**注释里不写数字** |
| 复位 | 外部按键异步置位 → **同步释放**，并**以 `LOCKED` 为前提** | **R43 血泪**：`CLKFBOUT` 曾漏接 `.CLKFBIN`（反馈环开路）⇒ `LOCKED=0` ⇒ 复位永远不释放，板子"活着但不动" |

> **时钟域只有两个**：`sys_clk`（20 ns，仅用于 MMCM 输入与 ILA 采样）与 `sys_clk_core`（6.667 ns，全部逻辑）。
> 因此**没有跨时钟域数据通路**，也无需 CDC 处理 —— 这是让"上板行为 = 仿真行为"的前提之一。

---

## 3. 微架构设计要点：为什么这么设计

> **统一判据**：绝对吞吐 `CM/MHz × fmax`。只看 fmax 或只看 IPC 都会骗人 ——
> 本设计里出现过多次"IPC 换频率"（如 C-2：ticks +8.9%，fmax +9.7%，净赚 0.8%）。

### 3.1 设计原则

1. **先测量，再动手**：每轮优化前先用 `profile` 出停顿构成、用 `path_families.py` 出**关键路径族**（不是只看 top-1）。
2. **单变量 + 预登记判据**：每次只改一件事，并在动手前写下"什么数字算赢"（如"绝对吞吐 > 基线"）。
3. **代价必须实测**：C-2 推理算 +6.917%，实测 +8.905%（低估 22%）—— 因为"每次多 1 拍"这类推理会漏掉**事件数变了**。
4. **机制成功 ≠ 时序有收益**：6 次"墙转移"全部是"机制完全成功、净负"。

### 3.2 正面成果（全部单变量实测）

| 改动 | 关键做法 | fmax | ticks | 绝对吞吐 | 结论 | CSV 行 |
|---|---|---|---|---|---|---|
| **C-2** load 移出前递 | load-use 1→2 拍；前递源改为寄存器；EX 副作用门控拆分 `hold_mem` | 76.2 → **83.6**（+9.7%） | 413,070 → 449,854（+8.905%） | 184.4 → **185.8**（+0.8%） | 净赚（平衡点 82.98） | `c2-loaduse2` |
| **C-10** 前递预选 | ID 段预选 4 位寄存器；EX mux 选择端变寄存器 | 83.6 → **87.8**（+5.0%） | 不变 | ↑ | 净赚 | `c10-fwdpre` |
| **C-11** 重定向寄存 | 分支误判寄存一拍切环（trap 保持组合） | 87.8 → **92.6**（+5.5%） | +2.324% | 195.1 → **201.2**（+3.1%） | 净赚 | `c11-rebuilt-ctl` |
| **C-1** 两级 gshare | BTB 512 + PHT 8192，预测口全寄存器 | — | −1.38% | ↑ | 净赚（LUT+181/FF+91/BRAM+1） | `deliv117` |
| **候选 B** 删清 0 条件 | `id_ex_fwd_*`/`id_ex_jr_p` 的 CE 只留 `!pipe_stall` | 原 37/50 族消失 | 不变 | ILA 流 −0.434 → **+0.000** ⇒ 交付档 118.75→**128.125** | 本轮最大单笔 | `cB-128` |
| **C-12a** muldiv 操作数直取 | `.a/.b` 改 `ex_rs1/ex_rs2` | @131.25 WNS −0.437→−0.077 | 不变 | 273.5 → **286.2**（+4.6%） | 净赚（但换配置会变号） | — |
| **C-14/C-15** | JALR 单链 / registered flush | 族 7.791 → 6.795 ns | 不变 | +1.2 MHz | 局部收益远低于预测 | — |
| **C-9** 中断请求链寄存 | `mmio_subsys` 的 `irq_timer` 由**组合 64 位比较**改为寄存器输出（本核独有，论文里没有） | — | 不变 | — | 消除一条 64 位比较链；详见 `results/rvcorep-vs-ours.md` §5 | — |

> **C-15 的认知纠偏（本 session 最重要）**：预测 +2.07 ns，实测 +1.2 MHz。
> 原因不是"改动没用"，而是**瓶颈是"族"而不是"某条路径"** —— 治好 top-1 不等于整族消失。
> 这条催生了工具 `tools/path_families.py`（按族统计，而非只看 top-1）。

### 3.3 六次"墙转移"（诚实清单，全部"机制成功、时序净负"）

| # | 改动 | 机制结果 | 新墙 | WNS@150 | 处置 |
|---|---|---|---|---|---|
| 1 | **C-12c** muldiv 操作数先寄存 | DSP 级联族消失 ✓ | trap / CE 锥 | −0.852 | 回退（另：ticks +2.046%，FF 未被 DSP 吸收） |
| 2 | **候选 D′**（`alu_out/CE`） | `alu_out/CE` 族消失 ✓ | `id_ex/rs1_data_reg/CE` | — | 回退 |
| 3 | **候选 F**（`ex_mem_fwd_data` 组合 mux → 派生寄存器） | 等价性成立、硬件行为逐位中性 ✓ | `fwd_data_reg/D`（24 条 −0.255） | — | 回退 |
| 4 | **候选 F 变体 / 其余结构抓手** | — | — | — | 回退 |
| **5** | `id_ex` 控制网（fo=132）加 `max_fanout` | 扇出下降 ✓ | 新长 `id_ex/rs1\|rs2_data_reg/CE` 族 | **−0.276** | 回退 |
| **6** | bht `align` 自证链在综合视图移除 | **原 top-1 整条消失** ✓ | 墙转到 EX 数据通路 | **−0.006** | 回退 |

> 累计 **6 个**（`CHANGELOG.md` §13.2 结论行）。**规律**：在"均匀地差 0.5 ns"的设计里，
> 单点结构改动没有杠杆；真正的出路是**一次砍掉一族共享的根源**（候选 E′：`!pipe_stall → !hold_mem`，
> 一次治好三个 trap 族，贡献 **+0.470 ns**）。

### 3.4 负结果（同样重要，它们省下大量白工）

| 项 | 预登记判据 | 实测 | 处置 |
|---|---|---|---|
| **C-12c**（操作数寄存） | 预期收益大 | ticks **+2.046%**；FF 1360（=1290+70）**未被 DSP 吸收**；WNS −0.077→−0.235 | 回退 |
| **C-18a** ALU_MUL 走单片 DSP | DSP 数不增且族仍在 PCIN ⇒ 判负 | 语义逐位等价（9,711 条乘法断言 0 触发）但 DSP 8→8、39 条仍在 PCIN | 回退（判据事先写明，干净结论） |
| **C-12b′** 孤立测 | — | WNS −0.173 → **−0.543**（"用 CE 换 Q"） | 孤立测判负；在 C-14+C-1 上下文里**反转为 +0.45 ns** 而保留 |
| **125 MHz 档** | — | 达成 119.6，**比更紧的 131.25 档（128.3）更差** | 非单调（选档看达成值） |
| **RVCoreP 整套配方** | 期望复制其高性能 | 150 档 WNS **−0.770 → −1.621**（更差 0.85 ns） | 明确负结果：配方为 1338 LUT 扁平设计调优，对 2789 LUT 设计反而增拥塞 |
| **PLLE2 换 MMCM** | 期望不同 unc. | **−0.421**；clock uncertainty 与 MMCM **完全相同（0.043 ns）** | 换原语无效 |
| `-fanout_limit 64` | — | Vivado **崩溃**（rc=3221225477） | 进不可行区 |

### 3.5 方法论（可迁移）

1. **族 > 路径**：`Δ(top1, top2) < 0.03 ns` 且 50 条同族 ⇒ 逻辑重排没有空间（PITFALLS **R47**），
   只能切环/改结构/换布局。
2. **非单调性**：约束放松不一定更安全（150 → −0.172，142.1875 → **−0.307**，138.75 → +0.033）。
   **选档只能看"达成值"，不能插值。**
3. **口径反推校验**：同一份台账里 WNS 与达成 fmax 可互推"当时的约束周期" ——
   我们正是靠 `1000/139.1 = 7.191 ≈ 7.207 − 0.018` 抓住了一次"忘了切时钟"的假结论（`CHANGELOG.md` §10）。
4. **CRITICAL 警告不能"看着过了"就放过**：越界 Pblock 报 `[Vivado 12-4433]` ⇒ `resize_pblock` 失败、
   **整条约束没生效**；你以为的"调参结果"其实是"没调参"的结果。见 §6.1。

---

## 4. PPA 与性能

### 4.1 fmax 演进（同约束族内可比；跨约束只作量级参考）

| 阶段 | 主时钟/周期 | 运行频率 | WNS | fmax | 说明 |
|---|---|---|---|---|---|
| 基线 | `sys_clk` 20 ns | 50 MHz | — | 78.4 MHz | 20 ns 约束，**MMCM 前口径** |
| 首次引入 MMCM | `sys_clk_70` 14.286 ns | 70 MHz | +0.659 | 73.4 | 11 次构建逐位可复现 |
| 75 MHz 档 | 13.333 ns | 75 MHz | +0.206 | 76.2 | 首次把"提频"与"口径更正"分开记账 |
| 105 MHz 档 | 9.524 ns | 105 MHz | +0.117 | 106.3 | CSV `c14-105mhz` |
| 117 MHz 档 | 8.547 ns | 117 MHz | +0.075 | 119.1 | 两流对齐后首次过门 |
| 128.125 MHz 档 | 7.805 ns | 128.125 MHz | +0.090 | 129.6 | 候选 B；**ILA 流首次 PASS** |
| 138.75 MHz 档 | 7.207 ns | 138.75 MHz | +0.033（评分流）/ +0.150（ILA） | 139.4 | 上板验证；UART+ILA 双通道 |
| **150 MHz 交付档** | **6.667 ns** | **150.00 MHz** | **+0.007** | **150.2** | **合法配置**，QSPI 自启动验证 |

> **为什么 150.2 而不是 150.0**：`fmax = 1000 / (6.6667 − 0.007) = 150.17 ≈ 150.2`
> （6.6667 ns = 1/150 MHz 的精确周期；台账按内部精确周期记账）。
> 台账里另有 `deliv150-keep`（150.0，LUT 3111）与 `legal150-final`（150.2，LUT 3098）两行 ——
> **交付档以 `legal150-final` 为准**（合法、0 Critical Warning、已烧 QSPI）。

### 4.2 最终 PPA（交付档 `legal150-final`）

| 指标 | 值 | 来源 |
|---|---|---|
| LUT | **3098** | `coremark.csv` 行 `legal150-final` / `fpga/util.rpt` |
| FF | **1447** | 同上 |
| BRAM Tile | **9.5**（RAMB36 ×8 + RAMB18 ×3） | 同上 / `fpga/util.rpt` |
| DSP48E1 | **8**（M 扩展乘法） | 同上 |
| fmax | **150.2 MHz** | 1000/(6.667−0.007) |
| WNS / WHS | **+0.007 ns** / 正 | `fpga/timing.rpt` |
| Critical Warning 数 | **0** | 构建日志（`--pblock-range off` 修复后） |
| 功耗 | **待补**（本节唯一缺口：需 `report_power` 或 PDS 功耗报告，见 §8） | — |

> **面积为什么比基线的 3499 LUT 还小**：基线是**无 BRAM**（IMEM/DMEM 是 LUT ROM），
> 一次"存储迁移"把 ~1228 LUT 的取指 ROM 搬进 BRAM（LUT −1228），此后新增的预测器/CSR/AMO/调试钩子
> 又花回去一部分，净值 LUT −11%。**这不是"变小了"，是"换了资源的用途"**：BRAM 0→9.5、DSP 0→8。
> 与同级参考核比，我们的 LUT 约是其 2.3 倍（多出 CSR/AMO/GEMM/ILA/两级预测器/trap），这是 §7 的核心差距。

### 4.3 CoreMark 与分数口径（**必须一起读三行**）

| 口径 | 值 | 计算 | 说明 |
|---|---|---|---|
| **规范分数**（对外宣称） | **324.19** | `4600 / (2,128,330,453 / 150e6)` = 4600/14.1889 | 固件 `[portme] score=324.19 spec` 行 |
| 固件打印 | 328 | `4600 / 14`（整数秒截断） | **+1.3% 虚高，不可当宣称分数** |
| CoreMark/MHz | **2.1613** | `4600e6 / 2,128,330,453` | 与频率无关，不受截断影响 |
| 绝对吞吐 | **≈324.2** | `CM/MHz × fmax = 2.1613 × 150` | 交付档 fmax≈运行频率 ⇒ 与规范分数同量级 |

> **为什么会出现 328**：移植层 `HAS_FLOAT 0` ⇒ `secs_ret` 为整数秒 ⇒ `time_in_secs()` 做整数除法
> （14.1889 s → 14 s）⇒ 4600/14 = 328.57 → 328。修复尝试 `HAS_FLOAT=1` **链接失败**
> （`-nostdlib` 缺 `fcvtbuf`）。最终方案：**不改 CoreMark 核心一行**，在我们自己的 `[portme]` 打印块里
> 用 **64 位整数**算规范分数 `score = ITER * CLK / ticks`（只在上板构建编译）。实测
> `tick 2,128,330,449 → 2,128,330,453`（代码布局 +4 拍）、`324.20 → 324.19`，自洽。

**逐档上板实测**（每档都有采集清单；tick 与频率无关 ⇒ 同一 RTL 跨档 tick 逐位相同是"频率缩放真实"的决定性证据）：

| 档 | 迭代 | tick | 墙钟 | 硬件 CM/MHz | 迭代率 | 吞吐（CM/MHz×频率） | 验证通道 |
|---|---|---|---|---|---|---|---|
| 75 MHz | 3000 | 1,239,079,510 | 17.70 s | 2.4212 | 169.5 /s | 184.4 | ILA |
| 105 MHz | 3000 | 1,380,682,494 | 13.15 s | 2.1728 | 228.1 /s | 230.9 | ILA |
| 118.75 MHz | 3000 | 1,359,770,617 | 11.45 s | 2.2063 | 262.0 /s | 262.0 | ILA |
| 128.125 MHz | 3000 | 1,359,770,617 | 10.61 s | 2.2063 | 282.8 /s | 282.7 | ILA |
| 138.75 MHz | 4600 | 2,128,330,451 | 15.34 s | 2.1613 | 299.9 /s | 299.9 | ILA + UART |
| **150 MHz（交付）** | 4600 | **2,128,330,453** | 14 s（14.19） | **2.1613** | 328 /s（=324.19 规范） | **324.2** | **UART + FLASH 自启动** |

> **"吞吐"列的口径**：本列 = CoreMark/MHz × 该档**运行频率**，与固件打印的迭代率一致；
> 项目内部的裁判指标取 `CM/MHz × fmax`，在 150 档为 **≈324.2**（该档 fmax≈运行频率，两者数值重合）。

> 前三档 CM/MHz 偏高（2.42/2.17/2.21）而 128 之后回落到 2.1613：**IPC 下降是 C-2/C-12c 主动换频率的代价**，
> 而绝对吞吐一路 184→324（+76%）。**这正是"绝对吞吐做裁判"的意义**：
> 只看 CoreMark/MHz 会得出"越改越差"的错误结论。

### 4.4 150 MHz 是压线交付：8 组"留余量"实验全部判负

| 尝试 | WNS@150 | 判读 |
|---|---|---|
| **交付档**（无 pblock + contain-routing + AltSpreadLogic_high） | **+0.007** | **设计极限** |
| 换 **PLLE2**（VCO 1200/8） | −0.421 | clock uncertainty 与 MMCM 相同 ⇒ 换原语无效 |
| `id_ex` 控制网加 `max_fanout` | −0.276 | 第 5 个墙转移 |
| bht `align` 自证链移除 | −0.006 | 第 6 个墙转移（机制成功） |
| 合法 Pblock `X0Y0:X3Y2` / `X0Y0:X2Y2` / `X0Y1:X2Y2` | −0.348 / −0.467 / −0.131 | 全部更差 |
| 合法 Pblock @145.3125 / @143.75 | −0.001 / −0.295 | **非单调**（更松反而更差） |
| `route NoTimingRelaxation` / `route Explore` | +0.007 / +0.003 | 无提余量 |
| `phys_opt Explore` / `place WLDriven` | −0.037 / −0.780 | 更差 |
| 目标 148.4375 / 146.875 / VCO 1200 | 达成 135.9 / 143.3 / 146.6 | 均不过门 |

**结论**：150 MHz 时 **10 个路径族全部挤在 +0.026~+0.119 ns**（最大族 24 条、+0.048），
设计正好卡在自己的极限上 ⇒ **工程余量拿不到**。因此：

- **交付档 = 150 MHz（WNS +0.007，压线但 MET）**，并已用**独立通道**（UART CRC 自检 + FLASH 自启动
  + tick 与 138.75 档逐位一致）交叉验证；
- **退路 = 138.75 MHz**（评分流 WNS **+0.033**、ILA 流 **+0.150**，已上板验证，tick 2,128,330,451，
  15.34 s，299.9 /s）。若评审环境更差，**降频到 138.75 是零风险的**。

---

## 5. 验证体系

### 5.1 仿真回归矩阵（PASS 12）

`tools/fpga_workflow.py verify` 跑 **12 项**（矩阵定义在 `test_matrix()`），每项缓存键 = 参与编译的
**全部文件内容哈希** + plusargs + 编译器版本：

| # | 测试 | 覆盖 |
|---|---|---|
| 1 | `tb_units` | ALU/立即数/控制/CSR/regfile/BTB/AMO 单元检查（检查点数以运行时打印为准） |
| 2 | `tb_core_basic` | 系统级自校验（含非对齐访存） |
| 3 | `tb_core_trap` | Zicsr + 异常/中断 + MRET |
| 4 | `tb_soc_timer_irq` | mtime/mtimecmp 定时器中断（含 `+irq_trace` 覆盖率取证） |
| 5 | `tb_core_m_ext` | RV32M 边界（除零/溢出/有符号） |
| 6 | `tb_core_amo` | RV32A 读-改-写 + min/max 符号语义 |
| 7 | `tb_core_amo_diag` | RV32A 单步诊断（tohost 上报失败环节） |
| 8 | `tb_soc` | 外设 + UART 回环 |
| 9 | `tb_sw_lu_bench` | **load-use 代价标定**：距离 1 = 2 拍 / 距离 2 = 1 拍 + checksum |
| 10 | `tb_sw_hello` | 裸机 C 程序 |
| 11 | `tb_sw_coremark` | CoreMark（CRC 四件套） |
| 12 | `tb_sw_nn_demo` | 神经网络 GEMM（与独立参考逐元素比对） |

**判定依据是 testbench 自己打印的 `RESULT : PASS`，不是 `vsim` 退出码**（ModelSim `quit -f` 恒返回 0；
早期用 `"PASS" in output` 判据曾把编译失败/超时误判为通过，已改为白名单 + 崩溃/超时否决）。

**已知覆盖缺口（诚实标注）**：`tb_soc_timer_irq` 实测中断只接受 2 次且**两次 `stall=0`**
⇒ 该测试**从未覆盖"停顿期取中断"**。候选 E′ 的行为变化因此记为"**未被测试覆盖**"，
不以 PASS 冒充已验证。

### 5.2 三通道证据链（这是本作品最"工程"的部分）

| 通道 | 用途 | 判据 | 证据文件 |
|---|---|---|---|
| **ILA over JTAG** | 早期各档（75/105/118.75/128.125/138.75） | `ila_ctrl=0xC2`（locked/done/pass）+ `score_result` bit31=1 + tick | `results/ila_done.csv`、`results/*capture.json`（含 RTL 哈希） |
| **UART 回读** | 150 MHz（评分流网表，绕开调试核） | `[portme] rate gate` + CRC 四件套 + `Correct operation validated` | `results/uart_final150.txt`、`uart_cm_final.txt`、`uart_scoreprint.txt` |
| **QSPI FLASH 自启动** | 交付闭环（断电重启，无 JTAG） | 同上 + tick 与烧写通道**逐位相同** | `results/uart_flash_boot_final.txt`、`results/flash_done.txt` |

> **为什么需要三条通道**：带 ILA 的网表在 150 MHz 过不去（−0.293~−0.514 ns），而评分流只差 0.172 ns。
> 也就是说 —— **不是核不够快，而是"用来观察它的调试核"在吃掉那 0.17 ns**。
> 打通 UART 通道后，交付档才能"用评分流网表上板 + 从串口读回结论"。
> **教训：验证手段要算进时序预算。**

**2048 拍真实硬件波形分析**（ILA 抓取，探针 `dbg_pc[31:0]` / `dbg_instr[31:0]` / `ila_ctrl[7:0]` / `score_result[31:0]`）：

| 观测量 | 硬件实测 | 仿真对照 | 判读 |
|---|---|---|---|
| 流水线停顿 stall | **237 / 2048 = 11.57%** | 9.6%（load-use 6.5% + muldiv 3.1%） | 量级一致 |
| 分支预测错误 redirect | **14 / 2048 = 0.68%** | 全程序均值 4.9% | 偏低是因为这 2048 拍恰好落在**预测很准的紧凑循环**里 —— **不是矛盾，是采样窗口不同** |
| PC 热点 | `0x80001218 ~ 0x80001248` | CoreMark 热点循环 | 与软件画像一致 |
| 指令样例 | `0x00F383B3`(add) / `0x00089303`(lb) / `0x4027D313`(srai) | — | 解码正确 |

> **这条也写进纪律**：用短窗口估全局占比要谨慎；**硬件波形用于"验证机制存在"，不能直接当 IPC 统计**。

### 5.3 证据强度：哈希绑定与"mtime 不是证据"

- **采集清单**：每次 UART/ILA 采集都写 `*.capture.json`，包含 `captured_at_local`、`channel`、
  `iterations`、`total_ticks`、`clk_hz`、`crc{4}`、`bit_sha256`、`rtl_sha256`（+ 被哈希的 `.sv` 文件数）
  ⇒ "这次采集对应哪版 RTL"**可机器复核**。
- **反例（已固化为纪律）**：`results/ila_done.csv` 是 git 跟踪文件，克隆/checkout 会刷新 mtime 但**不产生新采集**。
  2026-10-11 10:51 曾实测到"内容逐字节未变、mtime 变 5 分钟前"，导致工具误报"刚上过板"。
  ⇒ 此后**一律以采集清单为判据**；清单缺失时工具**拒绝给结论**。
- **RTL 指纹**：同一份 RTL 的判据是 `sha256` **逐文件集合哈希**（不是目录 mtime）。

### 5.4 仿真与硬件一致性

| 对比项 | 仿真 | 硬件 | 差异 | 结论 |
|---|---|---|---|---|
| ticks/迭代 | 463,366（`cm_hw` 镜像配置） | 462,680 | **−0.148%** | 系统性（镜像配置略异），历史各档一致 |
| 138.75 档 tick | — | ILA 2,128,330,451 / UART 2,128,330,449 | **2 拍（1e−7）** | 两通道逐位一致 |
| 138.75 ↔ 150 tick | — | 2,128,330,451 vs 2,128,330,449 | 2 拍 | **周期数与频率无关** ⇒ 频率缩放真实 |
| CRC | 四件套 | 四件套 | 完全相同 | 行为一致 |

### 5.5 工具门禁（让"人记不住"的事变成机器判据）

`check` 共 **7 项**非阻塞检查 + 1 项 HIL 提示：

1. RTL 文件清单三方同步（综合/仿真/哈希集）；2. 未例化模块；3. 软件源→`.hex` 新鲜度（内容哈希）；
4. bitstream 与输入是否同源；5. 内存布局同步；6. `.bat/.tcl` 纯 ASCII；7. **综合警告门**。

其中 **7** 最关键：Vivado 的警告 = 本工程的真 lint。基线为 48 类/274 条，
**`[Timing 38-1]`（MMCM 反馈环缺失）出现即判 FAIL** —— 该警告曾导致"整颗 CPU 被永久按在复位里"
（板子读到 `ila_ctrl=0x00`，`dbg_pc` 冻结在复位向量）。此外构建期还有 **`BUILD_TIMING=PASS/FAIL`
时序门**（不满足直接不出 bitstream）与 **31 位 tick 硬闸门**（`expect_tick > 2^31−1` 直接 BLOCK）。

> **闸门立功实例**：C-12c 把每迭代拍数从 453,942 抬到 463,366（+2.08%）⇒ 4700 迭代的 tick 越过 31 位上限，
> 闸门正确 BLOCK 并提前返回。**若没有这道闸门，我们会烧进一个 tick 回绕、看起来像"变快了"的成绩单。**

---

## 6. 上板与固化

### 6.1 合法 150 MHz 配方（0 Critical Warning）

```
python tools\fpga_workflow.py synth --no-lc --fanout_limit 128 \
    --pblock-range off --contain-routing \
    --place-directive AltSpreadLogic_high --tag legal150 --record --status keep
```

- `--no-lc`：禁 LUT 合并；`--fanout_limit 128`：全局扇出指导；`--contain-routing`：约束布线在区域内；
  `--place-directive AltSpreadLogic_high`：替代布局密度策略。
- **关键发现**：此前的越界 Pblock `X0Y1:X2Y3` 触发 `[Vivado 12-4433] Constraint ranges extend outside the device`
  ⇒ `resize_pblock` 失败、**整条 pblock 从未生效**。即：交付档实际一直跑在
  "无 Pblock + contain-routing + AltSpreadLogic_high" 上。显式改成 `--pblock-range off` 后
  **WNS +0.007、MET、0 个 Critical Warning** ⇒ **合法 150 MHz 成立**。
- **软件侧**：`mk_cm_hw.py 4600` 生成镜像（每迭代 463,366 拍 ⇒ 预期 tick 2,131,483,600，占 31 位 **99.3%**）；
  综合/实现选项必须与 PDS 迁移后的流程**逐项对齐**（见 §6.4）。

### 6.2 QSPI FLASH 自启动（交付闭环）

| 步骤 | 结果 | 证据 |
|---|---|---|
| 1. 转换 SPIx4 镜像 | `cpu_a100t_spix4.bin`（3,825,788 B） | `results/flash_done.txt` |
| 2. 预载 SPI accessor + 烧写 | `PROGRAM_OK`，Mfg ID `20` / Type `ba` / Cap `18`（mt25ql128） | 同上（`Mfg ID : 20 Memory Type : ba Memory Capacity : 18`） |
| 3. **16 MB 全片读回 + 逐字节 diff** | `VERIFY=PASS`（前 3,825,788 B 完全一致，其后无杂散非 FF 字节） | 同上（`readback=16777216`） |
| 4. **断电重启（无 JTAG）** | `[portme] rate gate: clk=150000000 Hz ticks=2128330453` + `score=324.19 spec` + CRC 四件套 + `Correct operation validated` | `results/uart_flash_boot_final.txt` |

> **为什么必须读回**：`program_hw_cfgmem` 在 `PROGRAM.VERIFY=0` + `CFG_PROGRAM=0` 时**仍会打印**
> `[Labtoolstcl 44-377] Flash programming completed successfully` —— **工具的成功字样不是证据**。
> 本工程用"16 MB 读回 + 逐字节 diff"当判据。
> 另两个已绕过的坑：`27-3347` 的真因不是 part 不匹配而是 **accessor 未加载**；
> `write_cfgmem` 拒绝 header 内为 1 的 bitstream 走 SPIx4（构建须带 `SPI_BOOT_X4=1`）。

### 6.3 复现路径（干净机器，一条命令级别）

```bat
:: 1) 环境自检（Vivado/ModelSim/Python 路径 + 版本）
cmd /c tools\doctor.bat
:: 2) 一致性检查（7 项漂移/新鲜度/警告门）
python tools\fpga_workflow.py check
:: 3) 仿真回归（12 项，带缓存）
python tools\fpga_workflow.py verify
:: 4) 综合 + 指标（四项指标 + fmax 推导整行打印）
python tools\fpga_workflow.py synth --no-lc --fanout_limit 128 --pblock-range off --contain-routing --place-directive AltSpreadLogic_high
:: 5) 生成跑分镜像（按当前 ticks/迭代 计算 expect_tick 与等待时间）
python tools\mk_cm_hw.py 4600
:: 6) 上板：只烧写 + 串口回读（先起监听，再烧写）
python tools\uart_capture.py --port COM13 --seconds 40 --out .fpga-cache\logs\uart_150.txt
cmd /c fpga\prog_uart.bat
:: 7) FLASH 固化 + 16 MB 读回校验
powershell -File tools\flash_boot.ps1 -Bit fpga\cpu_a100t_spix4.bit -Iface SPIx4
```

### 6.4 紫光同创迁移状态（**必须如实标注**）

| 项 | 状态 | 说明 |
|---|---|---|
| 目标器件 | 紫光同创（赛题原文指定 **PGL22G**） | 迁移面：顶层 + 约束（XDC→PDC）+ 时钟原语（MMCM→PLL）+ 构建流程 |
| 现状 | **尚未在紫光同创器件上实跑** | 本报告全部数字来自 **Artix-7 XC7A100T-2** |
| 有利条件 | **CPU 核零厂商原语**（BRAM 全行为级推断、不例化 IP） | 迁移不需要改 CPU 核内部 |
| 资源预算 | 本档 LUT 3098 / FF 1447 / BRAM 9.5 / DSP 8 vs PGL22G ~22K LUT 级 | **能装下**；主要风险是 BRAM/DSP 数量与布线质量 |
| 预期频率 | **会下降**（40nm Logos vs 28nm Artix-7） | 迁移后必须重测；CoreMark 分数预计下降，但 **CM/MHz（架构效率）不变** |

> **诚实声明**：本报告的"150 MHz / 324.19 分"是 **Artix-7 上的实测**，不是紫光同创上的实测。
> 迁移后的数字必须重新测量，**不得沿用**。

---

## 7. 与 RVCoreP-32IM 的对标

对标对象：RVCoreP-32IM（arXiv 2010.16171，东京工业大学 Kise 实验室；官方 Wiki 与源码可查），
其官方数字为 **xc7a100tcsg324-1（最慢档 -1）** 上 **162~174 MHz**、LUT 1331~1456、CoreMark/MHz 2.33。

| 项 | RVCoreP-32IM | **本核** | 比 |
|---|---|---|---|
| fmax | 162 MHz @64KB（**-1** 档） | **150.2 MHz**（**-2** 档） | 跨速度档，见下 |
| LUT | 1338 | **3098** | **2.3×** |
| FF | 903 | **1447** | 1.6× |
| DSP48 | 4 | 8 | 2× |
| CoreMark/MHz | 2.33 | **2.1613** | **0.93×** |
| 绝对吞吐 | 377.5（=2.33×162） | **324.2**（=2.1613×150） | **0.86×** |
| 功能集 | RV32I（论文扩到 M）；无 CSR/异常/中断/A 扩展/MMIO | **RV32IM + Zicsr + M-mode 异常/中断 + RV32A + MMIO + 调试钩子** | 本核功能面更宽 |
| RTL 规模 | 5 个 `.v`（`proc.v` 一个文件装整核） | **21 个 `.sv` / 5115 行** | 可读性/可维护性权衡 |

**差距分析（按证据强度）**：

1. **设计规模大 2.3 倍**（强证据）：多出 CSR、AMO、GEMM、ILA 钩子、两级预测器、完整 trap/中断。
   逻辑多一倍 ⇒ 拥塞与布线更长。**这是最可能的主因，但不是"改几行"能解决的** —— 要减就得砍功能。
2. **存储器几何**（强证据）：本核 IMEM/DMEM 各 16 KB；本仓库自己的对照实验（同 RTL、同物理约束，
   仅 4 KB→16 KB）实测 **137.25 → 118.57 MHz（−18.7 MHz）**。这是量级最大的单一杠杆，
   但**需求要求 BRAM 留够**，故不做。
3. **绑定路径性质不同**（中证据）：他们的关键路径是"写回→EX 前递经 AGU"，**路由主导**；
   C-2 把这条等价路径拿掉了，我们撞上的是 **DSP 级联内部 3.4 ns（占 54%）**。
   **不能拿"我们的墙"和"他们的墙"直接比快慢**。
4. **速度等级换算**：他们在 **-1**（最慢）拿 162~174；我们在 **-2** 拿 150.2。
   经验换算（同一网表 -2 约快 15~20%），**本核放到 -1 上约 125~131 MHz**，
   仍约为他们的 **77~81%**（**估算值**，未在同器件上实跑，标注为估算）。

**诚实结论**：本核在"功能覆盖 + 交付闭环（自启动/证据链/自动化门禁）"上明显更完整，
在"纯频率/面积"上落后于这个以极简著称的参考核；**同类比较必须在同一速度档、同一存储器配置下重做**，
本报告给出的是**原始对齐数据**而非结论性排名。

---

## 8. 加分项与后续规划（已完成 / 计划中，严格分栏）

| 赛题加分项 | 状态 | 说明 |
|---|---|---|
| 运行操作系统（RTOS） | ⬜ **计划中** | 前置缺口：WFI、`mcycle`(Zicntr)、UART RX 中断、trap 兜底 handler、栈溢出检查。工作量约 3~5 天 |
| 移植 MicroPython / Arduino | ⬜ **计划中（优先级低）** | 需 RV32IM 端口 + 堆裁剪；工期长，风险高 |
| 自研 IDE / 全套工具链 | 🟡 **部分具备** | 已能"编译→烧写→串口回读→判据解析"（`tools/`），**缺 GUI/插件包装** |
| 指令集覆盖扩展 | ⬜ **计划中** | 候选：RV32C（压缩）、Zbb/Zbs（位操作）、Zicntr；C 扩展约 3~5 天 |
| RTL 合规补强 | 🟡 **部分完成** | 已修 `mcause` 中断位、`mtval`、R-01/R48 精确性；待做：mtvec 向量模式、load/store access fault、指令地址非对齐异常 |
| **PPA 补功耗** | ⬜ **待补** | 需 `report_power` / PDS 功耗报告（本报告 §4.2 唯一空缺） |
| PDS 迁移 + 紫光同创实跑 | ⬜ **P0 待做** | 见 §6.4；**这是合规硬门槛** |

> **不夸大声明**：以上"计划中"项**均未实现**，不计入本报告任何成绩数字。

---

## 9. 附录

### 9.1 关键数字一览（含来源，便于评审抽查）

| 数字 | 值 | 来源 |
|---|---|---|
| 交付档频率 | 150 MHz（`sys_clk_core` @6.667 ns） | `fpga/daVinciPro.xdc` + `results/NEXT-BURN.md` §1 |
| fmax | 150.2 MHz | `coremark.csv` 行 `legal150-final`（1000/(6.667−0.007)） |
| WNS | **+0.007 ns**（压线 MET） | `fpga/timing.rpt` + `uart_flash_boot_final.capture.json` |
| LUT / FF / BRAM / DSP | 3098 / 1447 / 9.5 / 8 | `coremark.csv` 行 `legal150-final`、`fpga/util.rpt` |
| CoreMark 规范分数 | **324.19** | `results/uart_flash_boot_final.txt`（`[portme] score=324.19 spec`） |
| CoreMark/MHz | **2.1613** | 4600e6 / 2,128,330,453 |
| 上板 tick | **2,128,330,453** | 同上 |
| 迭代 / 墙钟 | 4600 / 14 s（14.19 全精度） | 同上 |
| CRC 四件套 | `0xe714 / 0x1fd7 / 0x8e3a / 0x382f` | 同上 |
| 仿真回归 | **PASS 12** | `python tools\fpga_workflow.py verify` |
| 零厂商原语 | 是（BRAM 行为级推断） | `imem.sv` / `dmem.sv` / `bht.sv` |

### 9.2 坑清单精选（工程方法层面，完整 51 条见 `skills/fpga-riscv-a100t/PITFALLS.md`）

| # | 坑 | 教训 |
|---|---|---|
| R43 | MMCM 漏接 `.CLKFBIN` ⇒ 反馈环开路、`LOCKED=0`、复位永不释放 | 板子"活着但不动"时先查时钟锁定；`[Timing 38-1]` 出现即 FAIL |
| R47 | top-N 是"一堵墙"（同族、Δ<0.03 ns）时 RTL 逻辑重排期望 ≈ 0 | 先看族分布，再决定改结构 |
| R48 | 陷阱只冲 ID/EX ⇒ 被抢占指令**双执行** | 精确异常必须冲 EX/MEM；MEM/WB 刻意不冲 |
| R49 | 多周期状态机的"写相"与算子无关 ⇒ LR.W 把目标字清零 | 写使能必须按算子门控 |
| R50 | 换频只换抽头最安全；**收紧约束本身会抬高 fmax** | 报 fmax 必须同时说清约束 |
| — | `git checkout -- core.sv` 销毁未提交工作 | 长任务先提交/打 bundle 备份 |
| — | 含中文的 `.ps1` 经 `powershell -File` 因 BOM-less UTF-8 按 GBK 解码 | 脚本写 ASCII，或显式 BOM |
| — | 日志按中文匹配（ModelSim 落盘为 `?`）⇒ 正则永不匹配且**静默**退回旧假设 | 判据只用 ASCII token |

### 9.3 文档与证据索引（26 篇实测记录）

| 文件 | 内容 |
|---|---|
| `results/CHANGELOG.md` | 优化轨迹（含全部负结果与教训，707 行） |
| `results/FREQ-VERDICT.md` | 主频差距核实（对标 RVCoreP、速度档换算） |
| `results/rvcorep-vs-ours.md` | 与 RVCoreP 的并排对照与口径更正 |
| `results/analysis-report.md` / `gap-analysis.md` | 成绩分析 / 赛题差距对照 |
| `results/p2-timer-irq.md` … `p8-ifid-elide.md` | 各专项记录（定时器中断、fmax、imem、load-result、宏失效、gshare、RAS、GEMM、A 扩展、Cache 分析、IF/ID） |
| `results/ila_done.csv`、`results/uart_*.txt`、`results/*.capture.json`、`results/flash_done.txt` | **上板证据链**（原始输出 + 哈希绑定） |
| `results/coremark.csv` | 逐档台账（每次综合/上板一行，含 status 与 notes） |
| `results/NEXT-BURN.md` | 当前交付档的构建与复现速查 |
| `HANDOFF.md` / `CODE-MAP.md` | 交接细节 / 模块地图（阅读顺序与章节锚点） |

---

**（报告完）**

> 本报告所有数字均可在仓库内复核：`python tools\fpga_workflow.py report` 汇总台账，
> `check` 校验一致性，`verify` 复跑回归。**不接受"文档里写过"作为证据 —— 一切以实测文件为准。**
