> **范围/口径声明（证据/迭代文档）**：本文是开发迭代记录或证据文档，"实测"特指上板实测（附日志/清单路径），"派生/仿真"已分别标注。**Artix-7 XC7A100T 的所有数据按赛题规则仅作跨厂商对比**，交付主体为紫光同创 PG2L100H；完整边界见根 [`COMPLIANCE.md`](https://github.com/fgjg70/FPGA/blob/main/COMPLIANCE.md)。

# RVCoreP 源码拜读指南

> **源码位置**（已从实验 scratch 整理出来，保留原样）：`D:\USER\Desktop\FPGA\refs\RVCoreP\`
> - `v0.53\` —— 最新版（**建议读这版**）
> - `v0.46\` —— 前一个版本，可作 diff 对照
> - `2010.16171-论文全文.txt` —— 论文纯文本（arXiv:2010.16171）
>
> 许可：**MIT**（`LICENSE.txt`，Tokyo Tech Arch Lab）。
> 项目主页：<https://www.arch.cs.titech.ac.jp/wk/rvcore/doku.php>

---

## 0. 一句话认识它

**RVCoreP = 东京工业大学 Arch Lab 的五级流水 RISC-V 软核，全部 783 行塞在 `proc.v` 一个文件里。**
它最大的价值是"**极简但完整**"：没有厂商 IP（除时钟向导）、没有分层目录，一个文件里把
`regfile / IMEM / DMEM / BTB / PHT / ALU / 流水线 / 译码器` 全写完，非常适合**逐行通读**。

论文 `2010.16171` 的核心卖点（我们此前调研过，见 `results/rvcorep-vs-ours.md`）：
在 **xc7a100tcsg324-1**（速度档 -1，比我们的 -2 慢）上把 RV32I 跑到 **174/164 MHz**（4KB/64KB 存储）。

## 1. 文件导览（v0.53，按重要性排序）

| 文件 | 大小 | 作用 | 要不要读 |
|---|---|---|---|
| **`proc.v`** | 33.4 KB / **783 行** | **整个处理器**：13 个 module 全在这里 | ★★★ 必读 |
| **`config.vh`** | 3.6 KB / 86 行 | 全部编译开关与常量（存储大小、串口、UART 队列、BTB 等） | ★★★ 先读 |
| `main.v` | 9.3 KB | 板级顶层：时钟向导、复位、LED/七段、UART | ★★ 第二遍读 |
| `top.v` | 11.7 KB | 纯仿真 testbench（时钟/复位/初始化/USB 串口喂程序） | ★ 需要仿真时读 |
| `debug.v` / `uart.v` | 5.3 / 4.7 KB | 调试输出 / UART 收发 | 用到再看 |
| `result.txt` | 18.4 KB | **作者自己的实测**：Dhrystone IPC **0.929**、分支命中率 **0.916**、load-use 停顿 90,177 | ★★ 很有参考价值 |
| `bench/` `embench/` `test/` | — | 基准程序的 `.mem` 镜像与测试 | 要复跑时用 |
| `Makefile` | 11.4 KB | 仿真/综合/下载流程（Verilator + Vivado） | ★ 想复跑时读 |

## 2. `proc.v` 的 module 地图（按行号）

```
L  35  regfile          寄存器堆 —— 注意 L46-47：写回同一拍就用 wdata 旁路，省掉 WB→ID 的 RAW
L  54  m_IMEM (sync)    指令 MEM，(* ram_style="block" *)，同步读
L  74  m_IMEM (async)   异步读版本（D_SYNC_IMEM 开关切换）
L  96  m_DMEM (sync)    数据 MEM，含字节对齐/掩码
L 137  m_DMEM (async)
L 180  m_BTB            **分支目标缓冲**：valid(1)+tag(7)+data(18)+cnt(2) = 28bit
L 197  m_PHT            **模式历史表**（两位饱和计数器数组）
L 225  m_ALU (simple)   用 case 写的简化 ALU（D_SIMPLE_ALU）
L 265  m_ALU            真正的 ALU（含 BRU 的 bsel 7 位选择）
L 298  RVCore            ★★★ **主体：五级流水线（L298–L671，约 374 行）**
L 672  decoder_id       ID 级译码器（指令 → 控制信号）
L 756  decoder_if       IF 级译码器（预译码，给分支预测/前端用）
```

## 3. 建议阅读顺序（5 步，约 2~3 小时）

### 第 1 步：`config.vh`（10 分钟）
看清楚**哪些是编译开关**，这决定了你读 `proc.v` 时哪些 `ifdef` 分支是活的：
- `D_SYNC_IMEM` / `D_SYNC_DMEM` —— 同步 vs 异步存储（决定关键路径形态）
- `D_SIMPLE_DFWD` —— 单级数据前递（第 10 行，`proc.v` 里直接 `define` 打开）
- `D_SIMPLE_BTB` —— 单周期 BTB vs 两周期版本（**这是他们 fmax 的关键开关之一**）
- `MEM_SIZE` 默认 **4 KB**（论文里 4KB 那组的数字就是它）
- `SERIAL_WCNT` —— UART 等待计数（= 主频 / 波特率）

### 第 2 步：`RVCore` 的**接口与流水寄存器**（L298–L386）
先只看**数据宽度**，不看逻辑。会看到两个"反常识"但很关键的设计：
1. **PC 是 18 位、按"字"编址**（`reg [17:0] r_pc`）：PC 直接当 IMEM 的字地址用，
   省掉"字节地址 → 字地址"的移位/截断逻辑 —— 这是本核省面积/省路径的一个典型手法。
   代价是地址空间被限制在 1 MB（18 位字地址 = 2^18×4B）。
2. **四组流水寄存器**：`IfId_*`(L310) / `IdEx_*`(L327) / `ExMa_*`(L351) / `MaWb_*`(L374)，
   每组都带一个 `_v`（valid）位 —— 那是他们做 flush/stall 的方式（不是单独的清零网络）。

### 第 3 步：`RVCore` 的**流水控制**（L387–L470 左右）
重点看三行：
```verilog
wire w_stall = IdEx_luse;                    // L387: load-use 停顿 = 只有一个信号
wire w_btkn  = (w_btkn_t & w_pht[1]);        // L395: BTB 说跳 + PHT 两位计数器的方向
wire [15:0] w_npc = (w_bmis) ? w_pc_true[17:2] : (w_stall) ? r_pc[17:2] :
                    (w_btkn) ? w_btb[19:4]     : r_pc[17:2]+1;   // L397-398: 下一拍 PC 的三选一
```
**这就是全核的分支预测 + 停顿的全部**：没有单独的 hazard unit、没有 forward unit 模块，
全用 `wire` 拼出来。对比我们的实现（`hazard_unit.sv` + 一堆 `_pre` 预选），
他们的风格是"**能用一个 wire 表达就不建模块**"，代价是可读性要靠注释。

### 第 4 步：`decoder_id` / `decoder_if`（L672–L783）
看他们怎么把"译码"拆成**IF 级预译码**（给前端算 NPC/预测用）+ **ID 级完整译码**（给执行用）。
这与我们的 `control_unit.sv` 单级译码不同 —— 他们宁可多一份组合逻辑，换取 IF 级就能判断"是不是控制流指令"。

### 第 5 步：`main.v` + `top.v`（板级与仿真）
- `main.v`：`clk_wiz_0`（相当于我们的 MMCM 原语）、`r_rst <= !w_locked`（**和我们的 R43 同款**复位同步思路）、
  UART 串口喂程序（`NO_SERIAL` 开关决定是从串口初始化 IMEM 还是 `$readmemh`）。
- `top.v`：纯仿真用，`initial forever #50 CLK = ~CLK`（10 MHz 仿真时钟）。

## 4. 三个可以直接借鉴的点

| RVCoreP 的做法 | 我们能学什么 |
|---|---|
| **PC 按字编址（18 位）** | 我们的 PC 是字节地址，前端要 `pc>>2` 取指令地址。改成字地址能省一级逻辑（**但要小心 JALR 的 +imm 语义**） |
| **regfile 同拍旁路**（L46-47：`rs==rd ? wdata : mem[rs]`） | 我们用 WB→ID 前递解决，他们直接在寄存器堆读口做 mux —— 少一级前递选择 |
| **单文件 783 行、13 个 module** | 我们是 21 个文件 / 5115 行、分模块 + 断言。**评审/迁移时"一眼能读全"是优势**；他们也证明了"极简也能上 174 MHz" |

## 5. 与我们核的对比（详细版见 `results/rvcorep-vs-ours.md`）

| 项 | RVCoreP（论文 Table I） | 我们（当前交付） |
|---|---|---|
| 器件/速度档 | xc7a100tcsg324 **-1** | xc7a100t-fgg484 **-2** |
| fmax（RV32I，4KB/64KB） | **174 / 164 MHz** | — |
| fmax（RV32IM radix-4 / DSP） | **169 / 162 MHz** | **150.2 MHz**（RV32IM + 双预测器 + A 扩展） |
| CoreMark/MHz | ~2.3（论文口径） | **2.1613**（实测 tick） |
| 代码规模 | 783 行 / 1 文件 | **5115 行 / 21 文件** |
| 分支预测 | BTB + PHT（两位计数器） | **512 BTB + 8192 PHT（gshare，两级流水）** |
| 面积 | 更小（无 debug 基础设施） | LUT 3098 / FF 1447 / BRAM 9 / DSP 8 |

> ⚠ 注意：**-1 vs -2 速度档差约 15~20%**，所以"174 vs 150"不能直接比；同档换算后两者其实接近，
> 但我们多了 A 扩展 / 精确中断 / ILA 探针等基础设施，面积也更大。**公平对比需要同档重跑**（这是竞赛计划里的待办）。

## 6. 怎么快速验证读懂了

读完后试着回答这 4 个问题（答案都在上面标的行号里）：
1. `w_stall` 为什么只需要 `IdEx_luse` 一个信号？（提示：load 的数据什么时候可用、用了哪个前递）
2. `r_pc` 为什么是 18 位而不是 32 位？这个选择限制了哪些东西？
3. `m_BTB` 里 `cnt(2bit)` 是干什么用的？（提示：和 `w_btkn` 的两个条件有关）
4. `regfile` 的 `rs1==rd ? wdata : mem[rs1]` 在什么情况下会读到**旧值**？（提示：写使能同拍）

---

*本指南由 Lead 整理；源码保留在 `refs/`（不进 git，因为它是上游 MIT 源码，可重新下载）。
要重新获取：`git clone` 上游仓库或用论文页面链接。*
