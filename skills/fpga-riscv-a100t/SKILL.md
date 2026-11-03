> **文档性质声明（开发/交接文档）**：本文是内部开发/交接/审查文档，不是赛题交付结论或对外验收报告；涉及的数字请以根 [`COMPLIANCE.md`](https://github.com/fgjg70/FPGA/blob/main/COMPLIANCE.md) 的"证据分级"与对应证据文件为准。

---
name: fpga-riscv-a100t
description: 在正点原子达芬奇Pro (XC7A100T-FGG484-2) 上开发/验证 RISC-V 软核 CPU 时使用。涵盖 ModelSim 命令行回归、Vivado 2018.3 批处理综合与 JTAG 烧录、硬件闭环验证配方，以及本机环境特有的坑(DSH 会话剥离环境变量、cmd 批处理必须纯 ASCII、MMIO 读选通、UART 收发约定)。触发词：FPGA、A100T、达芬奇Pro、RISC-V、RV32I、ModelSim、Vivado、bitstream、烧录、CoreMark、紫光同创、PDS。
---

# 正点原子达芬奇Pro + RISC-V 软核 CPU 工程

本工程 = `D:\USER\Desktop\FPGA\FPGA`。以下全部**实测确认**，不是推测。

## 1. 环境事实

| 组件 | 路径 | 备注 |
|---|---|---|
| Vivado | `D:\software\Learn\Xilinx\Vivado\2018.3` | 未加入 PATH，用 `settings64.bat` |
| ModelSim | `D:\software\tools\Modelsim\win64` | **SE-64 2020.4** |
| RISC-V GCC | `D:\software\tools\riscv-none-elf\xpack-riscv-none-elf-gcc-15.2.0-1\bin` | `riscv-none-elf-gcc 15.2.0` |
| Python | `C:\Users\19716\AppData\Local\Programs\Python\Python313\python.exe` | asm.py 用 |
| iverilog | **不存在** | README 提到的便携版路径是空的 |
| PDS (紫光同创) | **未安装** | 迁移时才需要 |

## 2. 会话环境坑（每条都真踩过）

1. **`process.env` 是空的。** 子进程拿不到 `PROCESSOR_ARCHITECTURE`，Vivado 的 `xvlog.bat/vivado.bat` 会去找 `bin\unwrapped\win32.o\` 并报
   `ERROR: 32-bit platform is not supported`。
   **修**：在批处理里 `set "PROCESSOR_ARCHITECTURE=AMD64"`，或给 `execSync` 传完整 env。
2. **`LM_LICENSE_FILE` 在机器级已正确设置**（`D:\software\tools\Modelsim\win64\LICENSE.TXT`），但被会话剥离，导致 `vsim` 报
   `Unable to checkout a license`。
   **修**：在批处理里显式 `set`。（`vlog/vlib` 不需要 license，只有 `vsim` 需要。）
3. **`.bat` 必须纯 ASCII。** 中文注释会让 cmd（OEM 代码页）把**每行第一个字符吃掉**，表现为
   `'et' 不是内部或外部命令`（set 变成 et）。工程 README 早就警告过，仍踩了一次。
4. **`os.tmpdir()` 在空 env 下返回相对路径** `undefined\temp`，会把临时文件建到工作目录里。
   **修**：一律用绝对路径（如 `C:\Users\19716\AppData\Local\Temp\...`）。
5. **`powershell` 不在精简 PATH 中**。自定义 env 时要带上
   `C:\Windows\System32\WindowsPowerShell\v1.0`，否则命令找不到。
6. `tools.pwsh` 后台任务 + `job_output` 可跑大下载；临时文件放 `%TEMP%`，不要污染工程目录。

## 3. Vivado 2018.3 命令坑

| 坑 | 正确做法 |
|---|---|
| `open_hw_manager` 不存在 | 用 **`open_hw`**（`open_hw_manager` 是 2019+ 才有） |
| `read_verilog -define` 报 "only supported when is_compile_unit_mode is enabled" | 用 **`synth_design -verilog_define {MACRO="值"}`** |
| 是否要手动定义 `SYNTHESIS` | **不用**，Vivado 综合会自动预定义 |
| 未加载程序时综合结果只有 ~25 LUT | 是常量折叠：imem 全 NOP → 整条数据通路成死代码。**资源数字无意义**，必须用 `-verilog_define` 真加载程序再测 |

## 4. 命令配方

### ModelSim 回归（**不要**依赖 `-suppress 7061`，RTL 已修干净）
```bat
@echo off
set "LM_LICENSE_FILE=D:\software\tools\Modelsim\win64\LICENSE.TXT"
set "PATH=D:\software\tools\Modelsim\win64;%PATH%"
cd /d <scratch>
vlib work
vlog -sv -work work <所有 RTL> <tb>.sv
vsim -c -do "run -all; quit -f" work.<tb> +imem=<绝对路径>/xxx.hex
```

### Vivado 综合 / 上板构建
见 `fpga/build.tcl` + `fpga/build.bat`（非工程模式，synth→opt→place→route→write_bitstream）。
关键行：`synth_design -top top_a100t -part xc7a100tfgg484-2 -verilog_define {IMEM_INIT_FILE="...basic.hex"}`

### JTAG 探测与烧录
```tcl
open_hw
connect_hw_server
open_hw_target                      ;# target = localhost:3121/xilinx_tcf/Digilent/210512180081
set dev [lindex [get_hw_devices] 0] ;# xc7a100t_0, IDCODE 0x13631093
current_hw_device $dev
refresh_hw_device -update_hw_probes false [current_hw_device]
set_property PROGRAM.FILE {<绝对路径>.bit} [current_hw_device]
program_hw_devices [current_hw_device]
```

## 5. 板卡事实（正点原子 达芬奇Pro）

- 器件 **XC7A100T-FGG484-2**（与 `D:\Workspace\Xilinx\vivada\ZI_GUANG\RISC_V\RISC_V.xpr` 里 `Part` 一致；芯片丝印也是 -2）
- IDCODE `0x13631093`；FT2232H 已按 **Digilent 兼容**编程，Vivado 直接认
- 官方引脚文件：`D:\BaiduNetdiskDownload\达芬奇Pro\3_开发板原理图和硬件相关文件\DaVinci_Pro_PIN.xdc`

| 信号 | 引脚 | 电平 |
|---|---|---|
| `sys_clk` | **R4** | LVCMOS15，**50 MHz** |
| `sys_rst_n` | **U7** | LVCMOS15，低有效 |
| `led[0..3]` | V9 / Y8 / Y7 / W7 | LVCMOS15，**高电平点亮**（实测） |
| `uart_txd` / `uart_rxd` | D17 / E14 | LVCMOS33 |
| `key[0..3]` | T4 / T3 / R6 / T6 | LVCMOS15 |

- **R4 不是专用时钟引脚** → xdc 必须加 `set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets sys_clk]`
- **串口不暴露 COM 口**（FT2232H 绑的是 D2XX 驱动）。想要自动读结果，走 JTAG 上的 ILA，别指望 COM。
- LED 语义（已硬件验证）：`led[0]`心跳 ~3 Hz、`led[1]`PASS、`led[2]`FAIL、`led[3]`非法指令

## 6. RTL 级教训（都用真 bug 换来的）

1. **`string` 类型 + `$value$plusargs` 不可综合** → `ERROR: [Synth 8-27] string type not supported`。
   用 ````ifdef SYNTHESIS```` 分成综合/仿真两条路径（见 `imem.sv`）。
2. **`initial` 与 `always_ff` 驱动同一变量违反 LRM** → ModelSim `vopt-7061` 报错并拒绝优化。
   把 `always_ff` 改成 `always`。（iverilog 不报，换工具才暴露。）
3. **`always_ff` 里不允许 `wait` / `#延时`**。测试台的收尾判定要放独立 `initial` 块。
4. **MMIO 必须同时提供读选通和写选通。** 只给写选通时，外设的粘滞"数据就绪"标志软件**永远清不掉** ——
   表现为"第一次轮询正常，之后每次立即通过并读到上一次的数据"。`core.ext_re` 就是为此加的。
