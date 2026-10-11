# CODE-MAP.md — 代码地图与阅读路线

> 本文件是**读代码的向导**（不是设计文档）。目标：让你用最短时间建立起
> 「一条指令从 PC 到写回，中间经过哪些模块、被哪些控制信号驱动」的完整心智模型。
> 细节（每一位怎么算）可以后看；先用它把**骨架**搭起来。

---

## 0. 一句话

一个 **RV32IM_Zicsr + RV32A、M-mode、五级顺序单发射流水线** CPU，
带 2 位 Smith 分支预测 + BTB（可选 RAS / gshare）、非对齐访存硬件拆分、
精确陷阱、以及一个自选题目用的 **GEMM 加速器**；目标器件
**XC7A100T-FGG484-2（正点原子达芬奇Pro）**，板载 50 MHz 晶振
（XDC 里 `create_clock -period 20.000` —— 这就是"20 ns 周期"的唯一来源）。

---

## 1. 建议阅读顺序（三遍）

### 第 1 遍：骨架（约 30 分钟）—— 只追 5 个流水寄存器

只关心「指令在哪个寄存器里」，不关心控制细节：

```
rv32_pkg.sv           ← 先看类型定义 (ctrl_s / 各 enum)，10 分钟
core.sv:195-299       ← IF 段:  pc -> imem (其输出寄存器直接充当 IF/ID)
core.sv:451-538       ← ID 段:  imem_rdata -> regfile/译码 -> id_ex
core.sv:539-676       ← EX 段:  id_ex -> ALU/分支/乘除 -> ex_mem
core.sv:792-961       ← MEM 段: ex_mem -> dmem/LSU/MMIO -> mem_wb
core.sv:962-1013      ← WB 段:  mem_wb -> wb_data mux -> regfile 写口
```

**这一遍要能回答**：`id_ex` / `ex_mem` / `mem_wb` 三个寄存器各自
携带哪些字段？它们分别由哪个模块例化？（仍是 **5 级**：IF/ID 由 IMEM 的输出寄存器承担 —— 注意口径是
“**4 个流水寄存器 ⇒ 5 级**”，别差一。见 `results/p8-ifid-elide.md`）

### 第 2 遍：控制（约 1 小时）—— 谁在控制这条流水线

```
control_unit.sv       ← 译码器: 产生 ctrl_s (EX/MEM/WB 三段控制束) + pc_sel + wb_src
hazard_unit.sv        ← 前递选择 fwd_a/fwd_b + load-use 停顿 + 重定向门控
core.sv:621-676       ← 分支/跳转目标 + 预测校验 (actual_taken / pred_ok)
core.sv:677-746       ← Zicsr/陷阱判定 + 重定向仲裁 (pc_src / pc_target)
```

**这一遍要能回答**：一条 `lw` 紧跟一条依赖它的 `add`，会停几拍、由谁决定？
一次分支预测错误，是怎么把 ID/EX 冲成气泡的？（ID 由 `id_en=boot_done` 门控）

### 第 3 遍：按需深入（各自独立）

```
load_store_unit.sv    ← 最复杂: 非对齐拆分 FSM / AMO 三相位 / 字节提取
btb.sv + ras.sv       ← 预测器: vld+tag 命中、2 位方向、返回地址栈
csr_file.sv           ← 陷阱语义: mtvec/mepc/mcause/mstatus、trap/mret
muldiv.sv             ← RV32M: 多周期, busy 冻结整条流水线
gemm_accel.sv         ← 自选题 GEMM 加速器
```

---

## 2. 核心 RTL 清单（20 个文件，**4108** 行 @2026-10-11 RTL 冻结后实测）

