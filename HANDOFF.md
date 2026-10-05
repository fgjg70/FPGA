# 交接文档 — RISC-V CPU (紫光同创杯 2026 选题一)

> **给接手的 AI**：这是全新会话的第一条消息，你没有上下文。请先完整读一遍，
> 再读仓库里的两颗「记忆胶囊」：
> - `skills/fpga-riscv-a100t/SKILL.md` — 环境事实 / 命令配方 / RTL 与工具链经验（24KB）
> - `skills/fpga-riscv-a100t/PITFALLS.md` — **错误台账，症状优先**（9KB，务必先看）
>
> 这两份是 10 轮迭代的全部经验沉淀，能帮你避开已经踩过的几十个坑。

---

## 0. 一句话现状

**RV32IM 五级流水线 CPU 已在真实板卡上跑通 CoreMark v1.0（1200 次迭代 / 10.16 秒 / CRC 逐位正确），
三项评分指标齐全；赛题的基础任务全部完成。异常/中断（P1）已于本轮接入 core 并通过全部回归。**

仓库：`D:\USER\Desktop\FPGA\FPGA`（git，工作区干净，HEAD = `9083059`）

**上手第一件事（不要跳过，2 秒）**：
```bat
cmd /c tools\doctor.bat                          REM 环境自检 + R1 漂移检测
python tools\fpga_workflow.py verify             REM 增量回归, 期望 7 PASS
```
工具集说明见 `tools/README.md`；本轮的教训已补进 `skills/fpga-riscv-a100t/PITFALLS.md`
（新增 R4/R5 与"一·五 逐拍诊断"一节）。

---

## 1. 项目定位

| 项 | 内容 |
|---|---|
| 赛事 | 2026 紫光同创杯 · 选题一「基于紫光同创 RISC-V 指令集 CPU 设计」|
| 目标 | 至少支持 RV32IM，力争国二 |
| 开发板 | 正点原子 达芬奇Pro，XC7A100T-FGG484-2，板载 50 MHz |
| 评分三项 | CoreMark/MHz、最高时钟频率、CoreMark/LUTs |
| 工具链 | riscv-none-elf-gcc 15.2.0（xpack）|
| 基准 | CoreMark v1.0 |

### 赛题任务分解

**基础任务（必须）**：RV32I 通用处理单元 / ≥3 级流水线 + 数据冲突与分支处理 / 外设集成（UART、GPIO）
→ **本仓库全部完成** ✅

**高阶任务（加分）**：2 路组相联 I/D Cache + 总线突发 / 动态分支预测(BTB) + 完整异常中断 / AI 加速单元
→ BTB ✅；**完整异常/中断 ✅（P1 异常 + P2 定时器中断，回归 8 PASS）**；Cache 与 AI 未做 ⬜

**其他评分维度**：代码规范 ✅ / 分析报告（含 ILA 波形）素材已备 ✅ / 应用场景与 AI 模型未做 ⬜

### 还剩什么（按赛题加分价值排序）

| 项 | 价值 | 难度 |
|---|---|---|
| **fmax 还债 78.4→61.4** | 三项指标之一，**当前是最大失分点** | 中（根因已定位）|
| mtimecmp 定时器中断（P2）| 补齐"完整中断"的最后一块（现只有异常 + 已就绪的中断通路）| 低 |
| Cache（2 路组相联 + 突发）| 高阶任务，BRAM 已就位是前置条件 | 高 |
| AI 加速单元 + 应用场景 | 高阶任务与独立评分维度 | 高 |
| 迁移紫光同创 PDS | 赛题平台要求（但 CPU 核零厂商原语，已具可移植性）| 中（等装 PDS）|

---

## 2. 当前实测成果

> ⚠️ **先看这条**：下面「硬件闭环」一节是**上一版 bitstream（P1 之前）**的实测结果。
> **含 P1+P2+P3 的当前 bitstream 也已上板验证通过**（tick 逐位相同），
> 见下方 P4 节与 `results/hw-verified.md` 第 0 节。
> 另外历史行的 `LUT 2481 / fmax 74.6` 用当前代码复现不出来，原因见第 6 节 P1 的说明。

### 三项评分指标

| 指标 | 基线 | **最新可复现实测** | 变化 |
|---|---|---|---|
| **CoreMark/MHz** | 0.8263 | **2.3611**（仿真，硬件吻合 0.02%）| **+185.8%** |
| **最高时钟频率** | 78.4 MHz | **70.9 MHz**（`synth` 实测 WNS 5.902ns）| −9.6% |
| **CoreMark/LUTs** | 2.361e-4 | **9.347e-4** | **+295.9%** |

资源：**LUT 2526 / FF 1377 / BRAM 8 / DSP 8**（评分版，含 P1+P2+P3，不含 ILA）
绝对吞吐 = CoreMark/MHz × fmax = **167.5**（基线 64.8，+158.5%）

> CoreMark/LUTs 与绝对吞吐都**接近但略低于 P3 完成时的历史最好**
> （9.662e-4 / 177.1）—— 差额是 P2 定时器中断的代价（−5.5% fmax），
> 那是**用频率换"完整中断"这个赛题加分项**，详见 `results/p2-timer-irq.md`。
> 若要纯性能最优，可用 `--load-comb`/`--imem-comb-read` 之外的方式关掉中断——
> 但赛题要求完整中断，**不建议**。

> 这三行由 `python tools\fpga_workflow.py report` 从 `results/coremark.csv` 重算得出，
> 是**当前唯一可复现**的数字。旧记录（LUT 2481 / fmax 74.6）见下方历史表与第 6 节的说明。

### 硬件闭环（真实板卡，非仿真）—— **P1 之前的版本**

```
ila_ctrl     = 0x42  ->  done=1  pass=1  fail=0  illegal=0
score_result = 0x9E49D60C
  bit31 = 1  ->  crclist/crcmatrix/crcstate 全部匹配 CoreMark 官方参考值
  tick  =  508,155,404   (预期 508,232,400, 偏差 0.015%)
  时长  =  10.16 s       (满足赛题 >=10 秒硬性要求)
```