5. **UART TX 忙时丢弃写入** → 驱动必须轮询 `MMIO_UART_STAT`。
6. **UART RX 只有一个字节寄存器（无 FIFO）** → 必须**发一个读一个**，否则只有最后一个字节能读到。
7. **UART RX 下降沿检测**：`rxd_sync <= {rxd_sync[1:0], rx}` 时 `[2]` 最旧 `[0]` 最新，
   1→0 的样点序列是 `111→110→100→000`，即 `[2:1]` 走 `11→11→10→00` →
   判据是 **`2'b10`**，写成 `2'b01` 永远不触发（表现为"发送正常但接收一次都没成功"）。
8. **不要用粘滞标志做计数**（rdy 在程序读走前一直是 1，会每拍 +1），要用"事件完成"的单拍脉冲。
9. **周期/时间双看门狗**：周期计数看门狗在 `finished` 置位后停止计数，挡不住"卡在同一仿真时刻无限等待"。必须再加独立的时间看门狗。
10. **诊断信号要成对引出**：`dbg_pc` 用 IF 段的 `pc`（回答"跑到哪了"），`dbg_id_pc` 用 `if_pc`（与 `dbg_instr` 严格配对）。
    只引出一个都有坑：单用 `pc` 与 `if_instr` 差一拍指错指令；单用 `if_pc` 会在 flush 那拍被清成 0。