| 文件 | 行 | 角色 | 阅读要点 |
|---|---:|---|---|
| `rv32_pkg.sv` | 408 | **全局包**：类型 / 枚举 / 参数 / 接线契约 | `ctrl_s` 控制束；`pc_sel_e` / `wb_src_e` / `fwd_sel_e` / `sys_op_e`；存储器基址。**第一份该读的** |
| `pc.sv` | 50 | PC 寄存器 | 优先级 **flush > stall > pc_src**；`pc_plus4` |
| `imem.sv` | 83 | 指令存储器 | **默认寄存读（→ BRAM）**；定义 `IMEM_COMB_READ` 才回退成 LUT ROM |
| `control_unit.sv` | 372 | **主译码器** | 输出三段控制束；覆盖 RV32IM_Zicsr + RV32A |
| `imm_gen.sv` | 49 | 立即数生成 | I/S/B/U/J 五种 |
| `regfile.sv` | 67 | 32×32 寄存器堆 | 同拍写读的**写优先旁路** |
| `id_ex_reg.sv` | 124 | ID/EX 流水寄存器 | **R-01 新增显式 `valid` 位**（中断不再落在气泡上） |
| `alu.sv` | 105 | ALU | |
| `branch_unit.sv` | 43 | 分支条件判定 | `taken` 由 BR_EQ/NE/LT/GE 决定 |
| `load_store_unit.sv` | **382** | **访存单元（最复杂）** | ① 非对齐访存硬件拆分（HEAD/TAIL FSM）② AMO 三相位 ③ 字节提取+符号扩展 ④ WB 影子寄存器 ⑤ **R49：LR/SC 写相门控** |
| `muldiv.sv` | 215 | RV32M 乘除 | 多周期，`busy` 期间冻结流水线 |
| `csr_file.sv` | 211 | **CSR + 陷阱** | `mtvec`→`trap_vector`、`mepc`→`mret_pc`、mcause / mtval / mstatus、trap 入口与 mret |
| `btb.sv` | 191 | BTB + 方向预测 | **命中要求 `vld && tag`**（这条不变量在 fmax 实验里被用作论证依据）；Smith 2 位默认，`BTB_GSHARE` 可选；`is_ret` 给 RAS |
| `ras.sv` | 87 | 返回地址栈 | |
| `gemm_accel.sv` | 249 | GEMM 加速器 | 自选题部分 |
| `hazard_unit.sv` | 115 | **冒险/前递** | `fwd_a/fwd_b` 选择；`pipe_stall` / `id_ex_bubble` / `hold_mem` / `redirect` |
| `ex_mem_reg.sv` | 88 | EX/MEM 流水寄存器 | **R48 新增 `flush` 口**（`trap_enter` 时把被抢占的指令冲成气泡，否则会双执行） |
| `mem_wb_reg.sv` | 49 | MEM/WB 流水寄存器 | **刻意没有 flush**（这一拍是更老的指令，必须提交） |
| `dmem.sv` | 76 | 数据存储器 | 字节使能写 + 寄存读（→ RAMB36） |
| **`core.sv`** | **1144** | **顶层 CPU** | 例化全部 + 下一拍 PC + 预测校验 + 重定向 + 陷阱整合（R48）+ MMIO |

> 行数为 **2026-10-11 RTL 冻结后**实测（`[System.IO.File]::ReadAllLines(...).Length`，
> 20 个文件求和 = **4108**），含大量注释 —— 本工程把口径、取舍与踩过的坑都写在代码注释里。
>
> 相对冻结前的 +136 行主要来自本轮正确性修复：`core.sv` +57、`ex_mem_reg.sv` +40（**R48** flush）、
> `id_ex_reg.sv` +30（**R-01** valid）、`load_store_unit.sv` +25（**R49** LR/SC 门控）。
> 改过 RTL 后请用同一条命令重算：
> ```powershell
> 'rv32_pkg.sv','pc.sv','imem.sv','control_unit.sv','imm_gen.sv','regfile.sv','id_ex_reg.sv','alu.sv','branch_unit.sv','load_store_unit.sv','muldiv.sv','csr_file.sv','btb.sv','ras.sv','gemm_accel.sv','hazard_unit.sv','ex_mem_reg.sv','mem_wb_reg.sv','dmem.sv','core.sv' | %{ "{0,-20} {1,5}" -f $_,[System.IO.File]::ReadAllLines($_).Count }
> ```

### `core.sv` 章节地图（**2026-10-11 RTL 冻结版，core.sv = 1144 行**，按行号跳读）

> **冻结后已按当前文件全部重算。** RTL 再改动后请先重跑下面两条命令再按表跳读：
> ```powershell
> # ① 章节边界（每个 // ==== 分节头的行号）
> Select-String core.sv -Pattern '^\s*//\s*=+\s*$' | ForEach-Object { $_.LineNumber }
> # ② 关键锚点
> Select-String core.sv -Pattern 'u_pc |u_imem |u_btb |u_ras |u_ctrl |u_imm |u_regfile |u_alu |u_muldiv |u_csr |u_hazard |u_ex_mem |u_lsu |u_dmem |mem_wb_reg u_mem_wb|assign sel_dmem|wb_data ='
> ```

