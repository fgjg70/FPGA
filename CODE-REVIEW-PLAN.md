# CODE-REVIEW-PLAN.md — 代码审查与优化计划

> **审查对象**：`D:\USER\Desktop\FPGA\FPGA` @ `d6b48fe`（工作区干净，120 次提交）
> **审查日期**：2026-10-11
> **方法**：逐文件读 RTL（22 个核内文件全部读过或抽查）、复算 `results/*.csv`、
> 复算 Vivado 报告（`timing.rpt` / `util.rpt`）、**实跑一次强制全量回归**
> （`fpga_workflow.py verify --force` → PASS 11，逐项非缓存）、`doctor` / `check`、
> 并**实跑** `hw` / `metrics` / `path_hotspot.py` 复现度量链问题；
> 另有三次并行专项审阅（验证基础设施 / FPGA 与构建流程 / 文档与代码一致性），
> 其结论均按 `path:line` 标注，**关键结论由我亲自复核后才写入**。
>
> 本文**只记录问题与计划，没有改动任何代码**。
>
> 标注约定：
> `[已实测]` = 本次实跑得到的结果；`[复算]` = 从仓库内产物重新计算；
> `[代码分析]` = 读代码得出的结论，**尚未**用定向测试确认。

---

## 0. 结论摘要（先看这一段）

这个工程的工程质量**远高于同类课程/竞赛项目**：22 个 RTL 文件、47 条踩坑记录、
带缓存的回归/综合流水线、失败方案都留了数据。真正的风险不在"代码写得烂"，
而在**四类事**：

1. **一个潜伏的正确性 bug（中断可在流水线气泡上被接受，导致 `mepc = 0`）** ——
   现有 11 项回归**结构上测不到**它（详见 R-01）。
2. **评分指标 `fmax` 的自动计算是错的**，而且**从 2026-10-09 20:58 起对所有 RTL
   改动都不再敏感**（恒为 76.92）—— `keep/reject` 决策与"绝对吞吐"因此失真（详见 M-01）。
3. **文档口径整体停在 2026-10-08**：`fmax 69.8 → 74.64`、`LUT 2649 → 2667`、
   上板 `1300 迭代@50MHz → 3000 迭代@70MHz`。任何接手者（人或 AI）都会被误导，
   去重做已经做完（或已被否决）的优化（详见 D-01 ~ D-05）。
4. **"PASS 11" 这个结论的含金量被高估了**：11 项里有 **3 项（`tb_sw_*`）在程序算错时
   仍然打印 `RESULT : PASS`**（`sim/tb_sw.sv:394` 无条件打印），另有一项
   （`tb_units` 的 AMO 译码检查）**在日常回归里根本没被编译**，CoreMark 的 CRC 校验
   失败也不会让任何测试变红。也就是说 **`verify` 的绿灯只证明"程序跑到了结尾"**（详见 W-01/W-09/W-10）。
5. **"上板已验证"这句话可以被一次 `git checkout` 伪造**：`hw` 的新鲜度判据只有文件
   mtime，而 `results/ila_done.csv`（含一份完整的 PASS 采集）**是被 git 跟踪的** ——
   clone/checkout 把 mtime 刷成"现在"，工具就会在**没有板子**的情况下打印
   `上板验证 PASS`。这正是 R20（"验证工具可能制造虚假证据"）要防的事（详见 X-02）。

### 0.1 数字对照（文档 vs 我实测/复算）

| 指标 | 文档（README/HANDOFF） | 我实测 / 复算 | 证据 |
|---|---|---|---|
| CoreMark/MHz | 2.4209 | **2.4209** ✅ | `verify --force` → `tb_sw_coremark` PASS |
| 仿真 ticks | 413,070 | **413,070** ✅ | 同上 + `results/coremark.csv` |
| **fmax（工具口径）** | 69.8 MHz | ⚠ **76.92（错）** | `parse_reports()` 取错 slack，见 M-01 |
| **fmax（真实口径）** | — | **74.64 MHz** `[复算]` | `sys_clk_70` WNS 0.888 @14.285714 ns |
| LUT / FF / BRAM / DSP | 2649 / 1234 / 8 / 8 | **2667 / 1234 / 8 / 8** | `fpga/util.rpt` |
| CoreMark/LUTs | 9.139e-4 | **9.077e-4** | 2.4209 / 2667 |
| 绝对吞吐 | 169.0 | **180.7** | 2.4209 × 74.64 |
| fmax vs 基线(78.4) | −11.0% | **−4.8%** | 74.64 / 78.4 |
| 绝对吞吐 vs 基线(64.8) | +160.8% | **+178.9%** | 180.7 / 64.8 |
| 上板 | 1300 迭代 @50 MHz, `ila_ctrl=0x42`, tick 536,943,384 | **3000 迭代 @70 MHz**, `ila_ctrl=0xC2`, tick **1,239,100,518** | `results/ila_done.csv`、`coremark.csv` `clk70-hw` |
| 回归 | PASS 11 | **PASS 11** ✅（强制重跑）但见 W-01：其中 3 项不能因结果错而失败 | `verify --force`，11/11 真跑非缓存 |
| `tb_units` 检查点 | 以运行时打印为准 | **194**（其中 ~19 条 AMO 译码检查**默认不编译**） | `verify --force` 首行 + `sim/tb_units.sv:430-485` |
| PITFALLS 条目 | R1~R35（4 处文档） | **R1~R47** | `PITFALLS.md` 标题扫描 |

> **一句话**：功能大体是真的、CoreMark 数字是真的，但 **① 中断路径有一个结构上
> 未被覆盖的正确性缺陷，② 三项评分指标里的 `fmax` 算错了且对改动不敏感，
> ③ 文档整体滞后一个版本，④ "PASS 11" 的含金量低于字面（3 项实际不做结果校验）。**
> 这四条都能在一周内修完，且都**不触碰已经上板验证过的数据通路**。

---

## 1. 问题总表

优先级：**P0 = 影响正确性或"指标可信度"，必须最先做；P1 = 高价值短平快；
P2 = 补强；P3 = 需权衡/长期**。工作量：S ≤ 半天，M ≤ 2 天，L > 2 天。

### A. 正确性（RTL）

| ID | 级别 | 位置 | 问题 | 证据 | 影响 | 建议动作 | 量 |
|---|---|---|---|---|---|---|---|
| **R-01** | **P0** | `core.sv:730`；`csr_file.sv:150,174`；`id_ex_reg.sv:66-78` | **中断可在"流水线气泡"上被接受 → `mepc = 0`。** `irq_take = irq_pending && !pipe_stall && !exc_req && !is_mret`，**全核没有任何"EX 段指令有效"判据**。而 `id_ex_reg` 在 flush/bubble 时把 `pc` 清成 0。于是：某拍 `irq_pending=1` 且 `pipe_stall=1`（load-use 停顿 或 重定向）→ 下一拍 `pipe_stall` 落下、EX 里是**刚注入的气泡** → `trap_enter` 成立、`mepc <= id_ex_pc = 0`；同时 `any_redir` 把 ID/EX 与 IF/ID 冲掉 ⇒ **ID 中那条真指令被永久丢弃**。`mret` 后 `PC = 0`，而 `imem` 忽略高位地址（`imem.sv:79` 用 `addr[13:2]`）⇒ 从"程序第 0 条"重头执行。 | `[代码分析]` 逐拍推演；`id_ex_reg.sv:66-78`（气泡把 `pc<=0`）、`core.sv:723-731`（`exc_req` 有判据、`irq_take` 没有）、`csr_file.sv:174`（`mepc <= trap_pc`）、`core.sv:695`（`trap_pc = id_ex_pc`）。**现有测试测不到**：`sim/prog/timer_irq.S:61-63` 的等待循环是无 load 的紧循环（不吃 load-use 停顿），且 BTB 学会后无重定向气泡。 | 静默控制流损坏。任何"周期性定时中断 + 真实代码"都会踩到（load-use 停顿在 CoreMark 类代码里占 5~10% 周期，中断使能后第一次 load-use 停顿即可命中）。**这是本次审查最重要的发现。** | ① 给 ID/EX 增加显式 `valid` 位（最干净，顺带可用于断言/调试）；② 最小改动：`irq_take` 再与 `id_ex_valid` 相与，并在 `any_redir` 同拍抑制中断一拍（`irq_pending` 是电平，晚一拍取不影响正确性）；③ 新增定向回归：arm `mtimecmp` 后进入 `lw`+距离1依赖循环，断言 `mepc != 0` | S |
| **R-02** | P1 | `core.sv:696` | **`mtval` 恒 0**：`.trap_tval(32'd0)`。`csr_file.sv:14` 的头注释承诺"非法指令放指令编码、地址错放地址"，实际从不写入。 | `core.sv:696`；`csr_file.sv:182` | 非法指令无法定位（本工程历史上正是靠"哪条指令非法"定位问题）；不符合规范对 `mtval` 的要求。 | 把非法指令编码 / 触发地址接到 `trap_tval`；`tb_core_trap` 加一条断言 | S |
| **R-03** | P1 | `core.sv:927,947-951` | **无访问错误异常，且窗口外地址被静默吞掉**：地址只要不在 DMEM 窗口就全部送 `ext_*`（`sel_dmem=0`），未映射地址读回 0、写被丢弃；`CAUSE_LOAD/STORE_ACCESS_FAULT` 未实现。 | `core.sv:927`（`sel_dmem` 只判 DMEM 窗口）、`core.sv:947`（`ext_we = dmem_we && !sel_dmem`）、`rv32_pkg.sv:386-391`（只有 MISALIGN，没有 ACCESS_FAULT） | 野指针静默通过 —— 正是本工程反复踩的"静默失败"形态（PITFALLS R1/R23）。也让"改了 `link.ld` 但没同步"这类错误无法在运行期暴露。 | 增加 MMIO 合法性窗口（如只允许 `0xA000_0000..0xA000_0FFF`）与 ACCESS_FAULT 异常；或至少一个"未映射访问"粘滞调试标志 | M |
| **R-04** | P2 | `core.sv:75-76,947-948` | **`ext_re` 不是"1 拍脉冲"**：`ext_re = ex_mem_ctrl.mem_read && !sel_dmem`，未与 `hold_mem`/`lsu_stall` 门控。非对齐跨字 MMIO 读时 `state` 会在 IDLE/HEAD/TAIL 停 3 拍（`load_store_unit.sv:167`）⇒ `ext_re` 连续 3 拍高。 | `core.sv:76` 注释写"读选通 (1 拍脉冲)"；`core.sv:948`；`load_store_unit.sv:167` | 会**多次清除**外设的粘滞"数据就绪"标志（UART RX 就靠读清）。虽然"外设一律 32 位对齐访问"是约定（`rv32_pkg.sv:320`），但这是静默的、且约定没有被断言保护。 | 与 `hold_mem`/`!lsu_stall` 门控 `ext_re`，或把"非对齐 MMIO"显式判为 ACCESS_FAULT（配合 R-03） | S |
| **R-05** | P2 | `core.sv:884-887` | **AMO 的 `amo_op_r` 锁存依赖一条未加断言的不变量**：`else if (id_ex_ctrl.amo_en) amo_op_r <= ...`，注释（`core.sv:880-883`）明确说"它只在 `amo_en` 有效的那一拍为真值"。一旦将来在 AMO 前插入额外停顿/多拍，`amo_op_r` 会被后续指令覆盖 → AMO 算子错（历史上正是这个症状：`amoswap` 被当 `amoadd` 算）。 | `core.sv:873-887`；`control_unit.sv:266` | 只影响 `A_EN`（默认关），但对未来改动是**陷阱**。 | 改成边沿检测（`amo_en & ~amo_en_d`）并加 SVA 断言"`amo_en` 连续高 ≤1 拍" | S |
| **R-06** | P2 | `ras.sv:61` | **越界数组读**：`assign top = stk[sp - 1'b1];`，`sp=0` 时索引 = `4'b1111` = 15，而 `stk` 只有 `[0:7]`。`empty` 挡住了功能使用，但这是 out-of-range 读（部分仿真器报错/lint 报错），且 `top` 是 X。 | `ras.sv:36`（DEPTH=8，PW=4）、`ras.sv:59-61` | `RAS_EN` 默认关，风险低；但属"代码里有 UB"这一类。 | `assign top = empty ? 32'b0 : stk[sp - 1'b1];` | S |
| **R-07** | P3 | `core.sv:105,310` | **死信号**：`pred_hit` 声明并连到 `u_btb`，但 `core.sv` 内从未使用（`pred_taken` 已在 `btb` 内与 `pred_hit` 相与）。 | `core.sv:105`、`core.sv:310-324` | 综合会优化掉，无功能影响；但 lint 会报，且读者会以为它在用。 | 删除端口或加注释说明"仅供 tb 层次引用" | S |
| **R-08** | P3 | `imem.sv:31`、`dmem.sv:25` | **`BASE` 参数从未参与逻辑**，而 `core.sv:921-925` 的注释声称"这里让 BASE 真正参与译码" —— 实际参与译码的是 core 自己的 `DMEM_BASE` 常量。两个存储器的 `BASE` 是死参数。 | `imem.sv:31-42`（只用了 `BYTES`）、`dmem.sv:25-39` | 注释与代码不符（本工程最忌讳的一类）；也让"窗口外访问"无法在存储器内部兜底。 | 要么删参数、要么让模块真正译码（窗口外返回 0 / 断言），并改正注释 | S |
| **R-09** | P3 | `core.sv:930-933` | `ext_rdata_r` / `sel_dmem_r` 的时序块**无复位**（`always @(posedge clk)`），与全工程 `posedge rst` 风格不一致。 | `core.sv:930-933` | 无功能影响（一拍后自愈）。 | 统一加复位，或加注释说明有意为之 | S |
| **R-10** | P3 | `btb.sv:107-124`、`muldiv.sv:58-61` | `dctr` 数组/`prod_ss`/`prod_uu` 依赖 `initial` 而不参与复位；复位后预测器状态不确定（只清 `vld`/`ghr`）。 | `btb.sv:121-124`、`muldiv.sv:58-61` | 仿真可复现性依赖 `initial` 被支持；真实上电由 FPGA 初始化完成，功能无影响。 | 把 `dctr` 纳入复位分支（代价很小），或明确写"依赖 FPGA 上电初值" | S |

