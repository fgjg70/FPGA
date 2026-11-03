# 动 RTL 的纪律（2026-11-03 20:40 立）

> **立此文档的原因**：决定"可以动 RTL"。但本项目的实测成绩只有一份，
> 且**本机无板、无下载器、无 PDS**。动 RTL 本身不难，难的是**动了之后还能证明交付档是什么**。
> 这份文档只回答一件事：**什么条件下允许动、动了必须付清哪些账、什么级别的证据能配什么级别的宣称。**

---

## 0. 事实基础（先摆证据，纪律才有根）

| # | 事实 | 核实方式 |
|---|---|---|
| F1 | 交付档 tag `deliv150-o2ira` = 提交 `d592067` | `git rev-parse deliv150-o2ira` |
| F2 | 当前 HEAD = `922e487`，分支 `feat/ai-accel` | `git log --oneline -1` |
| F3 | 当前 RTL **已与交付档不同**：被指纹覆盖的文件中 **10 个改动 / +3210 −2 行** | `git diff --stat deliv150-o2ira..HEAD -- $(ls *.sv fpga/*.sv)` |
| F4 | 差异集 = `core.sv` +47、`fpga/top_a100t.sv` +102、`nn_*.sv` 六个新增、`rv32_pkg.sv` +38、`fpga/nn_mem_bb.sv` +53 | 同上 |
| F5 | 这些改动**全部 `ifdef NN_EN` 隔离**；`NN_EN` **默认 OFF**（`build.tcl:289` 原话：*Default OFF … the delivery netlist is unchanged when this is off*） | `grep -n NN_EN fpga/build.tcl` |
| F6 | 但从指纹上看，**当前工作区已不是交付档**：当前 30 个 `.sv` / `85e1bbd6…`；`ila_done` 那次是 23 个文件 / `c149556e…` | `python -c "from fpga_workflow import sha256_tree"` |
| F7 | 🔴 **交付档两份最重要的上板证据没有 RTL 指纹**：`uart_final150.capture.json`、`uart_flash_boot_final.capture.json` 的 `rtl_sha256` 均为 **`None`** | 逐文件读 capture.json |
| F8 | `sha256_tree()` 只哈希 **RTL 字节**（根 `*.sv` + `fpga/*.sv`），**不覆盖** `sw/`（CoreMark C 源码）、`.hex`、`.xdc`、`build.tcl` | `fpga_workflow.py:2866-2886` |
| F9 | `build.tcl` 与 `fpga_workflow.py` **都不检查 git 状态**（无 dirty 守卫、无 tag 校验、无提交号记录） | `grep "git status\|dirty\|rev-parse"` → 空 |
| F10 | 本机**无 JTAG 下载器、无 USB-TTL、无紫光 PDS**（PDS 仅在队友机 `E:/pango/`） | 上一轮 `Get-PnpDevice` / `Get-PSDrive` |
| F11 | 当前回归基线 `verify --force` = **PASS 16 / SKIP 3** | 实跑 |

**F7 + F8 合起来是一句很重的话**：
**"324.19" 与 "Flash 自启动成功" 这两个数，今天既不能按 RTL 指纹追溯，也不能按固件指纹追溯。**
它们只能靠当时的 git 提交推定。这正是 R54 能藏 17 天的同族漏洞 —— **指纹覆盖面小于"成绩依赖面"**。

---

## 1. 三条红线（任何情况下不破）

### 红线一 · 交付档不可被覆盖

`deliv150-o2ira` 是**只读封存档**。禁止：在该 tag 上提交、在该 tag 的检出处改文件、
用当前工作区覆盖它的位流或证据。

- 任何 RTL 改动**必须**在新分支上进行，分支名格式 `exp/<主题>-<日期>`；
- 交付档的三件套（tag / `fpga/cpu_a100t.bit` / `results/uart_final150.*`）**一次都不许动**；
- 交付仍烧 `deliv150-o2ira` 那套位流，**与实验分支无关**。

> 理由：只有 324.19 一份上板实测。它一旦被"顺手重编"掉，整个交付就没有实测数了。

### 红线二 · 证据与宣称必须同级

四级证据，**跨级宣称即造假**（详见 §3）：

