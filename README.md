# RV32IM 五级流水线处理器

PG2L100H视觉工程入口见 [fpga_pg2l100h/vision/README.md](fpga_pg2l100h/vision/README.md)。活动RTL为Verilog-2005，CPU、指令存储和数据存储目标125 MHz，NPU、摄像头采集及MMIO为50 MHz；摄像头接J7，AN430 LCD接J11。

该版本已通过原生布局布线和时序检查，并成功下载到FPGA RAM；配置状态中的PLL锁定标志仍为0，板上时钟启动和应用运行待确认。最新记录见 [BOARD_VALIDATION.md](fpga_pg2l100h/vision/BOARD_VALIDATION.md)。北方一到十手势尚待实拍训练，COCO80模型尚未部署，功能边界见 [MODES.md](fpga_pg2l100h/vision/MODES.md)。

之前的CPU/NPU均为50 MHz的源码基线保存在 [releases/cpu50mhz](releases/cpu50mhz/README.md)，来自2026-11-02 20:22的完整备份，包含独立构建入口、模型和历史验证记录。

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
>   `RESULT : PASS`（当前 **PASS 12**；12 项矩阵见 `tools/fpga_workflow.py` 的 `test_matrix()`）；
> - **上板验证** = 真实板卡 JTAG 烧录 + ILA 读回，判据是 **采集清单 `results/ila_done.capture.json`**
>   （`captured_at_local` / `csv_sha256` / `rtl_sha256` + 文件数 / `iterations` / `clk_hz` / `expect_tick`）
>   与 `fpga/cap_done.log` 的 `CAPTURE_OK`。
>   ⚠️ **`results/ila_done.csv` 的 mtime 不是证据**（X-02）；结论一律以采集清单为准。

**当前口径（三件事必须一起写，否则会误导下一手）**

| # | 项 | 值 | 来源（可复核） |
|---|---|---|---|
| ① | **时钟名** | **`sys_clk_core`** —— **频率无关命名**（名字里带频率会每改一次档就过期一次） | `fpga/daVinciPro.xdc`：`create_generated_clock -name sys_clk_core -multiply_by 21 -divide_by 7` |
| ② | **已上板验证档** | **150 MHz**（`sys_clk_core` @6.667 ns），**2026-10-17 从 QSPI FLASH 自启动**（断电重启即运行，无需 JTAG） | `results/uart_flash_boot_final.txt`（入库原始输出）+ `results/flash_done.txt` |
| ② | 该档上板实测 | tick **2,128,330,453**、**14 s**、**CoreMark 规范分数 324.19**（固件 `[portme] score=324.19 spec` 行）、硬件 CoreMark/MHz **2.1613**、`Correct operation validated`（CRC 全对）。注：核心打印的 `Iterations/Sec 328` 是整数秒截断值，**不作为宣称分数**（成因见 `results/CHANGELOG.md` §13.4） | `results/uart_flash_boot_final.txt`（FLASH 断电重启自启动原始输出）+ `results/uart_scoreprint.txt`（JTAG 通道输出） |
| ② | 该档综合 | fmax **150.2 MHz**（WNS **+0.007** @6.667 ns，压线但 MET，**0 Critical Warning**）；LUT **3098** / FF **1447** / BRAM **9** / DSP **8** | `results/coremark.csv` 行 `legal150-*` |
| ③ | **当前设计目标档** | **150 MHz 已达成**（无未收敛目标）。构建配置：`--no-lc` + `--fanout_limit 128` + `--pblock-range off` + `--contain-routing` + `--place-directive AltSpreadLogic_high`（**合法，0 Critical Warning**） | `results/NEXT-BURN.md` §1 + `results/coremark.csv` 行 `deliv150-final` |
| — | **当前源码仿真**（C-12c 操作数寄存 + 候选 E′） | ticks **463,366** ⇒ CoreMark/MHz **2.1581**（**已上板**，即上面 ② 那一版） | `.fpga-cache/logs/tb_sw_coremark.default.log` |