### B. 度量可信度（工具 / `tools/fpga_workflow.py`）

| ID | 级别 | 位置 | 问题 | 证据 | 影响 | 建议动作 | 量 |
|---|---|---|---|---|---|---|---|
| **M-01** | **P0** | `fpga_workflow.py:1275-1285` | **`fmax` 算错，且对 RTL 时序变化完全不敏感。** `re.search(r"^\s*sys_clk\s+(-?[\d.]+)", t, re.M)` 本意取 `sys_clk` 行的 WNS，但引入 MMCM 后核心跑在 **`sys_clk_70`**，`sys_clk` 行**已无 setup 端点**，正则于是抓到该行第一个数字 —— **脉宽余量 WPWS = 7.000**；再按硬编码 `period=20.0` 换算 ⇒ `fmax = 1000/(20−7.0) = 76.92 MHz`。**正确答案**：`sys_clk_70` WNS = **0.888 @14.285714 ns** ⇒ **74.64 MHz**。 | `[复算]` `fpga/timing.rpt`：Clock Summary `sys_clk_70 14.286 70.000`；Intra Clock Table `sys_clk` 行 WNS/TNS 为空、只有 `WPWS 7.000`；`sys_clk_70` 行 `WNS 0.888`。`[实测]` 2026-10-09 20:58 起 30+ 次综合的 `metrics.json` 全部 `wns=7.0, fmax=76.92`，而 LUT 在 2664~2669 之间变化 ⇒ **指标对改动零敏感**。`[已实测]` 代码第 2165-2166 行的注释已承认"period 硬编码 20.0…本次先不改，只在此标注"。**这是 MMCM 引入的回归**：MMCM 之前同一正则是对的（`20261008-203550-cm_hw/timing.rpt:152` 的 `sys_clk 5.675` 是真 WNS → `metrics.json` 69.808 = 文档里的 69.8）；MMCM 之后 `sys_clk` 行再无 setup 端点，正则会话**静默**落到脉宽行。**并且它会污染判定而不是只影响打印**：`[已实测]` 今天跑 `metrics --vs clk70-hw` 输出 `fmax 73.6 → 76.9 (+4.5%) / 绝对吞吐 178.2 → 186.2 / 判定: KEEP`，而同一份报告的真实值是 73.57 → 74.64（**+1.45%**）—— 收益被夸大 3 倍。更糟的是 `verdict()` 在解析失败时**失败开放**（`fpga_workflow.py:1654` `if not a or not b: continue`），解析一坏判定就静默退化成 2 项指标。 | **fmax 是三项评分指标之一**；`绝对吞吐 = CM/MHz × fmax`（`fpga_workflow.py:1139,1161`）与 `metrics` 的 keep/reject 判定全部建立在错值上。虚高 +3.1%，并且掩盖了真实时序回归。 | 重写解析：从 Clock Summary 读出各时钟周期；在 Intra Clock Table 里按**设计主时钟**（应参数化，不要硬编码名字）取 setup WNS；`fmax = 1000/(T − WNS)`。同时输出"实际运行频率（70 MHz）"与"时序余量"两个数。**修完必须用 `20261011-004830-cm_hw` 复算得到 74.64 才算通过。** | M |
| **M-02** | P1 | `fpga_workflow.py:934-938,1041-1042` | **缓存会把 FAIL 洗成 SKIP 且返回 0。** skip 条件只比较 `fingerprint`，**不看上次 status**；汇总里 `bad = FAIL + BLOCK + XPASS`，`SKIP` 不计入 ⇒ 第一次 FAIL（exit 1），第二次无改动重跑 ⇒ `SKIP` + **exit 0**。 | `[已实测]` 今天 `verify` 全量 SKIP 输出 `SKIP 11` 且 exit 0。`[复算]` `.fpga-cache/verify-state.json` 里存有 `"tb_core_timer_irq": {"status": "FAIL"}` 这一**孤儿条目**（测试已不存在于 11 项矩阵中）—— 证明 FAIL 状态会被持久化，而缓存逻辑会把它当"未受影响"跳过。 | CI / 自动循环会把"没跑"和"上次失败"都当"通过"。这直接违背本工程最核心的教训（R1/R17/R31：静默失效）。 | ① skip 仅当 `prev.status == "PASS"`；② 汇总把"缓存的 FAIL"计入 `bad`；③ 增加 `--require-run`（全 SKIP 时非零退出）；④ 启动时清理不在矩阵里的孤儿条目 | S |
| **M-03** | P1 | `fpga_workflow.py:2167-2172` | `hw` 的 `--iterations` / `--clk-hz` **默认值仍是 1200 / 50e6**（MMCM 之前的旧值），不带参数直接调用会**静默**算出错误的时长与硬件 CoreMark/MHz。 | `[实测]` 代码内注释自己写了"用默认值算出的时长/CoreMark-MHz 会**全错**而且看起来很正常（静默错）"。当前真实值是 3000 / 70e6。**`[已实测]` 今天不带参数直接跑 `hw`：`iterations=1200` → `CoreMark/MHz = 0.9684`、`时长 = 24.78 s @50MHz`，并打印 `上板验证 PASS`；而 `results/coremark.csv` 记录的真值是 **2.4211 / 17.70 s @70MHz** —— 少报 2.5 倍，且 `--clk-hz` 那一半有告警、`--iterations` 那一半**没有任何告警**，`ok` 判据也不含这两个派生量。** | 上板结论可能被算错却看不出。 | 默认改为"必须显式传"，或从 `sim/prog/cm_hw.*` / bitstream 元数据自动推断 `ITERATIONS` 与 `CLK_HZ` | S |
| **M-04** | P2 | `results/coremark.csv`（155 行） | **同一列混两种口径**：`fmax` 列里 22 行是**手工修正**的（备注含 "the fmax cell is hand-corrected"），其余行是工具算的；且工具里**没有任何 override 参数**，说明是人工编辑生成的 CSV。 | `[复算]` CSV 第 10 列分布：74.6×7、74.1×3、74.4×2… 与 `metrics.json` 的 76.92 不一致；22 行备注文字自证。 | 趋势分析、keep/reject 对比是"苹果比橘子"；人工编辑生成物违反本工程自己的纪律。 | 先修 M-01，再**一次性重算整列**并新增 `fmax_src`（tool/hand）列标注来源；保留旧列做对照 | M |
| **M-05** | P2 | `fpga_workflow.py:1406-1429` | 综合缓存指纹**已覆盖** RTL/top/xdc/build.tcl/镜像/宏/place/pblock ⇒ **这一处没问题**（我核过，特意记录以免后人重复怀疑）。但 `verify` 侧的 `gcc_version()` 只进指纹不进输出 —— 工具链升级后若指纹只因版本串变化而失效，不会提示原因。 | `[已实测]` 代码第 1424-1428 行显式把物理约束纳入指纹 | 无实际缺陷；仅提示"日志里应打印指纹构成"。 | 打印指纹构成摘要（便于归因"为什么重跑了"） | S |
| **M-06** | P2 | `tools/` 全局 | **缺少静态检查/lint。** 本机 `iverilog`、`verilator`、`yosys` **均不存在**（`[已实测]` `Get-Command` 全部 NOT FOUND，`%LOCALAPPDATA%\riscv-tools\mingw64` 也不存在）。本工程反复出现的 bug 类别 —— 隐式 1 位网络（R8/R25）、位宽截断（R6/R7）、越界索引（R-06）、未声明信号 —— **恰好都是 lint 一击命中的**。 | `[已实测]` 工具探测结果；PITFALLS R8/R25 明确记录过"隐式推断、静默出错" | 现在只能靠人眼与仿真。加一层 lint 是**投入产出比最高**的防线。 | 引入 Verilator `--lint-only`（或 iverilog `-Wall`）作为 `check` 的独立项；把 `-Wall` 警告纳入 `verify` 的失败条件（现在 `run.bat` 有 `-Wall`，但没人看） | M |
| **M-07** | P3 | `tools/flash_*.ps1/tcl`、`tools/path_hotspot.py`、`tools/pdf_*.py` | 这些工具**没有自动化冒烟测试**，也没有在顶层文档登记（见 D-06/D-07）。 | `[已实测]` `tools/` 目录 20 个文件；`CODE-MAP.md:148-153` 只列了 6 个 | 新会话里没人知道它们存在，等于白做。 | 文档登记 + `doctor` 检查关键脚本可解析（`tcl` 用 `vivado -mode batch` 干跑） | S |
| **M-08** | P3 | `tools/fpga_workflow.py:934` 附近 | `expect_fail_ok` 现在**没有任何测试使用**（11 项全部 PASS，别名已摘掉），但分支仍在；`XFAIL/XPASS` 汇总逻辑随之成为死代码。 | `[已实测]` `verify --force` 输出 11 PASS，无 XFAIL；`tools/README.md:96` 记录已摘除 | 无功能影响。 | 保留（历史需要）但加注释，或删掉并在 PITFALLS 留档 | S |

### C. 文档一致性（危害最大的一类：会误导后续决策）

