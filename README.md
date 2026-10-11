# RV32IM 五级流水线处理器

SystemVerilog 实现的 **RV32IM** 处理器：**5 级流水线 (IF/ID/EX/MEM/WB)** —— 其中 IF/ID 由 IMEM 的输出寄存器承担，
含动态分支预测、完整 M-mode 异常/中断、冒险处理、非对齐访存 2 拍自动拆分。

```mermaid
graph LR
  IF[IF 取指] --> ID[ID 译码] --> EX[EX 执行] --> MEM[访存] --> WB[写回]
```
（mermaid 仅为示意；实际是 **5 级**，见 `core.sv` 与 `results/p8-ifid-elide.md`）

---

## 成绩速览（真实板卡实测）

> **口径（务必先读）**：本文把"验证"分成两级，**不要混为一谈** ——
> - **仿真通过** = ModelSim 回归 `python tools\fpga_workflow.py verify`，判据是 testbench 打印的
>   `RESULT : PASS`（当前 **PASS 11**）；
> - **上板验证** = 真实板卡 JTAG 烧录 + ILA 读回，判据是 **`fpga/cap_done.log` 里的
>   `CSV_MTIME=... AGE_SEC=0` + `CAPTURE_OK`**，以及 `results/ila_done.capture.json`（采集清单）。
>   ⚠️ **`results/ila_done.csv` 的 mtime 不是证据**（它是 git 跟踪文件，见下）。
>
> **最后一次成功的上板验证 = 2026-10-09 21:29:30**（判据：`cap_done.log` 内 `CSV_MTIME=2026-10-09 21:29:30
> AGE_SEC=0` + `CAPTURE_OK`）。
> ⚠️ **`results/ila_done.csv` 的 mtime 会被 git 操作刷新而不产生新采集**（X-02）—— **2026-10-11 10:51
> 实测就发生了**：CSV 内容逐字节未变，mtime 却成了"5 分钟前"，`check` 的 [HIL] 因此误报"刚上过板"。
> 唯一见证是 **`results/ila_done.capture.json`（采集清单，由 `ila_cap_done.tcl` 写出、被 .gitignore 忽略）**；
> 该文件现在**不存在** ⇒ **`hw` 会拒绝给结论**，直到重跑 `cmd /c fpga\ila_cap_done.bat`。
> 自那以后 RTL 又动过：`load_store_unit.sv` 与 `fpga/build.tcl`
> （`d6b48fe`，2026-10-11 00:50，LSU 读格式化字节通道 + Pblock/放置指令重定位）—— **尚未上板**；
> `core.sv` 截至那次上板停在 2026-10-08 23:18（`602129d`），但**当前工作区**里它正被本次审查改动
> （`CODE-REVIEW-PLAN.md` R-01/R-02/W-04），**这些改动同样未上板**。
> **"哪些改动未上板"必须现查**（`git status` / `git log` + `python tools\fpga_workflow.py hw --stale`），
> 不要读文档里的静态清单。
> 因此下文凡写"上板验证"的，**都指 2026-10-09 那次采集**；表格里的上板参数/实测数字的口径更正
> 见 `CODE-REVIEW-PLAN.md` **D-01/D-03**。
>
> 另：上表的三个评分指标里，**fmax 与 LUT 来自 Vivado 综合报告**（`fpga/timing.rpt` / `fpga/util.rpt`），
> **不是**上板测出来的；上板只提供 CoreMark 的 tick 与 CRC 佐证。**别把"综合实测"写成"上板实测"。**
>
> **fmax 口径**：上表那一行是**旧口径**（`1000/(20 − WNS)`，MMCM 之前）**已失效**。现在设计主时钟是
> **`sys_clk_70` @14.286 ns**，正确口径是 `1000/(该时钟周期 − 该路径 WNS)`，且**必须写出时钟名与周期**、
> 配 `results/coremark.csv` 的 **`fmax_src`** 列一起读。完整纪律见 `HANDOFF.md` §8「口径纪律」。
> 数字本身的换代等 RTL 冻结、重新综合后由 Lead 统一给出（见 `CODE-REVIEW-PLAN.md` D-01/D-02）。

**平台**：正点原子 达芬奇Pro（XC7A100T-FGG484-2，板载 50 MHz）
**赛题**：2026 紫光同创杯 · 选题一「基于紫光同创 RISC-V 指令集 CPU 设计」
**基准**：CoreMark v1.0（PERFORMANCE_RUN）

