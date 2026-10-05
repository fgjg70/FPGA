# tools — 工作流工具集

本目录里的工具解决的是**工程纪律问题**，不是功能问题。
`skills/fpga-riscv-a100t/PITFALLS.md` 记录了 40+ 个踩过的坑，其中最高频的一条是
**R1「改了 A 忘了同步 B」——全部静默失败**（不报错、结果不变或结果错）。
`fpga_workflow.py` 存在的唯一目的，就是把这些"靠人记"的纪律变成"机器每次都查"。

---

## 快速开始

```bat
rem 环境自检 + 漂移检测 (改完代码收尾时跑, 约 2 秒)
cmd /c tools\doctor.bat

rem ModelSim 增量回归 (只跑受影响的测试)
python tools\fpga_workflow.py verify

rem 三项指标 + 绝对吞吐
python tools\fpga_workflow.py report
```

---

## 1. `fpga_workflow.py` — 统一入口

### `doctor` — 环境自检

检查 6 个工具路径是否存在，并打印会话环境的关键变量。
**为什么需要**：DSH 会话的 `process.env` 可能被剥离，此时 Vivado 报
`32-bit platform is not supported`、`vsim` 报 `Unable to checkout a license`。
工具内置 `clean_env()`，显式补齐 `PROCESSOR_ARCHITECTURE=AMD64` /
`LM_LICENSE_FILE` / `PATH`，所以**即使会话环境是空的也能跑**。

### `check` — R1 漂移检测（核心）

五项检查，全部来自 PITFALLS 里踩过的真坑：

| # | 检查项 | 对应的坑 |
|---|---|---|
| 1 | 三处 RTL 文件清单是否同步（`build.tcl` / `build_ila.tcl` / `run_coremark.py`） | R1：新增 RTL 忘了加进清单 → 静默用旧产物 |
| 2 | 是否存在"没有任何地方例化"的 RTL 模块 | 在研未接线的模块（如 `csr_file.sv`） |
| 3 | `sw/` 源文件是否比 `sim/prog/*.hex` 镜像新 | R1：改了软件忘了重建镜像 |
| 4 | `tb_sw.sv` 的 tohost 地址 / 注释是否与 `link.ld` 一致 | R1：改 `link.ld` 地址要同步 5 类文件 |
| 5 | `.bat` / `.tcl` 是否纯 ASCII | R2：cmd 用 OEM 代码页会吃掉行首字符 |

**严重度是分开的**，不是一刀切报警：

- `[FAIL]` = 必须修，退出码 1
- `[warn]` = 建议修，不阻塞
- `[info]` = 已知在研项，**预期如此**

`csr_file.sv` 目前不在任何清单里，这是**正确的**（`core.sv` 还没例化它）。
工具把它报成 `info` 而不是 `FAIL`，靠的是文件顶部的 `KNOWN_UNWIRED` 白名单。
**P1 做完后应该把 `csr_file.sv` 从 `KNOWN_UNWIRED` 删掉**，检查会自动开始强制要求它。

同一份白名单思路用在 RTL 编译顺序上：`CORE_SV_ORDER` 显式列举顺序，
`rv32_pkg.sv` 必须第一个编译（其余模块 `import` 它）。
> 这不是格式问题而是语义问题 —— 首次跑回归时按字母序排序，`rv32_pkg` 排到了后面，
> vlog 一次性报了 60 个 `Could not find the package (rv32_pkg)`。
> `unregistered_core_sv()` 会拦住"新加了 .sv 但忘了登记"的情况。

### `verify` — ModelSim 增量回归

跑 7 个测试，每个测试的缓存键 = **参与编译的所有文件的内容哈希** + plusargs + 编译器版本。
内容没变就跳过（首次约 30 秒，之后未受影响时 < 1 秒）。

| 测试 | 程序 | 内容 |
|---|---|---|
| `tb_units` | — | 194 项单元检查 |
| `tb_core_basic` | `basic.hex` | 系统级自校验（含非对齐访存）|
| `tb_core_m_ext` | `m_ext.hex` | RV32M 边界 |
| `tb_core_trap` | `trap.hex` | Zicsr + 异常/中断 + MRET（带 `+illegal_trace` 诊断探针）|
| `tb_soc` | `mmio.hex` | 外设 + UART 环回 |
| `tb_sw_hello` | `hello.hex` | 裸机 hello |
| `tb_sw_coremark` | `cm_rv32im.hex` | CoreMark 仿真 |

当前基线：**7 PASS**，全量约 23 秒，未受影响时 2.8 秒。

**判定依据是 testbench 自己打印的 `RESULT : PASS`，不是 `vsim` 的退出码。**
> ModelSim 用 `quit -f` 结束时，无论测试成败都返回 0。
> 早期版本用 `"PASS" in output` 判定，把"编译失败"和"超时"都误判成了通过 ——
> 4 个测试里 2 个假通过。现在用白名单（必须显式出现 `RESULT : PASS`）+ 崩溃/超时否决。

