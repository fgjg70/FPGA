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
core.sv:160-263       ← IF 段:  pc -> imem (其输出寄存器直接充当 IF/ID)
core.sv:416-503       ← ID 段:  imem_rdata -> regfile/译码 -> id_ex
core.sv:504-641       ← EX 段:  id_ex -> ALU/分支/乘除 -> ex_mem
core.sv:757-926       ← MEM 段: ex_mem -> dmem/LSU/MMIO -> mem_wb
core.sv:927-978       ← WB 段:  mem_wb -> wb_data mux -> regfile 写口
```

**这一遍要能回答**：`id_ex` / `ex_mem` / `mem_wb` 三个寄存器各自
携带哪些字段？它们分别由哪个模块例化？（仍是 **5 级**：IF/ID 由 IMEM 的输出寄存器承担 —— 注意口径是
“**4 个流水寄存器 ⇒ 5 级**”，别差一。见 `results/p8-ifid-elide.md`）

### 第 2 遍：控制（约 1 小时）—— 谁在控制这条流水线

```
control_unit.sv       ← 译码器: 产生 ctrl_s (EX/MEM/WB 三段控制束) + pc_sel + wb_src
hazard_unit.sv        ← 前递选择 fwd_a/fwd_b + load-use 停顿 + 重定向门控
core.sv:586-641       ← 分支/跳转目标 + 预测校验 (actual_taken / pred_ok)
core.sv:642-711       ← 陷阱判定 + 重定向仲裁 (pc_src / pc_target)
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

## 2. 核心 RTL 清单（20 个文件，3849 行）

| 文件 | 行 | 角色 | 阅读要点 |
|---|---:|---|---|
| `rv32_pkg.sv` | 408 | **全局包**：类型 / 枚举 / 参数 / 接线契约 | `ctrl_s` 控制束；`pc_sel_e` / `wb_src_e` / `fwd_sel_e` / `sys_op_e`；存储器基址。**第一份该读的** |
| `pc.sv` | 50 | PC 寄存器 | 优先级 **flush > stall > pc_src**；`pc_plus4` |
| `imem.sv` | 83 | 指令存储器 | **默认寄存读（→ BRAM）**；定义 `IMEM_COMB_READ` 才回退成 LUT ROM |
| `control_unit.sv` | 372 | **主译码器** | 输出三段控制束；覆盖 RV32IM_Zicsr + RV32A |
| `imm_gen.sv` | 49 | 立即数生成 | I/S/B/U/J 五种 |
| `regfile.sv` | 67 | 32×32 寄存器堆 | 同拍写读的**写优先旁路** |
| `id_ex_reg.sv` | 94 | ID/EX 流水寄存器 | |
| `alu.sv` | 105 | ALU | |
| `branch_unit.sv` | 43 | 分支条件判定 | `taken` 由 BR_EQ/NE/LT/GE 决定 |
| `load_store_unit.sv` | **314** | **访存单元（最复杂）** | ① 非对齐访存硬件拆分（HEAD/TAIL FSM）② AMO 三相位 ③ 字节提取+符号扩展 ④ WB 影子寄存器 |
| `muldiv.sv` | 215 | RV32M 乘除 | 多周期，`busy` 期间冻结流水线 |
| `csr_file.sv` | 205 | **CSR + 陷阱** | `mtvec`→`trap_vector`、`mepc`→`mret_pc`、mcause / mtval / mstatus、trap 入口与 mret |
| `btb.sv` | 191 | BTB + 方向预测 | **命中要求 `vld && tag`**（这条不变量在 fmax 实验里被用作论证依据）；Smith 2 位默认，`BTB_GSHARE` 可选；`is_ret` 给 RAS |
| `ras.sv` | 87 | 返回地址栈 | |
| `gemm_accel.sv` | 240 | GEMM 加速器 | 自选题部分 |
| `hazard_unit.sv` | 115 | **冒险/前递** | `fwd_a/fwd_b` 选择；`pipe_stall` / `id_ex_bubble` / `hold_mem` / `redirect` |
| `ex_mem_reg.sv` | 48 | EX/MEM 流水寄存器 | |
| `mem_wb_reg.sv` | 49 | MEM/WB 流水寄存器 | |
| `dmem.sv` | 76 | 数据存储器 | 字节使能写 + 寄存读（→ RAMB36） |
| **`core.sv`** | **1038** | **顶层 CPU** | 例化全部 + 下一拍 PC + 预测校验 + 重定向 + 陷阱整合 + MMIO |

> 行数是 **2026-10-08** 实测（`[System.IO.File]::ReadAllLines(...).Length`），
> 含大量注释 —— 本工程把口径、取舍与踩过的坑都写在代码注释里，所以行数偏高。

