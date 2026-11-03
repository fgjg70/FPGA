> **范围/口径声明（证据/迭代文档）**：本文是开发迭代记录或证据文档，"实测"特指上板实测（附日志/清单路径），"派生/仿真"已分别标注。**Artix-7 XC7A100T 的所有数据按赛题规则仅作跨厂商对比**，交付主体为紫光同创 PG2L100H；完整边界见根 [`COMPLIANCE.md`](COMPLIANCE.md)。

# style-audit.md — 代码风格与一致性审查（只读）

> **审查对象**：`D:\USER\Desktop\FPGA\FPGA` @ `6cbec89`（工作区干净，151 次提交）
> **审查日期**：2026-10-11
> **方法**：只读。逐条读仓库自己的规矩文档，再用脚本做全量普查
> （非 ASCII 字节数、行尾符、`always_*` 风格、复位极性、argparse 选项名、
> 输出前缀、宏名、数字字面量、跨文件行号引用、文件清单/行数对账）。
> **未改动任何代码文件**，唯一写入是本报告。
>
> 每条结论都给了 **file:line**；跨文件对比至少给两处。
> ⚠️ **快照说明**：审查期间另一个会话正在改 `core.sv`（实测 **1445 → 1491 行**，`git status` 为 `M core.sv`），
> 所以 `core.sv` 的行号锚点按**审查当时**记录，引用前请现查；其余文件在本轮内未变。
> **严重度**：**P0** = 与事实不符或与仓库自己的规矩冲突，会误导下一手；
> **P1** = 同一概念多种写法 / 重复知识；**P2** = 纯排版。
>
> **一句话结论**：本仓库的**内部**风格一致性很高（模块头注释块 21/21 统一、
> 复位极性统一、`.bat` 与 `.ps1` 全部纯 ASCII、无 BOM）。
> 真正的问题集中在**跨文件 / 跨语言的"契约同步"**上：RTL 与 XDC 的时钟名、
> 同一组宏开关的两种 CLI 拼写、以及**文档清单没跟上新增的 `bht.sv`**。
> 7 条 P0 里，有 4 条是"仓库自己在某处已经写明规则、另一处违反了它"。

---

## 1. 仓库自己的规矩（附来源）

这一节**不是我的审美**，是把仓库已经写在纸面上的规则摘出来。后面第 2 节全部按这份清单扫。

### 1.1 编码

| # | 规矩 | 来源 |
|---|---|---|
| E1 | **`.bat` 一律纯 ASCII**（`cmd` 用 OEM 代码页，中文会吃掉每行首字符） | `skills/fpga-riscv-a100t/PITFALLS.md:27`；`HANDOFF.md:342-346`；`skills/fpga-riscv-a100t/SKILL.md:29` |
| E2 | **Vivado 的 `.tcl` 一律纯 ASCII**（7 位掩码会把非 ASCII 注释字节变成控制字符，其中 `0x0A` 会把注释行劈成代码行） | `PITFALLS.md:622`；`HANDOFF-HW-LOOP.md:259`；`HANDOFF.md:346-347` |
| E3 | **`.tcl` 是"提醒"不是"拦截"** —— 已两次栽在编码上，纪律是"编辑 `.tcl` 后必须跑字节检查" | `PITFALLS.md:315-316`（`check` 里那条只算 remind） |
| E4 | 判"文件坏没坏"要看**码点/字节**，不能靠 `pwsh` 控制台肉眼看乱码 | `PITFALLS.md:866-881`（R51） |
| E5 | 文本一律 UTF-8 **无 BOM**；不要用 PowerShell 往返读写工程文本/CSV | `PITFALLS.md:121-132`（R10）、`PITFALLS.md:432-446`（R29） |
| E6 | `.md` / `.sv` / `.py` **允许中文**（全仓库注释就是中文）；ASCII 约束**只**针对 `.bat` / `.tcl` | 与 E1/E2 互补；`check` 的实现即如此 `tools/fpga_workflow.py:820-848` |

### 1.2 证据与口径

| # | 规矩 | 来源 |
|---|---|---|
| V1 | 结论必须给 **`path:line`**（或 `file:line`），关键结论要"亲自复核后才写入" | `CODE-REVIEW-PLAN.md:10`、`:14-16` |
| V2 | 标注约定：`[已实测]` / `[复算]` / `[代码分析]`，区分"实测"与"读代码得出" | `CODE-REVIEW-PLAN.md:14-16` |
| V3 | **不许把"综合报告的数字"说成"上板实测"**；结论要写清是"仿真通过"还是"上板验证" | `PITFALLS.md:916-918` |
| V4 | **fmax 必须带"时钟名 + 周期 + 运行频率 + WNS"**，否则不许进文档 | `HANDOFF.md:1032-1039`（【口径纪律】）；`CODE-MAP.md:244` |
| V5 | 引用 `results/coremark.csv` 的 `fmax` 列**必须同时读 `fmax_src` 列** | `HANDOFF.md:31`、`:287`、`:1049`；`README.md:39`；`CODE-MAP.md:245`；`HANDOFF-WORKFLOW.md:175`；`HANDOFF-HW-LOOP.md:299` |
| V6 | 换频 / 提频会同时改动 `fmax`，两者不独立，报告必须写清约束 | `PITFALLS.md:847-864`（R50） |
| V7 | **"看起来成功了"和"真的成功了"之间必须有一条硬判据**；开关型参数必须有**生效自证** | `PITFALLS.md:302-304`（R20）、`:466-468`（R31） |

### 1.3 一致性 / 单一事实来源（**本仓库的 R1 红线**）

