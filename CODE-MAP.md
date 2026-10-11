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

## 2. 核心 RTL 清单（20 个文件，**3972** 行 @2026-10-11 快照）

| 文件 | 行 | 角色 | 阅读要点 |
|---|---:|---|---|
| `rv32_pkg.sv` | 408 | **全局包**：类型 / 枚举 / 参数 / 接线契约 | `ctrl_s` 控制束；`pc_sel_e` / `wb_src_e` / `fwd_sel_e` / `sys_op_e`；存储器基址。**第一份该读的** |
| `pc.sv` | 50 | PC 寄存器 | 优先级 **flush > stall > pc_src**；`pc_plus4` |
| `imem.sv` | 83 | 指令存储器 | **默认寄存读（→ BRAM）**；定义 `IMEM_COMB_READ` 才回退成 LUT ROM |
| `control_unit.sv` | 372 | **主译码器** | 输出三段控制束；覆盖 RV32IM_Zicsr + RV32A |
| `imm_gen.sv` | 49 | 立即数生成 | I/S/B/U/J 五种 |
| `regfile.sv` | 67 | 32×32 寄存器堆 | 同拍写读的**写优先旁路** |
| `id_ex_reg.sv` | 110 | ID/EX 流水寄存器 | （R-01 正在给它加显式 `valid` 位，行数会再变） |
| `alu.sv` | 105 | ALU | |
| `branch_unit.sv` | 43 | 分支条件判定 | `taken` 由 BR_EQ/NE/LT/GE 决定 |
| `load_store_unit.sv` | **357** | **访存单元（最复杂）** | ① 非对齐访存硬件拆分（HEAD/TAIL FSM）② AMO 三相位 ③ 字节提取+符号扩展 ④ WB 影子寄存器 |
| `muldiv.sv` | 215 | RV32M 乘除 | 多周期，`busy` 期间冻结流水线 |
| `csr_file.sv` | 211 | **CSR + 陷阱** | `mtvec`→`trap_vector`、`mepc`→`mret_pc`、mcause / mtval / mstatus、trap 入口与 mret |
| `btb.sv` | 191 | BTB + 方向预测 | **命中要求 `vld && tag`**（这条不变量在 fmax 实验里被用作论证依据）；Smith 2 位默认，`BTB_GSHARE` 可选；`is_ret` 给 RAS |
| `ras.sv` | 87 | 返回地址栈 | |
| `gemm_accel.sv` | 249 | GEMM 加速器 | 自选题部分 |
| `hazard_unit.sv` | 115 | **冒险/前递** | `fwd_a/fwd_b` 选择；`pipe_stall` / `id_ex_bubble` / `hold_mem` / `redirect` |
| `ex_mem_reg.sv` | 48 | EX/MEM 流水寄存器 | |
| `mem_wb_reg.sv` | 49 | MEM/WB 流水寄存器 | |
| `dmem.sv` | 76 | 数据存储器 | 字节使能写 + 寄存读（→ RAMB36） |
| **`core.sv`** | **1087** | **顶层 CPU** | 例化全部 + 下一拍 PC + 预测校验 + 重定向 + 陷阱整合 + MMIO |

> 行数是 **2026-10-11 快照**（`[System.IO.File]::ReadAllLines(...).Length`，20 个文件求和 = **3972**），
> 含大量注释 —— 本工程把口径、取舍与踩过的坑都写在代码注释里，所以行数偏高。
>
> ⚠️ **这是进行中的工作区**：本次审查（`CODE-REVIEW-PLAN.md` R-01/R-02/W-04）正在改
> `core.sv`（1073→**1087**）/ `id_ex_reg.sv`（94→**110**）/ `csr_file.sv` / `load_store_unit.sv` /
> `rv32_pkg.sv`，**行数与本表都会继续漂移**。`core.sv` 章节行号已同步重算（见下一节），
> 其余文件请在 **RTL 冻结后**用同一条命令重算：
> ```powershell
> 'rv32_pkg.sv','pc.sv','imem.sv','control_unit.sv','imm_gen.sv','regfile.sv','id_ex_reg.sv','alu.sv','branch_unit.sv','load_store_unit.sv','muldiv.sv','csr_file.sv','btb.sv','ras.sv','gemm_accel.sv','hazard_unit.sv','ex_mem_reg.sv','mem_wb_reg.sv','dmem.sv','core.sv' | %{ "{0,-20} {1,5}" -f $_,[System.IO.File]::ReadAllLines($_).Count }
> ```

### `core.sv` 章节地图（**快照：2026-10-11，core.sv = 1087 行**，按行号跳读）

