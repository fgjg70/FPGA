> **范围/口径声明（证据/迭代文档）**：本文是开发迭代记录或证据文档，"实测"特指上板实测（附日志/清单路径），"派生/仿真"已分别标注。**Artix-7 XC7A100T 的所有数据按赛题规则仅作跨厂商对比**，交付主体为紫光同创 PG2L100H；完整边界见根 [`COMPLIANCE.md`](COMPLIANCE.md)。

# RVCoreP-32IM vs 本核：**双方不足记录**

> **文档定位**：用户要求"把双方的不足之处记录在案"。所以本文件**两边都写**，且**不写成"我们更好"的宣传稿** ——
> 每处更强/更弱都给出可核对的数字。
>
> **强制纪律（每条目成立的前提）**：所有判断必须带**数字 + 来源**。来源代号见文末 §7「来源代号」。
> 无来源的形容词（"较好/一般/有差距"）一律不写；凡论文/简报里流传但**归档材料里复算不出来**的数字，
> 在 §4「口径存疑与更正」里单独留痕，**不改动也不掩盖**。
>
> **第三方代码纪律**：RVCoreP-32IM 为 MIT 许可的第三方工程（`rvcorep_ver046` / `ver053`），
> 本文件**只读**引用其**文件名:行号**与**端口/参数宽度**作为证据，**不复制其任何一行代码、不将其加入 git**。
>
> 撰写时间：2026-10-11。本核一侧数字的冻结基线 = `clk75`（`.fpga-cache/reports/20261011-121231-cm_hw/`，2026-10-11 12:12）

---

## 1. 并排对照表

> 每格右下角的 `[x]` 是来源代号；**同一次比较必须用同一列口径**（他们的 162 MHz 是 **64KB** 配置，不是 4KB 的 169/174）。

| 项目 | **RVCoreP-32IM**（arXiv 2010.16171） | **本核**（clk75 交付配置） | 差距（本核 / 他们） |
|---|---|---|---|
| **fmax** | **162 MHz** @64KB（`-1` 器件 `xc7a100tcsg324-1`）`[P6-T1][P6]` | **76.18 MHz**（`sys_clk_75` @13.333 ns，WNS **+0.206**；`-2` 器件 `7a100t-fgg484`）`[M][TR]` | **0.470×**（−53.0%） |
| **Slice LUT** | **1338**（64KB）/ 1331（4KB）`[P6-T1]` | **2734**（LUT as Logic 2651 + as Memory 83）`[U]` | **2.04×** / 2.05× |
| **Slice Register (FF)** | **903**（64KB）/ 901（4KB）`[P6-T1]` | **1251** `[U]` | **1.39×** |
| **Slice（占用 Slice 数）** | **539**（64KB）/ 487（4KB）`[P6-T1]` | **846** `[U]` | **1.57×** |
| **DSP48** | **4** `[P6-T1]` | **8** `[U]` | **2.00×** |
| **CoreMark/MHz** | **2.33**（RV32IM-DSP）/ 1.69（radix-4）/ **0.84**（RV32I）`[P9-T4]` | **2.4209**（仿真 tick 413070/1 iter）；上板 **2.4212** `[M][CSV:168][README:59]` | **1.039×**（+3.9%） |
| **IPC（CoreMark）** | **0.825**（coremark3，官方源码自带 `result.txt`）`[RT:30]`；test.mem **0.825** `[WIKI]` | **0.877**（= 402,723 拍发指 / 459,460 拍；重算）`[TB:29,49]` | **1.063×** |
| **分支预测命中率** | **79.7%**（coremark3）`[RT:34]`；**71.6%**（test.mem）`[WIKI]` | **88.77%**（=(102656−11530)/102656；日志自印"89%"是取整）`[TB:63,64]` | **+9.1 / +17.2 pt** |
| **load-use 代价** | **2 拍气泡**（"we did not include the load data into the forwarding path"，自述的自觉代价）`[P3]` | **1 拍气泡**（EX/MEM 前递排除 load，但 **MEM/WB 前递包含 load 数据**，故 1 拍即可取到）`[HAZ:70,96-103][TU R9]` | 本核省 1 拍 —— **但这是用关键路径换的**，见 §3.4 |
| **load-use 停顿占比** | **1.93%**（172,136 / 8,900,524 拍，coremark3）`[RT:28,35]` | **6.70%**（30,793 / 459,460 拍，1 iteration）`[TB:29,57]` | 本核 **3.47×**（迭代数不同，仅作原始数字记录） |
| **预测器结构** | **两级流水 gshare**：PHT **8192** 项 + BTB **512** 项 `[P6]`（源码 `pPC[12:0]`=2^13=8192、`WADDR[8:0]`=2^9=512）`[SRC46]` | **64 项直接映射 BTB + 2 位 Smith**，**组合查表**、结果直接进 `pc_target` 优先级 mux（在取指地址路径上）`[README:87,114][CORE:772]` | PHT 容量 **128×**、BTB 容量 **8×**，且本核没有流水寄存 |
| **取指地址运算宽度** | PC **18 位**（`reg [17:0] r_pc`；`I_ADDR = {w_npc, 2'b00}`）`[SRC46]` | **32 位**（`logic [31:0] pc, pc_plus4, pc_target`；`pc_next` 32 位 mux）`[CORE:90,274]` | 本核宽 1.78× |
| **存储器** | **4KB 与 64KB 两档**都报；**跑完基准必须 64KB** `[P6-T1][P7]` | **imem 16KB / dmem 16KB**（BRAM Tile **8**）；实际只用到 **2437/4096 字（59.5%）** 与 **535/4096 字（13.1%）** `[README:122][U][HEX]` | 本核浪费 40.5% / 86.9% 容量 |
| **功能集** | **仅 RV32I，本文扩到 M**。SoC = IMEM / DMEM / timer / RS-232C `[P1][WIKI][P6-Fig7]`。**无 CSR / 异常 / 中断 / A 扩展 / MMIO 外设矩阵**；整份源码 grep `csr\|ecall\|ebreak\|mtvec\|mepc\|exception\|interrupt` = **0 命中** `[SRC-GREP]` | **RV32IM + Zicsr + 完整 M-mode trap/中断**（mstatus/misa/mie/mtvec/mscratch/mepc/mcause/mtval/mip + mvendorid~mhartid）`[CSR:71-83]`；**A 扩展**（9 AMO + LR.W，`A_EN` 门控默认关）`[README:91]`；**MMIO**：GPIO / UART 115200 / 64 位定时器 + mtimecmp 中断 / GEMM 加速器 `[README:89-92]` | 本核多出 **CSR/trap/中断/MMIO**（这是**代价**，不是"更好"，见 §3） |
| **绝对吞吐（CM/MHz × fmax）** | **377.5**（= 2.33 × 162） | **184.4**（= 2.4209 × 76.18）`[M:27]` | **0.489×**（−51.1%） |
| **基准证据强度** | **Verilator 仿真周期 × Vivado 报告周期**算出执行时间 `[P7]`；论文只报频率与 LUT/FF/Slice/DSP，**无功耗、无 WNS/时序余量** `[P6-T1]` | **ILA 上板采集**：`ila_ctrl=0xC2`、CRC bit31=1、tick 1,239,079,510（预期 1,239,100,117，偏差 **0.002%**）、**22 个 RTL 文件哈希入采集清单** `[ILA][README:57-59]` | 本核证据链更长（代价：需要人工上板 + 采集见证） |