| # | 规矩 | 来源 |
|---|---|---|
| C1 | **R1：改了 A 忘了同步 B，全部是静默失败** —— 新增 RTL 文件必须同步 `build.tcl` / `build_ila.tcl` / `run_coremark.py` / `CORE_SV_ORDER` / vlog 列表 | `PITFALLS.md:10-22`；`tools/README.md:41`；`tools/README.md:62-66` |
| C2 | **编码/枚举只定义一次**，各模块 `import` 使用 —— `rv32_pkg.sv` 是"单一事实来源" | `rv32_pkg.sv:3-4`、`:6-8`；`README.md:106`；`HANDOFF.md:299` |
| C3 | **标签与事实不一致 = 本工程最忌讳的一类**（原文即如此用词） | `fpga/daVinciPro.xdc:17-18` |
| C4 | 计数器/标签**会过时**：改语义必须同步改名字 | `PITFALLS.md:890-891`（"`redirect` 语义改了，`n_br_taken` 还叫原名"） |
| C5 | **不要在别处硬编码**由单一来源承载的值（迭代数等） | `HANDOFF-HW-LOOP.md:97`；`PITFALLS.md:549-552`；`HANDOFF.md:929` |
| C6 | 被推翻/过期的注释是最高危的一类（"改动者最先读的就是模块头"） | `CODE-REVIEW-PLAN.md:112`（D-09）；`PITFALLS.md:180-202`（R16） |
| C7 | **工具不自动改写清单** —— 清单漂移必须被报出来，不能被掩盖 | `tools/README.md:202-203` |
| C8 | 严重度必须准确：报警不准 = 没人看报警 | `tools/README.md:204-206` |

### 1.4 命名 / 写法

| # | 规矩 | 来源 |
|---|---|---|
| N1 | **RTL 全部走 `$root` 相对路径**，不留硬编码绝对路径 | `fpga/build.tcl:26-31`（E-02 修复后） |
| N2 | 所有路径用**正斜杠**（Vivado/Tcl 只吃 `/`） | `tools/README.md:199` |
| N3 | 时钟名**不得带频率** —— "名字里带频率会每改一次档就过期一次" | `fpga/daVinciPro.xdc:17-18`（所以改名 `sys_clk_core`） |
| N4 | 模块头注释块格式：`// ===...===` / `// file.sv — 标题` / `// ---...---` / 要点 | 21/21 个根 `.sv` 全部遵守（实测，见 §4） |
| N5 | 复位极性统一：**异步高有效 `posedge rst`**，"与全核统一，请保持极性一致" | `pc.sv:4`（模块头原文）；实测 21 个文件全部一致（见 §4） |
| N6 | 声明一律写在例化**之前**（避免隐式 net） | `PITFALLS.md:109-113`（R8）、`:381-387`（R25） |
| N7 | 给机器看的判据一律用 **ASCII 标记**（中文会被编码破坏） | `CODE-REVIEW-PLAN.md:695`；`PITFALLS.md` R33 族（`fpga_workflow.py:1370` 的 `ascii_safe()`） |
| N8 | 输出前缀分级：`[FAIL]` / `[warn]` / `[info]` / `[OK]` / `[BLOCK]`；`[FAIL]`=必须修，`[warn]`=建议修，`[info]`=已知在研 | `tools/README.md:56` |
| N9 | 宏是 `/` 分隔的语义化名字（`.bat`/`.tcl` 用大写宏名，CLI 用小写开关） | `fpga/build.tcl:184-190`；`control_unit.sv:264` |

### 1.5 改动后自检（收尾必跑）

来源 `PITFALLS.md:904-921`（第 8 节清单）+ `tools/README.md:35-56`（`check` 7 项）。
其中与本审查直接相关的两条：**"改过 RTL/软件 → 上板验证跟上了吗"**、
**".bat 是纯 ASCII?"**。

---

## 2. 不一致清单

按严重度排序。每条一行：**一句话 | 证据（≥2 处对比）| 建议的统一写法**。

### P0（与事实不符 / 与仓库自己的规矩冲突，会误导下一手）