### `core.sv` 章节地图（1038 行，按行号跳读）

| 行 | 章节 | 里面有什么 |
|---|---|---|
| 61-119 | 信号声明 | 集中声明，避免隐式线网 |
| 120-159 | Zicsr / 陷阱信号 | `exc_req` / `trap_enter` / `mret_taken` … |
| **160-263** | **IF 段** | `u_pc` 例化(190)、`u_imem`(242)、**`pc_next` (233)**、`imem_addr = pc_next`(239)、历史记录(250-263) |
| 265-293 | 分支预测（IF 预测） | `u_btb` 例化(275)、`pred_taken` / `pred_target` |
| 294-362 | 返回地址栈（`RAS_EN`，默认关） | `u_ras` |
| 363-415 | **去掉冗余 `if_id_reg` 的说明**（issue #5） | IF/ID 落在 IMEM 输出寄存器上；两个坑（组合环 / `if_id_flush` 串进 ID 路径）|
| **416-503** | **ID 段** | regfile(459) / control_unit / imm_gen / ID 门控(`id_en`) |
| **504-641** | **EX 段** | **前递 mux(517)**、AMO 地址加法器(524-541)、ALU(545)、乘除(561)、跳转目标独立加法器(586)、**`actual_taken`(608)**、`pred_ok`(635) |
| 642-711 | CSR / 陷阱 / 重定向 | `u_csr`(650)、`trap_enter` 判定(685)、**`pc_src`/`pc_target`(705-710)** |
| **712-737** | **冒险单元** | `u_hazard` 例化(715) |
| 738-756 | EX/MEM | `u_ex_mem`(741) |
| **757-926** | **MEM 段** | LSU 例化、AMO 新值(785-808)、MMIO 地址译码(886-891)、`u_dmem`(918) |
| **927-978** | **MEM/WB 与 WB 段** | `u_mem_wb`(930)、**`wb_data` mux(965-972)** |
| 979-1030 | 调试与仿真专用 | `dbg_pc`/`dbg_instr` 同级口径(981)、`dbg_illegal`(1009) |
| 1031-1038 | 流水线效率观测 | 纯观测信号，不参与逻辑 |

> ⚠️ 行号按 **2026-10-08**（删掉冗余 `if_id_reg` + 死代码清理之后）的 `core.sv` 实测；
> 改过 RTL 后再看本表，请先按 `// ====` 分节注释重新对一遍章节边界。

---

## 3. 工具链（`tools/` + `fpga/`）

### 一站式入口：`tools/fpga_workflow.py`（2114 行）

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
| `fpga/build.tcl` (215) | **非工程模式**综合流程：`synth → opt → Pblock → place → phys_opt → route → bitstream`；宏开关集中在文件头 |
| `fpga/daVinciPro.xdc` (25) | 引脚 + **`create_clock -period 20.000`**（"20 ns 周期"的来源） |
| `fpga/build_ila.tcl` + `ila_cap_*.tcl` | 上板 ILA 调试闭环（`jtag_probe` / `build_ila` / `ila_cap_done`） |

> ⚠️ **踩坑 R33**：ILA 构建失败后**必须删掉 `fpga/ila_proj*`** 才能重建成功（出现过两次）。

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
`tools/trace_diff.py`(152) **逐拍轨迹比对（找 RTL 改动的第一处分歧）**

---

## 4. 文档（看这里而不是翻聊天记录）

| 文件 | 内容 |
|---|---|
| `HANDOFF.md` (975) | **总入口**：当前交付配置、四项指标、存储策略、上板结论 |
| `HANDOFF-HW-LOOP.md` (269) | 上板闭环操作的逐步说明 |
| `HANDOFF-WORKFLOW.md` (280) | 工作流用法 |
| `results/*.md` (22 篇) | 每项工作的**完整实测记录**（含所有失败尝试与原因） |
| `results/coremark.csv` | 所有配置 × 四项指标的总表 |
| `skills/fpga-riscv-a100t/PITFALLS.md` | **R1~R35 踩坑记录**（改代码前扫一眼能省很多时间） |

---

## 5. 当前交付指标（一句话基线）

| 指标 | 值 |
|---|---|
| CoreMark/MHz | **2.4209**（仿真 ticks 413,070） |
| fmax | **69.8 MHz**（WNS 5.673 @20ns，由 `1000/(20−WNS)` 推得） |
| LUT / FF / BRAM / DSP | **2649 / 1234 / 8 / 8** |
| CoreMark/LUTs | **9.139e-4** |
| 绝对吞吐 | **169.0**（= CM/MHz × fmax） |
| 上板 | `ila_ctrl=0x42`、CRC bit31=1、tick **536,943,384**、**10.74 s** @50 MHz（1300 迭代）、硬件 CM/MHz **2.4211** |
