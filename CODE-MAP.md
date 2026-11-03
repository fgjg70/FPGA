> **文档性质声明（开发/交接文档）**：本文是内部开发/交接/审查文档，不是赛题交付结论或对外验收报告；涉及的数字请以根 [`COMPLIANCE.md`](COMPLIANCE.md) 的"证据分级"与对应证据文件为准。

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
core.sv  ── IF 段      ← 找分节头 `// IF 段`（pc -> imem；其输出寄存器直接充当 IF/ID）
core.sv  ── ID 段      ← 找 `// ID 段`（imem_rdata -> regfile/译码 -> id_ex）
core.sv  ── EX 段      ← 找 `// EX 段`（id_ex -> ALU/分支/乘除 -> ex_mem）
core.sv  ── MEM 段     ← 找 `// MEM 段`（ex_mem -> dmem/LSU/MMIO -> mem_wb）
core.sv  ── MEM/WB 与 WB 段 ← 找 `// MEM/WB 与 WB 段`（wb_data mux -> regfile 写口）
```

> ⚠️ **这里刻意不写行号**（行号会随每次 RTL 改动失效，是 R16 那种"被推翻的引用"）。
> 用**标识符/分节标题**定位；确需行号时按 §2 末尾的两条命令现算。
> 例：`Select-String core.sv -Pattern '^\s*//\s*=+\s*$'` 列出所有分节头行号。

**这一遍要能回答**：`id_ex` / `ex_mem` / `mem_wb` 三个寄存器各自
携带哪些字段？它们分别由哪个模块例化？（仍是 **5 级**：IF/ID 由 IMEM 的输出寄存器承担 —— 注意口径是
“**4 个流水寄存器 ⇒ 5 级**”，别差一。见 `results/p8-ifid-elide.md`）

### 第 2 遍：控制（约 1 小时）—— 谁在控制这条流水线

```
control_unit.sv       ← 译码器: 产生 ctrl_s (EX/MEM/WB 三段控制束) + pc_sel + wb_src
hazard_unit.sv        ← 前递选择 fwd_a/fwd_b + load-use 停顿 + 重定向门控
core.sv               ← 搜标识符 `actual_taken` / `pred_ok`（分支/跳转目标 + 预测校验）
core.sv               ← 搜标识符 `pc_src` / `pc_target`（Zicsr/陷阱判定 + 重定向仲裁）
```

**这一遍要能回答**：一条 `lw` 紧跟一条依赖它的 `add`，会停几拍、由谁决定？
一次分支预测错误，是怎么把 ID/EX 冲成气泡的？（ID 由 `id_en = boot_done` 门控）

### 第 3 遍：按需深入（各自独立）

```
load_store_unit.sv    ← 最复杂: 非对齐拆分 FSM / AMO 三相位 / 字节提取
btb.sv + bht.sv       ← 预测器 (C-1 两级流水): BTB 512 项 + PHT 8192 项、vld+tag 命中、返回地址栈
ras.sv                ← 返回地址栈 (RAS_EN; 见 PITFALLS/R50 族的"旧结论需重测")
csr_file.sv           ← 陷阱语义: mtvec/mepc/mcause/mstatus、trap/mret
muldiv.sv             ← RV32M: 多周期, busy 冻结整条流水线
gemm_accel.sv         ← 自选题 GEMM 加速器
```

---

## 2. 核心 RTL 清单（根目录 **21** 个 `.sv`，合计 **4691** 行 @2026-10-11 16:33 现查）

> ⚠️ **行数是活数**：另一条泳道正在改 RTL（本表测完 10 分钟内 `core.sv` 又从 1523 → **1532**）。
> 引用前请用下面的命令**现查**，不要抄本表数字。

> **口径先写清**（`check` 的 [1] 项"规范是 22 个文件"指的是"综合 + 仿真两侧清单里的核文件"，
> 与"根目录有几个 `.sv`"不是同一个数）：
> - **根目录 `.sv`：21 个 / 4682 行**（下表，`Get-ChildItem -Filter *.sv` 现查）
> - **`fpga/*.sv`：2 个**（`mmio_subsys.sv` 373 + `top_a100t.sv` 254）⇒ 全仓 `.sv` 共 **23 个**
> - **采集清单的 RTL 指纹**：包含**根目录 + `fpga/` 两处的所有 `.sv`**（`ila_cap_done.tcl` 的
>   `br_rtl_sv_files`）。2026-10-11 15:22 那次记录的是 **22** 个 —— 因为当时 `bht.sv` 还不存在
>   （它由 `028ca4d` 在 15:55 引入）。**所以"22"与"23"都不错，差的是时间点。**

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
| `btb.sv` | 192 | **512 项两级流水 BTB**（C-1 重写） | 预测口来自**寄存器**（pc mux 只挑寄存器输出 ⇒ 零气泡）；**命中要求 `vld && tag`**；内部例化 `bht`（`u_bht`，见 `btb.sv` 的例化处）|
| **`bht.sv`** | **148** | **方向预测表 PHT**（C-1 两级流水 gshare） | 8192 项 × 2 位饱和计数器，**1 块 RAMB18**；索引 `PC[13:1] ^ (GHR & mask)`；写回索引随流水带 2 拍（否则"冷计数"）；`GH_BITS=0` 退化成纯局部 2 位对照组；**由 `btb.sv` 例化，不是 `core.sv`**（`check` [2] 项的"谁例化"问题在这里）|
| `ras.sv` | 87 | 返回地址栈 | ⚠️ 旧结论"因 fmax 净亏"**需在 C-1 之后重测**（见 `results/p4-c1-2stage-gshare.md`：`--ras` ticks 453,942→452,288、JALR 误判 3,650→2,796）|
| `gemm_accel.sv` | 249 | GEMM 加速器 | 自选题部分 |
| `hazard_unit.sv` | 161 | **冒险/前递** | `fwd_a/fwd_b` 选择；`pipe_stall` / `id_ex_bubble` / `hold_mem` / `redirect`（C-10 起 `id_ex_rs1/rs2` 端口已删）|
| `ex_mem_reg.sv` | 88 | EX/MEM 流水寄存器 | **R48 新增 `flush` 口**（`trap_enter` 时把被抢占的指令冲成气泡，否则会双执行） |
| `mem_wb_reg.sv` | 49 | MEM/WB 流水寄存器 | **刻意没有 flush**（这一拍是更老的指令，必须提交） |
| `dmem.sv` | 76 | 数据存储器 | 字节使能写 + 寄存读（→ RAMB36） |
| **`core.sv`** | **1532** | **顶层 CPU** | 例化全部 + 下一拍 PC + 预测校验 + 重定向 + 陷阱整合（R48）+ MMIO |

> 行数是 **2026-10-11 16:33 现查**（`[System.IO.File]::ReadAllLines(...).Length`，根目录 21 个合计 **4691**）——
> 数字会随 RTL 改动变，用下面两条命令随时重算（含"根目录 + `fpga/`"两个口径）：
> ```powershell
> # ① 根目录：文件数 + 逐文件行数 + 合计
> Get-ChildItem -Filter *.sv | %{ "{0,-20} {1,5}" -f $_.Name,[IO.File]::ReadAllLines($_.FullName).Count }
> (Get-ChildItem -Filter *.sv | %{ [IO.File]::ReadAllLines($_.FullName).Count } | Measure-Object -Sum).Sum
> # ② 全仓（含 fpga/）—— 与采集清单的 rtl_sha256_files 同口径
> (Get-ChildItem -Path . -Recurse -Filter *.sv -File | ?{ $_.FullName -notmatch '\\(ila_proj|legacy|\.git)' }).Count
> ```

### `core.sv` 章节地图（**2026-10-11 现查版，core.sv = 1532 行（仍在变）**）

> **以分节标题/标识符为准，行号只是"现查快照"**（行号随每次 RTL 改动失效，属 R16 那类"被推翻的引用"）。
> 重算命令：
> ```powershell
> # ① 章节边界 + 标题（每个 // ==== 分节头；标题取其后首个注释行）
> Select-String core.sv -Pattern '^\s*//\s*=+\s*$' | ForEach-Object { $_.LineNumber }
> # ② 关键锚点（按标识符取首次命中的行号）
> Select-String core.sv -Pattern 'u_pc |u_imem |u_btb |u_ras |u_ctrl |u_imm |u_regfile |u_alu |u_muldiv |u_csr |u_hazard |u_ex_mem |u_lsu |u_dmem |mem_wb_reg u_mem_wb|assign sel_dmem|wb_data ='
> # ③ 预测器（bht 由 btb 例化，不在 core 里）
> Select-String btb.sv -Pattern 'bht\s*#'      # -> u_bht 例化处
> ```

| 分节标题（搜这个字符串） | 行（现查） | 里面有什么（按标识符找） |
|---|---|---|
| `互连信号声明` | 86-242 | 集中声明，避免隐式线网；`// ---- Zicsr / 陷阱 (M-mode) ----` 子节起 151 |
| **`IF 段`** | **243-369** | `u_pc`(273)、`pc_next`(336)、`imem_addr`(341/344)、`u_imem`(347) |
| `分支预测 (IF 预测 / EX 校验)` | 370-428 | `u_btb` 例化(399)；**`【C-1 接线】`(380) 起说明 btb 重写 + bht 新增**；`pred_taken` / `pred_target` |
| `返回地址栈 (RAS)` | 429-502 | `u_ras` 例化(461)；**旧"净亏"结论需 C-1 后重测** |
| `【issue #5 已实施】去掉冗余的 if_id_reg` | 503-557 | IF/ID 落在 IMEM 输出寄存器上；组合环 / `if_id_flush` 串进 ID 路径 |
| **`ID 段`** | **558-651** | `u_ctrl`(586) / `u_imm`(595) / `u_regfile`(601)、ID 门控 `id_en`(257 的赋值) |
| **`EX 段`** | **652-849** | **前递 mux**(698)、`ex_amo_addr`(724)、`u_alu`(727)、`u_muldiv`(743)、跳转目标独立加法器、**`actual_taken`(801)**、`pred_ok`(840) |
| `Zicsr 与陷阱 (M-mode)` | 850-1051 | `u_csr`(858)、`exc_req`(915)、`irq_take`(939)、**`pc_src`(1049)**；内含 **`【C-11】`(955)**、**`【trap/mret 同拍优先】`(984)** |
| **`冒险单元`** | **1052-1120** | `u_hazard` 例化(1055)；**`【C-10 清理】`(1054)**（`id_ex_rs1/rs2` 端口已删） |
| `EX/MEM` | 1121-1154 | `u_ex_mem`(1134)；**R48：`.flush(trap_enter)`**（1123 起说明"只冲 trap_enter、mem_wb 不能冲"） |
| **`MEM 段`** | **1155-1336** | `amo_newdata`(1158)、`u_lsu`(1167)、AMO 新值、**MMIO 地址译码**（`sel_dmem` 1302）、`u_dmem`(1313) |
| **`MEM/WB 与 WB 段`** | **1337-1392** | `u_mem_wb`(1343)、**`wb_data` mux(1380-1386)**；1339 起"刻意不对称：这里没有 flush" |
| `调试与仿真专用` | 1393-1515 | `dbg_pc`(1400)/`dbg_instr`(1409)、`dbg_illegal`(1430)、对齐断言；**1501-1510 是 C-1 的 BTB/BHT 对齐自证（`$error` 硬失败）** |
| `流水线效率观测` | 1516-1523 | 纯观测信号，不参与逻辑 |