**两条必须并列读的数字**（Lead 明确指出这是全文信息量最大的两行）：

- **CoreMark/MHz：本核 2.4209 > RVCoreP-32IM 2.33** —— 即"单位频率的架构效率"我们**赢 3.9%**`[M:25][P9-T4]`
- **绝对频率：他们在更慢的 `-1` 器件上 162 MHz，我们在更快的 `-2` 器件上 76.18 MHz（0.47×）**`[P6][M:7][TR:9]`
  ⇒ 因此**"我们功能多"不能当成唯一借口**，见 §6。

---

## 2. RVCoreP-32IM 的不足（逐条，一条一行）

> 说明：他们的**IPC 换频率**、**表容量换频率**都是有据可查的**自觉设计取舍**，本节的"不足"是就
> **能力边界 / 可复算性 / 披露完整性**而言，不是指责作者水平。

1. **CoreMark/MHz 落后于本核**：RV32IM(DSP) **2.33**，本核 **2.4209**（1.039×）；同表 RV32I 配置只有 **0.84**、radix-4 **1.69**。`[P9-T4][M:25]`
2. **CoreMark IPC 只有 0.825**（coremark3：7,346,906 条有效指令 / 8,900,524 拍）；本核重算 **0.877**。`[RT:28-30][TB:29,49]`
3. **分支预测命中率低**：coremark3 **0.797**、官方 wiki 的 `test.mem` 只有 **0.716**（hit 3615 / total 5045）；本核重算 **88.77%**。`[RT:34][WIKI][TB:63,64]`
4. **功能集是本文所有对比项里最小的**：**只有 RV32I，本文才扩到 M**；官方 wiki 自述 "Adopt **RV32I** ... Run RISC-V programs compiled with RV32I"。`[P1][WIKI]`
5. **完全没有 CSR / 异常 / 中断**：整份官方源码（ver046 + ver053 的**全部 `.v`**）grep `csr|CSR|exception|ecall|ebreak|mtvec|mepc|mstatus|mie` = **0 命中**。`[SRC-GREP]`
   → 直接后果：**跑不了任何依赖 trap 的软件**（无 ECALL/EBREAK 处理、无非法指令 trap、无 `mret`、无定时器中断）。