## 7. 当前架构与测试

```
top_a100t.sv ── core.sv (纯 CPU) ──ext_* MMIO 总线── mmio_subsys.sv (GPIO/周期计数器/UART)
```
- `core` 内做地址译码：DMEM 窗口内 → 内部 dmem；窗口外 → `ext_*` 总线
- MMIO 映射见 `rv32_pkg.sv`：`0xA0000000` GPIO_OUT / `+4` GPIO_IN / `+8` CYCLE_LO / `+C` CYCLE_HI / `+10` UART_TX / `+14` UART_STAT / `+18` UART_RX / `+1C` UART_RSTAT
- **不例化任何厂商 IP**，BRAM 靠行为级推断 —— 为迁移紫光同创 PDS 保留零成本路径

| 测试 | 内容 |
|---|---|
| `sim/tb_units.sv` | 194 项基础模块回归 |
| `sim/tb_core.sv` | 系统级自校验 (`sim/prog/basic.S`) |
| `sim/tb_soc.sv` | SoC 级：外设 + UART 环回 (`sim/prog/mmio.S`) |

汇编：`python tools/asm.py sim/prog/<x>.S -o sim/prog/<x>.hex`
（asm.py 只有 t0–t6，**没有 t7**；`t7` 不是合法 RISC-V 寄存器名。）


---

# 8. 软件工具链与 CoreMark（2026-10-05 打通）

## 8.1 【最重要】哈佛结构要求双镜像

本核 imem(0x8000_0000) 与 dmem(0x9000_0000) 是两个独立地址空间，
**load/store 只能到达 dmem**。这条约束引发了两次真实故障：

| 症状 | 原因 |
|---|---|
| 数值能打印，但**所有字符串标签消失** | `.rodata` 留在 IMEM，`lbu` 读到 0（落进 MMIO 未映射地址） |
| `.data` 全变成 0 | crt0 用 `lw` 从 IMEM 的 `__data_lma` 搬运初值——**读不到** |

**正解**：`.text` 进 imem 镜像，`.data`/`.rodata` 的 VMA 就放在 DMEM，
初值由 **dmem 自己的初始化镜像**装入。crt0 只需清 `.bss`（`__data_lma == __data_vma`
时搬运循环自然空转）。
- 仿真：`+dmem=<file>`
- 综合：`DMEM_INIT_FILE` 宏

## 8.2 构建流程

```bash
python tools/build_sw.py sw/coremark/*.c -I sw/coremark \
    -D ITERATIONS=1 -D 'FLAGS_STR="-Os -march=rv32i -mabi=ilp32"' \
    -o sim/prog/coremark.hex
# 产出两个文件: coremark.hex (imem) 与 coremark.dmem.hex (dmem)
```

