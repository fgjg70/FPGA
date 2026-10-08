# CODE-MAP.md — 代码地图与阅读路线

> 本文件是**读代码的向导**（不是设计文档）。目标：让你用最短时间建立起
> 「一条指令从 PC 到写回，中间经过哪些模块、被哪些控制信号驱动」的完整心智模型。
> 细节（每一位怎么算）可以后看；先用它把**骨架**搭起来。

---

## 0. 一句话

一个 **RV32IM_Zicsr + RV32A、M-mode、四级顺序单发射流水线** CPU，
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
core.sv:156-253       ← IF 段:  pc -> imem (其输出寄存器直接充当 IF/ID)
core.sv:372-433       ← ID 段:  imem_rdata -> regfile/译码 -> id_ex
core.sv:435-482       ← EX 段:  id_ex -> ALU/分支 -> ex_mem
core.sv:689-859       ← MEM 段: ex_mem -> dmem/LSU -> mem_wb
core.sv:860-886       ← WB 段:  mem_wb -> regfile 写口
```

**这一遍要能回答**：`id_ex` / `ex_mem` / `mem_wb` 三个寄存器各自
携带哪些字段？它们分别由哪个模块例化？（本核是 **4 级**：IMEM 的输出寄存器就是 IF/ID，
见 `results/p8-4stage-pipeline.md`）

### 第 2 遍：控制（约 1 小时）—— 谁在控制这条流水线

```
control_unit.sv       ← 译码器: 产生 ctrl_s (EX/MEM/WB 三段控制束) + pc_sel + wb_src
hazard_unit.sv        ← 前递选择 fwd_a/fwd_b + load-use 停顿 + 重定向门控
core.sv:517-572       ← 分支/跳转目标 + 预测校验 (actual_taken / pred_ok)
core.sv:573-642       ← 陷阱判定 + 重定向仲裁 (pc_src / pc_target)
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

## 2. 核心 RTL 清单（21 个文件，约 3200 行）

| 文件 | 行 | 角色 | 阅读要点 |
|---|---:|---|---|
| `rv32_pkg.sv` | 279 | **全局包**：类型 / 枚举 / 参数 / 接线契约 | `ctrl_s` 控制束；`pc_sel_e` / `wb_src_e` / `fwd_sel_e` / `sys_op_e`；存储器基址。**第一份该读的** |
| `pc.sv` | 37 | PC 寄存器 | 优先级 **flush > stall > pc_src**；`pc_plus4` |
| `imem.sv` | 61 | 指令存储器 | **默认寄存读（→ BRAM）**；定义 `IMEM_COMB_READ` 才回退成 LUT ROM |
| `control_unit.sv` | 322 | **主译码器** | 输出三段控制束；覆盖 RV32IM_Zicsr + RV32A |
| `imm_gen.sv` | 40 | 立即数生成 | I/S/B/U/J 五种 |
| `regfile.sv` | 57 | 32×32 寄存器堆 | 同拍写读的**写优先旁路** |
| `id_ex_reg.sv` | 88 | ID/EX 流水寄存器 | |
| `alu.sv` | 83 | ALU | |
| `branch_unit.sv` | 35 | 分支条件判定 | `taken` 由 BR_EQ/NE/LT/GE 决定 |
| `load_store_unit.sv` | **286** | **访存单元（最复杂）** | ① 非对齐访存硬件拆分（HEAD/TAIL FSM）② AMO 三相位 ③ 字节提取+符号扩展 ④ WB 影子寄存器 |
| `muldiv.sv` | 155 | RV32M 乘除 | 多周期，`busy` 期间冻结流水线 |
| `csr_file.sv` | 171 | **CSR + 陷阱** | `mtvec`→`trap_vector`、`mepc`→`mret_pc`、mcause / mtval / mstatus、trap 入口与 mret |
| `btb.sv` | 144 | BTB + 方向预测 | **命中要求 `vld && tag`**（这条不变量在 fmax 实验里被用作论证依据）；Smith 2 位默认，`BTB_GSHARE` 可选；`is_ret` 给 RAS |
| `ras.sv` | 63 | 返回地址栈 | |
| `gemm_accel.sv` | 222 | GEMM 加速器 | 自选题部分 |
| `hazard_unit.sv` | 101 | **冒险/前递** | `fwd_a/fwd_b` 选择；`pipe_stall` / `id_ex_bubble` / `hold_mem` / `redirect` |
| `ex_mem_reg.sv` | 38 | EX/MEM 流水寄存器 | |
| `mem_wb_reg.sv` | 39 | MEM/WB 流水寄存器 | |
| `dmem.sv` | 57 | 数据存储器 | 字节使能写 + 寄存读（→ RAMB36） |
| **`core.sv`** | **886** | **顶层 CPU** | 例化全部 + 下一拍 PC + 预测校验 + 重定向 + 陷阱整合 + MMIO |