6. **无 A 扩展、无 MMIO 外设矩阵**：SoC 只有 IMEM / DMEM / timer / RS-232C 串口（Fig.7）；**没有 GPIO、没有地址译码外设矩阵、没有原子指令**。`[P6][P6-Fig7]`
7. **用 IPC 换频率（自觉代价，要如实记）**：load 数据**不进** WB→EX 前递 ⇒ 依赖 load 的指令插 **2 拍气泡**（"two cycles bubble"，比常规 5 级的 1 拍**多一倍**）；MUL/DIV 依赖时**再多停 1 拍**。`[P3]`
8. **乘法器延迟高**：DSP 乘法 **2 拍**，radix-4 **18 拍**；除法 **33/34 拍**（被除/除数为 0 时 2 拍）。`[P5][P3]`
9. **基准数字不是上板实测，是仿真周期 × 时钟周期**："measured the number of clock cycles required ... Then execution time ... is calculated from the number of cycles required for simulation and the clock period"；频率是 Vivado 报告值。`[P7]`
10. **CoreMark 运行时间不满足 CoreMark 官方 ≥10 s 报告规则**：TABLE III 的 CoreMark 执行时间 **262.74 ms**（VexRiscv 296.02 ms）@162 MHz。本核上板 **3000 迭代 / 16.52 s**。`[P8-T3][README:57]`
11. **论文的 CoreMark/MHz 无法用公开数据独立复算**：官方源码自带 `result.txt` 的 coremark3 是 **8,900,524 拍 / 10 迭代**，按 `iterations×1e6/ticks` 得 **1.12**，与 TABLE IV 的 **2.33** 差 **2.08×**；论文与 `result.txt` **都没有披露 portme 计时器口径**。`[P9-T4][RT:28-30]`（详见 §4.3）
12. **存储器必须放大到 64KB 才能跑完基准**："to satisfy the memory requirement to run all the benchmark programs we took 64KB as the upper memory size"；而 **4KB 档的更高频率（RV32I 174 / RV32IM 169 MHz）跑不动完整基准**，64KB 时降到 **164 / 162 MHz**。`[P7][P6-T1]`
   → 即 **"174 MHz" 不是可用于基准的成绩**；论文把两档并列在 TABLE I，容易被误引。
13. **关键路径没有被消除，只是被绕开**：论文自述 "the critical path is a long routing path for register bypassing from the write back stage to execute stage **propagates through AGU** for memory load/store ... as **BRAM blocks input/output has routed**"。`[P6]`
   他们做的只是"**把 load 从旁路里拿掉**"（用 2 拍气泡换），**BRAM 仍在旁路环里**（ALU 前递仍穿 AGU/BRAM），结构性代价未解决 —— 与本核是同一种病。`[P3][P6]`
14. **预测器资源不小且未披露分解**：PHT **8192** 项 + BTB **512** 项 `[P6]`；TABLE I 只给 LUT/FF/Slice/DSP **总量**，**没有给出预测器占多少 LUT**（对比：本核 64 项 BTB 的 LUT 代价也未单独披露）。`[P6-T1]`
15. **无 I/D Cache、无 RV32C、无 Zicntr**：与第 5/6 条同源 —— 无 Cache（Fig.7 的 SoC 只有 IMEM/DMEM，所以基准对所有访存都吃满 BRAM 延迟 `[P6-Fig7]`）、无压缩指令（wiki 自述只支持 RV32I `[WIKI]`）、无 `mcycle`/`minstret`（**硬件上无法自测 CPI**，只能靠仿真器打印 `[SRC-GREP]`）。`[SRC-GREP][WIKI][P6-Fig7]`
16. **披露不完整**：TABLE I 只有 Frequency / Slice LUT / Slice register / Slice / DSP 五列，**没有功耗、没有 WNS / 时序余量、没有 BRAM 占用**；无法判断 162 MHz 是"勉强收敛"还是"有余量"。`[P6-T1]`

---

## 3. 本核的不足（逐条，一条一行）

> 这一节刻意写得更狠：本核的每一条都对应一个**我们花了钱却没买到的东西**。

1. **fmax 只有他们的 47%**：本核 **76.18 MHz**（`sys_clk_75` @13.333 ns，WNS +0.206）vs 他们 **162 MHz**（64KB）；绝对吞吐 **184.4 vs 377.5（0.489×）**。`[M:7,27][P6-T1]`
2. **器件比他们好却更慢**：本核在 **`-2`**（`7a100t-fgg484`，Speed File -2 PRODUCTION）上 76.18 MHz；他们在 **`-1`**（`xc7a100tcsg324-1`）上 162 MHz。**"器件差"这条辩解方向是反的。**`[TR:8,9][P6]`
3. **LUT 效率明显更差**：**2734 vs 1338（2.04×）**，FF **1251 vs 903（1.39×）**，Slice **846 vs 539（1.57×）**，DSP **8 vs 4（2.00×）**。`[U:34,39,72,115][P6-T1]`
4. **load-use 只花 1 拍（比他们省一半），代价是 dmem 的 BRAM 留在关键环里**：
   机制：`hazard_unit.sv:70` `pipe_stall = load_use || lsu_stall || ex_busy`，`:96-99` EX/MEM 前递排除 load，但 `:100-103` **MEM/WB 前递不排除 load** ⇒ 1 拍即可取数，**代价是 load 数据要从 dmem 的 BRAM 输出组合穿到 imem 地址脚**。`[HAZ:70,96-103]`
   关键路径 = `u_core/u_dmem/mem_reg_0/CLKBWRCLK → u_core/u_imem/rdata_reg_3/ADDRARDADDR[5]`，
   data path **12.466 ns = logic 4.011 (32.175%) + route 8.455 (67.825%)**，**16 级逻辑**。`[TP:14-23]`
   即：**省下的那 1 拍气泡，是用"前递 → 分支判定 → PC → imem 地址"这一整圈组合路径买来的。**