> ⚠️ **上板的那一版比当前源码早**：15:22 的采集清单覆盖 **22** 个 `.sv`，而当前树是 **23** 个
> （`bht.sv` 由 `028ca4d` 在 **15:55** 引入）—— 所以"硬件 CM/MHz 2.1728"是 C-1 之前的数，
> 与当前源码仿真的 **2.2029** 不同。**别把两者当成同一个配置**（这正是 X-03 要防的事）。
>
> **fmax 的来源怎么读（`fmax_src` 列尚待 M-04 落地）**：本文/其他文档此前要求"引用 `coremark.csv`
> 的 `fmax` 列必须配 `fmax_src` 列" —— **该列目前并不存在**（表头 12 列无此列，`tools/`+`coremark.csv`
> 全仓 0 命中）。现状是：**该列尚待 `CODE-REVIEW-PLAN.md` M-04 落地**。在它落地之前，
> `fmax_mhz` 的来源以该行 `notes` 为准（人工修正的行会在备注里写明 "the fmax cell is hand-corrected"；
> 其余行由 `fpga_workflow.py` 按**最差 setup 路径块自带的 `Requirement`** 算出）。
> ⚠️ `coremark.csv` 第 2 行那句 `fmax_mhz = 1000 / (20 - wns_ns)` 是**旧口径**（MMCM 之前），
> 已在 `HANDOFF.md` §8 被列为失效写法 —— 读到它请忽略，按上面的"最差路径块"口径理解。

| 评分指标 | 基线 | **最新档（150 MHz，FLASH 自启动）** | 变化 |
|---|---|---|---|
| **CoreMark/MHz** | 0.8263 | **2.1613**（硬件实测） | **+161.6%** |
| **最高时钟频率 fmax** | 78.4 MHz | **150.0 MHz**（WNS +0.007 @6.667 ns） | **+91.3%** |
| **CoreMark/LUTs** | 2.361e-4 | **6.926e-04**（派生） | — |
| 绝对吞吐 (CM/MHz × fmax) | 64.8 | **324.1**（派生） | **+400.2%** |

> 两个"派生"格按项目公式算：`CoreMark/LUTs = CM/MHz ÷ LUT`、`绝对吞吐 = CM/MHz × fmax`
> （用本档的 2.1613 / 3098 / 150.2）。**基线的 78.4 MHz 是在 20 ns 约束下测的**，
> 与现在的 `sys_clk_core` 不是同一口径 —— 跨约束直接比大小会被 R50 那条坑绊到，记结论时要说清约束。

**资源**：LUT **3098** / FF **1447** / BRAM **9** / DSP **8**（**合法 150 MHz 档**；`results/coremark.csv` 行 `legal150-*`）
**设计时钟**：`sys_clk_core` @ **150 MHz** —— MMCM `CLKFBOUT_MULT_F=21 / DIVCLK_DIVIDE=1 / CLKOUT0_DIVIDE_F=7`
（VCO 1050 MHz）；XDC 用 `-multiply_by 21 -divide_by 7` 建生成时钟。换档必须三处同源（见 `results/NEXT-BURN.md`）
**上板**（**2026-10-17，QSPI FLASH 断电重启自启动**，无 JTAG 介入）：**4600 迭代** / **14 s** @150 MHz / 与官方参考值 **逐位 CRC 匹配** /
`[portme] rate gate: clk=150000000 Hz` + `[portme] score=324.19 spec`、`Correct operation validated`、
tick **2,128,330,453**（与 JTAG 烧写那次**逐位相同**）、硬件 CoreMark/MHz **2.1613**、**规范分数 324.19**