- **[P0] `build.tcl` 违反自己第 5 行写的"本文件必须纯 ASCII"，是**唯一**有非 ASCII 字节的 `.tcl`（501 字节，8 行中文注释）** | 文件自己声明 `fpga/build.tcl:5-6`（`MUST stay PURE ASCII (PITFALLS R21…)`），却在 `fpga/build.tcl:15,16,17,18,19,21,22,23` 写了中文；同目录 `fpga/build_ila.tcl`、`fpga/ila_cap_done.tcl`、`fpga/ila_cap_mark.tcl` 实测**各 0 字节** | 把 `build.tcl:15-23` 的中文注释译成英文（`build_ila.tcl` 的英文注释就是现成范本）；并把 `check` 第 6 项对 `.tcl` 从 `[warn]` 升为 `[FAIL]`（见 §5-G1） |
- **[P0] 时钟信号名 `sys_clk_75` 与事实不符：XDC 已刻意改名 `sys_clk_core`，RTL 没跟上；该网实际跑 131.25 MHz，不是 75 MHz** | `fpga/daVinciPro.xdc:17-18` 明文写着"时钟名从 `sys_clk_75` 改成**频率无关**的 `sys_clk_core`：名字里带频率会每改一次档就过期一次（本工程最忌讳的'标签与事实不一致'）"、`:33` 落实为 `-name sys_clk_core`；而 `fpga/top_a100t.sv:75`（`logic sys_clk_75;`）、`:111`（注释断言"BUFG 的输出网就叫 `sys_clk_75`, 与 XDC 里 `create_generated_clock -name sys_clk_75` 同名"——**与 XDC 第 33 行直接矛盾**）、`:90`（`clk_75_raw`）、`:170`（`CLK_HZ (131_250_000)`，自带自证"这个网跑 131.25 MHz"） | 统一为 `sys_clk_core` / `clk_core_raw`；同时改 `fpga/top_a100t.sv:111-113` 的注释（现注释还写着 `14.286 ns`，而本文件 `:83` 的 `CLKOUT0_DIVIDE_F (8.0)` 对应 131.25 MHz = 7.619 ns） |
- **[P0] `verify` 与 `synth` 对**同一组 7 个宏开关**用了两套 CLI 拼写（下划线 vs 连字符），别名不一致，误传会静默无效果** | `tools/fpga_workflow.py:2941,2944,2946,2948,2950,2952`（`--imem_comb_read` / `--imem_reg_read` / `--load_reg` / `--gshare` / `--ras` / `--gemm`，其中 `--a-ext` 在 `:2954` 却是连字符）对比 `:3022,3025,3027,3029,3031,3033,3035`（`--imem-comb-read` / `--imem-reg-read` / `--load-reg` / `--gshare` / `--ras` / `--gemm` / `--a-ext`）；两组 `help` 文本**逐字相同**（如 `:2946-2947` vs `:3027-3028` 都是 `load 结果由 MEM/WB 寄存器给出 (LOAD_RESULT_REG)`）。argparse 把 `_` 与 `-` 当**两个不同选项**，而仓库反复记录过"开关型参数没生效"这一类静默失败（`PITFALLS.md:455-468` R31、`PITFALLS.md:204-241` R17） | 每个开关只保留**一个**规范拼写（推荐连字符，与 `--a-ext`/`--max-cycles`/`--clk-hz` 一致），另一套用 `aliases=` 或 `dest` 显式兼容 |
- **[P0] 三份 RTL 清单（README / CODE-MAP / HANDOFF）**完全没登记 `bht.sv`**，而 `bht.sv` 确实存在且已被三处构建清单登记 —— 文档口径与仓库事实不符** | 实测 `bht.sv` 存在（148 行）、且已在 `fpga/build.tcl:133`、`fpga/build_ila.tcl:242`、`tools/run_coremark.py:24`、`tools/fpga_workflow.py:144`（`CORE_SV_ORDER`）四处登记；而 `README.md:104-127`、`CODE-MAP.md:64-85`、`HANDOFF.md:374-384` 三张文件一览表**都从 `btb.sv` 直接跳到下一项**，全仓库 `grep -i bht` 在 8 个文档里 **0 命中**（只在 `build.tcl:18`、`fpga_workflow.py:139`、`run_coremark.py:27` 的**注释**里被提到）。顺带：`CODE-MAP.md:62` 写"20 个文件"、`CODE-MAP.md:88` 写"20 个文件求和 = 4108 行"，实测根目录 `.sv` **21 个 / 4604 行**；`HANDOFF.md:376`/`:867` 写"20 个 .sv"，而 `README.md:25`/`HANDOFF.md:21,25,42` 写的又是"**22 个** RTL 文件" | 在 `CODE-MAP.md:78` 之后插入 `bht.sv` 一行（可参照 `fpga_workflow.py:139-144` 的自我说明），并把三处计数统一为实测值；`bht.sv` 的分工应写成"方向预测表 PHT（8192 项 × 2 位）+ BTB 两级流水相位自证"，**不要**继续把它并进 `btb.sv` 的描述里（`CODE-MAP.md:78` 现在正是这么做的） |
- **[P0] 代码注释里内嵌的 `file.sv:NN` 行号已失效（正是 `CODE-MAP.md` D-05 那类漂移，只是坐在代码里）；同文件内还并存"行号引用"与"标识符引用"两套做法** | 失效例：`hazard_unit.sv:83` 断言"`sim/tb_sw.sv:317/322` 直接层次化引用 `load_use`"，而 `load_use` 实际在 `sim/tb_sw.sv:388,389,390,394,397,398`（`:317` 是 `logic [BTB_IDX_BITS-1:0] idx;`）；`btb.sv:9` 指 `core.sv:772` 的"`pc_target` 4:1 优先级 mux"，而 `core.sv:772` 是 `// 这一侧的链没有了…`（注释文字）；`rv32_pkg.sv:21` 指 `core.sv:517-536` 为"控制流目标独立加法器"，实际该区间是 `if_id_reg` 别名与 ID 门控（`:522-526`）；`rv32_pkg.sv:29` 指 `core.sv:566-571` 为 `redirect` 语义，实际是 `id_rs*` 字段赋值（`:568-570`）；`csr_file.sv:169-175` 被 `rv32_pkg.sv:380` 引用为"`mcause` 位布局"记录，实际在 `csr_file.sv:175-181`。**做法不一**：`tools/fpga_workflow.py:1231` 用**标识符**引用（`--imem_comb_read`/`--gshare`/`--load_reg`，不写行号），而 `tools/fpga_workflow.py:141` 写 `build.tcl:123`、实际 `read_verilog` 在 `fpga/build.tcl:133`；`tools/fpga_workflow.py:570` 写 `load_store_unit.sv:269` | **注释里一律用标识符引用，不写行号**（RTL 注释的固定脆点）；确需给行号时，改成 `CODE-MAP.md:99-105` 那种"先给重算命令、再给快照"的形式 |
- **[P0] `tools/run_coremark.py` 是 M-01 那个已修 bug 的**未修副本**：仍按 `^sys_clk` + 硬编码 `20.0` 算 fmax，且本期实测时钟表里 `sys_clk` 行**只剩脉宽余量**、真正的 WNS 在 `sys_clk_core` 行** | `tools/run_coremark.py:135`（`re.search(r'^sys_clk\s+([-\d.]+)', t, re.M)`）与 `:138`（`fmax = '%.1f' % (1000.0 / (20.0 - wns))`）对比 `tools/fpga_workflow.py:1589-1597`（同一正则的原始缺陷与真因，M-01/X-01 已修）；`fpga/timing.rpt:142`（`sys_clk … 20.000 … 50.000`）、`:155`（`sys_clk` 行 WNS/TNS **为空**、只有 `7.000` 脉宽）、`:158`（`sys_clk_core -0.517`）为实测对照 | 删掉本文件里的 fmax 解析，改为**复用 `fpga_workflow.py` 的解析函数**（或干脆删掉 `run_coremark.py` 里 `--record` 这条路径，改由 `fpga_workflow.py synth --record` 独写 CSV） |
- **[P0] 顶层文档声称的主导时钟与交付 fmax 与实测不符：文档全篇 75 MHz / 76.2 MHz，实测是 131.25 MHz 设计、WNS −0.517（约束未收敛），最近一次综合 fmax 106.30 MHz** | 文档侧：`README.md:37-38`、`:56`（`sys_clk_75 @13.333 ns = 75.00 MHz`）、`README.md:51`（fmax **76.2**）、`CODE-MAP.md:237`、`CODE-MAP.md:152`（"MMCM 的 **75 MHz** 输出约束"）、`HANDOFF.md:27-28`、`:63`、`:67`、`HANDOFF.md:1034`。实测侧：`fpga/daVinciPro.xdc:11-12`（`-multiply_by 21 -divide_by 8 → 131.25 MHz`）、`fpga/top_a100t.sv:83`（`CLKOUT0_DIVIDE_F (8.0)`）、`:170`（`CLK_HZ (131_250_000)`）、`fpga/timing.rpt:145`（`sys_clk_core 7.619 131.250`）、`:158`（`sys_clk_core` WNS **−0.517**、640 个失败端点）、`.fpga-cache/reports/20261011-151614-cm_hw/metrics.json`（`"wns": 0.117, "fmax": 106.30, "clk": "sys_clk_core", "period_ns": 9.524`）。另 `README.md:25`/`HANDOFF.md:21` 把上板采集描述为 `clk_hz=75000000`，而 HEAD 已到 `8bce1ed data(hw): 105 MHz 上板验证 PASS` | 按 V4【口径纪律】重写所有 fmax/时钟表述：**时钟名 `sys_clk_core` + 当次周期 + 运行频率 + WNS**；并明确"当前工作档位是 131.25 MHz（约束未收敛）/ 最近收敛档是 105 MHz"，不要让 75 MHz 的数字继续留在"当前交付"栏里 |