| 评分指标 | 基线 | **最终（交付配置实测）** | 变化 |
|---|---|---|---|
| **CoreMark/MHz** | 0.8263 | **2.4209** | **+193.0%** |
| **最高时钟频率 fmax** | 78.4 MHz | **69.8 MHz** | −11.0% |
| **CoreMark/LUTs** | 2.361e-4 | **9.139e-4** | **+287.1%** |
| 绝对吞吐 (CM/MHz × fmax) | 64.8 | **169.0** | **+160.8%** |

**资源**：LUT **2649** / FF **1234** / BRAM **8** / DSP 8（交付配置，不含 ILA）
**上板**：1300 迭代 / **10.74 s** @50 MHz / 与官方参考值 **逐位 CRC 匹配** /
`ila_ctrl=0x42`、CRC bit31=1、tick **536,943,384**、硬件 CoreMark/MHz **2.4211**
> ↑ 这一行是**历史口径**（2026-10-08 采集）。**最后一次采集是 2026-10-09 21:29**，
> 参数与上面不同 —— 以 `results/ila_done.csv` 现查为准，更正见 `CODE-REVIEW-PLAN.md` **D-03**。

> **绝对吞吐是本项目的核心结论**：+160.8% 表示同一块板每秒能跑 **2.61 倍**的
> CoreMark 迭代数。三项评分指标互相矛盾时，它是有意义的最终裁判。

**回归**（**仿真级**，判据来源 `python tools\fpga_workflow.py verify`）：**PASS 11**
（`tb_units` 的检查点数以**运行时打印**为准 + **10 组**系统级/软件级测试），无 XFAIL。

---

## 功能一览

| 项 | 状态 |
|---|---|
| RV32I + **M 扩展** + Zicsr + M-mode 异常/中断 | ✅ |
| 动态分支预测（64 项 BTB + 2 位 Smith，精度 **88.7%** 实测）| ✅ |
| 完整异常/中断（ECALL/EBREAK/非法指令/mtimecmp 定时器中断/MRET）| ✅ |
| 外设：UART 115200 8N1 收发 / GPIO / 64 位定时器 | ✅ |
| 应用场景：神经网络 GEMM 推理核心（与独立参考实现逐元素一致）| ✅ |
| RV32A 原子指令 | ✅ **已完成**（多周期"读-改-写"已打通，`tb_core_amo` PASS；`A_EN` 宏默认关 —— 对 CoreMark 三项零贡献）见 `results/p6-a-extension.md` §5.13 |
| AI 加速单元（GEMM） | ⚠ 机制已验证（42.59× 计算加速），因面积与正确性门控关闭 |
| I/D Cache | ⚖ 经分析判定无收益（存储器已是单周期命中的片上 BRAM）|

**详细的成绩、优化过程、失败记录与后续方向**见
[`results/analysis-report.md`](results/analysis-report.md)；
赛题逐项对照见 [`results/gap-analysis.md`](results/gap-analysis.md)。

---

## 文件一览

### 基础模块 (单周期与流水线共用)
| 文件 | 模块 | 说明 |
|---|---|---|
| `rv32_pkg.sv` | — | 编码包 (单一事实来源)：指令/ALU/分支/访存/写回编码、`ctrl_s` 控制束、地址映射、前递枚举、**RV32A 的 AMO 编码** |
| `alu.sv` | `alu` | RV32I 基础运算 + **RV32A 的 9 个 AMO 算符**（"待写回值"计算）|
| `branch_unit.sv` | `branch_unit` | 6 种分支判定，利用编码结构只做 3 个比较 |
| `control_unit.sv` | `control_unit` | RV32IM 全译码 + 三级合法性检查；非法指令严格无副作用；**OPC_AMO 译码由 `A_EN` 门控** |
| `imm_gen.sv` | `imm_gen` | I/S/B/U/J 五种立即数 |
| `pc.sv` | `pc` | PC 寄存器，带 `stall`/`flush` 钩子 |
| `regfile.sv` | `regfile` | 2R1W，x0 恒零，**组合读 + 写旁路**，调试读口 |
| `muldiv.sv` | `muldiv` | RV32M：乘法走 DSP，除法 32 步恢复余数法（多周期 `busy`）|
| `btb.sv` | `btb` | 64 项 BTB + 2 位 Smith 方向预测器 |
| `csr_file.sv` | `csr_file` | Zicsr + mstatus/mie/mip/mtvec/mepc/mcause/mtval/mscratch |
| `ras.sv` | `ras` | 8 项返回地址栈（`RAS_EN` 门控，默认关 —— 实测净亏）|
| `gemm_accel.sv` | `gemm_accel` | int8 GEMM 加速单元（`GEMM_EN` 门控，默认关 —— 实测面积翻倍）|

