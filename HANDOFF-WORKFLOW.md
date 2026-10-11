# 我的工作流 + 给你的集成建议

> **写给接手本项目的 AI。**
> 我已经用下面这套循环做了 10 轮迭代（三项指标从 0.8263 提到 **2.4209**）。
> 你已经建了 `tools/fpga_workflow.py`（doctor/check/verify/report/synth）—— 那是**工程纪律**层，做得很好。
> 本文补两件事：**① 我实际怎么迭代的（优化循环本身）；② 建议你把它固化成 skill / 子命令的设计**。
>
> 配套文档：`HANDOFF.md`（项目现状）、`HANDOFF-HW-LOOP.md`（硬件闭环能力）、
> `skills/fpga-riscv-a100t/PITFALLS.md`（错误台账）。

---

## 1. 我的实际循环（10 轮都是这个）

### 1.1 一轮的形状

```
  [0] 选靶子      <- 不是拍脑袋, 靠 [1] 的剖析数据决定
       |
  [1] 量当前状态   <- 剖析: 周期花在哪? 三项指标现在多少?
       |
  [2] 改一处      <- 一次只改一个东西, 否则归因不了
       |
  [3] 仿真验证     <- ModelSim 全套回归, 必须 RESULT : PASS
       |
  [4] 重综合量指标 <- Vivado 构建 -> WNS/资源; CoreMark 仿真 -> ticks
       |
  [5] 判定        <- 三项指标 + 绝对吞吐, 赢 2 输 1 才留; 否则回退
       |
  [6] 沉淀        <- results/*.md + coremark.csv 追加一行 + SKILL/PITFALLS
```

**关键：`[2]` 到 `[5]` 是一个闭环，`[6]` 是让它可复现。没有 `[6]` 的轮次等于白做。**

### 1.2 各步的真实命令

#### [1] 量当前状态 —— 剖析（纯仿真，不改 RTL）

在 `sim/tb_sw.sv` 里用**层次化引用**读 core 内部信号：

```systemverilog
if (!u_dut.if_id_flush && !u_dut.pipe_stall) n_fetch++;
if (u_dut.redirect)   n_redirect++;
if (u_dut.pipe_stall) n_stall++;
if (u_dut.u_hazard.load_use) n_stall_lu++;   // load_use 在 hazard_unit 内部
if (u_dut.md_busy)    n_stall_ex++;
if (u_dut.id_ex_ctrl.pc_sel != 2'd0) begin
  if (!u_dut.pipe_stall) n_ctrl++;
  if (u_dut.redirect_raw) n_mis++;           // 预测精度
end
if (u_dut.id_ex_ctrl.pc_sel == 2'd1) n_bcond++;   // 条件分支总数
```

**这一步是整个方法的支点。** 第 1 轮就是靠它发现「分支惩罚吃掉 29% 的周期」，
才决定先做分支预测而不是 M 扩展 —— 如果拍脑袋做 M 扩展，收益会小很多。

当前账（CoreMark；下面是**旧基线 423,486 ticks** 时的口径，**现基线为 413,070 ticks**）：
```
load-use 停顿  30,644  (7.1%)   <- 最大项
分支误判       23,002  (5.4%)   (11,501 次 x 2 拍)
乘除法停顿     14,415  (3.3%)
预测精度       89%    CPI 1.09
```

#### [3] 仿真验证

一条 .bat 跑完 12 个测试（`fpga_workflow.py verify` 已经把它自动化了，很好）：
```bat
set "LM_LICENSE_FILE=D:\software\tools\Modelsim\win64\LICENSE.TXT"
set "PATH=D:\software\tools\Modelsim\win64;%PATH%"
vlib work
vlog -sv -work work <21 个根 .sv + fpga\mmio_subsys.sv + fpga\top_a100t.sv> sim\tb_units.sv sim\tb_core.sv sim\tb_soc.sv sim\tb_sw.sv
vsim -c -do "run -all; quit -f" work.tb_units
vsim -c -do "run -all; quit -f" work.tb_core +imem=<abs>\basic.hex
vsim -c -do "run -all; quit -f" work.tb_sw   +imem=<abs>\cm_rv32im.hex +dmem=<abs>\cm_rv32im.dmem.hex
```