> 锚点复核口径（`[复算]`，2026-10-11 逐条 `Select-String` 取首次命中）：
> `u_pc` 273 / `pc_next` 336 / `u_imem` 347 / `u_btb` 399 / `u_ras` 461 / `u_ctrl` 586 / `u_imm` 595 /
> `u_regfile` 601 / `fwd_a` 698 / `ex_amo_addr` 724 / `u_alu` 727 / `u_muldiv` 743 / `actual_taken` 801 /
> `pred_ok` 840 / `u_csr` 858 / `exc_req` 915 / `irq_take` 939 / `pc_src` 1049 / `u_hazard` 1055 /
> `u_ex_mem` 1134 / `u_lsu` 1167 / `sel_dmem` 1302 / `u_dmem` 1313 / `u_mem_wb` 1343 / `wb_data` 1380-1386；
> `bht` 的例化在 **`btb.sv`**（`u_bht`），**不在 `core.sv`**。

---

## 3. 工具链（`tools/` + `fpga/`）

### 一站式入口：`tools/fpga_workflow.py`（3095 行 @2026-10-11 现查）

```powershell
python tools/fpga_workflow.py doctor      # 环境自检
python tools/fpga_workflow.py verify      # 仿真回归 (12 项, 带缓存)
python tools/fpga_workflow.py synth       # Vivado 综合 -> 四项指标 (带缓存+串行化)
python tools/fpga_workflow.py metrics     # keep/reject 判定 (绝对吞吐裁判)
python tools/fpga_workflow.py profile     # 停顿构成剖析 (优化前先测量)
python tools/fpga_workflow.py hw          # 解析上板 ILA 读回结果 (迭代数/主频从采集清单推断)
python tools/fpga_workflow.py check       # 7 项漂移检测 + 综合警告门
```