5. **这是一堵"物理墙"，不是逻辑问题**：`timing_paths.rpt` 里 `-max_paths 50` 报出的 **50/50 条路径同源**（全部 `u_core/u_dmem/mem_reg_0/CLKBWRCLK`），其中 **48/50 目的端是同族** `u_core/u_imem/rdata_reg_*/ADDRARDADDR`（另 2 条是 `u_id_ex/rs{1,2}_data_reg[2]/CE`）。`[TP 全文件统计]`
   - top-1 slack **0.206 ns**、top-2 **0.208 ns** ⇒ **Δ(top1,top2) = 0.002 ns**、第 50 条也只有 **1.058 ns**。
   - route 占 **67.8%**（本核）⇒ 纯改 RTL 的期望收益≈0（PITFALLS R47）。`[M:19][TP:22]`
6. **参数旋钮已经扫到头，只值 +1~2 MHz**：基线 **73.57 MHz**（WNS +0.694，CSV:135）→ 最好 **74.64 MHz**（WNS +0.888，`X0Y1:X2Y4` + `place ExtraTimingOpt`，**4 次重复逐位一致**）⇒ **净收益 +1.07 MHz（+1.5%）**；该轮共扫 **11 组 Pblock**（含基线 `X1Y0:X1Y3`，CSV 行 135-155）；另 4 种 `route_design -directive` 单独实测为 69.2 / 69.2（逐位相同）/ 69.1 / 68.2 —— **已封顶**。`[CSV:135-155][BUILD-TCL:291-300][PLAYBOOK:309]`
7. **预测器是组合查表，且落在取指地址路径上**：`btb.sv` = **64 项 BTB + 2 位 Smith**，查表结果**组合**进 `core.sv:772` 的 `pc_target` 4:1 优先级 mux；而他们是**两级流水**（预测目标/方向各寄存一拍）+ 8192 项 PHT。`[README:87,114][CORE:772][P6][SRC53]`
8. **上一版 gshare 失败是"表太小"，不是方法错**：`GH_BITS=6` 的历史 XOR 进 **64 项**表 ⇒ 精度从 89% **崩到 74%**（误判 11,535 → **26,547**，ticks 423,527 → **451,265**，慢 6%）。6 位历史把每条分支摊到 2^6=64 个计数器上，冷启动/表摊薄。`[GSHARE:27-42]`
9. **取指地址全程 32 位运算**：`logic [31:0] pc, pc_plus4, pc_target`；`wire [31:0] pc_next = fetch_hold ? pc : (pc_src ? pc_target : pc_plus4)`，全部在取指环上。他们只用 **18 位** PC（`reg [17:0] r_pc`，`I_ADDR = {w_npc, 2'b00}`）。`[CORE:90,274][SRC46]`
10. **综合策略旋钮在 2026-10-11 之前从未测过**：`fpga/build.tcl` 自己的注释写着 `synthesis directive: never swept before 2026-10-11`；而 RVCoreP-32IM 工程文件明确用 **`Flow_PerfOptimized_high`**（synth）+ **`Performance_ExplorePostRoutePhysOpt`**（impl）。`[BUILD-TCL:259-263][XPR:164,189]`
    ⇒ **他们靠工程策略拿到的频率，我们此前根本没试过**，是纯记账遗漏。
11. **自印 CPI 是错的，真值更差**：TB 打 `CPI = 1.10`，但 `n_wb=417,064` **大于** `fetch=402,723`（物理上不可能）—— 因为 `hold_mem` 期间 MEM/WB 冻结、同一条指令被重复计数。按发指计真值 **CPI = 459,460 / 402,723 = 1.1409**（IPC **0.877**）。`[TB:29,49,50,77][TU R11]`
12. **气泡占 12.35%**：**56,738 / 459,460** = load-use **30,793（54.3%）** + muldiv **14,415（25.4%）** + 重定向 **11,530（20.3%）**。其中重定向 11,530 恰等于误判数 ⇒ **每次重定向实测只占 1 拍**（不是长期假设的 2 拍）。`[TB:29,51,57,59,64]`
13. **无 I/D Cache、无 RV32C、无 Zicntr**：`csr_file.sv` 只实现 0x300/301/304/305/340/341/342/343/344 与 0xF11~0xF14，**没有 `mcycle`(0xB00) / `minstret`(0xB02)** ⇒ **硬件上无法自测 CPI**，只能靠仿真 TB 打印。Cache 是"分析判定无收益"而未做（存储器已是单周期命中的片上 BRAM）。`[CSR:71-83][README:93]`
14. **存储器配置明显浪费，且缩容的收益方向我们还没测准**：imem 16KB 只用 **2437/4096 字（59.5%）**、dmem 只用 **535/4096 字（13.1%）**；可行最小配置是 imem 12KB + dmem 4KB。`[HEX][README:122]`
    - **但"缩容能提速"在本核上尚无结论，反而有反证**：我们自己的 ref5 参照核**同一份 RTL**只换存储器规模（4KB/4KB → 16KB/16KB，其余 Pblock/place/route/phys 完全相同）实测 **137.250 → 118.568 MHz（−18.68 MHz）**，而 **LUT 只从 921 变 925（+4）**、**FF 458 不变**、BRAM 2→8 ⇒ 这是**纯布局/布线代价**。`[REF5-v7][REF5-v12]`
    - 我们 10-05 试过 `p3b-imem12k`（65.2 MHz），但那是 **byte-lane LSU / Pblock / 75 MHz 约束之前**的网表 ⇒ **结论已作废，从未在当前 RTL 上复检**（见 C-6）。`[CSV:17]`