**判据是 testbench 打印的 `RESULT : PASS`，不是 vsim 退出码**（你已经踩过并修好了）。

#### [4] 重综合量指标

```bat
cmd /c D:\USER\Desktop\FPGA\FPGA\fpga\build.bat
```
然后**必须从报告里读**，不能凭上次的数字：
```python
# ✅ 现在直接用工具: python tools\fpga_workflow.py metrics
#    M-01 已修: 解析器从 Clock Summary 取各时钟周期, 在 Intra Clock Table 里按【设计主时钟】
#    取 setup WNS, fmax = 1000/(T - WNS), 并把推导整行打印出来。当前主时钟名 = sys_clk_core
#    (131.25 MHz 目标档 @7.619 ns), 近期收敛档是 105 MHz: fmax = 1000/(9.524 - 0.117) = 106.30
#    ⇒ 只写 "fmax=xx" 的文档一律不合格: 必须带时钟名 + 周期 + 运行频率 + WNS。
# ⚠️ 反面教材(已失效, 别再照抄): 从 `sys_clk` 行取第一个数再按硬编码 20ns 换算 ——
#    引入 MMCM 后 `sys_clk` 行不再有 setup 端点, 该正则会静默抓到【脉宽余量 WPWS=7.000】,
#    报出虚高的 76.92 MHz。见 CODE-REVIEW-PLAN.md M-01 / X-01, PITFALLS R42.1。
# 资源: 从 util.rpt 按行匹配, 不要用 'lastIndexOf' 之类会串行的写法
def val(report, key):
    for line in report.splitlines():
        m = re.match(r'^\|\s*' + re.escape(key) + r'[^|]*\|\s*(\d+)', line)
        if m: return int(m.group(1))
LUT  = val(util, 'Slice LUTs')
FF   = val(util, 'Slice Registers')
BRAM = val(util, 'Block RAM Tile')
DSP  = val(util, 'DSPs')
```

> ⚠️ **`util.rpt` 里 `Slice Registers` 与 `Slice` 都会匹配到，`Block RAM Tile` 有多个分节。**
> 我用正则按行首 `|` 匹配才稳。早期用 `lastIndexOf` 取到了错误的段，导致 FF/BRAM 一直读成 `undefined`。

#### [5] 判定 —— 这是最容易被忽略的一步

```python
CM_MHZ = 1e6 / ticks          # CoreMark/MHz (主频自动约掉)
CM_LUT = CM_MHZ / LUT          # CoreMark/LUTs
ABS    = CM_MHZ * fmax         # 绝对吞吐 = 每秒多少次迭代
```

**为什么必须有 `ABS`**：三项指标可能互相矛盾。真实例子 ——

| 配置 | CM/MHz | fmax | CM/LUTs | ABS | 结论 |
|---|---|---|---|---|---|
| 分布式 RAM dmem | 2.3614 | 74.6 | 5.254e-4 | 176.2 | — |
| BRAM dmem | 2.3614 | 63.9 | **9.518e-4** | 150.8 | 赢 1 输 1，按赛题取向取舍 |
| RAS + BTB128 | 2.3856 | 71.2 | 4.961e-4 | 169.9 | **赢 1 输 2 → 回退** |

没有 ABS 就看不出「RAS 那个改动其实三项里输了两项」。

#### [6] 沉淀

- `results/coremark.csv` **追加一行**（不要改旧行 —— 旧行是当时代码的实测值）
- `results/<tag>.md` 写清**设计 + 取舍 + 踩的坑**
- 被否决的方案也要写，标 `rejected` —— 否则下一轮会重复试
- `skills/fpga-riscv-a100t/PITFALLS.md` 补坑（症状优先）