- `sw/crt0.S` 与 `sw/libc_min.c` 由 build_sw.py **自动包含**。忘了 crt0 会让
  `--gc-sections` 把整个程序回收掉，**静默产出 0 字节镜像**。
- `-nostdlib` 避免 newlib 膨胀，但**必须 `-lgcc`**：RV32I 无乘除法硬件，
  编译器会生成 `__mulsi3`/`__udivsi3` 调用。
- 用 `execFileSync` 传 argv，别用字符串拼 cmd——引号会被吃掉。

## 8.3 CoreMark 移植要点

- 基于 `barebones` 移植层。`ee_printf.c` 里的 `uart_send_char` 是带 `#error` 的桩，
  必须删掉并由 `core_portme.c` 提供（写 dmem 日志缓冲区）。
- `core_portme.h` 需 `#include <stddef.h>`（裸机下用编译器自带的 freestanding 头）。
- `CLOCKS_PER_SEC` **在 CoreMark 源码里没有定义**，必须自己给（= 主频）。
- `CORE_TICKS` 用 **64 位**：50 MHz 下 32 位约 86 秒溢出，而赛题要求跑 ≥10 秒。
- `MEM_METHOD=MEM_STATIC`、`HAS_FLOAT=0`、`MAIN_HAS_NOARGC=1`。
- 仿真里必然出现 `ERROR! Must execute for at least 10 secs` + `Errors detected`，
  **那是时长检查，不是算错**。看 `crclist/crcmatrix/crcstate/crcfinal` 是否等于官方值。

## 8.4 CoreMark/MHz 与主频无关

```
CoreMark/MHz = iterations / (ticks / f) / (f / 1e6) = iterations * 1e6 / ticks
```

**所以流水线优化的全部迭代都能在纯仿真里度量和验证**，不依赖 PDS、板卡或串口。
1 次迭代 ≈ 121 万周期，ModelSim 只要 **5 秒**。

## 8.5 当前基线（results/coremark.csv 追踪）

| 项 | 值 |
|---|---|
| **CoreMark/MHz** | **0.8263** (ticks=1,210,148, iters=1) |
| LUT / FF | 3499 / 732 |
| CoreMark/LUTs | 2.36e-4 |
| 隐含 fmax | 78.4 MHz |
| CRC | seedcrc/列表/矩阵/状态/最终 **全部等于官方值** |

一键复测：`python tools/run_coremark.py --tag <名字> --iterations 1 --record`


---

# 9. 分支预测与性能优化（2026-10-05）

## 9.1 优化前必须先测量

不要凭感觉优化。tb_sw.sv 里用**层次化引用**读 core 内部信号做剖析（纯仿真手段，不改 RTL）：

```systemverilog
if (!u_dut.if_id_flush && !u_dut.pipe_stall) n_fetch++;
if (u_dut.redirect) n_redirect++;
if (u_dut.pipe_stall) n_stall++;
if (u_dut.id_ex_ctrl.pc_sel == 2'd1) n_bcond++;     // PC_BR=1 PC_J=2 PC_JR=3
```

基线剖析结果（CoreMark，121 万周期）：

```
fetch 1,053,936 | redirects 184,890 (×2 拍 = 29% 周期!) | stalls 36,488 (2%) | CPI 1.21
条件分支 217,875 (taken 61%) = 全部指令的 20.7%
JAL 33,183  |  JALR(返回) 17,865
```

**分支惩罚 29% 是绝对瓶颈** → 先做分支预测，而不是 M 扩展或 BRAM。

## 9.2 BTB + Smith 预测器的要点

- `btb.sv`：直接映射，每项 {valid, tag, target, ctr[2]}，2 位饱和计数器。
- **预测结果必须随流水线传递**（IF/ID → ID/EX）。EX 时 pc 已跑到前面，无法重新查表，
  没有这一步就判断不了预测对错。