15. **文档侧仍有一行与参数不一致**：`fpga/mmio_subsys.sv:59` 注释写 `50MHz/115200 = 434`，而交付版 `fpga/top_a100t.sv:170` 传 `.CLK_HZ(75_000_000)` ⇒ `BAUD_DIV = 651`（实际 115,207.4 baud）。**已登记为待修，尚未修。**`[MMIO:59][TOP:170][README:89]`
16. **上板结论的"新鲜度"依赖人工流程**：`results/ila_done.csv` 是 git 跟踪文件，其 mtime **不是证据**（2026-10-11 10:51 实测发生过"内容未变、mtime 变新"导致 `[HIL]` 误报"刚上过板"）；结论必须靠 `results/ila_done.capture.json` + `fpga/cap_done.log` 双见证。`[README:26-29][ILA]`
17. **功能多 = 面积与路径都更贵，不是免费**：修 R-01/R48（中断精确性）与 R-02（mtval 合规）使 LUT **2649→2734（+85）**、FF **1234→1251（+17）**，`CoreMark/LUTs` 从 9.077e-4 掉到 **8.855e-4（−2.4%）**。**这是自觉取舍**，但账要记在我们头上。`[README:68-71]`

---

## 4. 口径存疑与更正（诚实留痕）

> 本节记录**任务简报里流传、但在归档材料中复算不出来**的数字。**以归档报告原文为准**，并保留双方数值。

| # | 简报中的说法 | 归档材料实测 | 归档值来源 |
|---|---|---|---|
| 4.1 | top-1 = `u_dmem/mem_reg_**3**`, **Δ(top1,top2) = 0.024 ns** | top-1 源为 `u_dmem/mem_reg_**0**/CLKBWRCLK`；**Δ(top1,top2) = 0.002 ns**（0.206 vs 0.208）；另一份归档 `x4`（70 MHz 约束）为 0.694 vs 0.752 = **0.058 ns** ⇒ **0.024 ns 与两份归档都对不上** | `[TP:14-15,132-133]`；`fpga/x4_timing_paths.rpt:14,132` |
| 4.2 | ref5 4KB→16KB "LUT 只从 **852** 变 **856**" | 配对实验（v7 vs v12-big16k，Pblock/place/route/phys 全同）：LUT **921 → 925（+4）**、FF **458 → 458**、RAMB **2 → 8**、fmax **137.250 → 118.568** ⇒ **ΔLUT = +4 一致，绝对值应为 921/925** | `.ref5_scratch/logs/v7.log:1086,1088`；`.ref5_scratch/logs/v12-big16k.log` |
| 4.3 | 论文 TABLE IV 的 CoreMark/MHz = 2.33 | 论文与官方源码**给不出可对齐的口径**：`result.txt` 的 coremark3 = 8,900,524 拍 / 10 迭代 ⇒ 按 `iterations×1e6/ticks` 得 **1.12**，与 2.33 差 **2.08×**；`portme` 计时器口径未披露 ⇒ **2.33 不可独立复算**（本核 2.4209 可由 `ticks=413070/1 iter` 在仿真与上板两处复算：2.4209 / 2.4212） | `[P9-T4][RT:28-30][M:25][README:59]` |
| 4.4 | 本核预测精度 "88.8%"，README 写 "88.7%" | 同一份日志重算 **=(102,656 − 11,530)/102,656 = 88.768%**；日志自己只打印取整的 `accuracy = 89%` ⇒ **88.7%/88.8% 是同一数字的两种四舍五入** | `[TB:63-64]`（README:87 写 88.7%） |
| 4.5 | C-4 代价按 "本核 MUL 占实测 **9,564 拍（2.3%）**" 计算 | 归档报告里**查不到 9,564**；可比的是 `stall_muldiv` **14,415 拍（3.14%）**减去插桩实测的除法 **2,897 拍** ⇒ **乘法启动 ≈ 11,518 拍（2.51%）**。**结论方向不变**（需 fmax +2.5% 才回本），但数字应以归档值为准 | `[TB:29,59]`；`[GAP:250-264]`；`[PROF:9,20]` |

**由此产生的一条纪律建议**：以后引用"预测精度/CPI/fmax"必须写**取数文件 + 行号 + 算式**，
因为本核这三项在**同一份日志里就有三个数**（自印 89% / 88.768% 重算；自印 CPI 1.10 / 真值 1.1409）。

---

## 5. 这轮大修的可搬运清单（C-1 ~ C-9 极简版）

> **排序依据（Lead 核定）**：按对 150 MHz 目标的贡献 **C-2 > C-1 ≈ C-8 > C-3 > C-7 > C-6 ≈ C-4**。
> 每一条都必须**单变量测量**（不与其他 RTL 改动混测），负结果同样入库。