### 硬件流程

| 文件 | 作用 |
|---|---|
| `fpga/build.tcl` (545) | **非工程模式**综合流程：`synth → opt → Pblock → place → phys_opt → route → bitstream`；宏开关集中在文件头；路径用 `$root` 相对化；**内建 `BUILD_TIMING=PASS/FAIL` 时序门** |
| `fpga/daVinciPro.xdc` (54) | 引脚 + **`create_clock -period 20.000`**（板载 50 MHz 输入）+ `create_generated_clock -name sys_clk_core -multiply_by 21 -divide_by 8`（⇒ **131.25 MHz**，**频率无关命名**）|
| `fpga/build_ila.tcl` (331) + `ila_cap_*.tcl` | 上板 ILA 调试闭环（`jtag_probe` / `build_ila` / `ila_cap_done`）；内建 `ILA_TIMING=FAIL` 门；抓取后写 **采集清单 `results/ila_done.capture.json`** |
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
| `sim/tb_core.sv` (181) | 定向汇编程序；`+illegal_trace` 打**逐拍轨迹** |
| `sim/tb_soc.sv` (272) | SoC 级（定时器/中断/MMIO） |
| `sim/tb_sw.sv` (704) | 跑完整软件（hello / **lu_bench** / CoreMark / NN）；输出**停顿构成剖析** |