| 级 | 含义 | 允许的措辞 |
|---|---|---|
| **E0** | 只改了源码，未跑任何工具 | 「计划」「待验证」 |
| **E1** | 行为仿真通过 | 「仿真通过」——**不得**出现"时序""资源""实测" |
| **E2** | 综合/实现出了报告 | 「综合后 fmax/资源」——**必须**带周期 + WNS + 时钟名；**不得**出现"上板""实测" |
| **E3** | 板上跑出结果 + 采集清单 | 「上板实测」——**必须**带 `rtl_sha256` + 位流 sha256 |

**本机现状（F10）⇒ 今晚任何 RTL 改动最高只能到 E2。**
所以：今晚改的 RTL，**不许在任何文档里写"实测"**。

### 红线三 · 一次只改一处，先立判据后改码

- 改之前先写下：**假设 / 预期收益 / 失败判据**（三行，写进 `results/<主题>.md`）；
- 一次提交只含一个可归因的改动；混合改动一律拆开；
- 被否决的方案必须标 `rejected` + 原因，否则半年后（或今晚）会重复试。

---

## 2. 动 RTL 的准入：Gate 0 四问

动任何 `.sv` 之前，四问全部答得出来才准动，答不出来就退回。

**Q1 · 这个目标能不能不改 RTL 就达到？**
先排除：C 代码/编译配方（`tools/cm_recipe.py`）、综合策略（`--pblock-range`/`--fanout-limit`）、
约束（`.xdc`）、镜像参数（`ITERATIONS`）、外设接线（`top_*.sv` 的例化，不算核内 RTL）。
本项目历史上**多次**出现"以为要改 RTL，其实是别的地方"（R54 / R58）。

**Q2 · 它动哪几个文件？在不在指纹覆盖集里？**
- 在 `root *.sv` / `fpga/*.sv` ⇒ **会改 `rtl_sha256`** ⇒ 该档立即失去与已有上板证据的可比性；
- 只在 `sw/`、`.xdc`、`.tcl`、`.hex` ⇒ **不改进指纹**（F8）⇒ 但**同样**要按 `cm_recipe` 纪律管住配方。

**Q3 · 改完谁来上板？**
本机无板（F10）。若答"没有人"，则本次改动**只能作为 E2 实验**，
必须在 `results/<主题>.md` 首行写明：`证据级别: E2（未上板）`。

**Q4 · 回滚点在哪？**
必须能回答：`git checkout <commit> && python tools\fpga_workflow.py synth ...` 能否在 30 分钟内回到今天的交付态。
做不到就不许动。

---

## 3. 一次改动的闭环（T0~T9）

沿用 `HANDOFF-WORKFLOW.md` §4，但补两条本项目特有的前置/后置：

| 步 | 动作 | 判据 |
|---|---|---|
| **T-1** | **开 worktree 隔离**（见 §4） | 实验在 `../fpga-exp`，交付目录不动 |
| **T0** | `python tools\fpga_workflow.py verify --force` | 起点必须 **PASS 16 / SKIP 3**；不干净先修 |
| T1 | `python tools\fpga_workflow.py profile` / `metrics` | 量出基线，写下假设与预期收益 |
| T2 | 改**一处** | diff ≤ 一个可归因单元 |
| T3 | `verify --force` | 不降级；`tb_core_trap` / `tb_soc_timer_irq` 必在 |
| T4 | **重建上板镜像**（若涉及 CoreMark）`python tools\mk_cm_hw.py <iters>` | 必须打印 `[recipe] ... 与仿真日志一致`（R54 闸门） |
| T5 | `synth --tag <新tag> --record` | 记 fmax **四件套**（时钟名 + 周期 + 频率 + WNS）+ LUT/FF/BRAM/DSP |
| T6 | 若有板：`prog_uart.bat` → `uart_capture.py` → `hw` | 三条同时满足才算 E3 |
| T7 | `metrics --vs <上一行>` | 判 `keep` / `reject`，写进 `results/coremark.csv` |
| T8 | 写 `results/<主题>.md` + 补 `PITFALLS`（若踩坑） | 含证据级别标注 |
| T9 | 提交 + 打 tag | tag 名带证据级别，如 `exp-irqext-e2` |

**T5 之后必须做的一件事**：把 `sha256_tree()` 的新值记进 `results/<主题>.md`。
理由 F9 —— 没有任何工具会自动记录"这个报告是从哪个提交编的"，只能人记。

---

## 4. 交付档保护：worktree 常驻