> **两条必须一起读的诚实口径**：
> 1. **fmax 一路从文档旧值 69.8 → 106.30 不是"一轮优化"**，它是三件事叠加：
>    ① **口径更正**（旧值用的是 MMCM 之前已失效的 `1000/(20−WNS)`）→ 74.4；
>    ② **提频 70 → 75 MHz** → 76.2（收紧约束本身也让工具更卖力，见 PITFALLS **R50**）；
>    ③ **C-1 两级流水 gshare + 逐档提频 95/105/128.125/138.75/150 MHz** → **150.2**。
>    **fmax 与"运行频率"不是独立评分项**，所以每写一个 fmax 都要带上"哪条时钟、周期、运行频率、WNS"。
> 2. **为正确性付出的面积**：修 R-01/R48（中断精确性两处架构缺陷）与 R-02（mtval 合规）使
>    LUT/FF 上升；此后 C-1（预测器两级流水）又换了面积与 IPC —— 逐档代价见 `results/coremark.csv`
>    各行 `notes` 与 `results/p4-c1-2stage-gshare.md`。

> **绝对吞吐是本项目的核心结论**：三项指标互相矛盾时，它是有意义的最终裁判
> （新口径下约 **231**，见上表；口径来源写在同一行里）。

**回归**（**仿真级**，判据来源 `python tools\fpga_workflow.py verify`）：**PASS 12**
（`tb_units` 的检查点数以**运行时打印**为准 + **11 组**系统级/软件级测试，含新增
`tb_sw_lu_bench` —— load-use 代价标定：距离 1 = 2 拍 / 距离 2 = 1 拍 + checksum），无 XFAIL。

**平台**：正点原子 达芬奇Pro（XC7A100T-FGG484-2，板载 50 MHz 晶振 → MMCM → `sys_clk_core`）
**赛题**：2026 紫光同创杯 · 选题一「基于紫光同创 RISC-V 指令集 CPU 设计」
**基准**：CoreMark v1.0（PERFORMANCE_RUN）

---

## 功能一览

| 项 | 状态 |
|---|---|
| RV32I + **M 扩展** + Zicsr + M-mode 异常/中断 | ✅ |
| 动态分支预测（**512 项两级流水 BTB + 8192 项 PHT/gshare**，C-1）| ✅ |
| 完整异常/中断（ECALL/EBREAK/非法指令/mtimecmp 定时器中断/MRET）| ✅ |
| 外设：UART 115200 8N1 收发（`BAUD_DIV = CLK_HZ ÷ 115200` 整数除，**随档位变**：105 MHz→911⇒115,258 baud/+0.05%；131.25 MHz→1139⇒115,233/+0.028%；150 MHz→1302⇒115,207 baud/−0.006%）/ GPIO / 64 位定时器 | ✅ |
| 应用场景：神经网络 GEMM 推理核心（与独立参考实现逐元素一致）| ✅ |
| RV32A 原子指令 | ✅ **9 个 AMO + LR.W 完整；SC.W 按规范允许恒失败（rd=1，不写内存）—— 无预约寄存器。** `A_EN` 宏默认关（对 CoreMark 三项零贡献）；见 `results/p6-a-extension.md` §5.13、PITFALLS **R49** |
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
| `btb.sv` | `btb` | **512 项两级流水 BTB**（C-1 重写）；预测口来自寄存器，内部例化下面的 `bht`（`u_bht`）|
| `bht.sv` | `bht` | **方向预测表 PHT：8192 项 × 2 位饱和计数器**（C-1 两级流水 gshare，1 块 RAMB18）；索引 `PC[13:1] ^ (GHR & mask)`；由 `btb.sv` 例化 |
| `csr_file.sv` | `csr_file` | Zicsr + mstatus/mie/mip/mtvec/mepc/mcause/mtval/mscratch |
| `ras.sv` | `ras` | 8 项返回地址栈（`RAS_EN` 门控，默认关）。⚠️ 当年以"栈顶 mux 落在 `pc_target` 路径上"否掉它，而 **C-1 之后该理由很可能已失效**：实测 `--ras` ticks 453,942 → **452,288**（JALR 误判 3,650 → 2,796），**需重测 fmax**（`synth --ras` 已支持），见 `results/p4-c1-2stage-gshare.md` |
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
| `sim/tb_core*.sv` / `tb_soc*.sv` / `tb_sw*.sv` | **11 组**系统级/软件级回归（连同 `tb_units` 共 **12 项**，全部 PASS；矩阵见 `tools/fpga_workflow.py` 的 `test_matrix()`）|
| `sim/prog/*.S`、`sw/*.c` | 测试程序与裸机 C 程序（CoreMark、神经网络 GEMM、编译器探针）|
| `tools/amo_vectors.py` | **RV32A 黄金向量生成器**（独立 Python 参考实现，108 条，双向交叉验证过）|
| `tools/fpga_workflow.py` | 统一工作流入口：`doctor`/`check`/`verify`/`synth`/`report`/`metrics`/`profile`/`hw` |
| `results/` | 成绩、逐轮优化记录、失败记录、赛题对照（**26 篇** `.md` + 3 份 CSV）|
| `skills/fpga-riscv-a100t/PITFALLS.md` | 踩坑记录 **R1~R51**（**51** 条编号记录，症状优先）|
| `legacy/` | 最初的 Verilog 单周期代码 (历史留档) |