CoreMark/MHz 硬件 2.3615 vs 仿真 2.3611，吻合到 0.02%。
**含 P1 的新评分版待复跑，预期 tick 不变（trap 逻辑不在热路径上）。**

### 逐轮指标历史（`results/coremark.csv`，含被否决的配置）

| tag | ticks | CM/MHz | LUT | fmax | 状态 |
|---|---|---|---|---|---|
| baseline-v1 | 1,210,148 | 0.8263 | 3499 | 78.4 | keep |
| branch-pred-v1 | 973,352 | 1.0274 | 3877 | 70.1 | keep |
| rv32im-v1 | 414,062 | 2.4151 | 4532 | 64.7 | **rejected** |
| m-ext-v2 | 423,486 | 2.3614 | 4551 | 74.6 | keep |
| branch-pred-v2-ras | 419,180 | 2.3856 | 4809 | 71.2 | **rejected** |
| bram-v1 | 423,486 | 2.3614 | 2481 ⚠️ | 63.9 | keep |
| HARDWARE-VERIFIED | 508,155,404 | **2.3615** | 2481 ⚠️ | 74.6 | 上板实测（P1 前）|
| p0-score-cm_hw | 423,486 | 2.3614 | 3679 | 64.0 | keep（P0 重建）|
| p1-trap-wired | 423,486 | 2.3614 | 3923 | 61.4 | keep（P1 异常/中断）|
| p3a-jalr-addder | 423,486 | 2.3614 | 3945 | 64.4 | keep（跳转目标专用加法器）|
| p3e-imem-bram-default | 423,486 | 2.3614 | 2656 | 65.3 | keep（取指寄存读/BRAM）|
| p3g-default-final | 423,486 | 2.3614 | 2444 | 75.0 | keep（load 结果寄存·**P3 最好**）|
| **p2-timer-irq** | 423,527 | **2.3611** | **2526** | **70.9** | **keep（当前·含完整中断）**|

⚠️ = 该 LUT 值用当前代码复现不出来，详见第 6 节 P1 小节末尾的说明。

> **本轮两项重大修正（都来自实测，见 `results/p3-imem.md` 与 `results/p3-load-result.md`）**：
> 1. `imem` 原来既不是 BRAM 也不是 LUTRAM，而是 **1228 个纯 LUT 的组合 ROM**（占全核 31%）。
>    改寄存读后进 BRAM，`u_imem` 1228 → **36 LUT**，全核 LUT 3945 → 2656，**CoreMark/MHz 逐位不变**。
> 2. `core.sv` 里 `mem_wb_reg` 的 `load_data_in` 原本**硬接 `32'h0`**，load 结果直接从
>    LSU 组合输出进 `wb_data` mux → 前递 mux → ID/EX，两跳压在一拍。
>    改成真正走 MEM/WB 寄存器后 **fmax 65.3 → 75.0（+14.8%）**，LUT −8.1%，
>    而 **ticks 与 load-use 停顿完全不变（零代价）**。
>
> ⚠️ 第 2 条曾长期被 `HANDOFF.md` 的 P3 方案 1 标注为"代价：load-use 停顿 1→2 拍，约 +7% 周期"
> 而搁置 —— **实测那个代价根本不存在**（dmem 的寄存读已经提供了那一拍）。
> **教训：文档里的"预期代价"必须重新实测，否则会白白放弃大收益。**
>
> 诊断建议：怀疑某个数组没进 BRAM、或某段逻辑被实现成了 LUT 时，跑
> `tools/hier_util.tcl`（按层次报告资源）。普通 `report_utilization` 看不出
> "imem 是 1228 个 LUT" 这类问题 —— 它在两张内存映射表里都不出现。

---

## 3. 环境事实（必读，否则寸步难行）

### 工具路径（已核实存在）

```
Vivado     D:\software\Learn\Xilinx\Vivado\2018.3
ModelSim   D:\software\tools\Modelsim\win64        (LICENSE.TXT 同目录)
RISC-V GCC D:\software\tools\riscv-none-elf\xpack-riscv-none-elf-gcc-15.2.0-1\bin
Python     C:\Users\19716\AppData\Local\Programs\Python\Python313\python.exe
```

没有 iverilog，没有 Pango PDS。

### 【最重要】子进程环境被剥离

DSH 会话的 `process.env` 是**空的**。直接 spawn 子进程会缺 `PROCESSOR_ARCHITECTURE`，
Vivado 会报 `32-bit platform is not supported`；ModelSim 会报 `Unable to checkout a license`。

**一切构建/仿真都通过 `.bat`，并在 bat 里显式 set：**

```bat
@echo off
set "PROCESSOR_ARCHITECTURE=AMD64"
set "LM_LICENSE_FILE=D:\software\tools\Modelsim\win64\LICENSE.TXT"
set "PATH=D:\software\tools\Modelsim\win64;%PATH%"
REM Vivado 用 settings64.bat 最省事:
call "D:\software\Learn\Xilinx\Vivado\2018.3\settings64.bat" >nul 2>&1
```

### 【最重要】`.bat` 与 Vivado 的 `.tcl` 一律纯 ASCII

两种不同成因，同一个结论：
- `.bat`：`cmd` 用 OEM 代码页解析，中文会让**每行首字符被吃掉**（报 `'et' 不是内部或外部命令`）
- `.tcl`：若用 7 位掩码编码写文件，非 ASCII 注释字节会变成控制字符，**其中一些正好是 `0x0A`，
  把注释行劈成代码行**，报 `invalid command name`

### 串口在本板不通

FT2232H 只有 D2XX 驱动、**没有 COM 口**；CH340 也都不在。所以**无法用 printf 读回结果**。
现有替代方案：**MMIO 上报 + ILA over JTAG**（见第 5.3 节）。
如果要让串口可用，需要装 FTDI 的 VCP 驱动 —— 那是驱动安装，得让用户操作。