---

## 2. 判据清单（什么算过 / 什么算可疑）

| 环节 | 通过 | **可疑信号（要停下来查）** |
|---|---|---|
| 仿真 | 12 个测试都打印 `RESULT : PASS`（矩阵见 `test_matrix()`）| 某个测试没输出 / 输出为空 / 编译有 Error 但测试仍「过」 |
| CoreMark | `crclist 0xe714` `crcmatrix 0x1fd7` `crcstate 0x8e3a` | ticks 与上次**完全相同** → 大概率镜像没重建 |
| 综合 | `BUILD_TIMING=PASS`（WNS ≥ 0）| LUT 只有几十个 → 没装程序，被常量折叠 |
| 上板 | `score_result` bit31 = 1 **且**采集清单 `ila_done.capture.json` 新鲜 | `score_result` = 0 → 程序没跑完 / ILA 是旧 RTL；清单缺失 ⇒ `hw` 拒绝给结论 |
| 任一环节 | 数字有变化且方向可解释 | **跨环节一致性过好**（镜像逐字节相同、指标一字不差） |

---

## 3. 建议：把闭环并进 `fpga_workflow.py`

你现有的 `doctor / check / verify / report / synth` 覆盖了纪律层。
缺的是**测量层与硬件层**。建议加三个子命令：

> ✅ **这三个子命令（`metrics` / `profile` / `hw`）现在都已经实现**（见 `tools/README.md`），
> 本节保留的是**当时的接口设计**，可作为"为什么这样设计"的说明；
> 实际用法以 `tools/README.md` 与 `python tools\fpga_workflow.py <cmd> -h` 为准。

### 3.1 `metrics` —— 三项指标 + 判定

```bash
python tools/fpga_workflow.py metrics                    # 打印当前三项 + ABS
python tools/fpga_workflow.py metrics --vs bram-v1       # 与历史某行对比, 给出 keep/reject 建议
```

**输入**：`fpga/timing.rpt` + `fpga/util.rpt` + 一个 ticks 值（来自仿真或上板）
**输出**：`{cm_per_mhz, fmax, cm_per_lut, abs, delta_vs}`

> **【fmax 口径纪律】`fmax` 这个数必须能回答"哪条时钟、周期多少、运行频率多少、WNS 多少"。**
> 引入 MMCM 后核心跑在 MMCM 输出域，**时钟名已改为频率无关的 `sys_clk_core`**
> （`fpga/daVinciPro.xdc`；旧名 `sys_clk_75` 已废），不是 `sys_clk` @20 ns，
> 所以旧公式 `1000/(20 − WNS)` **已失效**（`CODE-REVIEW-PLAN.md` M-01）。
> 修好的工具会打印完整推导，例如 105 MHz 档：
> `fmax 106.30 MHz  sys_clk_core @9.524ns, 运行 105.00 MHz; WNS +0.117ns -> fmax=1000/(9.524 - 0.117)`
> —— **照抄这个格式，不要只写"fmax=xx"**（时钟名/周期以当次报告为准）。
> ⚠️ **运行频率与 fmax 不独立**（PITFALLS **R50**）：约束从 14.286 收紧到 13.333 ns 后，
> fmax 自己就从 74.4 升到 76.2 —— 所以"提频"同时也是在动 fmax 这一项，报的时候要写清约束。
> ⚠️ `results/coremark.csv` 的 `fmax` 列**混着两种口径**，此前要求"必须配 `fmax_src` 列读"，
> 但**该列尚待 `CODE-REVIEW-PLAN.md` M-04 落地**（表头 12 列无此列）—— 在那之前以该行 `notes` 为准。