### P1（同一概念多种写法 / 重复知识）

- **[P1] 同一概念的宏/开关有三个名字：`LOAD_RESULT_REG`（RTL 宏）/ `LOAD_REG`（Tcl 环境变量）/ `--load-reg`（CLI）** | `core.sv:1281`、`:1308`（`` `ifdef LOAD_RESULT_REG ``）对比 `fpga/build.tcl:184`、`:185`（`$::env(LOAD_REG)` / `" LOAD_RESULT_REG=1"`）对比 `tools/fpga_workflow.py:2946`、`:3027`（`--load_reg` / `--load-reg`）；`tools/run_coremark.py:24` 的 RTL 列表注释也提 `LOAD_RESULT_REG` | 保留 `LOAD_RESULT_REG` 为**唯一**规范宏名；Tcl 里用同名环境变量（`env(LOAD_RESULT_REG)`），CLI 用 `--load-result-reg` |
- **[P1] 注释引用了一个**已经不存在的宏名** `IMEM_REG_READ`（现在的回退宏叫 `IMEM_COMB_READ`）** | `load_store_unit.sv:46`（"本项目在'改流水寄存器语义'上吃过四轮亏, 见 `IMEM_REG_READ`"）对比 `imem.sv:19`（"宏: 定义 `IMEM_COMB_READ` -> 组合读"）、`core.sv:249`、`:326`（`` `ifdef IMEM_COMB_READ ``）、`tools/fpga_workflow.py:2944`（`--imem_reg_read` 的 help 已自标"[已废弃]"） | `load_store_unit.sv:46` 改成 `IMEM_COMB_READ`；若确指历史名，写明"（旧名 `IMEM_REG_READ`，现名 `IMEM_COMB_READ`）" |
- **[P1] `results/coremark.csv` 表头的 fmax 公式仍是旧口径 `1000/(20−wns_ns)`，与仓库自己的"旧口径已失效"直接冲突** | `results/coremark.csv:2`（`# fmax_mhz = 1000 / (20 - wns_ns), 由 Vivado 时序报告推算`）对比 `HANDOFF.md:1039`（"正确口径：`fmax = 1000 / (该时钟周期 − 该路径 WNS)`"）、`README.md:39`（"旧式 `1000/(20−WNS)` 已失效"）、`HANDOFF-WORKFLOW.md:90-94`（把该写法列为"反面教材, 已失效"）；实测周期已是 `9.524`/`7.619` ns 而非 20（`.fpga-cache/reports/20261011-151614-cm_hw/metrics.json`） | 把该注释行改为"口径见 `HANDOFF.md` §8；周期由解析器从最差 setup 路径块取，不写死" |
- **[P1] 反复出现的"以 `fmax_src` 列为准"这条纪律，其依据的列**根本不存在**（CSV 表头 12 列无此列，全仓库代码 0 命中）** | 纪律侧 7 处：`HANDOFF.md:31`、`:287`（"必须看 `fmax_src` 列（`tool`/`hand`）"）、`:1049`、`README.md:39`、`CODE-MAP.md:245`、`HANDOFF-WORKFLOW.md:175`、`HANDOFF-HW-LOOP.md:299`；事实侧：`results/coremark.csv:4` 表头 = `date,tag,iters,ticks,coremark_per_mhz,lut,ff,bram,dsp,fmax_mhz,status,notes`（无 `fmax_src`），`tools/`+`fpga/` 下 `fmax_src` **0 命中**，`tools/fpga_workflow.py` 也无 `--fmax` 覆盖参数（0 命中）。注：`CODE-REVIEW-PLAN.md:94`（M-04）确实把"新增 `fmax_src`"列为待办，但**七处文档已把它当成既成事实来要求读者** | 二选一：① 真的实现（`append_csv` 增列 + `--fmax` 覆盖入口，见 `tools/fpga_workflow.py:1822-1860`）；② 在实现之前，把 7 处"必须配 `fmax_src` 列"改成"必须写明 fmax 的口径来源（工具/手工），该列**尚待 M-04 落地**" |
- **[P1] `results/coremark.csv` 里 22 行的备注仍在把 fmax 归因于"工具硬编码 period 20.0 读错行"，而那个 bug（M-01/X-01）**已经修好了** —— 备注与当前工具行为不符，读者会以为工具还是坏的** | 备注侧：`results/coremark.csv:144`、`:147`、`:151`、`:152`、`:155` 等 22 行都写着 `tools/fpga_workflow.py parse_reports() hardcodes period 20.0 and reads the 50MHz sys_clk row, so its number is wrong for this design`；事实侧：`tools/fpga_workflow.py:1589-1597` 已改成从**最差 setup 路径块**取 `Requirement`（`CODE-REVIEW-PLAN.md:91` M-01 的修法），`results/review-fixes-v1.md:78` 记录"复算历史报告 74.45/69.81/76.00/74.99 与 `coremark.csv` 历史行逐行吻合" | 只对**修复前**（2026-10-11 之前）的行保留该备注；修复后的行改为"fmax 由工具按最差 setup 路径块自动算出，`fmax_src=tool`"（正好与上一条的 `fmax_src` 列一起做） |
- **[P1] 两个工具**用两套行结构**写同一个 `results/coremark.csv`（12 列 vs 10 列），且 `run_coremark.py` 用 `open()` 默认编码 + 手工拼行** | `tools/fpga_workflow.py:1839-1860`（先读真实表头 `next(l for l in … if l.startswith("date,"))`，按列顺序填、对 `,`/`"` 做 CSV 转义、`encoding="utf-8"`）对比 `tools/run_coremark.py:145-148`（硬编码 `'%s,%s,%d,%d,%.4f,%s,%s,%s,%s,"%s"'` 正好 10 个域，用 `chr(10)` 收尾，无 `encoding=`），而表头是 12 列（`results/coremark.csv:4`，多 `status` 与 `fmax_src` 口径位） | `run_coremark.py` 改为调用 `fpga_workflow.py` 的 `append_csv()`，删掉自己那套格式串 |
- **[P1] `README.md` 说 `sim/run.bat` / `run.sh` "只是历史留档、尚未修复"，而两个脚本**已经重写完**并已成为权威入口** | `README.md:167-177`（"**不是可用的测试入口**"、"修法…**尚未修复**"）对比 `sim/run.bat:5-6`、`:28`、`:37`（"Authoritative entry point (11 tests)" + `build_sw.py --all` + 转调 `fpga_workflow.py verify`）与 `sim/run.sh:5-6`、`:24`、`:28`（同构）；`results/review-fixes-v1.md:95` 亦记录 W-05/W-06 已修 | 删掉或改写 `README.md:167-177`（改为"已修，`run.bat`/`run.sh` 现在会先删旧镜像再跑全量 verify"） |
- **[P1] CLI 参数命名两套：`--iters` vs `--iterations`、`--max-cycles` vs 工具内 `max_cycles`** | `tools/fpga_workflow.py:2965`（`--iters`，help"配合 `--ticks` 的迭代次数"）对比 `:2983`（`--iterations`）、`tools/run_coremark.py` 的 `--iterations`；`tools/fpga_workflow.py:2971`（`--max-cycles`）对比 `:739,744,753…` 内部键名 `max_cycles` | 全仓库统一 `--iterations` / `--max-cycles`；内部键名与 CLI 名一一对应 |
- **[P1] `tools/fpga_workflow.py` 的输出前缀大小写不统一：14 处 `[WARN]` 对 11 处 `[warn]`，而共享 tag 映射表用的是 `[warn]`** | `tools/fpga_workflow.py:802`、`:812`（`tag = {"FAIL": "[FAIL]", "WARN": "[warn]", "INFO": "  ok  "}`）与 `:756`、`:780`、`:787`、`:847`、`:900`、`:910`、`:913`、`:1935`、`:2098`、`:2128`、`:2148`、`:2281`、`:2383`、`:2910` 的 `[warn]` 对比 `:1341`、`:1457`、`:1460`、`:1683`、`:1734`、`:1836`、`:2240`、`:2243`、`:2256`、`:2835`、`:2994` 的 `[WARN]`；`tools/README.md:56` 规定的是 `[warn]` | 统一为 `[warn]`（除非有意区分"逐项 tag"与"结论性提示"，那就写进 `tools/README.md`） |