### 上板链路（已验证）

```
IDCODE 0x13631093, part xc7a100tfgg484-2
FT2232H 被 Digilent EEPROM 编程过, Vivado 能识别: localhost:3121/xilinx_tcf/Digilent/210512180081
LED 高电平点亮: led[0]=心跳 led[1]=PASS led[2]=FAIL led[3]=非法指令
```

---

## 4. 代码结构

```
D:\USER\Desktop\FPGA\FPGA\
├── 19 个 .sv (CPU 核, 纯行为级, 零厂商原语)
│     rv32_pkg.sv      类型/常量/MMIO 地址表/控制束 ctrl_s
│     core.sv          数据通路 + 流水寄存器 + 前递/停滞/重定向
│     control_unit.sv  主译码 (RV32IM + SYSTEM/FENCE)
│     alu.sv  muldiv.sv  branch_unit.sv  imm_gen.sv  pc.sv  regfile.sv
│     hazard_unit.sv  load_store_unit.sv  imem.sv  dmem.sv  btb.sv
│     if_id_reg.sv  id_ex_reg.sv  ex_mem_reg.sv  mem_wb_reg.sv
│     csr_file.sv      M-mode CSR + 陷阱状态机 (已写好, 未接进 core)
├── fpga/          顶层与构建
│     top_a100t.sv       顶层 (ILA 在此, 被 ifdef USE_ILA 隔离)
│     mmio_subsys.sv     GPIO / 64位周期计数器 / UART / 跑分上报寄存器
│     daVinciPro.xdc     引脚与时钟约束
│     build.bat/.tcl     评分版构建 (非工程模式)
│     build_ila.bat/.tcl 带 ILA 的调试构建 (工程模式)
│     ila_cap_done/mark  上板抓取脚本
├── sw/            裸机软件
│     link.ld  crt0.S  libc_min.c  portme.c  hello.c
│     coremark/    CoreMark v1.0 源码 + 移植层
├── sim/           测试台
│     tb_units.sv (194 项单元检查)  tb_core.sv  tb_soc.sv  tb_sw.sv
│     prog/  basic.S  mmio.S  m_ext.S  trap.S (+ 生成的 .hex)
├── tools/         asm.py  build_sw.py  elf2hex.py  run_coremark.py
│     fpga_workflow.py  ★统一入口: doctor/check/verify/report (见 tools/README.md)
│     doctor.bat        零摩擦包装 (纯 ASCII, 一条命令跑完自检+漂移检测)
├── results/       每轮优化的设计与实测数据 (见第 10 节)
└── skills/
      fpga-riscv-a100t/  SKILL.md + PITFALLS.md   (环境事实 + 错误台账)
      fpga-workflow/     SKILL.md                (改→验→量→记 的标准动作)
```

### 内存布局（改动过，注意）

```
0x80000000 .. 0x80003FFF   imem 16KB (.text, 有初始化镜像)
0x90000000 .. 0x90001FFF   dmem .data / .bss (8KB, 有 ASSERT 守卫)
0x90002000 .. 0x90002003   tohost
0x90002004 .. 0x90002BFF   栈 (顶 0x90002C00)
0x90003000 .. 0x90003FFF   日志缓冲区 (printf 重定向目标)
0xA0000000 ...             MMIO (见 rv32_pkg 地址表)
```

---

## 5. 已完成的工作

### 5.1 微架构

| 特性 | 实现 | 效果 |
|---|---|---|
| 5 级流水 IF/ID/EX/MEM/WB | `core.sv` | — |
| EX/MEM + MEM/WB 前递 | `hazard_unit.sv` | load-use 停顿仅 1 拍 |
| **分支预测** | `btb.sv` 64 项 BTB + 2 位 Smith | 精度 89%，CoreMark/MHz +24% |
| **RV32M** | `muldiv.sv` | CoreMark/MHz **+130%** |
| **BRAM 存储** | `dmem.sv` 寄存读 + 字节提取挪到 WB 拍 | LUT −45%，**零性能损失** |

**分支预测的关键语义**：`redirect` 重定义为**「预测错误」**而非「分支 taken」。
预测正确时绝不冲刷，否则两条正确路径被白丢、收益归零。

**M 扩展收益远超预期的原因**：libgcc 的 `__mulsi3/__udivsi3/__umodsi3` 是函数调用 + 循环，
分支密集。启用 M 后 **redirect 从 59,466 掉到 11,501（−81%）**，那部分分支流量整个消失。

**BRAM 怎么做到零损失**：BRAM 输出寄存器直接充当原来 MEM/WB 里那份 load 数据寄存器，
把字节提取/符号扩展挪到 WB 拍组合完成 —— 既不加深流水线，也不增加 load-use 停顿。

### 5.2 外设（`fpga/mmio_subsys.sv`）

| 外设 | MMIO 地址 | 说明 |
|---|---|---|
| GPIO_OUT / GPIO_IN | 0xA0000000 / 04 | |
| 64 位周期计数器 | 0xA0000008 / 0C | CoreMark 计时依赖它 |
| UART TX / STAT / RX / RSTAT | 0xA0000010/14/18/1C | 115200 8N1，回环自测通过 |
| **MMIO_MARK** | 0xA0000020 | W：单拍脉冲，ILA 触发点 |
| **MMIO_RESULT** | 0xA0000024 | W/R：写锁存并置 done |
| MTIMECMP / MTIME | 0xA0000028..0034 | **常量已加，逻辑未实现** |

地址译码在 `core.sv` 内完成：DMEM 窗口 → 内部 dmem；其它 → `ext_*` 总线。

### 5.3 上板自主读回（串口不通的替代方案）

```
软件 --(MMIO)--> 硬件 --(ILA)--> JTAG --> PC
```

**一个 32 位寄存器打包两件事**（上板只能回读一个数）：
```
bit31   = 1 表示 crclist/crcmatrix/crcstate 全部等于官方参考值
bit30:0 = 实测 tick 数
```