> `verify` 矩阵 = **12 项**（`tools/fpga_workflow.py` 的 `test_matrix()`）：
> `tb_units` / `tb_core_basic` / `tb_core_trap` / `tb_soc_timer_irq` / `tb_core_m_ext` / `tb_core_amo` /
> `tb_core_amo_diag` / `tb_soc` / **`tb_sw_lu_bench`** / `tb_sw_hello` / `tb_sw_coremark` / `tb_sw_nn_demo`。
> **`tb_sw_lu_bench`**（`fcdb48e` 新增）：load-use 代价标定 —— 距离 1 = **2 拍** / 距离 2 = **1 拍** + checksum。

### 辅助脚本

`tools/asm.py`(326) 汇编器 · `tools/elf2hex.py`(93) · `tools/build_sw.py`(343) ·
`tools/run_coremark.py`(164) · `tools/amo_vectors.py`(131) ·
`tools/mk_cm_hw.py`(199) **重建跑分镜像并重算 `ITERATIONS`（见 PITFALLS R35；含 31 位 tick 硬闸门）** ·
`tools/trace_diff.py`(152) **逐拍轨迹比对（找 RTL 改动的第一处分歧）** ·
`tools/path_hotspot.py`(821) **从 `fpga/timing.rpt` 出 top-N 关键路径 + 扇出榜**（物理优化前的首选测量工具，见 PITFALLS R47；fmax 口径已按最差路径自带的 `Requirement` 修正）·
`tools/pdf_text.py` / `tools/pdf_mine.py` **厂商 PDF 取文**（2405 页指南，`flash_logs/guide_text/`）

---

## 4. 文档（看这里而不是翻聊天记录）

> 括号里的行数是 **2026-10-11 快照**，文档被编辑后即失效 —— 需要精确值请现查
> （`[System.IO.File]::ReadAllLines($p).Count`）。