| ID | 级别 | 位置 | 问题 | 证据 | 量 |
|---|---|---|---|---|---|
| **D-01** | **P0** | `README.md:23`, `HANDOFF.md:39,165,980,1005`, `CODE-MAP.md:175`, `results/gap-analysis.md:49`, `results/analysis-report.md:39,266,459` | **头部 fmax 写成 69.8 MHz（−11.0%），真实是 74.64 MHz（−4.8%）**。"最大的剩余差距"这一整套叙事因此是错的。 | `[复算]` `sys_clk_70` WNS 0.888 @14.285714 ns；`coremark.csv` `rr2-final` = 74.6 / `keep` | S |
| **D-02** | P0 | `README.md:24,27`, `CODE-MAP.md:176-178`, `HANDOFF.md:42` | LUT **2649 → 2667**；CoreMark/LUTs **9.139e-4 → 9.077e-4**；绝对吞吐 **169.0 → 180.7**。注意 `2649 + 74.64` 这个组合**不对应任何真实配置**。 | `[实测]` `fpga/util.rpt` `Slice LUTs 2667`；`coremark.csv` `rr2-final` LUT 2667 | S |
| **D-03** | P0 | `README.md:28`, `HANDOFF.md:14,44-46`, `CODE-MAP.md:179`, `HANDOFF-HW-LOOP.md:26,73,98,256,261` | **上板口径停在 1300 迭代 @50 MHz / `ila_ctrl=0x42` / tick 536,943,384**；实际 bitstream 是 **3000 迭代 @70 MHz**（镜像 2407+516 字，正是 3000 版）、`ila_ctrl=0xC2`、tick **1,239,100,518**、17.70 s。按文档给的参数去判读会得到**假结论**。 | `[复算]` `results/ila_done.csv` 全 2048 行 = `c2` / `c9db2c66`；`ilac_ctrl` bit7 = `mmcm_locked`（R43 引入） | S |
| **D-04** | P1 | `README.md:100-116` vs `HANDOFF.md:270` | **README 把 `sim\run.bat` 当作"跑测试"入口**，但 `run.bat` 硬依赖**本机不存在的 iverilog**（`[已实测]` `%LOCALAPPDATA%\riscv-tools\mingw64` 不存在），且只跑 **2/11** 个测试；HANDOFF 又直接说"没有 iverilog"。真正可用的入口是 `python tools/fpga_workflow.py verify`。 | `[已实测]` 工具探测 + `sim/run.bat:13-24` | S |
| **D-05** | P1 | `CODE-MAP.md:87,90-110`（`core.sv` 章节地图） | **行号系统性偏 +35~+40**（`core.sv` 已 1038 → **1073** 行）：`u_pc` 190→225、`u_imem` 242→277、`u_hazard` 715→750、`u_mem_wb` 930→965、末节 1031-1038→1066-1073。该文件的存在意义就是"按行跳读"，现在每次都跳早 35 行。 | `[复算]` 抽样 12 处锚点全部偏 | M |
| **D-06** | P1 | `README.md:94`, `CODE-MAP.md:166`, `HANDOFF.md:803`, `results/analysis-report.md:484` | **PITFALLS 已到 R47，四处文档仍写 "R1~R35"**；`HANDOFF.md:6` 还把 PITFALLS 写成 **9 KB**（实际 **56 KB / 835 行**）。"R1~R35" 等于暗示"台账已读完"，而 R43（MMCM 漏接 `.CLKFBIN` 会把整颗 CPU 按在复位里）、R47（top-N 是墙时 RTL 重排期望≈0）恰恰是最值钱的。 | `[复算]` 标题扫描 R1..R47 连续无缺口 | S |
| **D-07** | P1 | 全部顶层文档 | **QSPI Flash 固化流程零提及**（`git log` 的 `5bd8e37` 引入了 8 个脚本 + `tools/flash_logs/REPORT.md` + R44/R45/R46）。`HANDOFF.md` §12"建议接手顺序"与 `CODE-MAP.md` §3 完全学不到这个已打通的能力。 | `[复算]` grep `flash/QSPI/mcs/cfgmem` 在 6 个顶层文档中 0 命中 | M |
| **D-08** | P2 | `results/p7-cache-analysis.md:25-41,33,65-69` | 该文件**自相矛盾**：正文写着 "`imem` ❌ **组合读 LUT ROM**，**不是** BRAM"，而 README/HANDOFF 拿它当"两者都是单周期命中 BRAM ⇒ Cache 无收益"的定量依据；文件还引用了**已不存在的宏 `IMEM_REG_READ`**（现在默认就是寄存读，回退宏叫 `IMEM_COMB_READ`）。 | `[已实测]` `core.sv:214,269`、`imem.sv:71-81` | M |
| **D-09** | P2 | `btb.sv:15` | 模块头注释写 gshare "（P4 优化，**默认开启**）"，与事实相反：`` `ifdef BTB_GSHARE `` 默认不定义，`build.tcl` 不传，且 `results/p4-gshare.md` 判定**慢 6% 已否决**。这正是 R16 记录的那类"被推翻的注释"，而**改动者最先读的就是模块头**。 | `[实测]` `btb.sv:93`；`results/coremark.csv` gshare 行 | S |
| **D-10** | P2 | `results/ila_pipeline.csv` + `analysis-report.md:344-356`、`HANDOFF.md:687,711-717` | 报告声称 stall 11.57% / redirect 0.68% 来自该 CSV，但**该 CSV 的表头里根本没有 stall/redirect 列**（只有 pc/instr/ila_ctrl/score_result），且文件是 **2026-10-05** 的（其后经过 P8、X1、X3、RR2、LSU 字节通道、MMCM 共 6 个版本）。 | `[复算]` CSV 表头 | M |
| **D-11** | P2 | `CODE-MAP.md:62,75,117,133-134,161-163` | 文件清单行数过期：总行 **3849 → 3942**；`load_store_unit.sv` **314 → 357**；`fpga_workflow.py` **2114 → 2230**；`build.tcl` **215 → 318**；`daVinciPro.xdc` **25 → 49**；`HANDOFF*.md` 三处亦偏小。 | `[复算]` 逐文件行数 | S |
| **D-12** | P2 | `results/analysis-report.md:237-250` | "度量纪律"示例表**内部不自洽**：一行写 `2.3614 CM/MHz + fmax 74.6 + 5.254e-4`,但 `2.3614/5.254e-4 = 4494 LUT`，而同表/正文另一处给的是 **LUT 2481**。该表是本报告用来教"必须同时看四项指标"的示范。 | `[复算]` `coremark.csv:9,11,12` | S |
| **D-13** | P3 | `HANDOFF.md:1002` | "本项目累计 **40+ 次**提交" —— 实际 **120** 次。 | `[实测]` `git rev-list --count HEAD` | S |

### D. 工程 / 仓库卫生 / 可移植性

| ID | 级别 | 位置 | 问题 | 证据 | 影响 | 建议动作 | 量 |
|---|---|---|---|---|---|---|---|
| **E-01** | P1 | 仓库根（155 个跟踪文件） | **60.9 MB 二进制被打进 git**：`tools/flash_logs/readback.bin` 16 MB、三个 `fpga/cpu_a100t*.mcs` 各 10.26 MB、`cpu_a100t_spix{1,4}.bin` 各 3.65 MB、`guide_text.txt` 5.5 MB、三个 `accessor/spi_*.bit` 各 0.57 MB。而**全部源码只有 3.2 MB** —— 8 个文件占了 95% 体积。 | `[实测]` `git ls-files` + 文件尺寸逐项求和 | 克隆/备份/搬运成本高；也助长了 `check`/`synth` 的 I/O 开销。 | `git rm --cached` + `.gitignore`（这些全是可再生成的：`.mcs` 可由 `flash_mkimage.tcl` 重建，`readback.bin` 是烧录日志）；需要长期留存就放 Git LFS 或外部归档。**注意：改写历史（filter-repo）属破坏性操作，需你确认后再做。** | M |
| **E-02** | P1 | `fpga/build.tcl:12,38,39` | **硬编码绝对路径** `D:/USER/Desktop/FPGA/FPGA`（且 `set root` 与 `read_verilog` 里的字面量**重复维护**）。换机器 / 换目录 / 换用户名即失败 —— 与"迁到紫光同创只需重写顶层与约束"的可移植性目标直接矛盾。 | `[实测]` `build.tcl:12` 与 `:38` 的字面量 | 交付/迁移时的第一道坎。 | 改成 `set root [file normalize [file join [file dirname [info script]] ..]]`，`read_verilog` 用 `$root/...`；`build_ila.tcl` 同样处理 | S |
| **E-03** | P2 | `load_store_unit.sv:201` | **关键等价性证据不在版本控制内**：注释指向 `.rr2_scratch/check_equiv.py`（"675 万组组合穷举、0 处不一致"）—— 该路径在**仓库根之外**（仓库是 `FPGA/`，scratch 在其父目录）、**未被 git 跟踪**、**任何文档都没登记**。这是交付版 LSU 字节通道 mux 唯一的正确性论证。 | `[实测]` 文件存在（3.2 KB）于 `D:\USER\Desktop\FPGA\.rr2_scratch\`；`git ls-files` 无此文件；grep 全部 `*.md` 0 命中 | 换台机器克隆仓库后，"已穷举验证"这句话**无法复现**。 | 把 `check_equiv.py` 移入 `tools/` 并入库，在 `results/` 留一条记录；同时把等价性检查接入 `verify`（可作为一条快速测试） | S |
| **E-04** | P2 | 工作区根 `D:\USER\Desktop\FPGA` | **仓库根与工程根不一致，且根目录堆了 9 个 scratch 目录**（`.bp_scratch` 5.0 MB、`.radix4_scratch` 32 MB、`.ref5_scratch` 5.0 MB、`.rr2_scratch` 2.5 MB、`.mul_scratch` 2.3 MB、`.opt_scratch` 1.6 MB、`.clk_scratch` 1.0 MB、`.rr_scratch` 1.0 MB、`.fix_scratch` 0.45 MB），加 6 份 `vivado*.log`（0.93 MB）、`regfile.sv.误改备份-20260926`、`.git-backup-20260926`、`FPGA/%TEMP/rvref`。 | `[实测]` 根目录清单与体积统计 | 新会话无法判断"哪个目录是仓库"；scratch 里的证据（`baseline_top10.txt`、`base_*_timing_paths.rpt`）随时可能被清掉。 | ① 在根目录放一个 `README.md` 说明"仓库在 `FPGA/`"；② 把仍被引用的证据（见 E-03）搬进仓库、其余归档或删除；③ 删掉 `%TEMP` 这类误建目录 | M |
| **E-05** | P3 | `.fpga-cache/` | 149 份综合报告 + 上千个 sim 缓存目录（工作树 **1.27 GB**），**无保留策略**。 | `[实测]` 目录计数与体积 | 磁盘膨胀；也无从判断"哪份报告对应交付配置"（好消息：`reports/<ts>-<prog>/` 命名 + `synth-cache.json` 已能定位，只是没清理策略）。 | 给 `fpga_workflow.py` 加 `cache --prune --keep N`（保留最近 N 份 / 保留被 `coremark.csv` 引用的那几份） | S |
| **E-06** | P3 | `fpga/build_ila.tcl`（R33） | ILA 构建失败后**必须手动删 `fpga/ila_proj*`** 才能重试（踩过两次）。已 `.gitignore`，但仍是人工步骤。 | PITFALLS R33 | 每次 ILA 迭代都可能卡住一个人。 | 在 `build_ila.tcl` 开头/失败分支自动 `file delete -force`；`jtag_probe.bat`/`fpga_workflow hw` 里加"检测到 ila_proj 残留则提示/清理" | S |

### E. 性能（fmax / 面积）——需权衡，**先读完"不要做"那一节**

| ID | 级别 | 位置 | 观察 | 证据 | 建议 | 量 |
|---|---|---|---|---|---|---|
| **P-01** | P2 | 交付关键路径 | 当前关键路径是 **BRAM→BRAM 的内部走线**：`u_core/u_dmem/mem_reg_1/CLKBWRCLK` → `u_core/u_imem/rdata_reg_1/ADDRARDADDR[5]`，`Data Path Delay 12.727 ns`（logic 5.131 = 40.3%，**route 7.596 = 59.7%**），**18 级逻辑**（CARRY4=7, LUT6=5…），余量只有 **0.888 ns**。 | `[复算]` `fpga/timing.rpt` Max Delay Paths | R47 已实测封死"top-N 是墙时 RTL 逻辑重排期望≈0"，所以下一杠杆应是**结构性**的：把这条 `dmem 读出 → 格式化/前递/分支判定 → 下一条取指地址` 的超长链**切断**（例如让 imem 取指地址不依赖当拍 dmem 数据；或把 `pc_next` 的关键反馈与访存数据解耦）。**动之前先用 `tools/path_hotspot.py` 出 top-N + fo 榜，不要凭"用了多少"推断"能省多少"**（p3-imem 的教训：缩容 16KB→12KB 反而多 883 LUT）。 | L |
| **P-02** | P3 | `daVinciPro.xdc:34,46` | 50 MHz 输入时钟走 **非专用时钟引脚 R4**（需 `CLOCK_DEDICATED_ROUTE FALSE`）。 | `[实测]` XDC | 输入抖动/偏斜偏大。若板子走线允许，评估换到 MRCC 引脚；若是厂商固定走线则记录"已接受"。 | M |
| **P-03** | P3 | `fpga/timing.rpt` | `async_default` 组 `WNS 5.669`、823 端点（复位同步器的恢复/移除）。非瓶颈。 | `[复算]` Inter/Other Path Groups 表 | 无需动作，仅登记为"已知非瓶颈"，避免后人误当瓶颈追。 | S |

### F. 验证覆盖补强

| ID | 级别 | 缺口 | 证据 | 建议测试 | 量 |
|---|---|---|---|---|---|
| **V-01** | **P0** | **中断与流水线停顿/重定向并发**（即 R-01）**结构上零覆盖**。 | `[代码分析]` `sim/prog/timer_irq.S:61-63` 等待循环无 load、无重定向气泡，所以恰好避开；11 项回归里没有一项在 `irq_pending` 期间制造 load-use 停顿 | 新增 `tb_soc_irq_stall`：使能 MTIE+MIE、arm `mtimecmp` 为**很近**的到期点，然后立刻进入 `lw` + 距离 1 依赖循环；断言 `mepc != 0`、`mcause = 0x80000007`、且被打断指令在 `mret` 后**确实重新执行**（用 tohost 上报组号） | S |
| **V-02** | P1 | 无"非对齐 MMIO 访问"与"未映射地址访问"的测试（R-03/R-04 的行为从未被固定）。 | `rv32_pkg.sv:320` 只写了"外设一律 32 位对齐访问"的**约定** | 加定向测试：非对齐 MMIO 读/写、`0xB000_0000` 等未映射地址读写，明确"当前行为是 X"，为 R-03 的修复建立基线 | S |
| **V-03** | P1 | **上板闭环已经 37 小时没有更新**：`check` 自己报 `最后一批上板验证: 10-09 21:29 (2225 分钟前)`，而 10-10/10-11 的改动（LSU 字节通道、pblock、RR2）**全部未上板** —— 但文档仍以"已上板验证"表述。 | `[已实测]` `fpga_workflow.py check` 第 4/6 项输出 | ① 文档区分"仿真通过"与"上板验证"；② 让 `check` 的过旧告警**回流到 `metrics/report` 的结论**（现在只是 warn）；③ 上板一次以关闭风险 | M |
| **V-04** | P2 | 无 X 传播 / 时序断言（SVA）覆盖；`alu.sv:101`、`imm_gen.sv:45` 都**有意**输出 `'x` 作为"集成 bug 指示器"，但没有测试把这些 X 变成失败。 | `[实测]` `alu.sv:9-10,101`、`imm_gen.sv:45`；核内仅 `core.sv:1058-1064` 一条手工断言 | 给 `tb_units` / `tb_core` 加"关键写回/地址信号不得为 X"的断言；把 `core.sv` 里那条对齐断言扩展成一个小 SVA 包（含"trap 时 EX 必须有效"⇒ 正好能拦住 R-01） | M |
| **V-05** | P3 | `IMEM_COMB_READ` / `A_EN` 等回退配置不在 11 项矩阵里（靠 `--imem_comb_read --a-ext` 单独跑），默认回归**不覆盖**它们；而这些分支里有真实的分支逻辑（`core.sv:214-223` 的 `boot_done` 曾经就只在其中一个分支里声明过，导致过致命 bug）。 | `[实测]` `core.sv:208-223` 的历史注释；`build.tcl:55-120` | 至少把 `A_EN` 与 `IMEM_COMB_READ` 各加一条"编译+冒烟"到矩阵（`verify --only` 已有机制），或让 `check` 强制"每次改 RTL 后跑一次全宏矩阵" | M |

### G. 验证层自身缺陷（"谁来验证验证器"）

> 这一节来自对 `sim/`、`sw/`、`tools/` 的专项审阅 + 我的复核。**W-01/W-02/W-03 我已亲自确认。**