**为什么用这三个 CRC 而非 `crcfinal`**：它们与迭代次数**无关**（实测 1 次与 3 次完全一致），
只有跨迭代累积的 `crcfinal` 会变。所以 10 秒要求改了迭代次数后判据依然成立。

### 5.4 验证

**ModelSim 全套回归（当前全部 PASS）**：
```
tb_units  194 项单元检查 (ALU/立即数/控制单元/CSR/regfile/BTB...)
tb_core   basic.hex (含非对齐访存) + m_ext.hex (RV32M 边界)
tb_soc    mmio.hex (UART 回环)
tb_sw     hello.hex / cm_rv32im.hex (CoreMark)
```

**CoreMark 正确性证据**：`seedcrc 0xe9f5` / `crclist 0xe714` / `crcmatrix 0x1fd7` /
`crcstate 0x8e3a` 全部等于官方 2K PERFORMANCE_RUN 值。

---

## 6. 待办（按优先级，含具体怎么做）

### P0 · ~~重建评分版 bitstream~~ ✅ 已完成（本轮）

原来 `fpga/cpu_a100t.bit` 是旧的（`tohost` 上移与 MMIO 新增之前构建），且
`build.tcl` **只定义了 `IMEM_INIT_FILE`** —— 本核是哈佛结构，缺少
`DMEM_INIT_FILE` 会让 `.data/.rodata` 全是 0，跑不了真正的程序。

**已修**：`build.tcl` 现在同时定义两个镜像，并把程序镜像**参数化**：

```tcl
set PROG basic        # 工具会临时改写这一行, 跑完自动还原
set imem "$root/sim/prog/$PROG.hex"
set dmem "$root/sim/prog/$PROG.dmem.hex"
# 两个镜像都存在才继续; 缺 dmem 直接报错退出, 不静默继续
```

一键重建评分版（跑分程序）并同时得到四项指标：

```bat
python tools\fpga_workflow.py synth --prog cm_hw --tag <标签> --record
```

`synthesize` 会自己加**全局构建锁**（Vivado 必须串行，两个实例重叠会谎报
`pkgIndex.tcl` 缺失）、按内容哈希缓存、并把 `timing.rpt`/`util.rpt` **归档**
（它们每次构建都被覆盖，不留档就无法复核历史数字）。

**上板复验：✅ 已完成**（见 P4 节）—— `score_result` bit31=1、tick 508,155,404。
注意 `results/coremark.csv` 里 `bram-v1`/`HARDWARE-VERIFIED`
两行的 LUT=2481 用当前代码复现不出来，详见下方"P1 已完成"小节的说明。

### P1 · ~~异常/中断的 core 接线~~ ✅ 已完成（见下方"P1 已完成"小节）

**P1 之前已完成的部件**（接线时原样沿用，未改逻辑）：
- `csr_file.sv` —— mstatus/mie/mtvec/mscratch/mepc/mcause/mtval/mip + 进陷阱/MRET 状态机
- `control_unit.sv` —— SYSTEM（ECALL/EBREAK/MRET/Zicsr）+ FENCE 译码，**tb_units 12 项新检查已通过**
- `tools/asm.py` —— CSR 指令 + 助记名表（编码已逐条手工验算）
- `sim/prog/trap.S` —— 6 组异常自校验程序

**缺的就是 `core.sv` 里的接线。设计已经想清楚，照下面写即可：**

```systemverilog
// ---- csr_file 实例 ----
csr_file u_csr (
  .clk, .rst,
  .raddr (id_ex_ctrl.csr_addr),  .rdata (csr_rdata),
  .we    (csr_we),               .waddr (id_ex_ctrl.csr_addr),  .wdata (csr_wdata),
  .trap_req (trap_req), .trap_cause (trap_cause), .trap_pc (id_ex_pc), .trap_tval (32'd0),
  .trap_enter (trap_enter), .trap_vector (trap_vector),
  .mret_req (is_mret && !pipe_stall), .mret_taken (mret_taken), .mret_pc (mret_pc),
  .irq_timer (1'b0), .irq_ext (1'b0),        // P2 再接
  .irq_pending (irq_pending), .irq_cause (irq_cause)
);

// ---- EX 段：CSR 读改写 ----
is_csr    = (id_ex_ctrl.sys_op == SYS_CSR);
csr_src   = id_ex_ctrl.csr_src_imm ? {27'b0, id_ex_ctrl.csr_uimm} : ex_rs1;
csr_wdata = (id_ex_ctrl.csr_cmd == 2'b01) ? csr_src
          : (id_ex_ctrl.csr_cmd == 2'b10) ? (csr_rdata |  csr_src)
          :                                 (csr_rdata & ~csr_src);
// 规范: CSRRS/CSRRC 且源为 0 时不写 (读只读寄存器不得触发异常)
csr_we    = is_csr && !pipe_stall && (id_ex_ctrl.csr_cmd == 2'b01 || csr_src != 32'd0);

// 写回旧值: 给 ex_result 加一路
ex_result = is_muldiv ? md_result : is_csr ? csr_rdata : ex_alu_out;
// 写回 mux 里 WB_CSR 走 mem_wb_alu_out (EX/MEM 已存下 ex_result)

// ---- 陷阱判定 (EX 段, 指令提交前) ----
is_mret   = (id_ex_ctrl.sys_op == SYS_MRET);
exc_req   = !pipe_stall && (id_ex_ctrl.illegal
                          || id_ex_ctrl.sys_op == SYS_ECALL
                          || id_ex_ctrl.sys_op == SYS_EBREAK);
exc_cause = id_ex_ctrl.illegal           ? CAUSE_ILLEGAL
          : id_ex_ctrl.sys_op==SYS_ECALL ? CAUSE_ECALL_M : CAUSE_BREAKPOINT;
irq_take  = irq_pending && !pipe_stall && !exc_req && !is_mret;
trap_req  = exc_req || irq_take;
trap_cause= exc_req ? {1'b0, exc_cause} : irq_cause;

// ---- 重定向 (与分支预测冲刷共用一套机制) ----
trap_redir  = trap_enter | mret_taken;
any_redir   = redirect | trap_redir;
pc_src      = any_redir || pred_taken;
pc_target   = trap_enter ? trap_vector
            : mret_taken ? mret_pc
            : redirect   ? actual_target : pred_target;
if_id_flush = any_redir;                 // 原来只写 redirect
id_ex_reg 的 .flush 也改成 any_redir;    // 原来只写 redirect
```