| 行（冻结版） | 章节 | 里面有什么 |
|---|---|---|
| 86-200 | 互连信号声明 | 集中声明，避免隐式线网；**151 起**是「Zicsr / 陷阱」声明子节 |
| **201-305** | **IF 段** | `u_pc`(231)、`pc_next`(274)、`imem_addr`(277/280)、`u_imem`(283) |
| 306-334 | 分支预测（IF 预测） | `u_btb` 例化(316)、`pred_taken` / `pred_target` |
| 335-403 | 返回地址栈（`RAS_EN`，默认关） | `u_ras` 例化(367) |
| 404-456 | **去掉冗余 `if_id_reg` 的说明**（issue #5） | IF/ID 落在 IMEM 输出寄存器上；组合环 / `if_id_flush` 串进 ID 路径 |
| **457-548** | **ID 段** | `u_ctrl`(485) / `u_imm`(494) / `u_regfile`(500)、ID 门控 `id_en` |
| **549-686** | **EX 段** | **前递 mux(561-564)**、`ex_amo_addr`(587)、`u_alu`(590)、`u_muldiv`(606)、跳转目标独立加法器、**`actual_taken`(653)**、`pred_ok`(680) |
| 687-776 | Zicsr / 陷阱 / 重定向 | `u_csr`(695)、`exc_req`(733)、`irq_take`(751)、**`pc_src`(770)** |
| **777-802** | **冒险单元** | `u_hazard` 例化(780) |
| 803-830 | EX/MEM | `u_ex_mem`(814)；**R48：`.flush(trap_enter)`**（805 起有整段"为什么只冲 trap_enter、mem_wb 不能冲"的注释） |
| **831-1012** | **MEM 段** | `amo_newdata`(834)、`u_lsu`(843)、AMO 新值、**MMIO 地址译码(972-978)**、`u_dmem`(989) |
| **1013-1067** | **MEM/WB 与 WB 段** | `u_mem_wb`(1019)、**`wb_data` mux(1050-1063)**；1015 起是"刻意不对称：这里没有 flush"的说明 |
| 1068-1136 | 调试与仿真专用 | `dbg_pc`(1075)/`dbg_instr`(1084)、`dbg_illegal`(1105)、对齐断言 |
| 1137-1144 | 流水线效率观测 | 纯观测信号，不参与逻辑 |

> 锚点复核口径（`[复算]`，2026-10-11 冻结版逐条 `Select-String` 取首次命中）：
> `u_pc` 231 / `pc_next` 274 / `u_imem` 283 / `u_btb` 316 / `u_ras` 367 / `u_ctrl` 485 / `u_imm` 494 /
> `u_regfile` 500 / `fwd_a` 561 / `ex_amo_addr` 587 / `u_alu` 590 / `u_muldiv` 606 / `actual_taken` 653 /
> `pred_ok` 680 / `u_csr` 695 / `exc_req` 733 / `irq_take` 751 / `pc_src` 770 / `u_hazard` 780 /
> `u_ex_mem` 814 / `u_lsu` 843 / `sel_dmem` 978 / `u_dmem` 989 / `u_mem_wb` 1019 / `wb_data` 1055-1061。
> **RTL 冻结后应重跑上面的两条命令再更新本表**（这是 R1「改了 A 忘了同步 B」的文档形态）。

---

## 3. 工具链（`tools/` + `fpga/`）

### 一站式入口：`tools/fpga_workflow.py`（2973 行 @2026-10-11 75 MHz 冻结版实测）

```powershell
python tools/fpga_workflow.py doctor      # 环境自检
python tools/fpga_workflow.py verify      # 仿真回归 (11 项, 带缓存)
python tools/fpga_workflow.py synth       # Vivado 综合 -> 四项指标 (带缓存+串行化)
python tools/fpga_workflow.py metrics     # keep/reject 判定 (绝对吞吐裁判)
python tools/fpga_workflow.py profile     # 停顿构成剖析 (优化前先测量)
python tools/fpga_workflow.py hw          # 解析上板 ILA 读回结果 (迭代数/主频从采集清单推断)
python tools/fpga_workflow.py check       # 7 项漂移检测 + 综合警告门
```

### 硬件流程