| 文件 | 内容 |
|---|---|
| `HANDOFF.md` (1204 @2026-10-11) | **总入口**：当前交付配置、四项指标、存储策略、上板结论、口径纪律、`check` 7 项检查门 |
| `HANDOFF-HW-LOOP.md` (329 @2026-10-11) | 上板闭环操作的逐步说明 |
| `HANDOFF-WORKFLOW.md` (312 @2026-10-11) | 工作流用法 |
| `tools/README.md` (250 @2026-10-11) | 统一工作流的逐子命令说明（含 `check` 7 项与综合警告门详解） |
| `results/*.md` (**26 篇**) | 每项工作的**完整实测记录**（含所有失败尝试与原因） |
| `results/coremark.csv` | 所有配置 × 四项指标的总表。⚠️ `fmax` 列的口径：**`fmax_src` 列尚待 `CODE-REVIEW-PLAN.md` M-04 落地**（现表头 12 列无此列）；在它落地前以该行 `notes` 为准。表头注释里 `1000/(20-wns_ns)` 是**旧口径**，已失效 |
| `results/style-audit.md` | 独立只读风格/一致性审查（P0=7 / P1=9 / P2=5），含 §4「已统一、不必动」清单 |
| `tools/flash_logs/REPORT.md` (212) | **QSPI Flash 固化**的完整报告（根因 / part 对照表 / 端到端命令 / 上电自举步骤）|
| `skills/fpga-riscv-a100t/PITFALLS.md` (**R1~R51**) | **51 条踩坑记录**（改代码前扫一眼能省很多时间）；最值钱的新条目：**R43**（MMCM 漏接 `.CLKFBIN` 会把整颗 CPU 永久按在复位里）、**R47**（top-N 是"一堵墙"时 RTL 逻辑重排期望 ≈ 0）、**R48**（陷阱只冲 ID/EX ⇒ 被抢占指令双执行）、**R49**（多周期状态机写相与算子无关 ⇒ LR.W 把目标字清零）、**R50**（换频只换抽头最安全；提频本身也会抬高 fmax）|

---

## 5. 交付指标（**2026-10-11 历史快照；当前交付档 150 MHz 见 README-ARTIX.md ②**）

| # | 项 | 值 | 来源 |
|---|---|---|---|
| ① | 时钟名 | **`sys_clk_core`**（频率无关命名）| `fpga/daVinciPro.xdc`（`-multiply_by 21 -divide_by 8`）|
| ② | 已上板验证档 | **105 MHz**（@9.524 ns），2026-10-11 **15:22:41** | `results/ila_done.capture.json` |
| ② | 该档上板实测 | `0xC2` / `0xD24B8AFE`（bit31=1）/ tick **1,380,682,494** / **13.15 s** / 硬件 CM/MHz **2.1728** | `results/ila_done.csv` + 采集清单 |
| ② | 该档综合 | fmax **106.30 MHz**（WNS **+0.117** @9.524 ns）；LUT **2706** / FF **1290** / BRAM 8 / DSP 8 | `results/coremark.csv` 行 `c14-105mhz` + `reports/20261011-151614-cm_hw/metrics.json` |
| ③ | **当前设计目标档** | **131.25 MHz**（@7.619 ns）—— **时序未收敛**（WNS **−0.963**、1141/4437 失败端点；`Timing constraints are not met.`）；工作区 LUT **2865** / FF **1393** / BRAM **9.5** | `fpga/timing.rpt` + `fpga/util.rpt` |
| — | 当前源码仿真 | ticks **453,942** ⇒ CoreMark/MHz **2.2029**（**未上板**）| `.fpga-cache/logs/tb_sw_coremark.log` |

> **fmax 口径纪律**：必须带**时钟名 + 周期 + 运行频率 + WNS**（`HANDOFF.md` §8）。
> 旧口径 `1000/(20−WNS)` 只在 MMCM 之前成立。⚠️ **运行频率与 fmax 不独立**（PITFALLS **R50**）。
> ⚠️ `results/coremark.csv` 的 `fmax` 列**暂无 `fmax_src` 列**（尚待 M-04）—— 别按旧文声称"必须配该列"。
> **上板凭据是采集清单**，不是 CSV 的 mtime（X-02）。
