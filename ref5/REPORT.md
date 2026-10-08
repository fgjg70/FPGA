# ref5 — 普通五级 RV32I 参照核 · fmax 测量报告

**器件**：`xc7a100tfgg484-2`（与主核同一颗、同一速度等级）
**口径**：非工程模式，`create_clock -period 20.000`，`fmax = 1000 / (20 − WNS)`
**流程**：`synth_design -resource_sharing off` → `opt_design` → `place_design -directive WLDrivenBlockPlacement`
→ `route_design`（默认 directive）→ `report_timing_summary` / `report_utilization`
**日期**：2026-10-08　**作者**：RTL 实现（子会话）

---

## 0. 结论摘要（先看这三行）

| 口径 | fmax | WNS | 说明 |
|---|---|---|---|
| **最终版（推荐标尺）** | **137.25 MHz** | **+12.714 ns** | 4KB+4KB 存储器、Pblock `X1Y0:Y3`、V7 RTL |
| 最终版 RTL + 主核同档存储器（16KB+16KB） | **118.57 MHz** | +11.566 ns | 只有存储器几何不同 |
| 规范字面版（16KB、无 Pblock、最"笨" RTL） | **102.47 MHz** | +10.241 ns | V1 基线 |

> **一句话**：教科书式普通五级 RV32I（无前递、无预测）在这颗器件上大约能跑到
> **100–140 MHz**；瓶颈**不是 ALU，而是取指存储器的 clk-to-out + 冒险判定回灌到
> imem 地址脚这条环**（最终版 6.76 ns，其中布线占 62%）。
> 对照：同一颗器件上"做满优化"的主核（前递 + BTB + CSR/trap + MMIO + 宽控制束）
> 实测 **69.8 MHz**。两者之差就是那些功能的价格。

---

## (a) `ref5/` 文件清单

| 文件 | 作用 |
|---|---|
| `ref5/ref5_core.sv` | **五级流水 RV32I 核**（单文件、自带局部 localparam、不 import rv32_pkg）。无前递/无预测/无 M·A·CSR·trap；冒险靠"停顿+气泡"；分支在 EX 判定即冲刷。当前 = **最终版 V7**。 |
| `ref5/ref5_top.sv` | 顶层 + 两个存储器模块：`ref5_imem`（同步读→RAMB36）、`ref5_dmem`（同步读 + 字节写使能→RAMB36）。存储器内容用**地址相关常量模式**初始化（防止"内容全同的 ROM 被常量折叠"，那样 BRAM 会从关键路径上消失、fmax 就假了）。默认 4KB/4KB，`REF5_BIG_MEM` 切 16KB/16KB。 |
| `ref5/ref5.xdc` | 唯一约束：`create_clock -period 20.000 [get_ports clk]`（与主核同口径）。 |
| `ref5/build_ref5.tcl` | 独立非工程模式构建脚本。默认即**最优配置**（Pblock `CLOCKREGION_X1Y0:X1Y3`、WLDrivenBlockPlacement、Default route、4KB 存储器）；全部可被环境变量覆盖（`REF5_TAG` / `REF5_PBLOCK` / `REF5_PBLOCK_CELLS` / `REF5_PLACE_DIR` / `REF5_ROUTE_DIR` / `REF5_PHYS_OPT` / `REF5_BIG_MEM`）。跑完自动打印 WNS、fmax、前 8 条路径、LUT/FF/BRAM 计数，并把报告写到 `ref5/timing.rpt`、`ref5/util.rpt`。 |
| `ref5/timing.rpt` / `ref5/util.rpt` | **最终版**的时序/资源报告（= `runs/final/` 的两份）。 |
| `ref5/runs/<tag>/{timing,util}.rpt` | 每个版本的报告原件（v1…v12-big16k、final 共 13 组），对照表的原始证据。 |
| `ref5/logs/<tag>.log` | 每个版本的完整 Vivado stdout（含 `REF5_*` 关键数字行）。 |
| `ref5/probe_regions.tcl` | 秒级器件资源普查（列出 8 个时钟区域各有多少 SLICE/DSP；BRAM 站点不在该查询口径内）。 |
| `ref5/REPORT.md` | 本文件。 |

跑法（Vivado 不在 PATH）：

```powershell
$env:PROCESSOR_ARCHITECTURE="AMD64"
# 最终版（默认配置，一条命令即可复现 137.25 MHz）
& "D:\software\Learn\Xilinx\Vivado\2018.3\bin\vivado.bat" -mode batch -nojournal -nolog `
  -source D:\USER\Desktop\FPGA\FPGA\ref5\build_ref5.tcl