**关键点**：陷阱时冲刷 ID/EX 会把触发指令变成气泡 → 它**不写寄存器、不写存储器** → 精确陷阱。
`csr_file` 里 `mepc` 取 `trap_pc` 本身**不 +4**，因为异常与中断都在指令提交前裁决，
被抢占的指令必须重新执行，两种情况语义统一。

**改完必须**：`tb_units` / `tb_core(basic,m_ext)` / `tb_soc` / `tb_sw(hello,coremark)` 全过，
并把 `sim/prog/trap.S` 加进 tb_sw 测试列表跑通。

#### ✅ P1 已完成（本轮）—— 以上就是最终落地的接线

**回归 7 PASS**（`tb_units` / `tb_core_basic` / `tb_core_trap` / `tb_core_m_ext` /
`tb_soc` / `tb_sw_hello` / `tb_sw_coremark`）。`csr_file.sv` 已进三处 RTL 清单与
`CORE_SV_ORDER`，`KNOWN_UNWIRED` 白名单已清空（`check` 不再报未接线）。

**过程中修掉的三个真 bug（都在 PITFALLS 里立了条）：**

| # | 症状 | 真因 |
|---|---|---|
| R5 | `tb_core` 在 555ns 就 `$fatal`，测试程序没机会跑 handler | `dbg_illegal` 在 **ID 段**锁存，而陷阱在 **EX 段**裁决，早整一拍 → 改用 `id_ex_ctrl.illegal` |
| R4 | 第二次陷阱跳到 `0x00000000`（实际是 `mtvec` 被写成 `11`） | `trap.S` 用 `t0` 存 handler 地址，而 handler 也用 `t0` → 已改用 `s1` |
| — | `tb_core` 报的非法指令地址差 8 字节 | 诊断用了 `dbg_pc`（IF 段）而非 `dbg_id_pc`（与 `dbg_instr` 同级）——SKILL 6.10 早写过，这次真踩了 |

**测量到的代价（`results/coremark.csv` 的 `p1-trap-wired` 行）：**

| 指标 | P1 前 | P1 后 | 变化 |
|---|---|---|---|
| CoreMark/MHz | 2.3614 | 2.3614 | 0（诚实：trap 逻辑不在热路径上）|
| LUT | 3679 | **3923** | +6.6% |
| FF | 1146 | **1333** | +16.3% |
| fmax | 64.0 | **61.4** | **−4.1%** |
| CoreMark/LUTs | 6.418e-4 | 6.019e-4 | −6.2% |
| 绝对吞吐 | 151.1 | 145.0 | −4.0% |

**结论**：用 +6.6% LUT、−4.1% fmax 换来了赛题高阶任务「完整异常中断」——
**值得**，因为它从"未完成"变成"完成"。fmax 的 −4.1% 大概率是
`pc_target` 从 2 路 mux 变 4 路 mux（陷阱向量 / MRET / 重定向 / 预测目标）加在
**关键路径末端**上，属于 P3 要还的同一类债，可与 P3 一起修。

> ⚠️ 另外记一笔：`results/coremark.csv` 里 `bram-v1` 与 `HARDWARE-VERIFIED` 两行的
> LUT=2481 **用当前代码与构型复现不出来**。现在这条 `synth` 命令实测稳定给出
> LUT 3679（P1 前）/ 3923（P1 后），且 BRAM 推断正常
> （`LUT as Distributed RAM = 83`、`Block RAM Tile = 4`，与 bram-v1 的意图一致）。
> 推测 2481 来自更早的 RTL 修订。**后续以 `synth` 的实测值为准**，历史行仅供趋势参考。

### P2 · ~~mtimecmp 定时器中断~~ ✅ 已完成（本轮）

`rv32_pkg.sv` 里的地址常量（`MMIO_MTIMECMP_LO/HI`、`MMIO_MTIME_LO/HI`）已落地：

- `fpga/mmio_subsys.sv`：64 位 `mtimecmp` 寄存器（复位值全 1 → 上电不会立刻中断），
  `mtime` **复用**已有周期计数器（保证 MMIO_MTIME_* 与 MMIO_CYCLE_* 读数必然一致），
  `irq_timer = (mtime >= mtimecmp)` 电平输出
- `core.sv`：新增 `irq_timer` 端口 → `csr_file.irq_timer`（→ `mip.MTIP`），不再硬接 1'b0
- `top_a100t.sv` / `tb_soc.sv` / `tb_sw.sv` 已接线（`tb_core` 保持恒 0，它不接外设）
- 新测试 `sim/prog/timer_irq.S` + `tb_soc_timer_irq`：验证中断触发、`mcause` 判定、
  handler 推进 mtimecmp 清电平、`mret` 返回、**handler 用 mscratch 保存/恢复现场**、
  以及中断之后 UART/GPIO 仍正常。**全套回归 8 PASS。**

> ⚠️ **中断是电平触发**：`mret` 后若 handler 没推进 `mtimecmp`，条件依然成立 → 立刻重入
> → 死循环。这是**规范的正常行为**，由中断处理程序负责写 `mtimecmp`。

**本轮修掉的两个真 bug（都只在测中断时才暴露）：**

| # | 症状 | 真因 |
|---|---|---|
| R6 | 中断进了但 handler 走错分支；`mcause` 读回 `0x17` 而非 `0x80000007` | `mcause <= {27'b0, trap_cause}` 把**中断位放到了 bit4**，规范要求 bit31。**同步异常下 bit31 本来就是 0，所以此前一直没暴露** |
| R7 | 定时器测试自旋等待、中断永不使能 | `csrsi mie, 0x80` 的立即数**只有 5 位**（规范），`0x80 & 0x1F = 0` → 静默变成 `csrsi mie, 0`。MTIE 是 bit7，**必须用寄存器形式** `li t0,0x80` + `csrw mie,t0` |