| 编号 | 做什么 | 他们的依据 | 我们要付的代价 / 风险 |
|---|---|---|---|
| **C-1** | **两级流水 gshare 预测器**：PHT **8192** 项 + BTB **512** 项，预测目标与方向**各寄存一拍**，不放在取指地址的组合路径上 | `[P6]` "two-stage pipeline gshare ... PHT of 8,192 entries and a BTB of 512 entries"；源码 `r_btb`/`r_btkn_t` 寄存 `[SRC53]` | 面积（上次 64 项表失败是表太小，不是方法错 `[GSHARE:39-42]`）；接口需与 `core.sv` 重接（Lead 负责） |
| **C-2** | **把 load 数据从 WB→EX 前递路径上摘掉**，依赖时插 **2 拍**气泡 | `[P3]` "we did not include the load data into the forwarding path from the write back stage. As a result ... two cycles bubble" | **直接吃掉 IPC**：已量化的预测值 = **ticks +6.14%**（`[PROF:25]` 的 `cost_if_load_use_2cyc_pct`；task-9 独立估 +6~8%）；换来的是打断 `dmem BRAM → 前递 → 分支 → PC → imem 地址` 这条 **route 67.8%、50/50 同源**的墙 `[TP][HAZ:70,96-103]` |
| **C-3** | **MUL/DIV 输出也不进 MEM→EX 前递**，依赖时从 WB 前递、多停 1 拍 | `[P3]` "multiplier and divider output ... is not included in the data forwarding path from the memory stage to the execute stage" | 与 C-2 同源；我们已有的反向实验（省一拍）净亏 −1.8%，说明**方向必须由实测决定**`[CODE-REVIEW-PLAN:526]` |
| **C-4** | **DSP 乘法器输入加流水寄存器** | `[P4]` "we used the pipeline register to the input of the DSP ... **shortens the critical forwarding paths from the memory and the write back stage to DSP**"（代价：MUL 延迟变 **2 拍**） | **要算账**：`stall_muldiv` 合计 **14,415 拍**，其中除法只占 **2,897 拍**（84 条 × ~34.5 拍，插桩实测）⇒ **乘法启动拍 = 14,415 − 2,897 = 11,518 拍 = 459,460 的 2.51%**（加法上限）⇒ 加 1 拍需 **fmax +2.5%** 才回本 `[TB:29,59][GAP:250-264]`（另见 §4.5） |
| **C-5** | **扫工具策略旋钮**（`synth_design -directive` / `phys_opt_design -directive`，并进综合指纹），外加 **cell 级逻辑锥诊断** | 他们工程用 `Flow_PerfOptimized_high` + `Performance_ExplorePostRoutePhysOpt` `[XPR:164,189]`；而我们 `build.tcl` 自述 `never swept before 2026-10-11` `[BUILD-TCL:259]` | 零 RTL 风险；收益上界未知（route/place directive 已封顶 +1~2 MHz `[PLAYBOOK:309]`） |
| **C-6** | **存储器缩容**：imem 16KB→12KB（3072 字）+ dmem 16KB→4KB（1024 字），BRAM 8→4、地址网扇出减半 | `[P6-T1]` 他们并列 4KB 与 64KB 两档 | **结论已过期、必须在当前 RTL 重做 A/B**：ref5 同 RTL 4KB→16KB = **−18.68 MHz** 且 **LUT 只差 +4** `[REF5]`；10-05 的 `p3b-imem12k`（65.2 MHz）是旧网表，作废 `[CSV:17]` |
| **C-7** | **取指地址的加法与 mux 截断到 16~18 位**，只缩窄"取指地址"这一小段 | 源码取指环用 `r_pc[17:2]` / `w_npc[15:0]` / `w_btb[19:4]`，宽度 16~18 位 `[SRC53]` | **必须保留 32 位 PC 给 `auipc`/`jal` 的链接值**，并加地址回绕断言；**P2，排在 C-1/C-2/C-8 之后** |
| **C-8** | **把停顿从取指地址脚移出**：改成寄存的 0/1 加法（`r_pc[17:2] + IdEx_luse_x`）+ imem 读使能 | 源码 ver053 `proc.v:411`（`w_npc = (w_bmis) ? w_pc_true[17:2] : (IdEx_luse_x & w_btkn) ? r_btb[19:4] : r_pc[17:2]+IdEx_luse_x`）+ `:415 r_pc <= {w_npc, 2'b00}` `[SRC53]` | 本核现在是 `core.sv:274 pc_next = fetch_hold ? pc : (...)`，**停顿信号坐在最高优先级、直接压在地址脚上** ⇒ 移出即缩短该环 |
| **C-9** | **（本核独有，论文里没有）中断请求链寄存**：`fpga/mmio_subsys.sv:160` 原来是组合的 `assign irq_timer = (cycle_cnt >= mtimecmp)` —— **64 位比较器**组合穿 `csr → irq_take → trap_enter → pc_target 4:1 mux → imem 地址` | —— | 75 MHz 下它不在 top-50（被 dmem 的墙盖住），**150 MHz 下是最可能接班的新墙**；已改为寄存一拍（电平中断，功能等价，零 IPC 代价），`tb_soc_timer_irq` 复验 PASS |