# 规范字面版（16KB / 无 Pblock）
$env:REF5_PBLOCK="off"; & ... -source ...\ref5\build_ref5.tcl
```

**纪律确认**：`ref5/` 之外**零改动**（未动 `fpga/build.tcl`、`tools/`、根目录 `*.sv`；未 commit、未切分支）。
`ref5/` 内的 `runs/`、`logs/`、`.Xil/`、`vivado*.jou` 都是 Vivado 生成物，仅为留证。

---

## (b) fmax 对照表（每一版都是实测）

| # | 版本 / 改动 | fmax (MHz) | WNS (ns) | LUT | FF | BRAM | 关键路径一句话 |
|---|---|---|---|---|---|---|---|
| V1 | **基线**：16KB+16KB、无 Pblock、无任何优化 | 102.47 | 10.241 | 885 | 396 | 8 | imem BRAM 输出 → 冒险比较 → pc mux → **imem 地址脚**（5 级，route 6.58/9.23 ns = 71%） |
| V2 | V1 + Pblock `X1Y0:X1Y3` | 108.97 | 10.823 | 885 | 396 | 8 | 同上（route 5.99 → 同一条路少走 0.6 ns） |
| V3 | V2 + **存储器 4KB/4KB**（各 1 块 RAMB36） | 117.33 | 11.477 | 879 | 396 | 2 | 同上（地址网只驱动 1 个 BRAM，route 5.35） |
| V4 | V3 + **RTL 卫生**：ALU 操作数在 ID 预选、冒险判定扁平化成 6 项 OR、`-resource_sharing off`、`max_fanout=16` | **126.49** | 12.094 | 853 | 457 | 2 | `id_ex_rs2` → 32 位比较 → redirect → 冒险 → pc mux → imem 地址（10 级！） |
| V5 | V4 + **分支判定搬到 ID**（1 位结果进流水线） | **111.09 ✗** | 10.998 | 851 | 457 | 2 | imem 输出 → **LUTRAM 读** → 32 位比较 → `id_ex_br_taken`（6 级，8.73 ns）—— ID 段被压垮 |
| V6 | V4 + **把 redirect 从冒险路径摘掉**（mux 优先级代替 `!redirect` 折进使能） | **131.80** | 12.413 | 858 | 457 | 2 | imem 输出 → 冒险 → `id_ex` 控制位 D（5 级）；取指地址那条降到 3 级 |
| **V7 = 最终** | V6 + **只寄存 1 位气泡标志**，ID/EX 控制束不再挂 `id_ex_en` mux | **137.25** | **12.714** | 852 | 458 | 2 | **imem BRAM 输出 → 冒险比较 → pipe_stall → 取指地址 mux → imem 地址脚（4 级，6.76 ns，route 62%）** |
| V8 | V7 + `phys_opt_design AggressiveExplore`（布局后+布线后各一次） | 137.25 | 12.714 | 852 | 458 | 2 | **与 V7 逐位相同 —— phys_opt 完全没动它** |
| V9 | V7 + Pblock 收紧到单个时钟区域 `X1Y1` | **129.20 ✗** | 12.260 | 852 | 458 | 2 | 同类路径，route 变长（与主核"收紧更差"的结论一致） |
| V10 | V7 + `place -directive ExtraTimingOpt` | **134.10 ✗** | 12.543 | 852 | 458 | 2 | 同类路径，3 级但 route 4.49 |
| V11 | V7 + `route -directive AggressiveExplore` + phys_opt | **135.30 ✗** | 12.609 | 852 | 458 | 2 | 关键路径**换到 ALU**：`id_ex_b` → ALU → EX/MEM（5 级，route 6.23） |
| V12 | 最终版 RTL + **16KB/16KB**（主核同档存储器规模） | 118.57 | 11.566 | 856 | 458 | 8 | `id_ex_b` → ALU → EX/MEM（5 级，route 7.28/8.46 = 86%） |

> 单位口径：LUT = `Slice LUTs`，FF = `Slice Registers`，BRAM = `Block RAM Tile`（都是 `util.rpt` 的官方行）。
> V1–V3 的 396 FF 少 60 位是因为还没有"预选操作数"那两份寄存器；V4 起为 457/458。
> **最终版可复现性**：`final` 与 `v7` 两次独立运行的数字**逐位相同**（WNS 12.714、LUT 852、FF 458、路径同一条）。

---

## (c) 最终版（V7）完整分解

### 数字

```
WNS   = +12.714 ns      (TNS 0.000, 1165 个端点，0 失败)   → fmax = 1000/(20−12.714) = 137.25 MHz
WHS   = +0.130 ns       (0 个 hold 失败)
资源  = Slice LUTs 852（LUT as Logic 804 / LUT as Memory 48）
        Slice Registers 458
        Block RAM Tile 2（RAMB36 ×2：imem ×1 + dmem ×1；参考核 16KB 版是 ×8）
        LUTRAM：RAMD32 ×72 + RAMS32 ×24（寄存器堆 2 读 1 写，零 BRAM）
        DSP 0