### P2（纯排版）

- **[P2] 行尾符混用：7 个根 `.sv` 用 CRLF，其余 14 个 + 全部 `sim/`/`tools/`/`fpga/` 用 LF** | CRLF：`core.sv`(1445)、`id_ex_reg.sv`(124)、`imem.sv`(83)、`load_store_unit.sv`(382)、`muldiv.sv`(215)、`ras.sv`(87)、`regfile.sv`(67)；LF：`rv32_pkg.sv`(408)、`alu.sv`(104)、`bht.sv`(148) 等；另 `tools/flash_run.ps1`(56) 是唯一 CRLF 的脚本 | 加 `.gitattributes` 固定 `* text=auto eol=lf`（或至少对 `*.sv`/`*.py` 统一 LF） |
- **[P2] `HANDOFF-WORKFLOW.md` 用 `MHz` **同时**用大写的 `MHZ` 当标识符** | `HANDOFF-WORKFLOW.md:112-114`（`CM_MHZ = 1e6 / ticks` / `CM_LUT = CM_MHZ / LUT` / `ABS = CM_MHZ * fmax`）对比 `tools/fpga_workflow.py:165`（输出键名是 `cm_per_mhz`）；单位拼写 `MHz` 本身全仓库一致（实测 `Mhz` 0 命中） | 文档里的伪代码改用与工具一致的 `cm_per_mhz` |
- **[P2] 同一"单一事实来源"文件内，大数字面量的下划线风格不统一** | `rv32_pkg.sv:309-310`、`:312`、`:322-329`（`32'h8000_0000` / `32'hA000_0000` / `32'hA000_0010`，带 `_`）对比 `rv32_pkg.sv` 内另有 18 处 7 位以上**不带** `_` 的字面量；同族孤立例：`alu.sv`、`pc.sv`、`muldiv.sv` 各 1~2 处带 `_`，`core.sv`(9 处)、`ex_mem_reg.sv`(3 处)、`control_unit.sv`(3 处)、`load_store_unit.sv`(3 处) 全部不带 | 规定"≥5 位十六进制字面量一律 `_` 分段"（`rv32_pkg.sv` 已是事实标准），或反过来全不写；**别两套并存** |
- **[P2] `CODE-MAP.md` 的工具/文件行数快照全部偏小** | `CODE-MAP.md:135`（`fpga_workflow.py` **2973** 行）vs 实测 **3075**；`CODE-MAP.md:151`（`build.tcl` **484**）vs 实测 **545**；`CODE-MAP.md:152`（`daVinciPro.xdc` **51**）vs 实测 **54**；`CODE-MAP.md:199`（`tb_core.sv` **175**）vs 实测 **181**；`CODE-MAP.md:62`（合计 **4108**）vs 实测 **4604** | 该文件自己已给了重算命令（`CODE-MAP.md:92-95`、`:99-105`），按它重算并刷新；建议同时把"行数快照"标注为带日期的软数据 |
- **[P2] 注释分隔线在同一文件内并存 `// ====` 与 `// ----` 两种宽度/字符** | `control_unit.sv`：`====` 2 处 vs `----` 26 处；`core.sv`：35 vs 27；`csr_file.sv`：2 vs 15；`rv32_pkg.sv`：2 vs 38；而 `alu.sv`/`bht.sv`/`pc.sv` 等 14 个文件是固定的 2+1 结构（见 §4） | 不必强制统一（见 §4），但若统一，规则应是"文件头/大段用 `====`、文件内小节用 `----`"——`alu.sv` 就是这个模板 |