> **可移植性**：CPU 核**零厂商原语**（BRAM 全用行为级推断，不例化 IP），
> 迁到紫光同创 PDS 只需重写顶层与约束文件。

## 跑测试

**唯一可用入口是 ModelSim 统一工作流**（**12 项**全量回归）：

```bat
python tools\fpga_workflow.py verify            :: 增量回归 (基线 PASS 12)
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
  `A_EN`（RV32A：9 AMO + LR.W 完整、SC.W 按规范恒失败，但对 CoreMark 三项零贡献）、
  `GEMM_EN`（面积翻倍 + C 读回未修完）、`RAS_EN` 与 `BTB_GSHARE`。
  > ⚠️ **`RAS_EN` 的旧结论需要重测**：当年否掉它的理由是"8:1 栈顶 mux 落在 `pc_target` 路径上"，
  > 而 **C-1 把 `pred_target` 的两个来源都变成寄存器输出之后该理由很可能已失效** ——
  > `p4-c1-2stage-gshare.md` 实测 `--ras` 让 ticks 从 453,942 降到 **452,288**（−0.36%）、
  > JALR 误判 3,650 → 2,796。**要不要默认打开取决于 `--ras` 的 fmax 实测**（`synth --ras` 已支持）。
- **Cache（2 路组相联 + 总线突发）**：**分析判定架构性无收益**，不实现 ——
  `imem`/`dmem` 都已是单周期命中的片上 BRAM，没有它要掩盖的存储器延迟。
  定量依据见 `results/p7-cache-analysis.md`。
- **fmax 现状**：最新已上板档 = **150.2 MHz**（`sys_clk_core` @6.667 ns，WNS **+0.007** MET，**0 Critical Warning**）；
  **无未收敛目标**，合法配方见 `results/NEXT-BURN.md` §1。
  **余量已实测拿不到**（8 组实验全部更差，见 `results/CHANGELOG.md` §13.2）：150 档 10 个族全挤在 +0.026~+0.119 ns；
  要工程余量须降到 **138.75 MHz** 档（+0.033/+0.150，ILA+UART 双验证）。
  另见 **R50**：**收紧约束本身就会让 fmax 变高**（74.4→76.2 就是实例），所以"提频"与 fmax 不是独立两项。
- **`LOAD_RESULT_REG`**：实测更差，已否决（`results/p4-macro-failure.md` 5.2）。
- **唯一未完成项**：GEMM 加速单元的 C 读回 + 缓冲改 BRAM（不计入成绩）。
- **设计坑记录** (都踩过并已修复，代码注释里有详细说明)：
  1. `logic x = expr;` 是**声明式初始化**，只在 0 时刻求值一次，
     不是连续赋值 —— 多处曾因此产生恒 X 信号。全部改为显式 `assign`。
  2. **连续赋值调用函数**时，若函数体引用模块级信号，部分仿真器
     (实测 iverilog) 只把实参计入敏感列表 → 前递结果变陈旧值。
     `hazard_unit` 已改为显式组合逻辑。
  3. 枚举类型的三目运算在 iverilog 需显式转换，改用 `always_comb` + if/else。