```

### 关键路径（`ref5/timing.rpt`，一字不改）

```
Slack (MET) :  12.714 ns
Source:      u_imem/rdata_reg/CLKARDCLK          <- imem 的 BRAM 输出寄存器 (RAMB36_X3Y10)
Destination: u_imem/rdata_reg/ADDRARDADDR[11]    <- 同一个 BRAM 的地址脚
Data Path:   6.760 ns  (logic 2.545 = 37.6% | route 4.215 = 62.4%)
Logic Levels: 4  (LUT6=4)

RAMB36  CLKARDCLK -> DOADO[15]            2.125   6.612   BRAM clk-to-out（固定硅延迟，无法优化）
net (fo=41)                               1.515   8.127   u_imem/DOADO[15]   <- 输出网扇出 41
LUT6  id_ex_bubble_i_14                   0.105   8.232   hit 项（5 位比较 + 使能，1 个 LUT6）
net (fo=1)                                0.510   8.742
LUT6  id_ex_bubble_i_6                    0.105   8.847   hit 项
net (fo=2)                                0.497   9.343   hit[4]
LUT6  id_ex_bubble_i_2                    0.105   9.448   6 项 OR -> pipe_stall
net (fo=16)                               0.973  10.421   u_core/pipe_stall
LUT6  pc[8]_i_1                           0.105  10.526   取指地址 mux（redirect > fetch_hold > pc+4）
net (fo=2)                                0.722  11.247   u_imem/D[6]
RAMB36                                     -     11.247   ADDRARDADDR[11]
```

**这条环的构成**：`指令被取出来 → 用它自己的 rs1/rs2 判 RAW → 决定这条指令要不要停 →
停下就得把取指地址摁住 → 地址回到同一个 BRAM`。它是**无前递设计的固有回路**：
冒险判定必须在"指令已经出来"之后、且在"下一个时钟沿的地址建立"之前完成。

### 前 8 条路径（都是一个家族 —— 说明关键路径没有旁落）

```
TOP1 12.714  L=4  u_imem/rdata_reg/CLKARDCLK -> u_imem/rdata_reg/ADDRARDADDR[11]
TOP2 12.785  L=4  ...                                        ADDRARDADDR[10]
TOP3 12.970  L=4  ...                                        ADDRARDADDR[13]
TOP4 12.978  L=4  ...                                        ADDRARDADDR[12]
TOP5 13.042  L=4  ...                                        ADDRARDADDR[8]
TOP6 13.043  L=4  ...                                        ADDRARDADDR[7]
TOP7 13.071  L=4  ...                                        ADDRARDADDR[14]
TOP8 13.089  L=4  ...                                        ADDRARDADDR[9]
```
（12 条地址线分布在 0.4 ns 内 —— 说明瓶颈是**这一整条环**，不是某一位的偶然。）

### 逻辑分解：这一版为什么快

最终版把这条环压到 **4 级 LUT**（理论上限附近）：

1. **6 个 hit 项各 1 个 LUT6**：`(rs1==rd) && wr_en` 正好 5+1 = 6 个输入；
2. **6 项 OR 再 1 个 LUT6** → `pipe_stall`（V4 的扁平化）；
3. `fetch_hold ? pc : …` 与 `redirect ? ex_target : …` 被综合器合并进**每一地址位 1 个 LUT6**；
4. `redirect` 不再串进冒险逻辑（V6），`ID/EX` 控制束也不再挂在冒险逻辑上（V7，只留 1 位气泡标志）。

剩下的 6.76 ns 里真正"不可动"的只有 **BRAM clk-to-out 的 2.125 ns**，
其余 4.6 ns 基本是**布线**（BRAM 输出网 fo=41 一跳 1.5 ns；地址 mux → BRAM 地址脚 0.7 ns）。

---

## (d) 试过但**没用**（负结果，同样重要）

| 手段 | 结果 | 数据/原因 |
|---|---|---|
| **分支判定提前到 ID 并寄存**（V5） | **−26 MHz ✗** | 111.09 vs 126.49。虽然把 32 位比较从 EX 摘掉了，但 ID 段变成 `imem 输出 → LUTRAM 读 → 32 位比较 → FF`，反而更长（8.73 ns） |
| **Pblock 收紧到单个时钟区域**（V9） | **−8 MHz ✗** | 129.20 vs 137.25，"收紧更差"在主核上也复现过；本项目 921 LUT 仍需要 4 个时钟区域的布局自由度 |
| `place_design -directive ExtraTimingOpt`（V10） | **−3.2 MHz ✗** | 134.10 vs 137.25（同 Pblock、同 RTL） |
| `route_design -directive AggressiveExplore` + phys_opt（V11） | **−2 MHz ✗** | 135.30 vs 137.25；还**把关键路径推到 ALU** 上（`id_ex_b → ALU → EX/MEM`，route 6.23 ns） |
| `phys_opt_design -directive AggressiveExplore`（V8） | **0（逐位相同）✗** | WNS/路径/LUT/FF 一模一样，等于没跑 |
| 把 `!redirect` 折进冒险使能（V4 的一步） | **反噬** | 当时看是"扁平化"，实际造出 `比较 → redirect → hit → pipe_stall → 地址` 一条 10 级的路，V6 才拆掉 |
| 16KB/16KB 存储器（V12，主核同档） | **−18.7 MHz** | 118.57 vs 137.25：8 块 RAMB36 把逻辑摊开，ALU 那条路的布线涨到 7.28 ns（86%） |

**没来得及试的（留给下一轮）**：
① 用 BRAM 的 **ENARDEN 保持读输出**代替"地址 mux"（可再砍掉取指环最后一级，预期 +5~10 MHz）；
② **JALR 之外的目标在 ID 段预算好并寄存**（把 32 位加法器移出 EX→pc 的路）；
③ ALU 结果 mux 分层（V11/V12 显示 ALU 那条路只差 0.3~0.7 ns 就并列，值得压平）。

---

## (e) 一句话结论

**普通五级 RV32I（无前递/无预测/无 M·A·CSR·trap）在 XC7A100T-FGG484-2 上的 fmax 上限约
100–140 MHz**：最"笨"的规范字面版 102 MHz，同 RTL 换小存储器 + Pblock 到 **137.25 MHz**；
若坚持主核同档的 16KB 存储器规模则是 **118.6 MHz**。
**它和"做满优化"的差距（137 vs 主核 69.8 MHz）主要来自**：

1. **数据前递网络** —— 主核最贵的一条路（`dmem 输出 → LSU 提取 → 写回 mux → 前递 mux → ID/EX`）。
   ref5 用"停 3 拍"换掉了它，代价是 CPI，收益是整条路消失（本设计里 load 数据只需走到寄存器堆写口）。
2. **分支预测（BTB）** —— 有预测才敢让"分支比较 → 重定向 → 取指地址"这条路存在；
   ref5 里这条路的替代品是"比较 → redirect → 地址 mux"，实测它一度（V4）就是最坏路径。
   预测器本身又反过来给取指地址加了一级 LUTRAM 读 + 目标 mux。
3. **宽控制束 / CSR / trap / MMIO / 中断** —— 控制束每加宽一位，就多一份要在"冒险逻辑"
   与"ID/EX 控制位"之间穿行的布线；trap/中断还要把 EX 段的重定向做成多源 mux。
4. **存储器规模与物理约束** —— 单这一项在这颗器件上就有 ~19 MHz 的差别（V7 vs V12），
   说明 100T 上"逻辑放哪、BRAM 放哪"与 RTL 同等重要。

**给后续优化的标尺**：任何改动要算收益，请用同一条口径
（`xc7a100tfgg484-2` + `create_clock -period 20.000` + `fmax = 1000/(20−WNS)`）对标
**137.25 MHz**（ref5 最终版）；主核当前 69.8 MHz 与它之间那 2× 就是上面四项的价格。

---

### 附：本报告没有做的事（诚实边界）

- **没有做功能仿真、没有跑程序**（任务明确不要求）。正确性是设计推理 + 逐项检查得出的，
  **未经仿真验证**；`ref5/` 里的存储器内容只是防止常量折叠的伪随机模式，不是程序镜像。
  → 这个核的用途是 **STA 标尺**，不是可运行核。
- 没有上板、没有 ILA、没有 `write_bitstream`（fmax 由 STA 得出，按任务要求）。