**建议逻辑**（把第 [5] 步的纪律编码进去）：
```
win = 0; lose = 0
for k in (cm_per_mhz, fmax, cm_per_lut):
    if now[k] > prev[k] * 1.005: win  += 1
    elif now[k] < prev[k] * 0.995: lose += 1
verdict = 'KEEP' if win > lose else ('REJECT' if lose > win else 'TIE(看赛题取向)')
if abs < prev_abs * 0.98: verdict += '  [WARN: 绝对吞吐下降]'
```

> 判据里的 0.5%/2% 阈值不是随手写的：仿真噪声与工具重排会带来 ~1% 的抖动，
> 低于它不该算赢。

### 3.2 `profile` —— 优化前的剖析（结构化）

```bash
python tools/fpga_workflow.py profile --prog cm_rv32im --json results/profile.json
```

跑一次 tb_sw，把第 [1] 步那些计数器抽成 JSON：
```json
{
  "ticks": 413070, "retire": 426281, "cpi": 1.09,
  "stall": {"load_use": 30645, "split_mem": 0, "muldiv": 14415},
  "redirect": {"total": 11535, "cond": 6041, "jal": 1096, "jalr": 2823},
  "predictor": {"ctrl": 101961, "mispredict": 11535, "accuracy": 0.887}
}
```
> ⚠️ 上面是**格式示意**（键名以 `profile` 的真实输出为准，见 `fpga_workflow.py`
> 里解析它的正则）；`ticks` 已按当前基线（**413,070**）校正，其余计数值随改动而变，
> **一律以 `profile` 当次打印为准，不要抄这里的数**。
**为什么值得做**：这是「先测量再优化」的抓手。没有它，优化就是猜。
有它之后，选靶子可以变成一个规则：**取占比最大的那一项**。

### 3.3 `hw` —— 上板闭环（详见 `HANDOFF-HW-LOOP.md`）

```bash
python tools/fpga_workflow.py hw --stale                # ILA bit 与 RTL 新鲜度
python tools/fpga_workflow.py hw --capture done         # 烧录+跑+读回结果
python tools/fpga_workflow.py hw --capture wave         # 抓流水线波形
python tools/fpga_workflow.py hw --rebuild              # 重建 ILA 版 (含串行锁)
```

**`--stale` 是最有价值的一个**，因为 ILA 版 bitstream 与 RTL 脱节是**静默失败**：
抓回来的是旧设计的信号，不报任何错。判据：
```python
stale = [f for f in RTL_AND_TOP_FILES if mtime(f) > mtime(ILA_BIT)]
# 非空 -> 必须先 hw --rebuild, 否则本次上板结论无效
```

**`--capture` 的输出**应该是解析好的结论，不是原始 CSV（**下面是 2026-10-11 冻结版的真实形态**）：
```json
{
  "program": "cm_hw", "iterations": 3000,
  "done": 1, "pass": 1, "fail": 0, "illegal": 0,
  "crc_ok": 1, "ticks": 1239079510, "seconds": 16.52, "clk_hz": 75000000,
  "cm_per_mhz": 2.4212, "csv": "results/ila_done.csv",
  "source": "results/ila_done.capture.json (采集清单)"
}
```
> `iterations` / `clk_hz` **不再需要手传**：按 `命令行 > 采集清单 > sim/prog/cm_hw.build.json`
> 推断，并把来源打印出来；三处都没有才拒绝给结论（M-03 已修）。

---

## 4. 建议：一个 skill（把循环本身固化）

现有两个 skill 是**知识型**（`fpga-riscv-a100t` 环境与坑、`fpga-workflow` 纪律）。
建议再加一个**动作型** skill，比如 `fpga-optimize-loop`，定义标准回合：