| 文件 | 作用 |
|---|---|
| `fpga/build.tcl` (484) | **非工程模式**综合流程：`synth → opt → Pblock → place → phys_opt → route → bitstream`；宏开关集中在文件头；路径用 `$root` 相对化；**内建 `BUILD_TIMING=PASS/FAIL` 时序门** |
| `fpga/daVinciPro.xdc` (51) | 引脚 + **`create_clock -period 20.000`**（板载 50 MHz 输入）+ MMCM 的 **75 MHz** 输出约束 |
| `fpga/build_ila.tcl` + `ila_cap_*.tcl` | 上板 ILA 调试闭环（`jtag_probe` / `build_ila` / `ila_cap_done`）；抓取后写 **采集清单 `results/ila_done.capture.json`** |
| `tools/check_equiv.py` (175) | LSU 字节通道等价性穷举（**675 万组，~5 s**）—— 交付版访存 mux 的正确性论证 |

> ⚠️ **踩坑 R33**：ILA 构建失败后**必须删掉 `fpga/ila_proj*`** 才能重建成功（出现过两次）。

### QSPI Flash 固化（断电自举）—— 已打通，别重复造

整条链路已闭环并**逐字节读回校验通过**（`5bd8e37`，2026-10-09；实测报告
`tools/flash_logs/REPORT.md`）。**一条命令端到端**（自动预载 flash accessor → `write_cfgmem`
建镜像 → 烧写 → **16 MB 全片读回逐字节比对**）：

```powershell
powershell -File tools\flash_boot.ps1 -Bit fpga\cpu_a100t_spix4.bit -Iface SPIx4
rem 回退到 SPIx1（同样验证过）: powershell -File tools\flash_boot.ps1 -Iface SPIx1
```

> 命令形式取自脚本自己的 Usage 头；判据是最后一行 `VERIFY=PASS`。
> 注意脚本里 Vivado/Python 路径是**硬编码绝对路径**（同 E-02 的可移植性问题），
> `-Bit` 相对路径取不到时会在 `MKIMAGE: bit exists = 0` 处显式失败。

| 文件 | 作用 |
|---|---|
| `tools/flash_boot.ps1` | **推荐入口**：一条命令跑完 accessor + 建像 + 烧写 + 全片读回比对 |
| `tools/flash_run.ps1` | 单次实验 runner（`-Part` / `-Action`），完整 stdout/stderr 落 `tools/flash_logs/` |
| `tools/flash_sweep.ps1` | 9+2 个 128Mb cfgmem part 逐一试烧，出 `sweep_results.csv` |
| `tools/flash_program.tcl` | 核心 Tcl 流程（accessor 预载 + 器件过滤绑定 + 8 种 action） |
| `tools/flash_mkimage.tcl` | `write_cfgmem` 生成 `.mcs`/`.bin` 启动镜像 |
| `tools/flash_readback.tcl` | 只读：全片读回 dump |
| `tools/flash_probe.tcl` | 只读：枚举 cfgmem part 库 / help / 属性 |
| `tools/flash_partcheck.tcl` | 只读：对比"器件过滤 vs 不过滤"查找，捕获 `44-655` 原文 |

**板上实测**（非推断）：芯片 JEDEC `20 BA 18` = **Micron N25Q128 / MT25QL128**（128 Mbit，
与原理图 BOM 一致）⇒ 正确 part = **`mt25ql128-spi-x1_x2_x4`**（`n25q128-3.3v-spi-x1_x2_x4`
只是它的 `MEM_DEVICE_ALIAS`，**不可检索**）。
两个必须记住的坑：**① `PROGRAM.CFG_PROGRAM` 必须为 1**（为 0 会擦除后打印"成功"却什么都不写）；
**② 必须先 `program_hw_devices` 预载 accessor**，否则报 `27-3347 Failure to set flash parameters`。
完整故事见 `tools/flash_logs/REPORT.md` + PITFALLS **R44/R45/R46**。

> 上电自举验证只剩"断电再上电看 DONE 灯"这一步需要人做（`REPORT.md` §4 有步骤）；
> 跑分/读回本身仍是全自动的（ILA over JTAG）。

### 仿真

| 文件 | 作用 |
|---|---|
| `sim/tb_units.sv` (563) | 单元测试（ALU/前递/冒险/CSR/AMO…），**检查点数以运行时打印为准** |
| `sim/tb_core.sv` (175) | 定向汇编程序；`+illegal_trace` 打**逐拍轨迹** |
| `sim/tb_soc.sv` (269) | SoC 级（定时器/中断/MMIO） |
| `sim/tb_sw.sv` (406) | 跑完整软件（hello / CoreMark / NN）；输出**停顿构成剖析** |

### 辅助脚本