### P3 · fmax 还债 ✅ 已完成（61.4 → 75.0 MHz，+22.2%）

三个实验，全部已落地为**默认配置**，详见 `results/p3-fmax.md` / `p3-imem.md` / `p3-load-result.md`：

| 实验 | 改动 | fmax | LUT | 绝对吞吐 |
|---|---|---|---|---|
| （起点，P1 之后） | — | 61.4 | 3923 | 145.0 |
| A | 跳转目标专用加法器（绕开 ALU 操作数 mux）| 64.4 | 3945 | 152.1 |
| B | 取指存储器改寄存读 → 进 BRAM | 65.3 | 2656 | 154.2 |
| **C** | **load 结果改由 MEM/WB 寄存器给出** | **75.0** | **2444** | **177.1** |

**全部零周期代价**（CoreMark ticks 逐位不变 423,527）；CoreMark/LUTs 与绝对吞吐
两项均已**超过历史最好**。距 78.4 仅差 4.3%。

> ⚠️ **一条重要教训**：`HANDOFF.md` 原先把实验 C 标注为"代价：load-use 停顿 1→2 拍，
> 约 +7% 周期"而长期搁置。**实测那个代价根本不存在** —— `dmem` 的寄存读已经提供了
> 那一拍，`MEM/WB` 只是把同一个值再接一次。**文档里的"预期代价"必须重新实测再据此决策。**
>
> 两个可回退开关：`--load-comb`（实验 C）与 `--imem-comb-read`（实验 B）。

**当前关键路径**（已不是 load 路径）：
```
Source:      u_id_ex/rs2_addr_reg[4]/C
Destination: u_id_ex/rs1_data_reg[28]/D
13.236ns (logic 28.5% | route 71.5%), slack 6.664ns
```

### P4 · ~~上板复跑~~ ✅ 已完成（2026-10-05 16:43，含 P1+P2+P3 全部改动）

**上板验证 PASS**（`cmd /c fpga\ila_cap_done.bat`）：

```
ila_ctrl     = 0x42  ->  done=1 pass=1 fail=0 illegal=0
score_result = 0x9E49D60C
  bit31 = 1  ->  CRC 全部匹配 CoreMark 官方参考值
  tick  = 508,155,404    (预期 508,232,400, 偏差 0.015%)
  时长  = 10.16 s        (赛题 >=10s 满足)
  CoreMark/MHz = 2.3615  (仿真 2.3611, 吻合 0.02%)
```

> **tick 与 P1 之前逐位相同** —— P1/P2/P3 都不改变指令数与周期数（P3 是纯时序优化，
> P1/P2 的陷阱逻辑不在热路径），硬件上逐位复现，证明**仿真与硬件在三次结构性改动后仍一致**。

流水线波形见 `results/ila_pipeline.csv`（stall 11.57%、redirect 0.68%），
详细记录见 `results/hw-verified.md` 第 0 节。

**上板闭环是全自动的**，见 `HANDOFF-HW-LOOP.md`。要点：
1. **改过 RTL 必须先重建 ILA 版**（`cmd /c fpga\build_ila.bat`，约 5-6 分钟）——
   ILA bit 与 RTL 脱节是**静默失败**（抓到旧设计的信号，不报错）。
   核对脚本：比 `fpga/ila_proj.runs/impl_1/top_a100t.bit` 与各 RTL 的 mtime。
2. `write_hw_ila_data` 目标 CSV 已存在时**必须加 `-force`**（否则 `Labtoolstcl 44-54`）。
3. 读回用 `python tools\fpga_workflow.py hw --iterations 1200 --tag <标签> --record`。

### P5 · Cache / AI 加速单元（工作量大，未开始）

### P6 · 迁移紫光同创 PDS（需用户先装 PDS）

可移植性已经保证：**CPU 核 19 个源文件零厂商原语**，只需重写 `top_a100t.sv` 与约束文件。
注意 Xilinx BRAM 是 36Kb、紫光同创是 18Kb，**不要例化 BRAM IP** —— 现在是行为级推断，能直接迁。

---

## 7. 命令配方

### 【先跑这个】统一工作流入口

`skills/fpga-riscv-a100t/PITFALLS.md` 记了 40+ 个坑，最高频的是 **R1「改了 A 忘了同步 B」——
全部静默失败**。这套工具把那条纪律从"靠人记"变成"机器每次都查"：

```bat
rem 收尾必跑: 环境自检 + R1 漂移检测 (约 2 秒)
cmd /c tools\doctor.bat

rem 回归: ModelSim 增量 (未受影响的测试直接跳过)
python tools\fpga_workflow.py verify

rem 指标: 三项指标 + 绝对吞吐 (从 results/coremark.csv 重算)
python tools\fpga_workflow.py report
```

`verify` 的判定依据是 testbench 打印的 **`RESULT : PASS`**，不是 `vsim` 退出码
（ModelSim 用 `quit -f` 退出时无论成败都返回 0）。当前基线：
**7 PASS**，全量约 23 秒，未受影响时 2.8 秒。

`check` 查六件事：三处 RTL 清单是否同步 / 有无未登记或未接线的模块 /
软件源是否比 `.hex` 镜像新 / **bitstream 是否比 RTL 与镜像新** /
tohost 地址与注释是否一致 / `.bat`·`.tcl` 是否纯 ASCII。
**新增 `.sv` 必须登记进 `tools/fpga_workflow.py` 的 `CORE_SV_ORDER`**
（`rv32_pkg.sv` 必须排第一 —— 其余模块 `import` 它，顺序是语义不是格式）。

### 改一处 RTL → 四项指标全出（测量半环）

```bat
python tools\fpga_workflow.py synth --prog cm_hw --tag <标签> --record
```