### `core.sv` 章节地图（886 行，按行号跳读）

| 行 | 章节 | 里面有什么 |
|---|---|---|
| 61-113 | 信号声明 | 集中声明，避免隐式线网 |
| 115-153 | Zicsr / 陷阱信号 | `exc_req` / `trap_enter` / `mret_taken` … |
| **156-253** | **IF 段** | `u_pc` 例化(179)、imem 接口、**`pc_next` (222)** |
| 255-282 | 分支预测（IF 预测 / EX 校验） | BTB 例化、`pred_taken` / `pred_target` |
| **372-433** | **ID 段** | regfile / control_unit / imm_gen / ID 门控(`id_en`) |
| **435-482** | **EX 段** | ALU、**前递 mux (445)** |
| 483-516 | RV32M 乘除单元 | |
| 517-537 | 跳转/分支目标独立加法器 | 历史遗留：为 fmax 单独拉的加法器 |
| 538-572 | **控制流真实结果 + 预测校验** | `actual_taken`(553)、`pred_ok`(566) |
| 573-642 | CSR / 陷阱 / 重定向 | `trap_enter` 判定(616)、**`pc_src`/`pc_target`(636-641)** |
| **644-688** | **冒险单元** | `u_hazard` 例化(646) |
| **689-859** | **MEM 段** | LSU 例化、MMIO 选择、`u_dmem`(852) |
| **860-886** | **MEM/WB 与 WB 段** | `u_mem_wb`(864)、**`wb_data` mux** |

---

## 3. 工具链（`tools/` + `fpga/`）

### 一站式入口：`tools/fpga_workflow.py`（1870 行）

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
| `fpga/build.tcl` (188) | **非工程模式**综合流程：`synth → opt → Pblock → place → phys_opt → route → bitstream`；宏开关集中在文件头 |
| `fpga/daVinciPro.xdc` (17) | 引脚 + **`create_clock -period 20.000`**（"20 ns 周期"的来源） |
| `fpga/build_ila.tcl` + `ila_cap_*.tcl` | 上板 ILA 调试闭环（`jtag_probe` / `build_ila` / `ila_cap_done`） |

> ⚠️ **踩坑 R33**：ILA 构建失败后**必须删掉 `fpga/ila_proj*`** 才能重建成功（出现过两次）。

### 仿真

| 文件 | 作用 |
|---|---|
| `sim/tb_units.sv` (503) | 单元测试（ALU/前递/冒险/CSR…） |
| `sim/tb_core.sv` (148) | 定向汇编程序；`+illegal_trace` 打**逐拍轨迹** |
| `sim/tb_soc.sv` (228) | SoC 级（定时器/中断/MMIO） |
| `sim/tb_sw.sv` (333) | 跑完整软件（hello / CoreMark / NN）；输出**停顿构成剖析** |

### 辅助脚本

`tools/asm.py`(279) 汇编器 · `tools/elf2hex.py`(73) · `tools/build_sw.py`(119) ·
`tools/run_coremark.py`(109) · `tools/amo_vectors.py`(102) ·
`tools/trace_diff.py`(125) **逐拍轨迹比对（找 RTL 改动的第一处分歧）**

---

## 4. 文档（看这里而不是翻聊天记录）

| 文件 | 内容 |
|---|---|
| `HANDOFF.md` (611) | **总入口**：当前交付配置、四项指标、存储策略、上板结论 |
| `HANDOFF-HW-LOOP.md` (186) | 上板闭环操作的逐步说明 |
| `HANDOFF-WORKFLOW.md` (202) | 工作流用法 |
| `results/*.md` (21 篇) | 每项工作的**完整实测记录**（含所有失败尝试与原因） |
| `results/coremark.csv` | 所有配置 × 四项指标的总表 |
| `skills/fpga-riscv-a100t/PITFALLS.md` | **37 条踩坑记录**（改代码前扫一眼能省很多时间） |

---

## 5. 当前交付指标（一句话基线）

| 指标 | 值 |
|---|---|
| CoreMark/MHz | **2.3611**（ticks 423,527） |
| fmax | **69.2 MHz**（WNS 5.543 @20ns） |
| LUT / FF / BRAM / DSP | **2820 / 1345 / 8 / 8** |
| CoreMark/LUTs | **8.373e-4** |
| 绝对吞吐 | **163.3**（= CM/MHz × fmax） |
| 上板 | `ila_ctrl=0x42`、CRC bit31=1、tick 508,155,404、10.16 s @50 MHz |