`tools/asm.py`(326) 汇编器 · `tools/elf2hex.py`(93) · `tools/build_sw.py`(143) ·
`tools/run_coremark.py`(131) · `tools/amo_vectors.py`(131) ·
`tools/mk_cm_hw.py` **重建跑分镜像并重算 `ITERATIONS`（见 PITFALLS R35）** ·
`tools/trace_diff.py`(152) **逐拍轨迹比对（找 RTL 改动的第一处分歧）** ·
`tools/path_hotspot.py`(821) **从 `fpga/timing.rpt` 出 top-N 关键路径 + 扇出榜**（物理优化前的首选测量工具，见 PITFALLS R47；fmax 口径已按最差路径自带的 `Requirement` 修正）·
`tools/pdf_text.py` / `tools/pdf_mine.py` **厂商 PDF 取文**（2405 页指南，`flash_logs/guide_text/`）

---

## 4. 文档（看这里而不是翻聊天记录）

> 括号里的行数是 **2026-10-11 快照**，文档被编辑后即失效 —— 需要精确值请现查
> （`[System.IO.File]::ReadAllLines($p).Count`）。

| 文件 | 内容 |
|---|---|
| `HANDOFF.md` (1190 @2026-10-11) | **总入口**：当前交付配置、四项指标、存储策略、上板结论、口径纪律、`check` 7 项检查门 |
| `HANDOFF-HW-LOOP.md` (319 @2026-10-11) | 上板闭环操作的逐步说明 |
| `HANDOFF-WORKFLOW.md` (310 @2026-10-11) | 工作流用法 |
| `tools/README.md` (243 @2026-10-11) | 统一工作流的逐子命令说明（含 `check` 7 项与综合警告门详解） |
| `results/*.md` (22 篇) | 每项工作的**完整实测记录**（含所有失败尝试与原因） |
| `results/coremark.csv` | 所有配置 × 四项指标的总表 |
| `tools/flash_logs/REPORT.md` (212) | **QSPI Flash 固化**的完整报告（根因 / part 对照表 / 端到端命令 / 上电自举步骤）|
| `skills/fpga-riscv-a100t/PITFALLS.md` (**R1~R51**) | **51 条踩坑记录**（改代码前扫一眼能省很多时间）；最值钱的新条目：**R43**（MMCM 漏接 `.CLKFBIN` 会把整颗 CPU 永久按在复位里）、**R47**（top-N 是"一堵墙"时 RTL 逻辑重排期望 ≈ 0）、**R48**（陷阱只冲 ID/EX ⇒ 被抢占指令双执行）、**R49**（多周期状态机写相与算子无关 ⇒ LR.W 把目标字清零）、**R50**（换频只换抽头最安全；提频本身也会抬高 fmax）|

---

## 5. 当前交付指标（一句话基线，**2026-10-11 冻结版**）

| 指标 | 值 |
|---|---|
| CoreMark/MHz | **2.4209**（仿真 ticks 413,070） |
| fmax | **76.2 MHz** —— `sys_clk_75` @13.333 ns（运行 75.00 MHz），WNS **+0.206** ⇒ `1000/(13.333−0.206)` |
| LUT / FF / BRAM / DSP | **2734 / 1251 / 8 / 8** |
| CoreMark/LUTs | **8.855e-4** |
| 绝对吞吐 | **184.4**（= CM/MHz × fmax） |
| 上板（2026-10-11 12:19:02） | `ila_ctrl=0xC2`、CRC bit31=1、tick **1,239,079,510**、**16.52 s** @75 MHz（3000 迭代）、硬件 CM/MHz **2.4212** |

> 数字来源：`.fpga-cache/reports/20261011-121231-cm_hw/`（timing/util/metrics）+ `results/coremark.csv`
> 行 `clk75` + `results/ila_done.capture.json`（采集清单）。**fmax 必须带时钟名 + 周期 + 运行频率**
> （纪律见 `HANDOFF.md` §8「口径纪律」）；引用 `coremark.csv` 的 `fmax` 列要配 `fmax_src` 列。
> ⚠️ **运行频率与 fmax 不独立**（PITFALLS R50）：约束收紧 14.286→13.333 ns 本身就让 fmax 74.4→76.2。

> 上板一行的凭据是 **`results/ila_done.capture.json`（采集清单，2026-10-11 12:19:02）**，
> 不是 CSV 的 mtime（CSV 被 git 跟踪，mtime 可被 checkout 刷新 —— X-02）。