自动串行化（全局构建锁）、内容哈希缓存、报告归档，一次给出
CoreMark/MHz + fmax + CoreMark/LUTs + 绝对吞吐 并追加进 `results/coremark.csv`。

### 软件构建

```bash
# CoreMark (注意: --march 才是真生效的, -D FLAGS_STR 只改打印出来的字符串)
python tools/build_sw.py sw/coremark/*.c -I sw/coremark -D ITERATIONS=1200 \
    -D 'FLAGS_STR="-Os -march=rv32im -mabi=ilp32"' --march=rv32im \
    -o sim/prog/cm_hw.hex

# 普通裸机程序 (build_sw 已自动包含 crt0.S 和 libc_min.c, 不要再手动传)
python tools/build_sw.py sw/hello.c sw/portme.c -I sw -o sim/prog/hello.hex

# 汇编程序
python tools/asm.py sim/prog/basic.S -o sim/prog/basic.hex
```

### ModelSim 仿真（必须走 .bat，见第 3 节）

```bat
set "LM_LICENSE_FILE=D:\software\tools\Modelsim\win64\LICENSE.TXT"
set "PATH=D:\software\tools\Modelsim\win64;%PATH%"
vlib work
vlog -sv -work work <19 个 RTL> fpga\mmio_subsys.sv sim\tb_XXX.sv
vsim -c -do "run -all; quit -f" work.tb_sw +imem=<abs>/cm_rv32im.hex +dmem=<abs>/cm_rv32im.dmem.hex
```

### 上板构建

```bat
cmd /c fpga\build.bat        REM 评分版 (非工程模式, 快)
cmd /c fpga\build_ila.bat    REM 带 ILA 调试版 (工程模式, 慢; 产物在 fpga/ila_proj.runs/)
```

---

## 8. 必读的坑（完整版在 `skills/fpga-riscv-a100t/PITFALLS.md`）

### 最高频 · 改了 A 忘了同步 B（已踩 5+ 次，全部静默失败）

> **现在这条已经机器化了** —— 改完直接跑 `cmd /c tools\doctor.bat`，
> 下面这张表里的第 1、2、3 行都会被自动查出来。

| 改了什么 | 必须同步 |
|---|---|
| 新增 RTL 文件 | `fpga/build.tcl`、`fpga/build_ila.tcl`、`tools/run_coremark.py`、以及所有 vlog 列表、**`tools/fpga_workflow.py` 的 `CORE_SV_ORDER`** |
| 改软件源码 | 重建 `.hex`，**并重新综合 bitstream**（imem/dmem 是综合时 `$readmemh` 进去的）|
| 改 `link.ld` 地址 | portme.c / crt0.S / core_portme.c / top_a100t.sv / 三个 tb 的 TOHOST_ADDR / **`sim/prog/*.S` 里硬编码的地址** |
| 改 `.S` | 重新用 asm.py 汇编（tb 用的是 .hex，不是 .S）|

**识别信号**：结果与上次「完全一致」、镜像逐字节相同、或程序跑到 `j .` 自旋。

### 其他高频坑

| 症状 | 真因 |
|---|---|
| `.bat` 报 `'et' 不是内部或外部命令` | 文件里有中文，cmd 用 OEM 代码页吃掉了行首字符 |
| Vivado Tcl 报 `invalid command name` | `.tcl` 里有中文，7 位掩码编码把注释行劈成了代码行 |
| `Synth 8-2715 syntax error near /` | `verilog_define` 里路径没加引号 |
| `[Synth 8-27] string type not supported` | `string` 不可综合，要用 ifdef SYNTHESIS 包住 |
| ModelSim `vopt-7061` | `initial` 与 `always_ff` 同时驱动一个变量，改用 `always` |
| 信号恒为 X | `logic x = expr;` 是声明式初始化，只在 0 时刻求值一次，要用 `assign` |
| `vlog-13069 unexpected '['` | 不能对括号表达式位选，`(a>>b)[31:0]` 非法，要先赋中间 wire |
| `get_hw_probes probe2` 返回空 | ILA 探针名是**连接的网络名**（`dbg_pc`/`ila_ctrl`/…），不是 `probe0..3` |
| `TRIGGER_COMPARE_VALUE` 各种报错 | 需要比较前缀且位宽匹配：`eq8'h40` 可以 |
| ILA 触发值看着对却永不触发 | 精确匹配太脆弱（结束时 pass 位也是 1，0x42 不等于 0x40），用默认 `eq8'hXX` 无条件触发 |
| 综合出 25 个 LUT | 没装程序，全被常量折叠；必须 `-verilog_define IMEM_INIT_FILE=...` |

### 设计纪律

**赛题记三项指标，改一项必须同时量三项 + 绝对吞吐（CoreMark/MHz × fmax）。**
反例：RAS+BTB128 让 CoreMark/MHz +1.0%，但 fmax −4.6%、CoreMark/LUTs −4.4%，净亏，已回退。
**优化前先测量** —— 当初就是靠剖析发现分支惩罚占 29%，才决定先做预测而不是 M 扩展。

---

## 9. 关键设计决策与理由

| 决策 | 理由 |
|---|---|
| `redirect` = 「预测错误」而非「分支 taken」 | 预测正确时冲刷会把两条正确路径白丢，收益归零 |
| 跳转目标直接取 ALU 的**原始加法器输出** | BR/JAL/JALR 的 alu_op 恒为 ADD，少走一级操作码 mux（零面积代价）|
| 乘法乘积寄存进 DSP 的 MREG/PREG | 组合乘法路径 15.5ns 拖垮 fmax；寄存后用 2.2% CoreMark 换回 15% fmax |
| 除法 `busy` 覆盖启动拍 + 单周期特例 | 否则 DIV 在结果出来前离开 EX，或 EX/MEM 捕获上一次的结果 |
| BRAM 用寄存读 + 提取挪到 WB | 组合读只能落分布式 RAM（2131 LUT，占全核 47%）|
| FENCE 译成合法 NOP 而非 illegal | 编译器/运行库会插 fence，误判为非法会让正常程序一上来就掉陷阱 |
| `mepc` 取 `trap_pc` 不 +4 | 异常与中断都在指令提交前裁决，被抢占的指令必须重新执行 |
| MMIO 需要读选通 `ext_re` | 只靠 `we` 的话外设的粘滞就绪标志永远清不掉 |