**XFAIL 语义**（当某个测试记录的是"还没做"的状态时用 `expect_fail_ok` 标记）：
- `XFAIL` = 如预期地失败，不算回归失败
- `XPASS` = 它开始通过了 → **说明那个待办做完了，该把标记去掉**，退出码 1 提醒你

XFAIL 测试**永远重跑、永不缓存** —— 缓存命中会把"从失败翻转成通过"这个重要信号掩盖掉。
> P1（异常/中断接线）就是用这个机制收尾的：`tb_core_trap` 由 XFAIL 翻成 XPASS，
> 提示标记已过时，去掉后全套变成 7 PASS。

选项：`--only tb_units tb_soc`（只跑指定）、`--force`（忽略缓存）、`-v`（通过时也打印摘要）。
日志落在 `.fpga-cache/logs/<test>.log`。

### `synth` — Vivado 综合 → 四项指标（测量半环）

```bat
python tools\fpga_workflow.py synth --prog cm_hw --tag my-experiment --record
```

一条命令走完 **synth → opt → place → phys_opt → route → bitstream → 解析报告 → 算四项指标**：

- **全局构建锁**：用 `O_EXCL` 原子创建锁文件 + pid 陈旧锁回收，保证同一时刻只有一个
  Vivado。两个实例重叠会让 IP 生成器初始化失败，而且**谎报** `pkgIndex.tcl` 缺失 ——
  报错指向完全无关的地方，极难定位。
- **参数化程序镜像**：把 `build.tcl` 的 `set PROG <name>` 临时改成要测的程序，
  跑完**自动还原**。缺 `.dmem.hex` 会**报错退出**而不是静默继续（否则 `.data/.rodata`
  全 0，bitstream 照样生成 —— 正是本工程反复踩的静默失败）。
- **内容哈希缓存**：RTL / 镜像 / `build.tcl` 任一变化才重建，否则复用上次结果。
- **报告归档**：`timing.rpt`/`util.rpt` 每次构建都被覆盖，所以自动归档到
  `.fpga-cache/reports/<时间戳>-<prog>/`。**本项目出现过"旧报告被覆盖后无法复核历史数字"**。

四项指标一次算出（赛题记三项，但必须同时看绝对吞吐）：

```
CoreMark/MHz  |  fmax (由 WNS 推)  |  CoreMark/LUTs  |  绝对吞吐 = CoreMark/MHz x fmax
```

`--record` 会按 `results/coremark.csv` 的表头顺序追加一行。

### `report` — 三项指标 + 绝对吞吐

从 `results/coremark.csv` 读历史，重算并打印：
**CoreMark/MHz、LUT、fmax、CoreMark/LUTs、绝对吞吐（CoreMark/MHz × fmax）**，
以及"最新保留配置 vs 基线"的四项变化率。

> 对应 SKILL.md 第 10.2 节的铁律：**赛题记三项指标，改一项必须同时看三项 + 绝对吞吐。**
> 反例就是 RAS 实验：CoreMark/MHz +1.0%，但 fmax −4.6%、CoreMark/LUTs −4.4% → 净亏回退。
> 手算这个容易只看一项就下结论，所以做成一条命令。

---

## 2. `doctor.bat` — 零摩擦包装

对应"上板构建一律走 `.bat`"的既有约定。为什么需要它：

1. **绕开 R2**：`cmd` 里敲带引号/中文的命令本身就是踩坑来源，`.bat` 纯 ASCII 一次写好
2. **绕开环境剥离**：`cd /d "%~dp0.."` 到仓库根，Python 自解析路径
3. **一条命令**：`doctor` + `check` 串起来跑，收尾时只跑这一个

---

## 3. 设计约定

- **所有路径用正斜杠**：Vivado/Tcl 只吃 `/`，Windows 两种都认，所以统一 `/` 避免转换
- **不 glob `fpga/`**：该目录有大量 Vivado 生成物（`.runs` / `.cache` / `.Xil`），
  所以 SoC 侧文件在 `SOC_SV` 里显式列举
- **解析而不是重写清单**：工具**读**三处清单来对账，不自动改写它们。
  自动改写会把"漂移"变成"被掩盖的漂移"，失去检查意义
- **严重度必须准确**：报警不准 = 没人看报警。`csr_file.sv` 报 `info` 而不是 `FAIL`
  是刻意的，否则每次跑 `check` 都有一条红色，很快就被无视

---

## 4. 还没做的（按价值排序的建议）

1. **`verify` 接上 Vivado 时序**：把 `report` 与 `verify` 合并成"一次改动 → 三项指标全出"
2. **fmax 自动测量**：现在 `fmax` 要从 `fpga/timing.rpt` 手工读，可以并入 `verify --synth`
3. **`.hex` 依赖图**：第 3 项检查现在是"sw/ 下任一文件比镜像新"的粗粒度判断，
   实际可以按 `#include` 建精确依赖
4. **上板闭环自动化**：`ila_cap_done.bat` 的读回结果可以直接解析进 `results/coremark.csv`
5. **R3 期望值独立验算**：`tb_units.sv` 里的期望值目前靠人算对（曾把
   `0xFFFFFFEC / 3` 写成 1431655762，实际 1431655758）。可以让 Python 独立算一遍再比对