> ⚠️ **这张表是"会过期"的**：`core.sv` 正在被本次审查修复改动（`CODE-REVIEW-PLAN.md` R-01/R-02/W-04，
> 仅 2026-10-11 一天内就从 1073 → **1087** 行，全部锚点再次下移）。**改过 RTL 后请先重算**
> 再按表跳读：
> ```powershell
> # ① 章节边界（每个 // ==== 分节头的行号）
> Select-String core.sv -Pattern '^\s*//\s*=+\s*$' | ForEach-Object { $_.LineNumber }
> # ② 关键锚点
> Select-String core.sv -Pattern 'u_pc |u_imem |u_btb |u_ras |u_ctrl |u_imm |u_regfile |u_alu |u_muldiv |u_csr |u_hazard |u_ex_mem |u_lsu |u_dmem |u_mem_wb |assign sel_dmem|wb_data ='
> ```

| 行（快照） | 章节 | 里面有什么 |
|---|---|---|
| 86-195 | 互连信号声明 | 集中声明，避免隐式线网；**146 起**是「Zicsr / 陷阱」声明子节 |
| **196-300** | **IF 段** | `u_pc`(226)、`pc_next`(269)、`imem_addr = pc_next`(272/275)、`u_imem`(278)、历史记录(286-299) |
| 301-329 | 分支预测（IF 预测） | `u_btb` 例化(311)、`pred_taken` / `pred_target` |
| 330-398 | 返回地址栈（`RAS_EN`，默认关） | `u_ras` 例化(362) |
| 399-451 | **去掉冗余 `if_id_reg` 的说明**（issue #5） | IF/ID 落在 IMEM 输出寄存器上；两个坑（组合环 / `if_id_flush` 串进 ID 路径）；`id_en = boot_done`(450) |
| **452-541** | **ID 段** | `u_ctrl`(480) / `u_imm`(489) / `u_regfile`(495)、ID 门控(`id_en`) |
| **542-679** | **EX 段** | **前递 mux(554-557)**、`ex_amo_addr`(580)、`u_alu`(583)、`u_muldiv`(599)、`ex_result`(612)、跳转目标独立加法器(624-645)、**`actual_taken`(646)**、`pred_ok`(673) |
| 680-760 | Zicsr / 陷阱 / 重定向 | `u_csr`(688)、`exc_req`(726)、`irq_take`(744)、**`pc_src`(754)/`pc_target`(756)** |
| **761-786** | **冒险单元** | `u_hazard` 例化(764) |
| 787-805 | EX/MEM | `u_ex_mem`(790) |
| **806-975** | **MEM 段** | `amo_newdata` 声明(813)、`u_lsu`(818)、AMO 新值(834-932)、**MMIO 地址译码(935-941)**、`u_dmem`(952) |
| **976-1027** | **MEM/WB 与 WB 段** | `u_mem_wb`(979)、**`wb_data` mux(1010-1023)** |
| 1028-1079 | 调试与仿真专用 | `dbg_pc`(1035)/`dbg_instr`(1044) 同级口径、`dbg_illegal`(1065)、对齐断言 |
| 1080-1087 | 流水线效率观测 | 纯观测信号，不参与逻辑 |

> 锚点复核口径（`[复算]`，2026-10-11 用 `Select-String` 逐条取首次命中）：
> `u_pc` 226 / `u_imem` 278 / `u_btb` 311 / `u_ras` 362 / `id_en` 450 / `u_ctrl` 480 / `u_imm` 489 /
> `u_regfile` 495 / `fwd_a` 554 / `ex_amo_addr` 580 / `u_alu` 583 / `u_muldiv` 599 / `actual_taken` 646 /
> `pred_ok` 673 / `u_csr` 688 / `exc_req` 726 / `irq_take` 744 / `pc_src` 754 / `u_hazard` 764 /
> `u_ex_mem` 790 / `u_lsu` 818 / `sel_dmem` 941 / `u_dmem` 952 / `u_mem_wb` 979 / `wb_data` 1015-1021。
> **RTL 冻结后应重跑上面的两条命令再更新本表**（这是 R1「改了 A 忘了同步 B」的文档形态）。

---

## 3. 工具链（`tools/` + `fpga/`）

### 一站式入口：`tools/fpga_workflow.py`（2649 行 @2026-10-11 实测；**正被本次 M-01/M-02/M-03 修复改动，引用前现查**）