### 流水线模块
| 文件 | 模块 | 说明 |
|---|---|---|
| `imem.sv` / `dmem.sv` | — | 指令/数据存储器（**寄存读 → 行为级推断 BRAM**，各 16KB；dmem 带字节写使能）|
| `id_ex_reg.sv` / `ex_mem_reg.sv` / `mem_wb_reg.sv` | `*_reg` | **3 个**流水寄存器 (控制束整束传递，气泡 = 真实 NOP)。IF/ID 由 IMEM 的输出寄存器承担 ⇒ 连同它共 **4 个**流水寄存器 ⇒ **5 级**（`results/p8-ifid-elide.md`）|
| `hazard_unit.sv` | `hazard_unit` | 前递选择 + load-use 停顿 + 重定向门控 |
| `load_store_unit.sv` | `load_store_unit` | 字节通道 + **非对齐跨字访存 2 拍自动拆分** |
| `core.sv` | `core` | 五级流水线顶层 + 调试口 |
| `fpga/top_a100t.sv` 等 | — | 顶层 + MMIO 子系统（**唯一需要按厂商重写**的部分）|

### 验证
| 文件 | 说明 |
|---|---|
| `sim/tb_units.sv` | 基础模块单元回归（含**全部历史 bug 的定向回归** + RV32A 的 ALU/译码检查）|
| `sim/tb_core*.sv` / `tb_soc*.sv` / `tb_sw*.sv` | **10 组**系统级/软件级回归（连同 `tb_units` 共 **11 项**，全部 PASS）|
| `sim/prog/*.S`、`sw/*.c` | 测试程序与裸机 C 程序（CoreMark、神经网络 GEMM、编译器探针）|
| `tools/amo_vectors.py` | **RV32A 黄金向量生成器**（独立 Python 参考实现，108 条，双向交叉验证过）|
| `tools/fpga_workflow.py` | 统一工作流入口：`doctor`/`check`/`verify`/`synth`/`report`/`metrics`/`profile`/`hw` |
| `results/` | 成绩、逐轮优化记录、失败记录、赛题对照（22 篇 `.md` + 3 份 CSV）|
| `skills/fpga-riscv-a100t/PITFALLS.md` | 踩坑记录 **R1~R47**（**47** 条编号记录，症状优先）|
| `legacy/` | 最初的 Verilog 单周期代码 (历史留档) |

> **可移植性**：CPU 核**零厂商原语**（BRAM 全用行为级推断，不例化 IP），
> 迁到紫光同创 PDS 只需重写顶层与约束文件。

## 跑测试

**唯一可用入口是 ModelSim 统一工作流**（11 项全量回归）：

```bat
python tools\fpga_workflow.py verify            :: 增量回归 (基线 PASS 11)
python tools\fpga_workflow.py verify --force    :: 忽略缓存, 强制全量重跑
python tools\fpga_workflow.py verify --only tb_units tb_soc   :: 只跑指定项
```

单跑一项 / 抓波形：

```bat
cd sim
vsim -c -do "run -all; quit -f" work.tb_core +imem=prog/basic.hex +dump=wave.vcd
```

换程序：改 `basic.S` 后重新汇编即可（无需重编译 RTL）：

```bat
python tools\asm.py sim\prog\basic.S -o sim\prog\basic.hex
```

> ⚠️ **`sim\run.bat` / `sim\run.sh` 不是可用的测试入口**（`[已实测]` 2026-10-11）：
> 1. 它硬依赖 **iverilog**，而本机**没有** —— `%LOCALAPPDATA%\riscv-tools\mingw64` **不存在**
>    （`Test-Path` → False）、`Get-Command iverilog` → **NOT FOUND**；
> 2. 即使装上 iverilog，它也**只编译并跑 2 个测试**（`tb_units` + `tb_core` + `basic.hex`），
>    却打印 `=== ALL TESTS PASSED ===` —— 照它走只能拿到 **2/11 的覆盖 + 绿灯**；
> 3. 它的 `if not exist prog\basic.hex` 守卫**判"存在"不判"新鲜"** —— 汇编失败时会静默拿上一次的
>    hex 去测（PITFALLS R1 的形态）。
>
> 因此这两个脚本现在只作**历史留档**；修法（转调 `fpga_workflow.py verify`）已登记为
> `CODE-REVIEW-PLAN.md` **W-05/W-06**，**尚未修复**。
> **`run.bat` 必须保持纯 ASCII**：cmd 用 OEM 代码页解析批处理，UTF-8 中文注释会导致解析错误。