- **`redirect_raw` 要重定义为"预测错误"**，不是"分支 taken"。预测正确时若仍冲刷，
  两条正确路径被白丢，收益归零。
- **重定向目标 = 正确后继 PC**：实际 taken → 控制流目标；**不 taken → pc+4**。
  条件分支不 taken 时 `ex_pc_target` 是分支目标而不是后继，用它会把 PC 送进错误路径。
- tag 只需覆盖会变化的 PC 位（imem 16KB → `pc[13:8]` 共 6 位），不必存 24 位。

## 9.3 【最容易踩】JAL 链接值前递

`jal ra, f` 紧跟 `mv t0, ra` 是**距离 1** RAW。jal 在 EX/MEM 时：
- `ex_mem_alu_out` = **跳转目标**（不是链接值）
- `ex_mem_pc_plus4` = **链接值 PC+4**

**正确做法是按 wb_src 选前递源**：
```systemverilog
wire [31:0] ex_mem_fwd_data = (ex_mem_ctrl.wb_src == WB_PC4) ? ex_mem_pc_plus4
                                                            : ex_mem_alu_out;
```

**千万不要在 hazard_unit 里把 WB_PC4 整条前递路径排除掉** —— 那样消费者只能拿到
ID 段读到的陈旧 ra。这个错误**加预测之前被 2 拍冲刷掩盖着**（jal 后的指令被冲掉重取，
到 WB 时 ra 已写好），预测一生效立刻暴露，表现为 libgcc 的 `__umodsi3` 陷入死循环
（`jr t0` 自我跳回，2 拍无限循环）。

> 教训：**任何"今天触发不了"的防御性改动都可能在加新特性后变成真 bug。**
> 审查报告 §1.6 预言过这类问题，只是触发它的是分支预测而不是改重定向。

## 9.4 时序：关键路径与 P&R 指令

关键路径：`ex_mem_rd → hazard/前递 (fwd_b fanout 34) → ALU → 目标选择 → pc`

实测 **logic 仅 3.7ns，route 占 10~11ns（72~75%）** —— 是布局/扇出问题，不是逻辑深度。

| 构建流程 | fmax |
|---|---|
| synth/opt/place/route | 65.1 MHz |
| + `phys_opt_design` | 65.9 MHz（几乎无效） |
| + `place_design -directive ExtraTimingOpt` + `route_design -directive AggressiveExplore` | **70.1 MHz** ✅ |

**构建脚本必须包含 `place_design -directive ExtraTimingOpt` 与
`route_design -directive AggressiveExplore`**，见 fpga/build.tcl。

其他：**别在 pc 路径上现算 `id_ex_pc + 4`** —— 流水寄存器里已有 `id_ex_pc_plus4`，
现算会串进一个额外的 32 位加法器（实测 WNS 4.636→4.825）。

## 9.5 指标追踪

`results/coremark.csv` 每次优化追加一行；详细分析放 `results/*.md`。

| 版本 | CoreMark/MHz | LUT | fmax |
|---|---|---|---|
| baseline-v1 | 0.8263 | 3499 | 78.4 MHz |
| branch-pred-v1 | **1.0274** (+24.3%) | 3877 | 70.1 MHz (−10.6%) |

赛题记三项指标，**改动后要同时看三项**：CoreMark/MHz、fmax、CoreMark/LUTs。
branch-pred-v1 赢两项输一项，绝对吞吐 +4.5%。

**待还的技术债**：ALU 兼职 pc 目标加法器 → 把 ALU 全部运算结果的 mux 串在 pc 路径上。
给它一个独立的小加法器可显著缩短关键路径。


---

# 10. RV32M 与微架构迭代（2026-10-05）

## 10.1 指标总览（results/coremark.csv 追踪）

| 版本 | CoreMark/MHz | LUT | DSP | fmax | 绝对吞吐 |
|---|---|---|---|---|---|
| baseline-v1 (rv32i, 无预测) | 0.8263 | 3499 | 0 | 78.4 | 64.8 |
| branch-pred-v1 (BTB) | 1.0274 | 3877 | 0 | 70.1 | 72.0 |
| **m-ext-v2 (当前最优)** | **2.3614** | **4494** | 8 | **74.6** | **176.2 (+172%)** |