> **统计**：P0 = **7** 条，P1 = **9** 条，P2 = **5** 条，合计 **21** 条。

---

## 3. 非 ASCII 字节统计表

用脚本逐文件 `ReadAllBytes` 统计 `> 127` 的字节数（`[复算]`，2026-10-11）。
**"是否应修"的依据是 §1.1 的 E1/E2/E6，不是我的偏好。**

### 3.1 应修（违反 E2：Vivado `.tcl` 必须纯 ASCII）

| 文件 | 非 ASCII 字节 | 是否应修 |
|---|---:|---|
| `fpga/build.tcl` | **501**（8 行注释，见 §2 第 1 条） | **✅ 应修** —— 唯一未转 ASCII 的 `.tcl`，且文件自己第 5 行声明必须 ASCII |

### 3.2 合规（ASCII 硬约束覆盖到的文件，全部 0）

| 文件 | 非 ASCII | 说明 |
|---|---:|---|
| `fpga/*.bat`（7 个：`build`/`build_ila`/`ila_cap_done`/`ila_cap_mark`/`ila_info`/`ila_try`/`jtag_probe`） | 0 | E1 合规 |
| `sim/run.bat` | 0 | E1 合规 |
| `tools/doctor.bat` | 0 | E1 合规 |
| `fpga/*.tcl` 其余 6 个（`build_ila`/`ila_cap_done`/`ila_cap_mark`/`ila_info`/`ila_try`/`jtag_probe`） | 0 | E2 合规（R21 修复后） |
| `tools/*.tcl`（7 个：`flash_*`/`hier_util`） | 0 | E2 合规 |
| `tools/*.ps1`（3 个：`flash_boot`/`flash_run`/`flash_sweep`/`sweep_pblock_place`） | 0 | 与 `.bat` 同级约定，合规 |
| `sim/run.sh` | 0 | 合规 |

### 3.3 允许（E6：`.sv` / `.py` 的中文注释是全仓库既定风格，**不必动**）

| 文件 | 非 ASCII 字节 | 文件 | 非 ASCII 字节 |
|---|---:|---|---:|
| `core.sv` | 33352 | `sim/tb_sw.sv` | 12499 |
| `tools/fpga_workflow.py` | 41972 | `sim/tb_units.sv` | 3474 |
| `load_store_unit.sv` | 8834 | `fpga/mmio_subsys.sv` | 3809 |
| `rv32_pkg.sv` | 7425 | `fpga/top_a100t.sv` | 3321 |
| `tools/path_hotspot.py` | 4752 | `tools/mk_cm_hw.py` | 3351 |
| `hazard_unit.sv` | 4465 | `tools/build_sw.py` | 2457 |
| `bht.sv` | 2673 | `sim/tb_soc.sv` | 1692 |
| `control_unit.sv` | 3201 | `sim/tb_core.sv` | 1629 |
| `btb.sv` | 2966 | `tools/amo_vectors.py` | 1578 |
| `muldiv.sv` | 2837 | `sim/run_prog.py` | 636 |
| `gemm_accel.sv` | 2742 | `tools/trace_diff.py` | 1227 |
| `csr_file.sv` | 2607 | `tools/run_coremark.py` | 1041 |
| `ras.sv` | 1835 | `tools/asm.py` | 969 |
| `id_ex_reg.sv` | 1581 | `tools/elf2hex.py` | 189 |
| `alu.sv` | 1536 | `tools/check_equiv.py` | 39 |
| `ex_mem_reg.sv` | 1517 | `tools/pdf_mine.py` | 33 |
| `imem.sv` | 1436 | `tools/pdf_text.py` | 0 |
| `regfile.sv` | 1092 | `dmem.sv` | 1053 |
| `pc.sv` | 444 | `imm_gen.sv` | 408 |
| `branch_unit.sv` | 195 | `mem_wb_reg.sv` | 195 |