```powershell
python tools/fpga_workflow.py doctor      # 环境自检
python tools/fpga_workflow.py verify      # 仿真回归 (11 项, 带缓存)
python tools/fpga_workflow.py synth       # Vivado 综合 -> 四项指标 (带缓存+串行化)
python tools/fpga_workflow.py metrics     # keep/reject 判定 (绝对吞吐裁判)
python tools/fpga_workflow.py profile     # 停顿构成剖析 (优化前先测量)
python tools/fpga_workflow.py hw          # 解析上板 ILA 读回结果
python tools/fpga_workflow.py check       # 漂移检测 (文件清单/编码/新鲜度)
```

### 硬件流程

| 文件 | 作用 |
|---|---|
| `fpga/build.tcl` (461 @2026-10-11；**正被本次 X-06/X-09/E-02 修复改动，引用前现查**) | **非工程模式**综合流程：`synth → opt → Pblock → place → phys_opt → route → bitstream`；宏开关集中在文件头 |
| `fpga/daVinciPro.xdc` (49) | 引脚 + **`create_clock -period 20.000`**（"20 ns 周期"的来源） |
| `fpga/build_ila.tcl` + `ila_cap_*.tcl` | 上板 ILA 调试闭环（`jtag_probe` / `build_ila` / `ila_cap_done`） |

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
`tools/path_hotspot.py`(785) **从 `fpga/timing.rpt` 出 top-N 关键路径 + 扇出榜**（物理优化前的首选测量工具，见 PITFALLS R47；其 fmax 口径正在修正，见 `CODE-REVIEW-PLAN.md` X-05）·
`tools/pdf_text.py` / `tools/pdf_mine.py` **厂商 PDF 取文**（2405 页指南，`flash_logs/guide_text/`）

---

## 4. 文档（看这里而不是翻聊天记录）

> 括号里的行数是 **2026-10-11 快照**，文档被编辑后即失效 —— 需要精确值请现查
> （`[System.IO.File]::ReadAllLines($p).Count`）。

| 文件 | 内容 |
|---|---|
| `HANDOFF.md` (1167 @2026-10-11) | **总入口**：当前交付配置、四项指标、存储策略、上板结论、口径纪律、`check` 7 项检查门 |
| `HANDOFF-HW-LOOP.md` (308 @2026-10-11) | 上板闭环操作的逐步说明 |
| `HANDOFF-WORKFLOW.md` (306 @2026-10-11) | 工作流用法 |
| `tools/README.md` (231 @2026-10-11) | 统一工作流的逐子命令说明（含 `check` 7 项与综合警告门详解） |
| `results/*.md` (22 篇) | 每项工作的**完整实测记录**（含所有失败尝试与原因） |
| `results/coremark.csv` | 所有配置 × 四项指标的总表 |
| `tools/flash_logs/REPORT.md` (212) | **QSPI Flash 固化**的完整报告（根因 / part 对照表 / 端到端命令 / 上电自举步骤）|
| `skills/fpga-riscv-a100t/PITFALLS.md` (**R1~R47**) | **47 条踩坑记录**（改代码前扫一眼能省很多时间）；最值钱的新条目：**R43**（MMCM 漏接 `.CLKFBIN` 会把整颗 CPU 永久按在复位里）、**R47**（top-N 是"一堵墙"时 RTL 逻辑重排期望 ≈ 0）|

---

## 5. 当前交付指标（一句话基线）

> ⚠️ **本表是旧口径，引用前必须现查**：fmax 一行的算法（从 `sys_clk` 行取 WNS 再按 20 ns 换算）
> 在引入 MMCM 之后**已经失效** —— `sys_clk` 行不再有 setup 端点，会把**脉宽余量**当成 WNS
> （详见 `CODE-REVIEW-PLAN.md` **M-01 / X-01 / D-01~D-03**）。
> 请以**修正后的** `python tools\fpga_workflow.py metrics` 或现读 `fpga/timing.rpt` + `results/coremark.csv` 末行为准。

| 指标 | 值 |
|---|---|
| CoreMark/MHz | **2.4209**（仿真 ticks 413,070） |
| fmax | **69.8 MHz**（WNS 5.673 @20ns，由 `1000/(20−WNS)` 推得） |
| LUT / FF / BRAM / DSP | **2649 / 1234 / 8 / 8** |
| CoreMark/LUTs | **9.139e-4** |
| 绝对吞吐 | **169.0**（= CM/MHz × fmax） |
| 上板 | `ila_ctrl=0x42`、CRC bit31=1、tick **536,943,384**、**10.74 s** @50 MHz（1300 迭代）、硬件 CM/MHz **2.4211** |

> 上板一行的参数同样是**历史口径**（2026-10-08）；**最后一次 ILA 采集是 2026-10-09 21:29**
> （凭据 `results/ila_done.csv` + `fpga/cap_done.log`），两者不同 —— 以 CSV 现查为准。