## 10.2 【铁律】赛题记三项指标，改一项要看三项

任何改动后**同时**量 CoreMark/MHz、fmax、CoreMark/LUTs。
本轮的 RAS 实验就是典型: CoreMark/MHz +1.0%, 但 fmax −4.6%、CoreMark/LUTs −4.4%,
绝对吞吐 −3.6% → **净亏, 回退**。

## 10.3 RV32M 实现的三个坑（全在除法时序/位宽上）

1. **余数必须 33 位**。恢复余数法要 `{rem[31:0], dvnd[31]}` 左移补位; 32 位时
   除数 > 2^31 会丢位。
2. **`busy` 必须覆盖"启动那一拍"**。只由"迭代中"标志驱动的话, 启动拍流水线不冻结,
   DIV 会在结果出来前离开 EX。症状: 有符号除法测试一上来就失败。
3. **单周期的除零/溢出同样要占一拍**。它们也要先寄存 `div_result` 再放行, 否则
   EX/MEM 在同一个时钟沿捕获到的是**上一次**的结果。症状: 除零测试失败。
   统一判据: `busy = 迭代中 || (是除法 && 结果尚未寄存)`。

**MULHSU 只需 2 个乘法器**:
```
signed(a)*unsigned(b) = signed(a)*signed(b) + signed(a)*(b[31] ? 2^32 : 0)
=> high32(MULHSU) = high32(prod_ss) + (b[31] ? a : 0)
```
`(a<<32)` 低 32 位为 0, 不向高位进位。

## 10.4 fmax: 乘法结果一定要寄存进 DSP

组合乘法直达写回时关键路径是
`hazard/前递 → DSP48E1×2 → 13 级 CARRY4 → EX/MEM` = 15.5ns (fmax 64.7)。
写法改成 `always @(posedge clk) p <= a*b;` → Vivado 推断 DSP 的 MREG/PREG:
**fmax 74.6 (+15%), 只让 CoreMark/MHz 2.2%** (每次乘法 +1 拍)。净赚。

## 10.5 BTB 目标位宽压缩（纯赚）

PC 恒在 imem 窗口内, **目标只需存低 PC_TOP(=14) 位**, 高位由 `IMEM_BASE` 补回。
64 项时每项从 41 位压到 23 位 → LUT 4551→**4494**。扩到 128 项也不会更贵
(但实测 128 项的 LUTRAM 输出树更深, fmax −4.6%, 不值)。

## 10.6 微架构开销账（优化前必做）

tb_sw 里用层次化引用量出停顿构成与预测精度:
```systemverilog
if (u_dut.u_hazard.load_use) n_stall_lu++;   // load_use 在 hazard_unit 内部
if (u_dut.lsu_stall) n_stall_ls++;
if (u_dut.md_busy)   n_stall_ex++;
if (u_dut.id_ex_ctrl.pc_sel != 0 && !u_dut.pipe_stall) n_ctrl++;
if (u_dut.redirect_raw) n_mis++;
```
当前账 (423,486 ticks): load-use 7.1% / 分支误判 5.4% / 乘除法 3.3%, 精度 89%, CPI 1.09。
**注意旧计数器标签会过时**: redirect 语义改成"预测错误"后, 原先叫 `n_br_taken` 的
计数器实际统计的是"被误判的条件分支"。

## 10.7 静默配置错误的教训

`build_sw.py` 曾把 `-march=rv32i` 硬编码。用 `-D FLAGS_STR=-march=rv32im` 只改了
CoreMark **打印的字符串**, 镜像逐字节相同。**暴露它的是"两次 ticks 完全一致"**。
现在有 `--march` 参数。
> 构建脚本里"报告性参数"和"生效性参数"必须分清; 指标异常一致时先怀疑没生效。


---

# 11. BRAM 存储系统（2026-10-05）

## 11.1 为什么必须把 dmem 改成寄存读