## 流水线架构

```
 IF          ID              EX                MEM                WB
─────    ──────────    ──────────────    ──────────────    ──────────
 PC  ──►  译码/立即数 ──►  前递mux/ALU  ──►  访存单元   ──►  写回mux
 IMEM      Regfile读      分支判定          DMEM             Regfile写
                           跳转目标计算      非对齐拆分
```

**关键设计点**

1. **跳转目标复用 ALU**：`BR/JAL` 用 `a=PC`、`JALR` 用 `a=rs1`，`b=imm`，
   ALU 兼作目标加法器 → 省一个 32 位加法器。JALR 目标清最低位 (规范要求)。
2. **分支在 EX 判定** → 重定向冲刷 IF/ID 与 ID/EX (2 周期惩罚)。
3. **前递**：EX/MEM 与 MEM/WB 两级前递到 EX；load 不在 EX/MEM 段前递
   (那时只有地址没有数据)，由 load-use 停顿保证。
4. **寄存器堆写旁路**：覆盖"距离 3"的 RAW (WB 写与 ID 读同拍)。
   距离 1/2 由前递解决，距离 3 必须靠写旁路 —— 光靠 NBA 不够，因为
   ID/EX 的读数据在时钟沿前就被锁存了。
5. **停顿与重定向互斥**：重定向信号被停顿门控。冻结期间 EX 中的指令可能
   因操作数未就绪算出错误判定，下一拍重算后再生效。
6. **非法指令**：控制束已中性化为无副作用 (`reg_write/mem_read/mem_write=0`,
   `pc_sel=PC_NEXT`)，顶层置粘滞标志 `dbg_illegal` 供 TB 断言。
   trap 阶段替换为跳异常入口。

## 非对齐访存 (硬件自动拆分)

采用**统一移位法**：头字与尾字拼成 64 位后按字节偏移整体移位，
一套逻辑覆盖全部对齐/非对齐情况：

```
load : raw = {tail_word, head_word} >> (8*addr[1:0])   再按 size/符号扩展
store: shifted = {32'b0, rs2} << (8*addr[1:0]), 写使能为掩码移位到两个字
```

**何时需要两拍**：仅当 `off + size_bytes > 4` (跨 4 字节边界)：
- 字节访问：永不跨字 (零开销)
- 字内非对齐半字 (`off=1`)：不跨字，零额外开销
- 跨字访问：第 1 拍读/写头字并冻结流水线，第 2 拍读/写尾字并当拍合并
  → 总代价 1 个停顿周期

## 已知取舍与后续路线

> 本节原先写的是单周期时代的计划（"M 扩展译码待做 / CSR,trap 待实现 / 存储器待改 BRAM"）——
> **那三项早已全部落地**。下面是**当前真实的**取舍与剩余方向。

- **默认关闭的四个宏**（都留了实测数据与复现开关，不要重复试）：
  `A_EN`（RV32A：功能已完成，但对 CoreMark 三项零贡献）、
  `GEMM_EN`（面积翻倍 + C 读回未修完）、`RAS_EN` 与 `BTB_GSHARE`（实测净亏）。
- **Cache（2 路组相联 + 总线突发）**：**分析判定架构性无收益**，不实现 ——
  `imem`/`dmem` 都已是单周期命中的片上 BRAM，没有它要掩盖的存储器延迟。
  定量依据见 `results/p7-cache-analysis.md`。
- **fmax 剩余空间**：当前 **69.8 MHz**（基线 78.4，−11.0%）；关键路径 route 占比高，
  纯改 RTL 收益有限。
- **`LOAD_RESULT_REG`**：实测更差，已否决（`results/p4-macro-failure.md` 5.2）。
- **唯一未完成项**：GEMM 加速单元的 C 读回 + 缓冲改 BRAM（不计入成绩）。
- **设计坑记录** (都踩过并已修复，代码注释里有详细说明)：
  1. `logic x = expr;` 是**声明式初始化**，只在 0 时刻求值一次，
     不是连续赋值 —— 多处曾因此产生恒 X 信号。全部改为显式 `assign`。
  2. **连续赋值调用函数**时，若函数体引用模块级信号，部分仿真器
     (实测 iverilog) 只把实参计入敏感列表 → 前递结果变陈旧值。
     `hazard_unit` 已改为显式组合逻辑。
  3. 枚举类型的三目运算在 iverilog 需显式转换，改用 `always_comb` + if/else。