### 5.1 不可搬运的部分（必须写明）

他们拿到 162 MHz 的路径里，**有一部分是靠"少做功能 + 用 IPC 换频率"换来的，这部分我们付不起、也不该付**：

1. **不能靠删功能换频率**：CSR/Zicsr、M-mode 精确异常、定时器中断、MMIO 外设矩阵是**赛题要求**（README:86-91）。他们整份源码 grep CSR/trap = **0 命中**`[SRC-GREP]` ⇒ 他们省掉的正是我们必须保留的。
   - 我们自己的账已量化：仅修 R-01/R48/R-02 的中断精确性与 mtval 合规就使 LUT **+85**、FF **+17**、`CoreMark/LUTs` **−2.4%**`[README:68-71]`。
2. **不能靠"基准跑不完"换频率**：他们 4KB 档的 174/169 MHz **跑不动完整基准**，能出成绩的是 64KB 档的 164/162 MHz`[P7][P6-T1]`。我们的 16KB/16KB 是**能跑完 CoreMark 3000 迭代并上板 CRC 匹配**的配置`[README:57]`，不能为了 MHz 把存储器缩到跑不动。
3. **不能照搬"load-use 2 拍"而不记账**：C-2/C-3 的代价是 **ticks 上升**，而我们的 CoreMark/MHz 领先（2.4209 vs 2.33）**恰恰建立在不付这个代价上**（1 拍气泡）。搬 C-2 就必须用"提频 × 降 IPC"的净吞吐来判定，**不能只看 fmax**。
4. **不能把"我们功能多"当唯一借口**：见 §6 —— 他们用的是**更慢的 `-1` 器件**`[P6][TR:9]`。
5. **我们的上板证据链不能简化掉**：CRC 三值校验 + 22 文件哈希的采集清单 + `cap_done.log` 见证`[ILA]` 是我们相对"仿真周期 × 报告周期"的唯一优势，简化等于自弃。

---

## 6. 诚实的定位（结论）

**本核的 CoreMark/MHz（2.4209）高于 RVCoreP-32IM 的 2.33（+3.9%）`[M:25][P9-T4]`；
两者的差距几乎全部是纯频率 —— 绝对吞吐 184.4 vs 377.5，我们只有他们的 0.489×`[M:27]`。**

而且必须把这两句话并列说出：

- 他们的 **162 MHz 是在 `-1` 器件（更慢）上测的**`[P6][TR:9]`；
- 我们的 **76.18 MHz 是在 `-2` 器件（更快）上测的**`[M:7][TR:9]`。

**所以"我们功能多（CSR/trap/中断/MMIO）"不能当成唯一的借口。**
真正的账单是：**我们在更快的器件上慢了 2.1 倍，其中至少有一半是我们可以搬的结构手法没搬**
（C-1 两级流水预测器、C-2/C-3 出前递、C-4 DSP 输入寄存、C-5 工具策略、C-7 地址截断、C-8 停顿出地址脚），
另一部分才是**必须付的功能代价**（§5.1：CSR/trap/中断/MMIO 与"基准必须跑完"）。
诚实的自我评价是：**架构效率赢了 3.9%，物理实现输了 53%，而在"承认方法差距"这件事上，我们此前是欠账的。**

---

## 7. 来源代号