组合读**无法映射到 BRAM**, 只能落分布式 RAM。16KB 的 dmem 吃掉 **2131 个 LUT**
(占全核 4494 的 **47%**)。改成寄存读后:

| | 分布式 RAM | BRAM |
|---|---|---|
| Slice LUTs | 4494 | **2481 (−45%)** |
| LUT-as-Distributed-RAM | 2131 | 83 |
| Block RAM Tile | 0 | **4** |
| CoreMark/LUTs | 5.254e-4 | **9.518e-4 (+81%)** |
| Total ticks | 423,486 | **423,486 (零损失)** |
| fmax | 74.6 | 63.9 (−14%) |

**纯行为级推断, 不例化任何厂商 IP** —— Xilinx 36Kb 与紫光同创 18Kb 的 BRAM 原语不同,
例化就锁死了。行为级推断才能零成本迁移 PDS, 也是赛题高阶任务 (Cache) 的前置条件。

## 11.2 怎么做到零性能损失（4 个要点）

1. **把字节提取/符号扩展整体挪到 WB 段组合完成**。BRAM 的输出寄存器就充当了原来
   MEM/WB 里那份 load 数据的寄存器 —— 写回 mux 直接接 LSU 的 WB 拍组合输出,
   **不再经过第二个寄存器**, 所以既不加深流水线也不增加 load-use 停顿。
2. **WB 段影子寄存器** (`off_wb/size_wb/uns_wb/split_wb`) 在"访存请求离开 MEM"那一拍
   记下规格 (`(req_read||req_write) && !lsu_stall`)。WB 拍时 EX/MEM 已换成下一条指令,
   不能再读 `req_*` 算偏移/符号。
3. **MMIO 读数据也要在 core.sv 里寄存一拍**。内部 dmem 寄存了、外部 MMIO 没寄存,
   两条路径差一拍, 写回 mux 会取错。连 `sel_dmem` 一起寄存才对得齐。
4. **跨字访问状态机改成 IDLE→HEAD→TAIL 三拍** (原来两拍)。TAIL 拍 `lsu_stall=0` 且继续
   送尾字地址, 好让 WB 拍 `dmem_rdata` 仍是尾字。CoreMark 里跨字访问为 0。

## 11.3 【SystemVerilog 语法坑】不能对括号表达式做位选

```systemverilog
wire [31:0] x = (a >> b)[31:0];      // ✗ vlog-13069: unexpected '['
wire [63:0] t = a >> b;
wire [31:0] x = t[31:0];             // ✓ 必须先赋中间 wire
```

## 11.4 【真踩的 bug】store 的移位量不能用影子寄存器

`store_shifted` 必须用**当前请求**的 `off`, 不是 WB 影子的 `off_wb` —— 影子属于
上一条已进入 WB 的访存指令, 拿它移位会把数据挪错位置。
症状: 基础测试直接跑挂, **tohost 变成 0x40000**。

## 11.5 fmax 为什么退步, 以及还债方向

新关键路径:
```
Source:      u_core/u_dmem/mem_reg_3/CLKBWRCLK
Destination: u_core/u_pc/pc_reg[2]/D
Data Path:   15.245ns (logic 4.948, route 10.297, 18 levels, CARRY4=4)
```
即 **"load 出来的值直接当 jalr 目标"** (从栈恢复 ra 后返回, 极常见):
BRAM 输出 → 字节提取 → 写回 mux → 前递 mux → ALU 加法器 → 目标 mux → PC, 全在一拍内。

**根因**: 旧版提取逻辑在 MEM/WB 寄存器**之前**, 前递路径从寄存器出发; 新版把提取挪到了
寄存器**之后**, 它就落进了前递路径。

还债方向 (按代价排序):
1. **load 结果寄存器 + 专用前递通道**: 提取结果在 WB 拍末打进 `load_result`, 前递从它取。
   代价: load-use 停顿 1→2 拍, 约 +7% 周期。
2. **缩短 PC 目标选择链**: 给 JALR 目标加法器独立 2:1 操作数 mux (现在要穿 ALU 的
   3:1 `ex_a` mux), 三级目标 mux 压成一级 LUT6。