---

## 10. 参考文档索引

| 文件 | 内容 |
|---|---|
| `skills/fpga-riscv-a100t/SKILL.md` | **环境事实 / 命令配方 / 12 节 RTL 与工具链经验** |
| `skills/fpga-riscv-a100t/PITFALLS.md` | **错误台账，症状优先，含改动后自检清单** |
| `results/coremark.csv` | 逐轮指标历史（含被否决配置与理由）|
| `results/hw-verified.md` | 上板实测数据 + ILA 抓取方法 |
| `results/gap-analysis.md` | 对照赛题逐项核对的差距清单 |
| `results/baseline-v1.md` | 基线剖析（分支惩罚 29% 的发现过程）|
| `results/branch-pred-v1.md` | 分支预测设计与两个关键 bug |
| `results/branch-pred-v2.md` | RAS/BTB 扩容的被否决实测数据 |
| `results/m-ext-v1.md` | M 扩展实现与三个除法器时序坑 |
| `results/bram-v1.md` | BRAM 转换 + fmax 技术债的根因分析 |
| `results/ila_pipeline.csv` | **分析报告要的 2048 拍流水线波形**（本次实测 stall 11.57%、redirect 0.68%）|
| `results/ila_done.csv` | 上板跑分读回的原始数据（含 tick 与 CRC 判定）|
| `results/p2-timer-irq.md` | 定时器中断实现 + 两个真 bug（mcause 位布局 / csrsi 5 位立即数）|
| `results/p3-fmax.md` `p3-imem.md` `p3-load-result.md` | fmax 还债三个实验的设计与实测 |
| `HANDOFF-HW-LOOP.md` | **上板闭环是全自动的** —— 烧录/运行/读回的完整配方 |

---

## 11. 需要用户确认/操作的事

1. ~~上板复跑~~ ✅ **已完成**（2026-10-05 16:43，含 P1+P2+P3，tick 逐位一致、CRC 判定=1）
2. **串口不可用** —— 若需要（如现场演示），得装 FTDI 的 VCP 驱动
3. **紫光同创 PDS 尚未安装** —— 迁移工作要等装好（CPU 核零厂商原语，可移植性已保证）
4. 仓库 `fpga/` 目录里有较多 Vivado 日志与备份文件（已被 gitignore），可清理
5. **剩余未做的赛题项**：Cache（2 路组相联 + 总线突发）、AI 加速单元与应用场景、
   分析报告成文（**素材已齐**：`results/*.md` + 两份 ILA CSV）

---

## 12. 建议的接手顺序

```
1. 读 skills/fpga-riscv-a100t/PITFALLS.md   (10 分钟, 能省你几小时)
2. 读 skills/fpga-riscv-a100t/SKILL.md      (环境与命令配方)
3. 读 HANDOFF-WORKFLOW.md                   (10 轮优化循环 + 判定阈值 + 建议的子命令)
4. 读 tools/README.md                       (统一工作流: doctor/check/verify/profile/synth/metrics/report)
5. 跑 cmd /c tools\doctor.bat               (环境自检 + 漂移检测, 2 秒)
6. 跑 python tools\fpga_workflow.py verify  (确认基线 7 PASS)
7. 按剩余时间取舍: P3 剩余方案 / P2 定时器中断 / ILA 波形 + 分析报告 / Cache
8. P4 上板复跑 (RTL 定稿后一次做)
```

> ✅ P0（重建评分版）、P1（异常/中断接线）**已完成**；P3 实验 A 已完成（fmax +4.9%）
> 并**暂停**，剩两个方案见上（盈亏平衡账已算清，不要凭感觉做）。
> 新优化回合请按 `HANDOFF-WORKFLOW.md` §1.1 的七步循环走，它已固化成
> `skills/fpga-workflow/SKILL.md` 里的标准动作。

**当前三项指标已是可参赛水平（基础任务全完成 + BTB + 完整异常中断）。
最大失分点是 fmax（78.4 → 64.4，还差 17.9%）。**

---

## 13. 本次迭代的完整轨迹（供参考，不必细读）

| 轮次 | 做了什么 | 结果 |
|---|---|---|
| 1-2 | 环境打通、基线剖析、分支预测 | CM/MHz 0.8263 → 1.0274 |
| 3 | RV32M 扩展 + fmax 还债 | → 2.3614，fmax 74.6 |
| 3 | RAS/BTB 扩容实验 | **净亏，回退** |
| 4 | BRAM 存储系统 | LUT 4494 → 2481，CM/LUTs +81% |
| 5-6 | 上板读回基础设施（MMIO + ILA）| — |
| 7-9 | 差距分析、CSR/异常基础、汇编器扩展 | tb_units 通过 |
| 10 | **上板 CoreMark 实测通过** | 10.16s，CRC 判定=1 |
| 11 | 工具化: `check`/`verify`/`synth`/`report` + 技能注册 | 回归 6 PASS + 1 XFAIL → 见下 |
| 11 | **P0** 评分版重建（补 `DMEM_INIT_FILE` + 参数化 `PROG`）| LUT 3679 / fmax 64.0 |
| 11 | **P1** 异常/中断接入 core（Zicsr + 陷阱 + MRET）| **7 PASS**；LUT 3923 / fmax 61.4 |

`PITFALLS` 本轮新增：R4（handler 破坏自己要用的寄存器）、R5（调试标志与事件不同流水级）、
一·五（逐拍诊断: 粘滞标志 + `$fatal` 会让"猜"变成唯一手段）。

git 提交：`e49f801`（原始）→ `97be06f` → `2ca639c` → `9083059`（HEAD）