> **顺带（BOM / 行尾）**：`git ls-files` 范围内的源码**全部无 BOM**（符合 E5）；
> 唯一带 BOM 的是 `results/coremark.csv`（`EF BB BF`，落在第 1 行注释头部，不在 `date,` 表头行上，
> 所以 `tools/fpga_workflow.py:1839` 的 `l.startswith("date,")` 仍能找到表头 —— **目前无害但属 E5 的埋雷**）。
> 行尾符混用见 §2 P2 第 1 条。

---

## 4. 已统一、不必动的部分

**这一节是给下一手的"别乱动"清单。** 以下差异是**有意**的，或者已经是全仓库一致的事实。

1. **模块头注释块 21/21 完全同构** —— 每个根 `.sv` 都是
   `` `timescale 1ns/1ps ``（空行）`// ====` / `// <file>.sv — <标题>` / `// ----` / 要点，
   且 `endmodule` 前有对应收尾线。**不要为了"统一"去重排其他文件的注释。**
   样例：`alu.sv:1-6`、`bht.sv:1-6`、`rv32_pkg.sv:1-6`、`core.sv:1-6`。
2. **复位极性全核一致：异步高有效 `posedge rst`** —— 实测 21 个根 `.sv` 中
   `negedge rst` / `posedge rst_n` / `if (!rst)` **各 0 命中**；
   `pc.sv:4` 的模块头还专门写了"与全核统一, 请保持极性一致"。**这是对的，别改成低有效。**
3. **`always_ff` / `always_comb` 与裸 `always @(posedge clk)` 的混用是有理由的** ——
   流水寄存器与顺序逻辑用 `always_ff`（`id_ex_reg.sv`、`ex_mem_reg.sv`、`mem_wb_reg.sv`、
   `pc.sv`、`ex_mem_reg.sv`、`core.sv` 的 12 处），纯组合用 `always_comb`；
   而 `btb.sv:1`(`always@(posedge)`×2)、`bht.sv`、`imem.sv`、`dmem.sv`、`regfile.sv`、`ras.sv`、
   `muldiv.sv`、`csr_file.sv` 用裸 `always`。**这是"要推断 BRAM / 要控制复位"的刻意选择**
   （`imem.sv`、`dmem.sv` 的模块头都写了"寄存读 → 行为级推断 BRAM"）。
   `PITFALLS.md:579-580` 还记录过 `initial` 与 `always_ff` 同驱动的 LRM 违规（必须用 `always`）。
   **不要为了风格统一把 `always` 全改成 `always_ff`。**
4. **`core.sv:1379/1398/1414/1430` 与 `imem.sv`/`dmem.sv`/`regfile.sv` 的时序块"无复位"是有意的** ——
   前者是调试/观测专用寄存器（`core.sv:1485` 标注"纯观测, 不参与逻辑"），
   后者是 BRAM/寄存器堆推断（复位会阻止推断或纯属浪费）。
   `CODE-REVIEW-PLAN.md:84`（R-09）也把这类列为"说明有意为之"而不是缺陷。
5. **`mem_wb_reg.sv` 刻意没有 `flush` 口** —— `core.sv:1317-1319`（"【刻意不对称: 这里**没有** flush】…给 `mem_wb_reg` 加 flush 会把已经进入 WB 的正确指令丢掉"）
   与 `core.sv:1106`、`CODE-MAP.md:83` 都有整段说明。**对称性在这里是错的。**
6. **`sys_clk_core` 这个名字是**有意**的频率无关命名** —— 见 `fpga/daVinciPro.xdc:17-18`。
   问题是 RTL 没跟上（§2），**不是 XDC 改错了**。别把 XDC 改回 `sys_clk_75`。
7. **RTL / TB / 工具的中文注释是既定风格**（E6）—— 全仓库 `.sv`/`.py` 共 ~200 KB 非 ASCII，
   这是"把口径、取舍和踩过的坑写在代码注释里"这一文化的载体（`CODE-MAP.md:88` 明写）。
   **ASCII 约束只针对 `.bat` / `.tcl`。**
8. **`.bat` 与 `.tcl` 的"同规则不同成因"是有意的区分** ——
   `.bat` 是 OEM 代码页（吃掉行首字符），`.tcl` 是 7 位掩码（把注释劈成代码行）；
   `PITFALLS.md:622` 明确写了这个区分，`check` 也因此给 `.bat` 判 `[FAIL]`、给 `.tcl` 判 `[warn]`。
   §2 第 1 条建议的是"把 `.tcl` 也升为 `[FAIL]`"，**但那是一个要不要收紧政策的问题，不是改错。**
9. **`ibex` 式的"空 `else` / 单行 `if` 不带 `begin/end`"在本仓库是少数但一致的** ——
   未发现同一文件内两种缩进风格混用（实测 `always_ff`/`always_comb` 的 `begin` 均在下一行缩进 2 空格）。
10. **断言风格**：RTL 侧带内断言（`CODE-REVIEW-PLAN.md:144` 把它记为"核内仅一条手工断言"），
    TB 侧用 `chk()` 函数（`sim/tb_units.sv:39` 的 `!==`）。
    **两套并存是合理的**：RTL 断言要可综合约束、TB 检查要 X 敏感（`PITFALLS.md` 二节还记录了
    "`logic x = expr;` 是声明式初始化，只在 0 时刻求值一次"这类必须靠断言/TB 抓的坑）。