`git worktree` 让交付档与实验分支**同时存在于磁盘**，互不污染：

```powershell
# 一次性：把交付档检出到独立目录（只读用途）
cd D:\USER\Desktop\FPGA\FPGA
git worktree add ..\fpga-deliv deliv150-o2ira

# 日常：实验在另一个目录做
git worktree add ..\fpga-exp -b exp/irqext-1103
cd ..\fpga-exp
# ... 改 RTL、verify、synth ...
```

判据：**`D:\USER\Desktop\FPGA\FPGA` 这个目录在任何时候都必须能 `git status --short` 干净，
且 RTL 指纹必须与 `deliv150-o2ira` 一致**（除非明确在做实验）。

> 注意：`.fpga-cache/` 与 `sim/prog/*.hex` 是 gitignore 的，worktree 里**不会共享**它们。
> 所以 `../fpga-deliv` 里要重跑一次 `mk_cm_hw.py` 才能综合 —— 而这正好是 R54 的入口，
> **必须**看到 `[recipe]` 闸门通过。

---

## 5. 已知漏洞（纪律管不住、必须靠人记的）

| # | 漏洞 | 现状 | 临时对策 |
|---|---|---|---|
| **H1** | 交付档两份上板证据的 `rtl_sha256` 为 `None`（F7） | 无法机器追溯 | 在 `results/hw-verified.md` 补一句"该证据推定对应提交 `d592067`，无指纹"；**不要在报告里声称它可指纹追溯** |
| **H2** | 指纹不覆盖固件/约束/配方（F8） | R54 的根源 | 靠 `cm_recipe.py` + `mk_cm_hw` 闸门 + `uart_capture --parse` 三层；RTL 指纹**不能**替代它们 |
| **H3** | 构建不记录 git 提交号（F9） | 报告与提交的对应靠人 | T5 之后手工把 `sha256_tree()` + `git rev-parse` 写进主题文档 |
| **H4** | 本机无板（F10） | 任何改动 <= E2 | 若要在今晚拿到 E3，先确认**板子+下载器在哪台机器上**，否则不要开启需要 E3 的改动 |

---

## 6. 当前时点的裁定（距截止 21h20m）

**结论：允许动 RTL，但今晚只有一种形态是合规的 —— 分叉实验，证据上限 E2，交付档不动。**

三条具体的票：

1. **`irq_ext` 接线类改动（动 `core.sv` + `top_a100t.sv` + `.xdc`）**
   ⇒ 会改指纹 ⇒ 交付档立即与 324.19 脱钩 ⇒ 而本机无板，拿不到 E3。
   **今晚不建议做**，除非同时确认"能上板验证"。
   若决定做：只在新分支 `exp/irqext-1103`，做完标注 `E2（未上板）`，交付仍烧旧位流。

2. **纯信息型改动（不加功能，只为了让报告有数）**
   ⇒ 例如 `use_dsp` 属性、约束微调、只读的剖析插桩。
   风险低、可回滚、不碰核内逻辑，**可以做**，但同样标 E2。

3. **任何"顺手修好"的冲动**
   ⇒ 本项目已判死的路线（双发射 / RV32C / RV32F / Pblock 收窄 / ExtraTimingOpt）**一律不许重开**，
   理由都在 `MEMORY.md` §5。距离截止 21 小时，重开等于放弃交付。

---

## 7. 与现有机制的接口

| 已有机制 | 覆盖什么 | 不覆盖什么 |
|---|---|---|
| `sha256_tree()` + capture.json | RTL 字节指纹 | 固件、约束、配方（H2）、不自动比对提交号（H3） |
| `cm_recipe.py` + `mk_cm_hw` 闸门 | CoreMark 配方漂移 | RTL 改动 |
| `verify --force`（PASS 16 / SKIP 3） | 功能回归 | 时序、资源、上板 |
| `synth --tag --record` | 时序/资源归档 | 与 git 提交的绑定（H3） |
| `PITFALLS` R1~R60 | 已知坑 | 尚未踩的坑 |

**本纪律新增的、目前仍是人工的部分**：T-1（worktree 隔离）、T5 后记指纹与提交号、证据级别标注。
若要机器化，最小改动是在 `synth` 里自动把 `git rev-parse HEAD` + `git status --short` 的空/非空
写进 `results/psynth.csv` 与报告头 —— **这是纯工具改动，不动 RTL，随时可做**。