```
### 一个优化回合的标准动作

1. `fpga_workflow.py verify`        -- 起点必须干净, 否则先修
2. `fpga_workflow.py profile`       -- 量, 找出占比最大的开销
3. 选定唯一改动, 写清假设与预期收益
4. 改代码
5. `fpga_workflow.py verify`        -- 回归
6. `fpga_workflow.py synth --tag X --record`  -- 重综合, 归档 rpt
7. CoreMark 仿真量 ticks (或 `hw --capture`)
8. `fpga_workflow.py metrics --vs <上一行>`   -- 判定 keep/reject
9. 写 results/X.md; 追加 coremark.csv 一行; 补 PITFALLS

### 硬规则 (写进 skill 的 IRON RULE)
- 一次只改一处, 否则归因不了
- 三项指标 + 绝对吞吐 必须同时量, 少一个就下不了结论
- 结果与上次完全一致 = 先怀疑镜像没重建, 不要当成「改动无效」
- 被否决的方案必须记录 (标 rejected + 原因), 否则会重复试
- 不落盘等于没测
```

---

## 5. 可复用的模式（换项目也能用）

| 模式 | 一句话 | 本项目里的样子 |
|---|---|---|
| **先测量再优化** | 优化前必须有剖析数据，否则是猜 | tb_sw 里的层次化引用计数器 |
| **多指标同时量** | 单一指标会骗人 | 三项 + 绝对吞吐，赢 2 输 1 才留 |
| **静默失败检测** | 「完全一致」通常意味着没生效 | 镜像逐字节比对、ticks 完全相同就查 |
| **否决也记录** | 负结果同样是资产 | coremark.csv 的 `rejected` 行 + 原因 |
| **改动影响面清单** | 改 A 要同步哪些 B | PITFALLS 的 R1 对照表 |
| **症状优先的台账** | 出错时先按症状查，不要从头推理 | PITFALLS.md 的组织方式 |
| **判据用内容不用时间** | mtime 会被 checkout/复制打乱 | 用内容哈希做缓存键（你已经这么做了）|

---

## 6. 我踩过、你可能还没遇到的坑（补充给 PITFALLS）

| 症状 | 真因 |
|---|---|
| `util.rpt` 解析出 `undefined` | 用 `lastIndexOf` 取错了分节；`Slice Registers` 与 `Slice` 会混淆 → 按行首 `\|` 正则匹配 |
| 综合出 25 个 LUT | 没定义 `IMEM_INIT_FILE`，整个设计被常量折叠 |
| `Synth 8-2715 syntax error near /` | `verilog_define` 的路径没加引号，宏展开成裸路径 |
| CoreMark 两次构建镜像逐字节相同 | `build_sw.py` 硬编码了 `-march=rv32i`；`-D FLAGS_STR` 只改打印的字符串 |
| 程序跑到 `j .` 自旋、tb 超时 | 改了 `link.ld` 地址但没同步 `.S` 里硬编码的 tohost |
| `vopt-7061` | `initial` 与 `always_ff` 同时驱动一个变量 |
| 信号恒为 X | `logic x = expr;` 是声明式初始化，只在 0 时刻求值一次 |
| `vlog-13069 unexpected '['` | `(a>>b)[31:0]` 非法，不能对括号表达式位选 |
| 层次化引用报 `Undefined variable` | `assign` 写在了信号声明之前 |
| Vivado Tcl 报 `invalid command name` | `.tcl` 里有中文；7 位掩码编码会把注释行劈成代码行 |
| IP 生成器 `::ipgen_iptclns` 初始化失败 | 两个 Vivado 实例重叠（你已经加了全局锁）|

---

## 7. 一句话总结

**你已经有了「纪律」（check/verify），我补的是「测量」与「判定」。**
`metrics` / `profile` / `hw` 三个子命令**已实现**，第 4 节的回合也已固化成 skill，
这个项目就从「有人盯着才不会错」变成「机器每一步都替你查、替你算、替你判」。

> ⚠️ 但"机器替你算"有个前提：**量具本身是对的**。本文 §1.2 [4] 那段 fmax 公式
> 已经因为 MMCM 而失效（`CODE-REVIEW-PLAN.md` M-01），修好之前 `metrics` 的
> keep/reject 判定不可信 —— **先修量具，再信结论**。