---

## 5. 建议的机器化闸门

原则来自 `tools/README.md:6`（"把这些'靠人记'的纪律变成'机器每次都查'"）与
`PITFALLS.md:463-465`（"判据放工具里, 不靠人看日志"）。
下面每条都写成 `check` 的一个检查项，**输入是仓库里的文件、输出是 `[FAIL]`**。

| # | 检查 | 抓什么 | 为什么能机器化 |
|---|---|---|---|
| **G1** | **`.tcl` 非 ASCII → `[FAIL]`**（现在 `[warn]`，`tools/fpga_workflow.py:846-848`） | §2 第 1 条（`fpga/build.tcl` 501 字节） | 已是现成实现（`:820-848`），只差改一个字的严重度；`PITFALLS.md:315-316` 自己就抱怨过"那是提醒不是拦截" |
| **G2** | **同一开关在多个 argparse group 里的**名字必须一致**（按 `dest` 归一化后对账）** | §2 第 3 条（`verify` `_` vs `synth` `-`） | 遍历 `sub.add_parser(...)` 收集 `add_argument` 的 `dest`，出现同 `dest` 不同 `option_strings` 就报 |
| **G3** | **文档文件一览表 ⊆ `canonical_rtl()`**（且反向也要报"存在但未登记"） | §2 第 4 条（`bht.sv` 不在 3 张表里） | `tools/fpga_workflow.py:163-164` 的 `unregistered_core_sv()` 已经在做 RTL 侧；把 `.md` 里的 `` `xxx.sv` `` 反引号记号抽出来对账即可（`check` 第 1 项已有"清单互相对账"的骨架，`:715-732`） |
| **G4** | **RTL 注释里的 `file.sv:NN` 引用必须解析成功**（或更彻底：禁止在注释里写行号，只准写标识符） | §2 第 5 条（`hazard_unit.sv:83` 等 5 处失效） | 正则抓 `[\w/]+\.(sv\|tcl\|py):(\d+)`，对每个引用检查"目标文件存在 且 目标标识符出现在那几行内"；`tools/fpga_workflow.py:141`(`build.tcl:123`) 与 `:570`(`load_store_unit.sv:269`) 也可被同一条抓住 |
| **G5** | **文档里承诺存在的标识符/列必须真的存在**（"文档声称 → 代码可查"） | §2 第 4 条 P1（7 处 `fmax_src`） | 抓文档里被反引号包住的**全仓库唯一的 token**（如 `fmax_src`），在 `tools/`+`results/*.csv` 表头里搜；0 命中就判"文档声称了不存在的东西" |
| **G6** | **`--record` 前必须有一次内容指纹匹配的 `verify`**（R42.1 的机器化） | 与 §2 第 7 条同源：`run_coremark.py` 的 ticks 与 fmax 来自两份**不同**产物 | `verify` 已把内容指纹写进 `.fpga-cache`（`tools/fpga_workflow.py:1046-1068`）；`--record` 时要求指纹一致，否则 `[STALE]`。这条 `CODE-REVIEW-PLAN.md:180`（X-03）已提出，**尚未实现** |
| **G7** | **`results/*.csv` 的表头/口径注释必须与工具口径同源** | §2 第 3 条 P1（CSV 第 2 行仍是 `1000/(20-w)`)  | `coremark.csv` 的第 1~3 行是手写注释；把口径说明改成由 `fpga_workflow.py` 在初始化 CSV 时写入 |
| **G8** | **输出前缀大小写白名单**（`[FAIL]`/`[warn]`/`[info]`/`[OK]`/`[BLOCK]`） | §2 第 8 条 P1（14 处 `[WARN]`） | 正则扫 `print()` 字符串字面量 |
| **G9** | **行尾符统一**（`.gitattributes` 或一条 check） | §2 P2 第 1 条（7 个 CRLF 的 `.sv`） | 读字节数 `\r\n` 与裸 `\n`；建议同时加 `.gitattributes` 治本 |
| **G10** | **RTL 大数字面量下划线风格**（≥5 位十六进制必须 `_` 分段） | §2 P2 第 3 条 | 正则 `\d{5,}` 在 `'h` 之后的字面量 |
| **G11** | **`open()` 一律带 `encoding=` 且用 `with`** | Python 侧 E5 的机器化：`tools/run_coremark.py`(3 个 `open()`，0 个 `encoding=`) 与 `tools/elf2hex.py`(2 个，0 个) 对比 `tools/amo_vectors.py`/`asm.py`/`build_sw.py`/`mk_cm_hw.py`(4/4 带) | 正则扫 `open(`；本仓库已因编码问题毁过文件（`PITFALLS.md:432-446` R29） |

---

## 附：本报告的复算命令（便于下次刷新）

```powershell
# 非 ASCII 字节数（逐个文件）
Get-ChildItem 'D:\USER\Desktop\FPGA\FPGA' -Filter *.sv -File |
  %{ $b=[IO.File]::ReadAllBytes($_.FullName); $n=0; foreach($x in $b){if($x -gt 127){$n++}}; "$($_.Name)`t$n" }

# 行尾符 / BOM
$b=[IO.File]::ReadAllBytes('<path>'); ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)

# 根 .sv 行数合计（CODE-MAP 口径）
(Get-ChildItem 'D:\USER\Desktop\FPGA\FPGA' -Filter *.sv -File |
  %{ [IO.File]::ReadAllLines($_.FullName).Count } | Measure-Object -Sum).Sum
```

> 本文件为**只读审查报告**，没有、也不应该改动任何代码文件。