| ID | 级别 | 位置 | 问题 | 证据 | 影响 | 建议动作 | 量 |
|---|---|---|---|---|---|---|---|
| **W-01** | **P0** | `sim/tb_sw.sv:394`（`$display("  RESULT : PASS")`）、`:129-138` | **`tb_sw` 的 3 项回归"永远 PASS"**：TB 只在 ① `tohost==1` ② `tohost∉{0,1}`（fatal）③ `dbg_illegal`（fatal）④ 超时 这四种情况下做判断，**从不检查程序算出来的结果**。而三个程序都把结论"打印"而不"上报"：`sw/hello.c:60`、`sw/nn_demo.c:408`、CoreMark 只把 CRC 打进 MMIO 给 ILA 看。`[harness] fpga_workflow.py:1003-1012` 也只看 `"RESULT : PASS"` 字符串 + 未崩溃 + 未超时。 | `[已实测]` 读 `sim/tb_sw.sv:129-138,375-396` 确认：`$display("  RESULT : PASS")` 前**没有任何比较**。 | **11 项里的 3 项（含 CoreMark 与 GEMM 神经网络）在结果错时仍然是绿灯** —— README 的"逐位 CRC 匹配""逐元素一致"证据链实际靠人眼看输出。**这是本次审查第二个最重要的发现。** | 三个程序改成 `if (bad) TOHOST=2; else report_done();`（`tb_sw.sv:133` 已经会把 `tohost∉{0,1}` 判为 FAIL，**TB 一行都不用改**） | S |
| **W-02** | P1 | `sw/coremark/core_portme.h:85-88`（`#define CLOCKS_PER_SEC 50000000`，注释还写着"50 MHz (xdc: -period 20)"） | **`CLOCKS_PER_SEC` 停在 50 MHz，而交付设计跑 70 MHz** ⇒ `time_in_secs()`、`Iterations/Sec`、以及 CoreMark 自己的 **"必须跑满 10 秒才算有效"** 判定全部偏差 **1.4×**：3000 迭代实际 17.70 s 会被打印成 24.78 s。 | `[实测]` `core_portme.h:88`；`[复算]` 1,239,100,518 / 70e6 = 17.70 s vs / 50e6 = 24.78 s。仿真侧确实是 50 MHz（`sim/tb_sw.sv:22`），所以**只在硬件上出错**。 | 目前不违规（17.7 > 10 s），但**唯一自动守卫"≥10 s"的机制宽了 1.4 倍** —— 1300 迭代 @70 MHz（真实 7.67 s）会被判成合法；也让 R35（每次提速后重算 ITERATIONS）无法被程序自己验证。 | 与 `top_a100t.sv` 的 `.CLK_HZ(70_000_000)` 一样，把时钟频率抽成一处唯一定义（构建时传宏 `-DCLOCKS_PER_SEC=70000000`），并让硬件路径断言"实测 tick / 真实频率 ≥ 10 s" | S |
| **W-03** | P1 | `sim/tb_sw.sv:212-221,344-348` vs `:394` | **取指对齐自检只打印、不判失败**：`n_align_err` 递增后只 `$display("… <-- 取指错位!")`，随后仍无条件打印 PASS。 | `[已实测]` 读代码确认；该计数器从未参与 `$fatal`。 | 它正是为"IMEM 寄存读"那次改动（R30 / `results/p4-macro-failure.md` §5.1）建的**唯一安全网** —— 而现在"静默错位"会显示一行红字然后**绿灯退出**。 | dump 之后加 `if (n_align_err != 0) $fatal(1);` | S |
| **W-04** | P1 | `control_unit.sv:295`、`core.sv:905-909`、`load_store_unit.sv:137,143,146,186,303-306` | **`LR.W` / `SC.W` 无任何功能覆盖，且现有 LSU 路径会把它们做错**：`amo_newdata` 对 LR/SC 被强制为 0，但 LSU 的写使能**只由相位决定、与算子无关**（`amo_wr = amo_active & amo_phase`）⇒ 到写相时仍会 `dmem_we=1, wstrb=4'b1111` 写上 `0`。即 **`LR.W` 会把读到的那个字清零**；`SC.W` 写 0 且 `rd` 拿的是旧内存值而不是成功标志（`load_store_unit.sv:214`）。 | `[代码分析]`（我复核了 `core.sv:907-909` 与 `load_store_unit.sv:137-147,186` 的读写门控关系）；`sim/prog/amo.S:2` 明写"9 个 AMO，不含 LR/SC"；`tools/amo_vectors.py:42-54` 也只生成 9 个算子；`sim/tb_units.sv:467` 的检查**标题写着"SC.W rd<-成功标志"却只查 `wb_src`**，所以它"通过"的同时断言的语义 RTL 并未实现。 | `A_EN` 默认关 ⇒ **对评分零影响，但 README:47 写着 "RV32A ✅ 已完成"、HANDOFF 写着"已打通"** —— 这是"文档声称完成、实际半成品"的典型。 | ① 先写 20 行 `.S`（`A_EN` 打开）把真实行为钉住；② 修法：`dmem_we`/`dmem_wstrb` 在 `S_AMO` 相与 `amo_op_r != AMO_LR/SC` 相与（LR 只读、SC 按成功与否写 `rs2` 并回成功标志）；③ 改 README 表述 | S（测试）+ M（修 RTL） |
| **W-05** | P1 | `sim/run.bat:28-51`、`sim/run.sh:19-34` | **文档入口只跑 2/11 测试却打印 `=== ALL TESTS PASSED ===`**（与 D-04 同一根因，此处给出更精确的证据）。 | `[实测]` 两个脚本只编译 `tb_units` + `tb_core`+`basic.hex`，然后无条件打印 ALL TESTS PASSED。 | 按 README 走的人拿到 **18% 覆盖 + 绿灯**；`tb_soc`/`tb_sw`（外设/UART/MMIO/C 程序）从文档入口**完全够不到**。 | 让两个脚本转调 `python tools/fpga_workflow.py verify`，或至少把"ALL TESTS PASSED"改成"2/11 项通过" | S |
| **W-06** | P1 | `sim/run.bat:37-41` + `tools/asm.py:312-314` | **`run.bat` 会静默测试旧的 `basic.hex`**：汇编失败时 `asm.py` 不写文件，而 `run.bat` 的守卫是 `if not exist prog\basic.hex`（判**存在**而不是**新鲜**）⇒ 编译+仿真继续跑**上一次**的程序。 | `[实测]` 读两个文件确认逻辑；`basic.hex` 在 `.gitignore` 内（必然由本地生成）。 | 正是 PITFALLS R1 的形态：**改了 `basic.S`、改坏了、跑 `run.bat`、拿到"PASS"**。 | 汇编前先删除旧 hex，或以汇编器退出码为门（`asm.py` 已有非零退出语义） | S |
| **W-07** | P1 | `.gitignore:16-24`、`tools/run_coremark.py:55`、`tools/mk_cm_hw.py:48` | **全新克隆无法复现 "PASS 11"**：`sim/prog/*.hex` 全部被 ignore（只放行 `amo_vectors.hex`），而 `cm_rv32im.hex`（`tb_sw_coremark` 用）与 `nn_demo.hex` 与 `hello.hex` **在任何脚本里都没有构建命令**；构建配方只以散文形式存在于 `HANDOFF.md:847`、`results/m-ext-v1.md:58`。 | `[复算]` `git ls-files sim/prog` 只有 9 个 `.S` + `amo_vectors.hex`；`grep` 全 `tools/` 无 `cm_rv32im` / `nn_demo` 目标；`[harness] fpga_workflow.py:975-988` 会报 `[BLOCK] 缺镜像`。 | "本工程以实测为准"这条纪律，**在别人的机器上无法启动**。 | 给 `build_sw.py` 加一个"按名字构建全部回归镜像"的子命令（或加 `tools/build_all.sh`），并在 README 写清一条命令 | M |
| **W-08** | P1 | `sim/prog/timer_irq.S`（**无**并发停顿场景） | （与 R-01/V-01 同一处，此处仅记录"为什么现有测试测不到"）：`wait1` 循环是 `li`+`bne` 两条无 load 指令，BTB 学会后**既无 load-use 停顿也无重定向气泡**，所以 `irq_pending` 拉高的那一拍 EX 里一定是真指令。 | `[实测]` 读 `timer_irq.S:61-63` | 解释了 R-01 为什么潜伏至今。 | 见 V-01 | — |
| **W-09** | P1 | `fpga_workflow.py:735-736` vs `:768`；`sim/tb_units.sv:430-485` | **`tb_units` 的 AMO 译码检查默认被 `ifdef` 掉**：AMO 相关 `chk()` 共 20 处，其中 **19 处在 `` `ifdef A_EN `` 分支内**，而回归矩阵给 `tb_units` 的 `defines` 是**空的**（对比 `tb_core_amo` 显式带 `("A_EN",)`）。 | `[实测]` 读矩阵配置与 TB 分支；`README.md:88`/`CODE-MAP.md:143` 却宣传 tb_units 含 "RV32A 的 ALU/译码检查"。 | **宣传的覆盖在日常回归里是死代码**；AMO 译码一旦回归不会被发现。另外矩阵里硬编码的描述 "194 项单元检查" 与 TB 运行时自打印的数字口径不一致（后者才是本工程约定的口径）。 | 给 `tb_units` 矩阵项加 `"defines": ("A_EN",)`；把硬编码的 194 改掉（以运行时打印为准） | S |
| **W-10** | P1 | `tools/run_coremark.py:94-96,127`、`fpga_workflow.py:1003-1006` | **CoreMark 的 CRC 校验失败不会让任何东西变红**：`run_coremark.py` 抓到 `ERROR!.*crc` 只打印 `(FAIL!)` 然后 `return 0`；`verify` 的崩溃判据只有 `"** Error"` / `"Fatal"`（而 CoreMark 打的是 `ERROR! list crc ...`) ⇒ CRC 不匹配 → 绿灯 + exit 0。 | `[实测]` 读两个文件；PITFALLS 的 Checklist 明确要求三个 CRC（0xe714/0x1fd7/0x8e3a）匹配。 | PITFALLS 自己列的验收项**没有自动化**；只有上板 bit31 路径能兜住。 | `run_coremark.py` 与 `verify` 都把 `ERROR!`/CRC 不匹配计入失败 | S |
| **W-11** | P1 | `sim/tb_core.sv:22,125`、`sim/tb_soc.sv`（无 plusarg） | **`+max_cycles=` 被 `tb_core`/`tb_soc` 静默忽略**：`tb_core` 用 `localparam MAX_CYCLES = 20000` 且只解析 `+dump`；`tb_soc` 完全不解析 plusarg。而回归矩阵给它们传的是 `max_cycles=200000/400000`。 | `[实测]` 读 TB；`[harness] fpga_workflow.py:739,744,753,767,776,780,993` 确实在传。 | 矩阵里的超时配置是**死配置**：五个 `tb_core*` 项实际都在 20 000 拍超时。写新程序需要更多周期时会得到假的 "timeout"，而工具声称给了 20 万拍。 | 两个 TB 都加 `$value$plusargs("max_cycles=%d", ...)`（`tb_sw.sv:104` 已有现成写法） | S |
| **W-12** | P2 | `tools/asm.py:168,179,183,187,191,195,205,215,268-310` | **汇编器对超范围立即数/分支静默取掩码**（`off & 0x1FFF`、`& 0x1FFFFF`、`& 0xFFF`、`sh & 0x1F`），**没有越界诊断**；`.org`/第二个 `.text` 只改标签计算器而**不填充到目标地址**；`.data` 下的 `.word` 被解析但**永不输出**。 | `[代码分析]`（审阅 A 逐段读了 `asm.py`；我未执行汇编器，因为它会写文件） | `sim/prog/*.S` 是本工程的"地面真值"。一个超范围分支会被编到错误目标，于是**测试实际验证的东西与它声称的不一样**（或变成死循环看起来像超时）；`.data` 里的字静默变 0。 | 加范围检查并在越界时报错退出；`.org`/`.data` 要么支持（填充/输出）要么明确报"不支持" | S |
| **W-13** | P2 | `sim/tb_units.sv:2-4,95-148` | **一半 RTL 模块没有单元测试**：`tb_units` 只例化 `alu`/`imm_gen`/`branch_unit`/`control_unit`/`regfile`/`pc`；`hazard_unit`、`load_store_unit`、`muldiv`、`csr_file`、`btb`、`ras`、`imem`/`dmem`、三个流水寄存器**都只能在 `tb_core`/`tb_sw` 里被间接覆盖**。另外 `mtval` 全工程无任何测试读取，`mstatus.MPP` 只被打印不被断言。 | `[实测]` `grep` 例化点只在 `core.sv`；`csr_file.sv:103,126,182,202` 实现了 `mtval`；`tb_soc.sv:111-115` 打印 mcause/mepc/mtvec/mstatus 但**不含 mtval**。 | 本工程最容易出事的三块（**冒险/前递、LSU、CSR/陷阱**）恰恰是最缺直接激励的。这也是 R-01 能潜伏的结构性原因。 | 至少给 `hazard_unit`（纯组合，最好测）与 `load_store_unit` 字节通道建独立单元测试；`csr_file` 的 mtval/MPP 加断言 | M |
| **W-14** | P2 | 全 `sim/` | **没有任何 X 传播断言**：全套 TB 里唯一对 X 敏感的是 `tb_units.sv:39` 的 `chk` 用 `!==`；`tb_core`/`tb_soc`/`tb_sw` 对 `dbg_pc`、`tohost_word`、控制束都没有 `$isunknown`/`===` 检查。 | `[实测]` `grep` 全 `sim/` 无 `$isunknown`、无 `1'bx` 比较；而本工程有明确的 X 历史（README:176-179、PITFALLS §二）。 | `alu.sv:101`、`imm_gen.sv:45` **有意**输出 `'x` 作为"集成 bug 指示器"，但没有测试把这些 X 变成失败；X 流到写地址或"从不被读回"的寄存器完全无声。 | 每个 TB 加一条 `always @(posedge clk) if (!rst && $isunknown(dbg_pc)) $fatal`，并扩展到控制束/写地址 | S |
| **W-15** | P3 | `fpga_workflow.py:797-817`；`sim/tb_sw.sv:236-249,349-365` | **宏门控代码默认从不编译**：`BTB_GSHARE`/`RAS_EN`/`GEMM_EN`/`IMEM_COMB_READ`/`LOAD_RESULT_REG` 全部是 opt-in 开关，11 项矩阵里没有一个设置它们；`tb_sw` 里整整一段 RAS 自证（层次化引用 `u_ras`/`u_btb.is_ret`）只在 `--ras` 下才编译。 | `[实测]` 读矩阵与 TB 分支 | R17 的教训是"宏生效必须有自证"，但**自证代码本身从不被编译**时，它会静默腐烂（编译错、层次名失效都要等到下次做实验才发现）。 | 给每个宏加一条 **compile-only 冒烟**（或 opt-in 矩阵行） | S |
| **W-16** | P3 | `tools/amo_vectors.py:85`、`sim/tb_units.sv:467`、`sim/tb_core.sv:7-9,15`、`sim/tb_sw.sv:294` | **"黄金向量"没有消费者 + TB 注释腐烂**：`amo_vectors.py` 生成的 108 条向量（README:91 / HANDOFF:128 都拿它当卖点）在仓库里**没有任何 TB / `.S` / 工具读取**（`git grep amo_vectors` 只命中文档与生成器自身）；`tb_core.sv:9` 说 tohost 在 `+0x1000` 而代码用 `+0x2000`（`link.ld:22-24` 记录过这次搬迁），而 `check` 里那条专门查这个腐烂的检查**文件清单只有 `tb_sw.sv`**，恰好漏掉 `tb_core.sv`；`tb_core.sv:15` 还引用不存在的 `sim\run_core.bat` 与 `IMEM_INIT` 参数。 | `[实测]` grep + `Test-Path` | 黄金向量 = 白做；`+0x1000` 那条注释会在调试 tohost 时把人带到错误地址。 | 接一个消费者（或把向量并入 `tb_units` 的 AMO 段）；把 `check` 的 tohost 一致性检查扩到 `tb_core.sv`；清掉 TB 注释腐烂 | M |

### H. 度量链与上板流程（专项审阅补充）

> 这一节来自对 `fpga/` 与 `rules/`（`fpga_workflow.py` 的度量/上板部分）的专项审阅，
> 其中 X-01/X-02 已由审阅者**实跑复现**。**它们与 M-01 合起来说明同一件事：
> 度量链上有 6 个独立的"数字来源不可信"点，任何一个都足以让 `results/` 里的结论失真。**

| ID | 级别 | 位置 | 问题 | 证据 | 影响 | 建议动作 | 量 |
|---|---|---|---|---|---|---|---|
| **X-01** | **P0** | `fpga_workflow.py:1279`（与 M-01 同一个 bug，此处给出**另一条独立证据链**） | 该正则在 MMCM **之前**是对的、**之后**静默失效 —— 也就是说它是**回归**，不是"一直如此"。 | `[已实测]` 审阅者复现：`.fpga-cache/reports/20261008-203550-cm_hw/metrics.json` → `"fmax": 69.808`（= 文档的 69.8，当时 `timing.rpt:152` 的 `sys_clk 5.675` 是真 WNS）；`20261011-004830-cm_hw/metrics.json` → `"wns": 7.0, "fmax": 76.923`（`timing.rpt:155` 的脉宽行）。 | 同上（M-01）。也解释了一个反常现象：**文档说 69.8（偏悲观），工具说 76.9（偏乐观），真值 74.64 被夹在中间，两边都不对。** | 修 M-01 时**同时加一条回归测试**：拿 20261008 与 20261011 两份报告喂给解析器，分别必须得 69.81 与 74.64 | S |
| **X-02** | P1 | `fpga_workflow.py:1877-1880`（`fresh = (now − mtime) ≤ --max-age-min`） | **`hw` 的"数据新鲜度"防线可被一次 `git checkout` 绕过，在没有板子的情况下打印"上板验证 PASS"。** 判据只有 mtime，而 `results/ila_done.csv` **是被 git 跟踪的**（含 2048 行 `ila_ctrl=0xC2`（locked\|done\|pass）、`score_result=0xC9DB2C66`（CRC bit31=1）），任何 clone/checkout/restore 都会把 mtime 刷成"现在"。 | `[已实测]` `git ls-files results` 含 `results/ila_done.csv`；`git log` 显示由 `688083b` 提交；`.gitignore` 明确忽略 `fpga/*.log`，所以唯一的旁证 `fpga/cap_done.log`（`CAPTURE_OK`）**不在版本控制里**，无法交叉校验。 | 这正是 **R20/PITFALLS:283「验证工具可能制造虚假证据」** 要防的事，而现在的触发条件从"板子掉线"变成了**日常 git 操作**。对以"上板实测"为核心价值的项目，这是最危险的一条。 | ① 判据加"同一次采集的见证"（`fpga/cap_done.log` 的 `CAPTURE_OK` + 时间戳，或把采集令牌写进 CSV 头）；② 把 `results/ila_done.csv` 移出 git（改名保留 `*.fixture.csv`）；③ 或直接用综合指纹绑定（见 X-03） | S |
| **X-03** | P1 | `fpga_workflow.py:1289-1304`（`latest_ticks()`）、`:1333-1336`、`:1377`（`append_csv`） | **CoreMark 的 ticks 来自"碰巧存在的那份仿真日志"，与它被配对的 LUT/fmax **没有任何来源绑定**。** 机器可校验的钥匙其实早就存在（`verify` 存了每项测试的内容指纹 `verify-state.json`；`synth` 存了自己的 32 位输入指纹），但**两者从不比较**。 | `[复算]` `parse_profile(read_text(.fpga-cache/logs/tb_sw_coremark.log))` 无条件读取；PITFALLS **R42.1** 记录过一次真实事故（`jal-ifdec-c` 行的 `ticks/cm` 来自 RAS 配置、而 `lut/ff/fmax` 来自 JAL 配置），当时靠 `2e203d4` **手工修行**。 | "用旧 RTL 的 ticks 算新配置的 CoreMark/MHz" —— 又一个静默错误，且**已经发生过一次**。 | `verify` 把日志指纹写进日志头/状态文件，`latest_ticks()` 要求它与当前综合指纹一致，否则拒绝并用 `[STALE]` 报错 | S |
| **X-04** | P1 | `fpga_workflow.py:1377`（`"status": "keep"` 硬编码）、`:1146-1148`（`kept[0]`/`kept[-1]`） | **工具永远无法记录一个"被否决"的实验**：`append_csv` 的 `status` 是常量 `"keep"`，从不来自 `m`（`notes` 来自 `m`，`status` 不来自），`cmd_synth`/`cmd_hw` 也没有传入口。于是 `report` 的"最新保留配置 vs 基线"会用**工具最后一次追加的那一行**做锚点，**包括被否决的构建**。 | `[复算]` 代码 + CSV 里 22 行被**人工**改成 `rejected`/`[MEASUREMENT ONLY - not the shipped config; reverted]`（`coremark.csv:152-161` 等）。 | 实验日志的核心不变量（keep vs rejected）**没有机器约束**；工具自己那句纪律提醒（`:1726`"被否决的方案要记 rejected"）**通过工具做不到**。 | 让 `status` 由调用方/判定结果传入；`report` 的锚点只取 `status == keep` 且**当前综合指纹匹配**的行 | S |
| **X-05** | P1 | `tools/path_hotspot.py:141-160,369-374,394` | **`path_hotspot.py` 的 fmax 也是错的（偏低 30%）**：它取报告里**第一个** `Period(ns):`，而那是 `sys_clk` 的脉宽块（`timing.rpt:200` = 20.000），不是最差路径的 `Path Group: sys_clk_70` / `Requirement: 14.286ns`（`timing.rpt:276`）。 | `[已实测]` 审阅者实跑：`period = 20.000 (constraint block) / WNS = 0.888 / fmax = 52.32 MHz`，正确值 74.64 —— 而且它把矛盾的两行**并列打印出来了**。 | 这个工具是 R47 之后指定的"物理优化前的首选测量工具"（PITFALLS:665-666），而它给出的 fmax/slack 记账**锚低了 22 MHz**：会把真实改进读成"没动"、把回归读成"改进"。 | 优先用报告块自带的 `Requirement:` 时钟/周期（它已经解析了 `Path Group`）；或按最差路径的组名去 Clock Summary 里配对，而不是取第一行 | S |
| **X-06** | P1 | `fpga/build.tcl:244,317`；`fpga_workflow.py:1519,1284` | **构建链上没有任何"时序收敛"门。** `report_timing_summary` 只是生成报告，`build.tcl` 从不检查 WNS/WHS 或 Vivado 自己那句 `All user specified timing constraints are met.`；harness 的成功判据只有 `BUILD_OK` 标记与宏自证标记。 **时序违约的构建照样写出 bitstream，并被 `parse_reports` 算出一个"看起来正常"的 fmax（例如 WNS=−1 → 47.6 MHz），再被 `append_csv` 盖上 `keep`。** | `[复算]` `timing.rpt:132` 有 `All user specified timing constraints are met.` 但没人读；`parse_reports:1284` 的 `if wns < 20.0` 对负 WNS 也成立。 | 一个坏构建会被当成"一次正常的测量回归"记进 `results/`，而不是"构建失败"。 | `build.tcl` 里断言 `WNS ≥ 0` 并 `puts "BUILD_TIMING=FAIL"`；`cmd_synth` 把它当致命错误（`write_bitstream` 在 2018.3 非工程模式下是否自己拒绝违约 **需确认**，但 harness 侧缺门是确定的） | S |
| **X-07** | P1 | `fpga_workflow.py:476-479` vs `:484-487`、`:1547-1559` | **`check` 用 mtime 判 RTL 是否比 bitstream 旧，而同目录的 JSON 里其实已经存了内容哈希。** `synth-cache.json` 存了每次构建的输入哈希，但只有**两个镜像**按 sha256 比对，RTL/XDC 走的是 `os.path.getmtime(fp) > bit_t`。 | `[复算]` 代码；`git checkout <file>` / `git stash` / 从归档拷贝都会让**不同内容**看起来"更旧" ⇒ 被误判为"新鲜" ⇒ `check` 打印 `bitstream 比所有输入新`。 | `check` 可能在**工作区 RTL 与 .bit 里的网表不一致**的情况下给出"一致"结论 —— 而这正是上板前最后一道门。 | 把每次构建的逐输入 sha256（或整个 `fp` 指纹）落盘，`check` 改为**比内容**、mtime 只做兜底 | S |
| **X-08** | P2 | `fpga/mmio_subsys.sv:35,88-91,108-121` | **MMIO 写忽略 `wstrb`**：`wstrb` 只在端口声明与 `GEMM_EN` 分支里出现，寄存器逻辑从不读它；而同一张地址映射的 DMEM 侧**是**遵循字节使能的（`core.sv:947` 用 `dmem_wstrb != 0` 判空写）。⇒ 对 `MMIO_GPIO_OUT` 做一次 `sb` 会把 `rs2` 的**全部 32 位**写进去，而不是 1 个字节。 | `[复算]` `git grep wstrb fpga/mmio_subsys.sv` 只有声明与 GEMM 连接。 | 栈内错误的静默外设状态。当前被"软件只用字写"掩盖（`core_portme.c:96-97`、`nn_demo.c:32-42`），属**潜伏的真 bug**。 | 每个字节通道按 `wstrb` 门控；或明确记录限制并**在仿真里加断言**（后者更便宜，符合本工程"约定要有守卫"的作风） | S |
| **X-09** | P2 | `fpga/build_ila.tcl:15,46-49`；`fpga/ila_cap_done.tcl:29-31`；`fpga_workflow.py:2164` | **ILA 构建同样没有时序检查**（只断言 `PROGRESS == 100%`），且**抓取窗口与预期 tick 是手工同步的魔数，散落在三个文件里**：`after 22000`（`ila_cap_done.tcl:29`）、`--expect-tick 1239100117`（`fpga_workflow.py:2164`）、`ITERATIONS=3000 → 约 1.239e9 拍 → 17.70 s`（`build_ila.tcl:8-9`）。 | `[复算]` 三个文件里的常量；`build_ila.tcl` 从不读 `timing_ila.rpt:51`。 | ① 时序违约的 ILA 镜像也能被烧进去并产出"上板已验证"的证据；② 下次按 R35 改 `ITERATIONS` 时，这三处必须**同时**改，否则抓取落在运行中间（表现为"没采到 done=1"）。 | ① `build_ila.tcl` 断言 WNS ≥ 0；② 让 `mk_cm_hw.py` 把 `ITERATIONS` 与预期 tick 写进一个小 JSON，`.tcl` 和 workflow 都从它读 | S |
| **X-10** | P2 | `skills/fpga-riscv-a100t/PITFALLS.md:483-506,716-726`；`fpga/build_ila.tcl:15` | **R33 的修复仍是人工步骤，R41 的哈希守卫仍未实现。** `create_project -force` 只覆盖 `.xpr`，不清 `ila_proj.srcs/.../ip/ila_0`、`ila_proj.runs`、`.cache`、`.hw`、`.ip_user_files` —— 正是 R33 描述的损坏态；`git grep ila_proj` 在三个脚本里都找不到清理步骤。R41 的"建像前后各记一次哈希"也仍是人工：`.fpga-cache/_rtl_before.txt` 存在，但**没有任何被跟踪的代码读写它**（`git grep _rtl_before` 只命中 PITFALLS）。 | `[复算]` `git grep` + 文件存在性。 | 一个"看起来像 Vivado 坏了"、已重复两次的失败模式，每次仍要付一个完整 ILA 构建周期；"这个 bitstream 里是哪版 RTL"对**唯一产出硬件结论的产物**仍是人工流程。 | `build_ila.tcl` 开头 `file delete -force` 那 5 个路径；`add_files` 后 `puts "ILA_RTL_SHA=<sha256 of all *.sv>"` | S |
| **X-11** | P3 | `fpga/mmio_subsys.sv:179-187,202-205,264-273,282-286` | **UART 无背压，两个字节计数器统计的是"尝试/到达"而不是"成功传输"**：`tx_byte_count` 在写选通上自增而不管 `tx_busy`（写丢失也照加）；RX 无 FIFO、无 overrun 标志，第二个字节会在软件读走前**覆盖** `rx_byte`，而计数器继续加。 | `[复算]` 代码。 | 拿来证明"UART 通了"的两个仪器都会多报；丢失的字节无法察觉。板载 FT2232H 没引 COM 口，所以**硬件上目前没被使用**。 | 加 1~2 级 TX FIFO 或粘滞 `tx_drop`；RX 加 overrun 位；只对成功移位的字节计数 | M |
| **X-12** | P3 | `fpga/mmio_subsys.sv:213` vs `fpga/top_a100t.sv:116` | **异步输入 `uart_rxd` 的同步链缺 `ASYNC_REG`**（同一个工程的复位同步链 `rst_sync` 却写对了）。 | `[复算]` 两处对比；`uart_rxd` 是 D17/E14 的板级异步输入（`daVinciPro.xdc:43`），同步后还被**组合**使用（`:243,250,258`）。 | 功能影响低（采样点距边沿约 300 拍），但修复免费且是一致性。 | 加 `(* ASYNC_REG = "TRUE" *)` | S |
| **X-13** | P3 | `fpga/mmio_subsys.sv:135-137,151-160,294-295,303-304` | **`mtime`/`mtimecmp` 与自由运行计数器别名，无原子快照**：注释说"`MMIO_MTIME_*` 与 `MMIO_CYCLE_*` 读出来必然一致"（这句是真的），但 LO/HI 两次读可以跨越进位；`mtimecmp` 分两拍写会暴露中间值（LO 先写**变小**的到期点时，会瞬态得到 `{旧HI, 新LO}` ⇒ **可能提前触发**）。 | `[复算]` 代码；`sw/coremark/core_portme.c:64-75` 用 hi/lo/hi 重试，所以**当前唯一消费者是安全的**。 | 目前无撕裂消费者（已核对 `core_portme.c` 与 `nn_demo.c:76-80`），但 P2 的方向正是"让中断处理程序用定时器"—— 那就会踩到。 | 加"读 LO 锁存 HI"的读影子寄存器（CLINT 做法），或在 `MMIO_MTIME_*` 常量旁写明**必须** LO/HI/LO 重试 | S |
| **X-14** | P3 | `fpga/mmio_subsys.sv:344-350,160`；`rv32_pkg.sv:359` | **GEMM 遗留**：`gemm_irq` 被接出来却**没有去任何地方**（`irq_timer` 里没有它），所以 `MMIO_GEMM_CTRL.bit1=irq_en` 是**死开关**；arena 窗口译码用 `addr[31:11]`（2 KB），而注释写"1 KB"。 | `[复算]` 代码。 | `GEMM_EN` 默认关且实测净亏（LUT 4019→9984、FF +916%），影响低；但按 `:321-323` 重新启用的人会遇到"中断永远不来 + 窗口大小和文档不符"。 | 接上 `gemm_irq` 或删掉这个开关；把窗口大小改成与 `addr[31:11]` 一致 | S |

---

## 2. 分期计划

### P0 —— 先做这六件（都在 1~2 天内）

1. **R-01 中断气泡 bug**：确认 → 修 → 加 `V-01`/`W-08` 定向测试。
   *验收*：新测试在修前**必须能复现**（`mepc == 0`），修后 `mepc` 为被打断指令的真实 PC；
   11 项既有回归仍 PASS 11。
2. **M-01 fmax 解析**：重写 `parse_reports()`，时钟名与约束周期参数化。
   *验收*：对 `20261011-004830-cm_hw` 复算得 **74.64**（不再是 76.92）；
   人工把 `create_clock -period` 改成 15 → 结果必须变化（证明不再对时序不敏感）；
   **并把 `20261008-203550` 那份报告作为回归用例**（必须仍得 69.81，证明不是"改坏了旧的"）。
   顺带修 **X-05**（`path_hotspot.py` 取错 period，现在给出 52.32 MHz 的荒谬值）。
3. **M-02 缓存把 FAIL 洗成 SKIP**：skip 条件加 `status == "PASS"`，清理孤儿条目。
   *验收*：构造一个必然 FAIL 的测试跑两次，两次都必须报 FAIL 且 exit ≠ 0。
4. **W-01 `tb_sw` 无条件 PASS**：三个程序改成"算错就写 `tohost=2`"。
   *验收*：故意把 `nn_demo.c` 的一个期望值改错，`verify` 必须变红；改回后必须变绿。
   > 这条与 1~3 同级的原因：**在 W-01 修好之前，"PASS 11"不能作为任何改动的安全网** ——
   > 包括 R-01 的修复本身。

另外两件同样属于 P0、但只花几分钟（**"结论可信度"的地基**）：

5. **X-02 堵住"假上板证据"**：给 `hw` 的新鲜度加"同一次采集的见证"（`fpga/cap_done.log`
   的 `CAPTURE_OK`+时间戳，或把采集令牌写进 CSV 头），并把 `results/ila_done.csv` 移出 git。
   *验收*：`git checkout results/ila_done.csv` 之后跑 `hw`，必须报 `[STALE]`/拒绝给结论。
6. **X-03 ticks 来源绑定**：`verify` 把 CoreMark 日志的指纹写下来，`latest_ticks()`
   要求它与当前综合指纹一致（R42.1 曾经手工修过一次 CSV，这次让它机器可查）。

### P1 —— 一周内（信任度与文档）

7. **X-04** `append_csv` 的 `status` 改为由判定/调用方传入（现在硬编码 `"keep"`，
   工具**永远无法记录一个被否决的实验**），并修掉 CSV 内层引号未转义的 bug。
8. **X-06** 构建链加时序收敛门：`build.tcl` 断言 `WNS ≥ 0` 并打 `BUILD_TIMING=FAIL`，
   `cmd_synth` 当致命错误（现在时序违约的构建照样出 bitstream 并被记成 `keep`）。
9. **X-07** `check` 的 RTL 新鲜度改为**比内容哈希**（哈希已经存在 JSON 里），mtime 只兜底。
10. **D-01/D-02/D-03** 一次性把 README / HANDOFF / CODE-MAP / gap-analysis / analysis-report
   的头部指标、上板口径全部改成实测值（用本文 §0.1 的表作为唯一口径）。
11. **D-04/W-05/W-06** 修正"跑测试"入口：改为 `python tools/fpga_workflow.py verify`；
   修掉 `run.bat` 的"存在即新鲜"守卫与"2/11 却报 ALL PASSED"。
12. **W-02** `CLOCKS_PER_SEC` 与真实时钟统一（构建时传宏），并让硬件 ≥10 s 判定可自证。
13. **W-03** `tb_sw` 取指对齐自检改为 `$fatal`。
14. **W-04** `LR.W`/`SC.W`：先写测试钉住行为，再修 LSU 写使能；同时改 README 的"RV32A ✅ 已完成"。
15. **W-09/W-10/W-11** 三个"配置与判据失效"：`tb_units` 补 `A_EN`、CRC 失败判红、
    `+max_cycles` 真正生效。
16. **W-07** 新克隆可复现：加一条命令构建全部回归镜像。
17. **D-05/D-06/D-11** `CODE-MAP.md` 行号与行数按当前文件重算；PITFALLS 的数量与体积改正。
18. **D-07** 新增"Flash 固化"一节（脚本清单 + 一条端到端命令 + R44-R46 指路）。
19. **E-01** 大二进制出库（`git rm --cached` + `.gitignore`）；**E-02** `build.tcl` 去硬编码路径。
20. **E-03** `check_equiv.py` 入库并接入 `verify`。
21. **M-06** 引入 Verilator lint（或 iverilog `-Wall` 严格模式）作为 `check` 的一项。
22. **V-03** 明确区分"仿真通过 / 上板验证"，并把 HIL 过旧告警回流到结论。
23. **R-02** `mtval` 接真实值。

### P2 —— 两三周内（补强）

24. **R-03/R-04** 访问错误异常 + `ext_re` 门控（这两条一起做，因为都涉及"地址是否合法"）。
25. **X-08** MMIO 写按 `wstrb` 门控（现在 `sb`/`sh` 会写满 32 位），或至少加断言把约定钉住。
26. **M-03/M-04** `hw` 默认值改为必填/自动推断；`coremark.csv` 的 `fmax` 列一次性重算 + 标注口径。
27. **X-09/X-10** ILA 流程：构建后断言 WNS、把 `ITERATIONS`/预期 tick 抽成单一来源、
   自动清理 `ila_proj*`、打印 RTL 哈希（R33/R41 收尾）。
28. **D-08/D-09/D-10/D-12** 修掉自相矛盾/被推翻的技术文档（尤其 `p7-cache-analysis.md` 与 `btb.sv` 头注释）。
29. **W-12** `asm.py` 加越界诊断（分支 ±4 KiB / JAL ±1 MiB / 立即数），`.org`/`.data` 要么支持要么报错。
    > 优先级不低：**测试程序本身编错，等于所有依赖它的结论都不可信**。
30. **W-13** 给 `hazard_unit` / `load_store_unit` / `csr_file` 建独立单元测试（含 `mtval`、`mstatus.MPP`）。
31. **V-02/V-04/W-14** 非对齐/未映射访存基线测试 + X 传播断言 + "trap 时 EX 必须有效"断言。
32. **E-04/E-05/E-06** 工作区整理、缓存清理策略、ILA 重建自动化。
33. **R-05/R-06/R-08** 小项：AMO 锁存边沿化 + 断言、`ras` 越界、死参数/死信号。
34. **P-01** 关键路径**先测量再动**（**先把 X-05 修好**，否则 `path_hotspot.py` 的测量本身不可信）。

### P3 —— 有明确触发条件再谈

35. **W-15** 宏门控分支的 compile-only 冒烟（防止 RAS/gshare 自证代码腐烂）。
36. **W-16** 黄金向量的消费者、`check` 的 tohost 一致性检查扩到 `tb_core.sv`、TB 注释腐烂清理。
37. **X-11/X-12/X-13/X-14** UART 背压与计数口径、`rxd_sync` 的 `ASYNC_REG`、
    `mtime`/`mtimecmp` 原子快照、GEMM 的 IRQ 与窗口大小。
38. **P-02** 时钟引脚（若要做第二版板卡）。
39. `R-07/R-09/R-10/M-07/M-08/D-13` 的收尾清理。

---

## 3. 不建议做（已被实测否决，别再花时间）

> 本工程最贵的教训就是"看起来该做、实测净亏"。以下每一项都**已有数据**，
> 新会话不要重开。参考 `HANDOFF.md:72-84` 与 `skills/fpga-riscv-a100t/OPTIMIZATION-PLAYBOOK.md`。

| 事项 | 实测结论 | 出处 |
|---|---|---|
| I/D Cache（2 路组相联 + 突发） | 架构性无收益（`imem`/`dmem` 已是单周期命中 BRAM） | `results/p7-cache-analysis.md` |
| `RAS_EN` | 机制有效（JALR 误判 4378→3558）但栈顶 mux 落在最紧的 `pc_target` 路径上，绝对吞吐 −2.3% | `results/p4-ras.md` |
| `BTB_GSHARE` | 两个变体都输给纯局部 Smith（慢 6%） | `results/p4-gshare.md` |
| `LOAD_RESULT_REG` | 更差 | `results/p4-macro-failure.md` 5.2 |
| radix-4 除法 | 只省 0.29% 周期，且对占比更大的"乘法启动拍"无效 | `muldiv.sv:93-113` |
| `GEMM_EN` | FF 1387→14097（+916%）、fmax −13%，且 C 读回未修完 | `results/p5-ai-accelerator.md` |
| BTB 扩到 128 项 | 误判仅少 347 次，LUT +258 且 fmax −4.6% | `core.sv:307-309` |
| 缩小 `imem` 容量省 LUT | 16KB→12KB 反而**多** 883 个 LUT | `results/p3-imem.md` |
| 单靠 `phys_opt` / place 策略调 fmax | 3 种策略 + 12 组 pblock 实测都在噪声量级 | `results/p3-fmax.md`、`coremark.csv` `rr2-pb-*` |
| `CLKFBOUT_MULT_F`/时钟再往上提 | 70 MHz 下余量只剩 0.888 ns（fmax 74.64），在没有 P-01 结构性改动前不要动 | `[复算]` `fpga/timing.rpt` |

---

## 4. 我对这个工程的整体评价（审查思考）

**做得好的地方（建议保持并显式写进交接文档）**

- **失败也留证据**：`results/` 22 篇 + 155 行 `coremark.csv` + 47 条 PITFALLS，让"别再试这个"有据可依。这是绝大多数同类项目缺的。
- **单一事实来源**：`rv32_pkg.sv` 把编码/枚举/控制束集中定义，`ctrl_s` 全零即安全 NOP —— 从写法上消灭了一类锁存器/复位 bug。
- **宏开关自证**：`build_ila.tcl` 打 `ILA_BUILD_IMEM_BRAM=1`、`btb` 打 `GSHARE ... ACTIVE`（`btb.sv:118`）—— 这是对 R17"宏没传进去"的正确回应。
- **缓存键覆盖物理约束**：`fpga_workflow.py:1424-1428` 把 pblock/place 指令纳入指纹，比多数 CI 做得细。
- **口径纪律**：`HANDOFF.md` 明确写"本节是唯一权威口径"，并在 `coremark.csv` 的备注里记录 WNS 与路径明细 —— 只是这次没守住（见 D-01）。

**结构性风险（这次审查暴露出来的）**

1. **"自证"链条上有断点**：`tb_units` 自打印检查点、`build_ila` 自打印宏状态都做得很好，但
   **`fmax` 这一个评分指标是从报告里正则抓来的、抓错了也没人发现**；
   **回归的缓存会把 FAIL 洗成 SKIP**；**`tb_sw` 的三项回归在结果错时仍然打印 PASS**；
   **CoreMark 的 CRC 校验失败不会让任何测试变红**；**`tb_units` 宣称的 AMO 译码覆盖默认不编译**。
   五处都属于同一类：**验证工具本身没有被验证**。
   ⇒ 建议立一条纪律并写进 `HANDOFF.md`：**任何进入 `results/` 或文档的数字，
   都必须能被一条命令复现，且"复现失败"必须能让命令非零退出。**
   具体做法：给 `verify` 加一条 `--self-test`，故意注入一个错误期望值，要求它变红。
2. **文档滞后于代码 ≥ 2 个迭代周期**：这不是"文笔问题"，而是**会主动误导决策的缺陷**
   —— 头部 fmax 差 6.9%，上板口径差整整一代。本工程的文档密度极高（这是优点），
   但缺乏"数字自动生成"机制，全靠手工同步。
   ⇒ 建议把 README/HANDOFF 的指标表改成**由 `fpga_workflow.py report` 生成**（或至少
   用 `check` 校验文档里的数字与 `coremark.csv` 一致），把"同步"从人的责任变成工具的责任。
3. **"未上板"与"已上板"在同一份文档里不加区分**：`check` 已经能算出"37 小时没上板"，
   但这个信息没有回流到结论。对一个以上板实测为核心价值的项目，这是最该自动化的一条。
4. **"声称完成"与"实际完成"之间有缝**：`README.md:47` 写 RV32A "✅ 已完成"，
   但 `LR.W`/`SC.W` 既无测试、其 LSU 路径还会把目标字清零（W-04）；
   `README.md:91` 拿 108 条黄金向量当卖点，而它们没有任何消费者（W-16）；
   `CODE-MAP.md:143` 说 `tb_units` 覆盖冒险/CSR/AMO，实际既没例化 `hazard_unit`/`csr_file`，
   AMO 检查默认也被 `ifdef` 掉（W-09/W-13）。
   ⇒ 建议给每个"✅"补一个**可执行证据字段**（哪条命令、哪个产物），没有就写"⚠ 部分"。
   这条对交接价值最大：本工程的口径纪律一向很好，**唯一没守住的就是"完成度"这一栏**。

### 4.1 已逐项核实为**正确**的部分（不要再花时间怀疑）

> 审查的价值一半在"发现问题"，一半在"确认哪些没问题"。以下都是**读过代码/复算过数据**
> 之后的结论，列出来是为了防止后人重复怀疑。

| 项 | 结论 | 证据 |
|---|---|---|
| 时钟链与 MMCM | **正确**。`CLKFBOUT_MULT_F=21 / DIVCLK_DIVIDE=1 / CLKOUT0_DIVIDE_F=15` 与 XDC 的 `create_generated_clock -multiply_by 21 -divide_by 15` **逐项对齐**；`.CLKFBIN` 已接（R43 已修）；BUFG 在位；`timing.rpt` 里 `sys_clk 20.000/50.000`、`sys_clk_70 14.286/70.000` 与设计一致 | `top_a100t.sv:72-111`、`daVinciPro.xdc:7,28-31` |
| CDC / 约束完整性 | **正确**。MMCM 之后是**单时钟域**（`Inter Clock Table` 为空），所以不需要 `set_clock_groups`；XDC 覆盖 RTL 全部 7 个端口；无无时钟寄存器（`check_timing` 报 0） | `timing.rpt:166-168`；`top_a100t.sv:29-33` vs `daVinciPro.xdc:34-43` |
| 复位 | **正确**。异步置位/同步释放、且**要求 MMCM 已锁定**；丢锁会重新拉复位；`async_default` 组 WNS 5.669 说明 Vivado **确实**在分析这条恢复/移除路径 —— 所以加 `set_false_path -from sys_rst_n` 是**错的**，不是"漏了" | `top_a100t.sv:116-124`；`timing.rpt:177` |
| UART 波特率（70 MHz 下） | **正确**。`BAUD_DIV = 70e6/115200 = 607` ⇒ 实际 115,321（+0.105%），远在 UART 容差内；RX 的下降沿判据与半位假起始位拒绝都对。只有 `:59` 的注释"50MHz/115200 = 434"过期 | `mmio_subsys.sv:59,188-196,243,247-253` |
| MMIO 读译码 | **正确**。单 `always_comb` 优先级链 + 默认 0，`MMIO_*` 常量两两不重叠，与 DMEM 窗口不交叠 | `mmio_subsys.sv:291-308`、`rv32_pkg.sv:312-313,324-339` |
| CoreMark 指标公式 | **正确**。`cm = it*1e6/tk`、`cm/lut`、`throughput = cm*fmax` 与 CSV 手算一致（`1e6/413070=2.4209`、`2.4209/2667=9.078e-4`、`×74.64=180.7`）；`verdict` 的 ±0.5% 死区与 >2% 吞吐告警与文档规则一致 | `fpga_workflow.py:1336-1340,1656-1675` |
| 综合缓存指纹 | **正确且罕见地细致**：RTL + top + `mmio_subsys` + XDC **+ `build.tcl`** + 两个镜像 + 全部架构宏 + place/route 指令 + Pblock 范围/单元 + `CONTAIN_ROUTING` + retiming 全部入键；且请求的宏若在日志里找不到 `BUILD_*` 标记就硬失败 | `fpga_workflow.py:1406-1431,1497-1525` |
| 报告归档 | **存在且可用**：每次综合把 `timing.rpt`/`util.rpt`/`metrics.json` 存进 `.fpga-cache/reports/<时间戳>-<prog>`，149 份 —— 这正是本次能定位 M-01 的原因。**问题在解析器，不在证据链** | `.fpga-cache/reports/*` |
| R43 的修复 | **已修复且已被硬件复验**（`ila_ctrl=0xC2` 即 bit7=locked） | `results/coremark.csv:139`、`top_a100t.sv:237` |
| `results/ila_done.csv` 的内容自洽 | **自洽**：`ila_ctrl` 位定义与 `top_a100t.sv:237` 一致；`&0x7FFFFFFF` 复现 tick 1,239,100,518；bit31 为 CRC 通过。**问题只在新鲜度防线的可绕过性（X-02）** | `fpga_workflow.py:2007-2010` |
| Vivado 生成物 | **正确地被忽略**：`ila_proj.*`/`*.xpr`/`*.srcs`/`*.runs`/`*.rpt`/`*.log`/`*.bit` 均未入库。**缺口只有 `.mcs`/`.bin`/flash 日志那一组（E-01）** | `git ls-files` + `.gitignore` |
| `tb_units` 的自检机制 | **真的自检**：`chk` 用 `!==` 比较，结尾 `$fatal(1)`；`tb_core`/`tb_soc`/`tb_sw` 的 `tohost` 失败分支与 `dbg_illegal` 路径都真的 `$fatal(1)` | `tb_units.sv:36-43,559`；`tb_core.sv:157-171`；`tb_soc.sv:204-213` |
| `fpga_workflow.py` 的失败传播 | **设计得对**：按显式 `"RESULT : PASS"` 字符串判定（不是 `"PASS" in out`）、处理 `quit -f` 返回 0、把 XPASS/BLOCK 计入失败、有真实超时（`TimeoutExpired` → rc 124）。**缺口在缓存层（M-02）** | `fpga_workflow.py:998-1012,1041` |
| `tb_soc` 的看门狗与断言 | **真实**：周期上限 + `#(50ms)` 绝对时间双看门狗；GPIO/UART 是真 `!==` 断言而非打印 | `tb_soc.sv:230-239,253-264` |
| `sw/link.ld` | **稳健**：LMA==VMA 是深思熟虑的（并有解释），三条 `ASSERT` 守卫 `.data+.bss ≤ 0x90002000`、`.data` 起点、`.text ≤ 16 KiB` | `link.ld:49-67,79-83` |
| `tools/elf2hex.py` / `build_sw.py` / `mk_cm_hw.py` | **正确**：小端 4 字节、镜像溢出显式 `rc=2`；总是链接 `crt0.S`+`libc_min.c`、缺源预检、`-lgcc` 在源后；`FLAGS_STR` 单 argv（避开 R15） | `elf2hex.py:84-89`；`build_sw.py:21,61-76`；`mk_cm_hw.py:50-79` |
| `.github`/CI 之外的双路径一致性 | **已考虑**：`build.tcl` 不在 `synth_inputs_for` 里，避免了 `patch_build_prog` 还原 `build.tcl` 后造成的"假陈旧" | `fpga_workflow.py:158-176` |
| 已被测量封死、**不需要再讨论**的事 | 继续提频（无余量可言）、GEMM、RV32A、RAS、gshare、`LOAD_RESULT_REG`、Cache、扩 BTB、缩 imem | 见 §3 |

---

## 5. 附：本次审查的复现命令

```powershell
cd D:\USER\Desktop\FPGA\FPGA

python tools\fpga_workflow.py doctor          # 工具链：ModelSim + Vivado + riscv-gcc 齐备
python tools\fpga_workflow.py verify --force  # [已实测] 11/11 PASS（真跑，非缓存）
python tools\fpga_workflow.py check           # 漂移检测：含"37 小时未上板"告警

# R-01 的证据链（读代码）
#   core.sv:723-731   exc_req 有有效性判据, irq_take 没有
#   id_ex_reg.sv:66-78 气泡/flush 把 pc 清 0
#   csr_file.sv:174   mepc <= trap_pc (= id_ex_pc = 0)

# M-01 的证据链（复算）
#   fpga/timing.rpt  → Clock Summary: sys_clk_70 = 14.286 ns / 70.000 MHz
#                    → Intra Clock Table: sys_clk 行 WNS 空、WPWS 7.000
#                                         sys_clk_70 行 WNS 0.888
#   真实 fmax = 1000/(14.285714 - 0.888) = 74.64 MHz
#   工具报   = 1000/(20        - 7.000) = 76.92 MHz   ← 错

# W-01 的证据链（读代码）
#   sim/tb_sw.sv:129-138  只判 tohost==1 / tohost∉{0,1} / dbg_illegal / 超时
#   sim/tb_sw.sv:394      之后无条件 $display("  RESULT : PASS")
#   sw/nn_demo.c:408      report_done(); return 0;   ← 不携带任何结论

# W-04 的证据链（读代码）
#   control_unit.sv:295   AMO_LR/AMO_SC -> 占位 ALU_ADD
#   core.sv:907-909       LR/SC 的 amo_newdata 被强制为 0
#   load_store_unit.sv:186  amo_wr = amo_active & amo_phase      ← 与算子无关
#   load_store_unit.sv:143  dmem_wstrb = amo_wr ? 4'b1111 : 0
#   load_store_unit.sv:146  dmem_we    = amo_wr
#   ⇒ 写相必然到达, LR.W 会把读到的字写 0

# X-01 的回归用例（修 M-01 时必须两份都过）
#   .fpga-cache/reports/20261008-203550-cm_hw/  → 必须得 69.81（MMCM 之前）
#   .fpga-cache/reports/20261011-004830-cm_hw/  → 必须得 74.64（MMCM 之后）

# X-02 的复现（不需要板子）
#   git checkout -- results/ila_done.csv      # 只刷 mtime
#   python tools\fpga_workflow.py hw          # 现在会打印"上板验证 PASS"
#                                             # 修好后必须变成 [STALE] / 拒绝结论

# X-05 的复现
#   python tools\path_hotspot.py fpga\timing.rpt
#   → period = 20.000 (constraint block) / fmax = 52.32 MHz   ← 荒谬值

# M-03 的复现（不带参数默认值）
#   python tools\fpga_workflow.py hw
#   → iterations = 1200 / CoreMark/MHz = 0.9684 / 24.78 s     ← 真值 2.4211 / 17.70 s
```

---

## 6. 执行记录（Agent Team 实测结果）

> 本节在审查之后追加，记录"计划 → 落地"的真实过程。**审查结论（§0~§5）保持原样不动**，
> 便于对照"当时判断 vs 实际结果"。

### 6.1 团队与泳道（写入范围互不重叠）

| 泳道 | 负责 | 项 | 状态 |
|---|---|---|---|
| L0 度量链与工具 | **Lead** | M-01/M-02/M-03/X-01~X-07 + M-06（综合警告门）+ E-01 | ✅ 已提交 `1b04142` `75bbacb` `936b5e5` |
| L1 RTL 正确性 | `rtl-fix` | R-01、R-02、W-04、**R48（新发现）** | R-01/R-02/R48 ✅ `4186f13`；W-04 进行中 |
| L2 软件与验证层 | `sw-verify` | W-01/W-02/W-03/W-05~W-07/W-09~W-11 | ✅ 全部完成（待收尾提交） |
| L3 文档同步 | `docs-sync` | D-04/D-05/D-06/D-07/D-11/D-13/V-03 + 口径纪律 + 7 项 check | ✅ 已提交 `b3c251c` |
| L4 构建与仓库 | `build-repo` | E-02/E-03/X-06/X-09/X-10 + E-01(.gitignore) | ✅ 全部完成（Vivado 实跑验证中） |

### 6.2 本轮**新增**发现（计划书里没有的）

| ID | 内容 | 怎么发现的 | 严重度 |
|---|---|---|---|
| **R48** | **陷阱只冲 ID/EX，`ex_mem_reg` 根本没有 flush 口** ⇒ EX 里被抢占的指令照样提交，MRET 后**再执行一次** = 中断"双执行"（`add` 变 2 倍、`sw` 写两次）。实测 trace：`c=2506 trap_enter` → `c=2509 s5=12345678`（提交）→ `c=2546 mret 回 80000100` → `c=2550 s5=2468acf0`（=2×）。ecall/非法指令看不出来（`control_unit` 早把它们中性化），旧 `timer_irq.S` 的等待循环是 `li+bne`（幂等）⇒ 一直没暴露 | rtl-fix 修完 R-01 之后**第二个更深**的 bug 才浮出来 | **架构级** |
| **X-08 被门直接命中** | 新加的 `check [7] 综合警告门` 第一个基线里就有 `[Synth 8-3331] design mmio_subsys has unconnected port wstrb[3..0]` —— 端口声明了却没人读，**Vivado 报了 4 次，从来没人看**。这正是 X-08（MMIO 写忽略 wstrb） | 建立警告基线时发现 | 中 |
| **镜像布局 → ticks 漂 2 拍** | `tb_sw_coremark` 的 ticks 一度从 413070 变 413072。sw-verify 用 **4 组对照实验**（HEAD 软件+当前 RTL / HEAD core_main / 纯数据布局平移 / 删掉某句打印）隔离到 **W-02 在 `stop_time()` 仿真路径加的一句 `ee_printf`**；`nm` 显示 `iterate/core_bench_*` 逐符号地址一致，只有 `core_portme.o` +0x1C、rodata +0x40 ⇒ **本核 BTB 按 PC 索引，镜像布局一变，测量区间就可能差 2 拍**。删掉那句后回到 413070 | sw-verify 主动认领并定位 | 工程属性（值得记 PITFALLS） |
| **`RB36 async control check` × 36** | 警告门基线里发现 `u_core/u_dmem/mem_reg_0 has an input control pin ...`（BRAM 异步控制引脚） | 警告门基线 | 待评估（非本轮范围） |
| **`muldiv` 死寄存器 × 93** | `[Synth 8-3332] Sequential element (prod_ss_reg[*] / prod_uu_reg[*]) is unused and will be removed` —— 乘法器推断出的 DSP 内部寄存器被判定未用 | 警告门基线 | 低（功能已验证） |

### 6.3 最终数字（**已冻结，上板验证**）

来源：`.fpga-cache/reports/20261011-111332-cm_hw/`（timing.rpt / util.rpt / metrics.json）
+ `results/coremark.csv` 行 `review-fixes-v1` + `results/ila_done.capture.json`（2026-10-11 11:19:07）。

| 指标 | 基线 | **最终（上板验证）** | 变化 | 文档原值（错/旧） |
|---|---|---|---|---|
| CoreMark/MHz | 0.8263 | **2.4209** | **+193.0%** | 2.4209 ✅ |
| fmax | 78.4 MHz | **74.4 MHz** | **−5.1%** | 69.8（错：MMCM 之前的 20ns 口径） |
| CoreMark/LUTs | 2.361e-4 | **8.848e-4** | **+274.8%** | 9.139e-4 |
| 绝对吞吐 | 64.8 | **180.2** | **+178.1%** | 169.0 |
| 资源 | — | LUT **2736** / FF **1251** / BRAM **8** / DSP **8** | — | 2649 / 1234 / 8 / 8 |
| 仿真 ticks | — | **413,070** | 不变 | 413,070 ✅ |

fmax 口径：`sys_clk_70 @14.286ns`，WNS **+0.854**，`1000/(14.286 − 0.854) = 74.4 MHz`。

**上板实测**（2026-10-11 11:19:07，`build_ila` → `ila_cap_done` 全自动闭环）：

| 项 | 值 |
|---|---|
| `ila_ctrl` | `0xC2` → locked=1 done=1 pass=1 fail=0 **illegal=0** |
| `score_result` | `0xC9DADA56`（bit31=1 → **结果有效：CRC 匹配 且 时长≥10 s**） |
| tick | **1,239,079,510**（3000 迭代 @70 MHz，**17.70 s**） |
| 硬件 CoreMark/MHz | **2.4212**（仿真 2.4209，差 0.01%） |
| tick 与预期偏差 | **0.002%**（门限 0.5%） |
| 程序状态 | `dbg_pc` 稳定在 `0x80001C50`，停在结尾 `j .`（`dbg_instr=0x0000006F`）→ 确认跑完 |
| 判据 | `locked done pass crc secs>=10` 全 1；`fail illegal` 为 0 → **上板验证 PASS** |

**这轮改动的代价（如实记录）**：`CoreMark/LUTs` 从 9.077e-4 降到 **8.848e-4（−2.5%）**，
对应 +69 LUT / +17 FF / fmax −0.25%，换来 R-01（中断落气泡 → mepc=0）、
R48（陷阱未冲 EX/MEM → 被抢占指令双执行）、R-02（mtval 恒 0）三处修复。
中断/异常路径对评分三项**零贡献**，所以这是"用 2.5% 的一个分项换两处架构正确性 + 合规"的
**自觉取舍**，不是测量误差。若要换回分数，可单独 `git revert` 对应的 commit。

### 6.5 交付后的仓库状态

- 工作区**干净**；跟踪体积 **64.1 MB → 1.6 MB**（E-01 出库 62.66 MiB 构建产物）
- `python tools/fpga_workflow.py verify --force` → **PASS 11**；`--a-ext --force` → **PASS 11**
- 前置等价性检查：`CHECK_EQUIV=PASS`（675 万组穷举，0 不一致）
- `python tools/fpga_workflow.py check` → 7 项；`[7] 综合警告门` 基线 48 类/274 条
- 量具自证：`parse_reports()` 对历史报告给出 74.64 / 69.81 / 76.00 / 74.99（与 `coremark.csv`
  历史行逐行吻合）；`verify` 全 SKIP 时 `--require-run` 返回 1、不带开关返回 0

### 6.4 过程教训（值得进 PITFALLS 的一条）

**多写入者并行时，"提交前"必须先确认目标文件此刻没有被别人在写。**
我在 10:57:42 提交 `core.sv` / `id_ex_reg.sv` 时，rtl-fix 正在这两个文件里写 R-02，
于是 `4186f13` 的**提交信息只写了 R-01+R48，内容却含 R-02 的 RTL**。
处置：**不改写历史**（本地提交且其后已有多个 commit，多写入者下 rebase 风险太大），
改为在后续 commit 里如实记录并把 R-01/R-02 的回归用例一起补上，让历史可追溯。
这条与 R41（多写入者并行时建像前后各记哈希）是同一族，建议补一条编号条目。

---

## 7. 第二轮：物理优化（2026-10-11 下午）

> 触发：收到一份外部建议（要求在新网表上重扫 Pblock×place、重新归因瓶颈、评估乘法器 S2 等）。
> **下面每一条都先核实再执行** —— 其中两条被证伪/需要纠正。

### 7.1 核实结果

| 建议 | 核实结论 | 证据 |
|---|---|---|
| **#1 在新网表上重扫 Pblock × place** | ✅ **成立，已执行**（见 §7.2） | R-01/R48/R-02/W-04 让网表 +69 LUT/+17 FF，而 `build.tcl:277-290` 的配对表是在旧网表上量的；且 §7.2 证明瓶颈是"墙"而非"漏斗"，物理杠杆是唯一有效手段 |
| **#2 用 `path_hotspot.py` 看 Δ(top1,top2)** | ⚠ **成立，但命令必须改**：`fpga/timing.rpt` 里**只有 1 条 setup 路径**（`report_timing_summary` 只留最差那条），多路径明细在 **`fpga/timing_paths.rpt`**（50 条）。实测 `python tools\path_hotspot.py fpga\timing_paths.rpt --top 6` 可用（`--top` 默认 10） | `Select-String fpga\timing.rpt -Pattern 'Path Type:\s+Setup'` = **1**；`timing_paths.rpt` = **50** |
| **#3 盯 `u_id_ex/pc_reg[*] → u_csr/mepc_reg[*]`（曾 +0.084 ns），说它"很可能已成为 top-1"** | ❌ **已证伪**：那条路径**不在 top-50** | `Select-String fpga\timing_paths.rpt -Pattern 'mepc'` = **0**、`'u_csr'` = **0**；而 top-50 的 slack **全部 ≥ +0.854** ⇒ 该路径 slack > 1.08 ns。原因大概率是 ExtraTimingOpt 的布局把 u_csr 与 u_id_ex 摆近了（这条正是 build.tcl:296-299 自己标记"设计变大时要盯"的端点，现在可以销案） |
| **#4 乘法器 S2，门限 WNS ≥ +0.930（74.87 MHz），"缺口 0.28 ns"** | ⚠ **方向对，数字偏乐观 ~4 倍**（见 §7.3）：按 fde7561 的**实测**代价，真正门限是 **fmax ≥ 75.65 MHz（WNS ≥ 1.067 ns）**，现状 74.45 ⇒ **还差 ~1.2 MHz / 0.21 ns** |
| **#5 立刻 push（本地 ahead 14）** | ✅ 成立，**但当前做不到**：`git push` → `fatal: unable to access ... Recv failure: Connection was reset`（网络仍未恢复）。本地 ahead 14 保持不变，网络恢复后第一件事就是 push |
| **#5 31 位 tick 上限 ≈5,199 迭代仍未处理** | ✅ 成立，**已加硬闸门** | `tools/mk_cm_hw.py` 现在当 `expect_tick > 2^31-1` 时 **BLOCK** 并打印 `ITERATIONS_max`；正常时打印占用率（当前 3000 迭代 = 57.7%） |
| **#6 确认 `parse_reports` 在两套约束下都对** | ✅ **已修且已双证** | 50 MHz 报告 → **69.81**；70 MHz 报告 → **74.45**。旧口径的 76.92/78.4 已不可能再出现 —— 解析器改为从**最差 setup 路径块的 `Requirement`** 取周期（不再有硬编码 20.0、不再抓脉宽余量） |

### 7.2 瓶颈归因（新网表，已重跑）

`fpga/timing_paths.rpt`（50 条 setup 路径）的实测结构：

- **50 条路径全部同一个 Source**：`u_core/u_dmem/mem_reg_3/CLKBWRCLK`
- Destination 全是 `u_core/u_imem/rdata_reg_*/ADDRARDADDR[*]` 的各个位
- **Δ(top1, top2) = 0.024 ns**（0.854 vs 0.878）⇒ 按 R39/R47 的判据：**逻辑层面重排的期望收益 ≈ 0**
- 平均 **logic 32.6% / route 67.4%**，16 级逻辑（CARRY4=2）
- 最差路径 hop 明细里三处高扇出（fo=16 `u_mem_wb/rs1_data_reg[23]_1` 0.525 ns、fo=13 `u_id_ex/pc[1]_i_5_n_0` 0.551 ns、fo=9 `u_ex_mem/store_data_reg[23]_0` 0.642 ns）—— 全是**纯线长**

⇒ **结论：这是一堵墙，不是漏斗。** 唯一有效杠杆是物理（Pblock/place），正是 §7.2 的重扫；（曾经有人想"把逻辑拆开"的路线，在这份数据下期望收益 ≈ 0。）

### 7.3 乘法器 S2：把数字算清楚

权威来源是 **commit `fde7561` 的实测记录**（不是估算）：

| 配置 | ticks | CM/MHz | fmax | 吞吐 (CM/MHz × fmax) | 判定 |
|---|---|---|---|---|---|
| 基线（当时） | 413,070 | 2.4209 | 71.8 | 173.8 | KEEP |
| **S2**（DSP 输出寄存器充作 MUL 的 EX/MEM） | **403,646** | **2.4774 (+2.33%)** | **68.9 (−4.0%)** | 170.7 (**−1.8%**) | **回退** |
| S2b（S2 再去 `kind_r` 3:1） | 403,646 | 2.4774 | 67.9 | 168.1 | 回退 |
| S1（乘法当拍组合完成） | 403,646 | 2.4774 | 56.0 | 138.7 | 回退 |

- S2 的判据**不是"时序合法"，而是"净吞吐变好"**（`CM/MHz × fmax`）。
- 一般化盈亏平衡：`fmax_S2 ≥ fmax_now / 1.0233`。当前 74.45 ⇒ **72.75 MHz**。
- 实测 S2 的 fmax 代价 = **2.9 MHz**（71.8 → 68.9）。
- ⇒ 当前要值得做，净表必须 ≥ `72.75 + 2.9` = **75.65 MHz**（WNS ≥ **1.067 ns**）。
- 现状 **74.45 MHz（WNS 0.854）** ⇒ **还差 ~1.2 MHz / 0.21 ns**。
- 外部建议写的"门限 74.87 MHz / 缺口 0.28 ns"隐含 S2 代价只有 ~0.39 ns（≈1.9 MHz），
  **比 fde7561 实测的 2.9 MHz 乐观**。
- ⚠ **但 2.9 MHz 是旧网表（+69 LUT 之前）量的** ⇒ 真正实施前必须在当前网表上重测一次，
  不能直接套用；S2 的 RTL 形状**功能已验证**（PASS 11、ticks 与 S0 实测的 9424 拍 1:1 对上），
  保留在 `fde7561` 与 `.mul_scratch/`，随时可复用。

⇒ **S2 的优先级应排在 #1 之后**：先把 fmax 推到 ≥75.65，S2 才是纯赚；而 #1 正是买 fmax 的手段。

### 7.4 本轮顺带修的小口子

1. `synth` 归档现在**同时存 `timing_paths.rpt`** —— 此前只存 `timing.rpt`/`util.rpt`，
   而多路径归因全在 `timing_paths.rpt` 里，一旦被下次构建覆盖就永久丢失（§7.2 的分析正是靠它）。
2. `--place-directive` 的 help 文案更正：原来写"默认 WLDrivenBlockPlacement"，
   实际 `build.tcl` 的默认是 **ExtraTimingOpt**（与 PB_RANGE 成对选定）。
3. `tools/mk_cm_hw.py` 增加 **31 位 tick 上限硬闸门**（见 §7.1 最后一行）。

---

*本文由代码审查产生（含一次完整强制回归 + 度量链实跑复现）。§0~§5 是审查时的原始判断，
一律保留；§6 是第一轮执行记录；§7 是第二轮物理优化（含对外部建议的核实）。*