3. **dmem 保持组合读但缩容**: log 缓冲挪低, dmem 16KB→4KB, LUT-as-RAM 2131→约 530,
   fmax 不受影响 (但不是 BRAM)。

## 11.6 决策纪律

本轮是**三项里两项达到历史最好**（CoreMark/MHz 持平最好、CoreMark/LUTs +81% 最好）,
只有 fmax 退步。且 BRAM 是目标明确要求、是赛题高阶任务的前置条件 → 保留。
判断依据始终是 `results/coremark.csv` 里逐行记录的三项指标 + 绝对吞吐, 不凭感觉。


---

# 12. 上板自主读回（2026-10-05）

## 12.1 核心思路: 软件上报 + ILA over JTAG

本板串口收不到数据 (FT2232H 只有 D2XX 无 COM 口), 所以"跑完了吗/多少周期/算对了吗"
靠 **MMIO 上报 + ILA 抓取 + JTAG 读回**。新增两个 MMIO:
- `MMIO_MARK` (0xA0000020): W, 单拍脉冲 -> ILA 触发点
- `MMIO_RESULT` (0xA0000024): W/R, 锁存结果

**一个 32 位打包两件事**: bit31 = CRC 判定, bit30:0 = tick 数。

## 12.2 【关键】用与迭代次数无关的量做判据

`crclist/crcmatrix/crcstate` 与 ITERATIONS **无关** (实测 1 次与 3 次完全一致);
只有跨迭代累积的 `crcfinal` 会变。所以 10 秒要求改了迭代次数后, 仍可用这三个
数据类 CRC 判定硬件算得对不对。

## 12.3 四个坑

1. **CoreMark 的 `exit()` 根本没被调用** —— 程序靠 crt0 在 main 返回后写 tohost 结束。
   放在 exit() 里的上报是**死代码** (反汇编里查不到那条 sw)。改放 `stop_time()`。
2. **Tcl 的 `[...]` 内换行是命令分隔符, 不是列表分隔符** ——
   `add_files -norecurse [list \\
 "a.sv"
 "b.sv" ]` 会在第一个元素后结束,
   后面的被当成命令执行。**文件列表写在一行**。
3. **两个 Vivado 实例重叠会让 IP 生成器初始化失败** (`::ipgen_iptclns` / 谎报
   `pkgIndex.tcl` 缺失)。构建必须串行化, 并设 `XILINX_VIVADO`。
4. **`results[]`/`total_time` 是 main() 的局部变量** —— 跨文件拿不到,
   要在 core_main.c 里加 extern 全局。

## 12.4 内存布局 (改动面比想象大)

```
0x90000000 .. 0x90001FFF   .data / .bss   (8KB)
0x90002000 .. 0x90002003   tohost
0x90002004 .. 0x90002BFF   栈 (顶 0x90002C00)
0x90003000 .. 0x90003FFF   日志缓冲区
```
CoreMark 的 .data+.bss 正好用满 4KB, 加 12 字节就溢出, 所以 tohost 从 0x1000 上移到
0x2000。**必须同步改**: link.ld (PROVIDE+ASSERT)、portme.c、crt0.S、core_portme.c、
top_a100t.sv、三个 tb 的 TOHOST_ADDR、以及 sim/prog/*.S 里硬编码的 tohost (19 处)。
症状: 程序跑到 `j .` 自旋, tb 报超时。

## 12.5 ILA 构建 (工程模式)

非工程模式的 `create_ip` 容易出问题, 用 `fpga/build_ila.tcl` 走工程模式:
`create_project` -> `add_files` -> `create_ip ila` -> `launch_runs synth_1/impl_1`。
ILA 只在 `USE_ILA 时例化在顶层, **CPU core 不含任何厂商 IP**, 正式构建不带 ILA。

探针: probe0=dbg_pc, probe1=dbg_instr, probe2={done,mark,redirect,stall,illegal,pass,fail},
probe3=score_result。抓取脚本 `fpga/ila_cap_mark.tcl` / `ila_cap_done.tcl`。