| 代号 | 具体位置 |
|---|---|
| `[P1]`~`[P9]` | 论文全文 `D:\USER\Desktop\FPGA\.rvcorep_scratch\2010.16171.txt` 的 `===== PAGE n =====` 段落；括号内数字为该文件行号 |
| `[P3]` | 同文件 **第 272-293 行**（数据前递 / load-use 2 拍气泡 / 关键路径声明） |
| `[P4]` | 同文件 **第 320-346 行**（DSP 输入流水寄存器、MUL 延迟 2 / 18 拍） |
| `[P5]` | 同文件 **第 347-364 行**（除法器 33/34 拍） |
| `[P6]` | 同文件 **第 391-408、488-496 行**（两级流水 gshare / PHT 8192 / BTB 512 / `-1` 器件 / 综合策略 / 关键路径自述） |
| `[P6-T1]` | 同文件 **第 413-468 行 = PAGE 6 TABLE I**（频率 / Slice LUT / Slice register / Slice / DSP，4KB 与 64KB 两档） |
| `[P6-Fig7]` | 同文件 **第 469 行 = Fig.7**（SoC = IMEM / DMEM / timer / RS-232C） |
| `[P7]` | 同文件 **第 475-479、513-531 行**（必须 64KB；Verilator 周期 × 时钟周期） |
| `[P8-T3]` | 同文件 **第 885-957 行 = PAGE 8 TABLE III**（CoreMark 执行时间 262.74 ms / VexRiscv 296.02 ms） |
| `[P9-T4]` | 同文件 **第 966-979 行 = PAGE 9 TABLE IV**（DMIPS/MHz 1.03/1.25/1.40；CoreMark/MHz 0.84/1.69/2.33） |
| `[WIKI]` | RVCoreP 官方 wiki「Execution result when running `test/test.mem`」：https://www.arch.cs.titech.ac.jp/wk/rvcore/doku.php （IPC 0.825 / hit rate 0.716 / hit 3615 / miss 1430 / total 5045 / load-use stall 1897 / cycles 35030），2026-10-11 取 |
| `[RT]` | `.rvcorep_scratch\rvcorep_ver053\rvcorep_ver053\result.txt`（官方源码自带 IPC 结果：coremark3 = 第 28-38 行，dhrystone3 = 第 9-19 行） |
| `[SRC46]` / `[SRC53]` | `.rvcorep_scratch\rvcorep_ver046\...\proc.v` / `...ver053\...\proc.v`（ver046 `r_pc`=308、`I_ADDR`=474、`m_BTB [8:0]`=183、`m_PHT pPC[12:0]`=200；ver046/053 **均无** CSR 相关标识） |
| `[SRC-GREP]` | 对 ver046 + ver053 **全部 `.v`** 执行 `csr\|CSR\|exception\|ecall\|ebreak\|mepc\|mtvec\|mstatus\|mie` ⇒ **0 命中**；对 ver046 的 `config.vh` ⇒ `MEM_SIZE 1024*4`（第 27 行）、`D_SIMPLE_BTB`（第 18 行："single cycle BTB instead of two cycle version"） |
| `[XPR]` | `.rvcorep_scratch\rvcorep_ver046\rvcorep_ver046\main.xpr:164,189`（`Flow_PerfOptimized_high` / `Performance_ExplorePostRoutePhysOpt`） |
| `[CSV:n]` | `results/coremark.csv` 第 n 行（`clk75` = 第 168 行；`p3b-imem12k` = 第 17 行；rr2 系列 = 第 135-155 行） |
| `[M:n]` | `.fpga-cache\reports\20261011-121231-cm_hw\metrics.json` 第 n 行 |
| `[TP:n]` | 同一报告目录 `timing_paths.rpt` 第 n 行（`-max_paths 50`；50/50 同源、48/50 同目的族的统计为对该文件全文统计） |
| `[TR:n]` | `fpga\timing.rpt` 第 n 行（`7a100t-fgg484` / `Speed File : -2 PRODUCTION`） |
| `[U:n]` | `fpga\util.rpt` 第 n 行（LUT 2734 / Slice Registers 1251 / Slice 846 / Block RAM Tile 8 / DSPs 8） |
| `[TB:n]` | `.fpga-cache\logs\tb_sw_coremark.log` 第 n 行（cycles 459460 / fetch 402723 / retire(wb) 417064 / redirects 11530 / load-use 30793 / muldiv 14415 / ctrl-flow 102656 / mispredict 11530 / 自印 CPI 1.10） |
| `[ILA]` | `results\ila_done.capture.json`（`clk_hz` 75000000、`expect_tick` 1239100117、22 个 RTL 文件哈希、`bit_sha256`） |
| `[README:n]` | `README.md` 第 n 行 |
| `[CORE:n]` / `[HAZ]` / `[CSR:n]` / `[MMIO:n]` / `[TOP:n]` / `[BUILD-TCL:n]` | `core.sv` / `hazard_unit.sv` / `csr_file.sv` / `fpga\mmio_subsys.sv` / `fpga\top_a100t.sv` / `fpga\build.tcl` 第 n 行 |
| `[GSHARE:n]` | `results\p4-gshare.md` 第 n 行 |
| `[GAP:n]` | `results\gap-analysis.md` 第 n 行（`muldiv` 插桩：84 条除法 / 累计 busy 2,897 拍 / 每次 ~34.5 拍） |
| `[PROF:n]` | `results\profile.json` 第 n 行（`stall_muldiv` 14415、`share_pct.muldiv` 3.1、`cost_if_load_use_2cyc_pct` 6.14） |
| `[PLAYBOOK:n]` | `skills\fpga-riscv-a100t\OPTIMIZATION-PLAYBOOK.md` 第 n 行 |
| `[CODE-REVIEW-PLAN:n]` | `CODE-REVIEW-PLAN.md` 第 n 行 |
| `[TU R9]` / `[TU R11]` | Agent Teams 共享任务 `task-9` / `task-11` 的任务书（本轮大修的 RTL 与统计口径任务定义） |
| `[REF5-v7]` / `[REF5-v12]` | `D:\USER\Desktop\FPGA\.ref5_scratch\logs\v7.log`（4KB/4KB：137.250 MHz、LUT 921、FF 458、RAMB 2）与 `...\v12-big16k.log`（16KB/16KB：118.568 MHz、LUT 925、FF 458、RAMB 8）；两次 Pblock `CLOCKREGION_X1Y0:X1Y3`、`WLDrivenBlockPlacement`、`route Default`、`PHYS_OPT=0` 完全相同 |
| `[HEX]` | `sim\prog\cm_hw.hex` = **2437** 行（字）/ 4096；`sim\prog\cm_hw.dmem.hex` = **535** 行（字）/ 4096（2026-10-11 12:12:44 生成，与 clk75 综合同批） |

**第三方素材声明**：`[SRC46][SRC53][XPR][RT]` 均位于仓库之外的 `.rvcorep_scratch\`，为 MIT 许可第三方工程，
本文件仅引用其**路径/行号/参数宽度/公开输出**，**未复制任何代码**，也**未将该目录纳入 git**。
