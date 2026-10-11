# review-fixes-v1 — 2026-10-11 审查修复轮结论

> **后续（同日）**：本文记录的是 **70 MHz** 那一轮的交付状态。当天下午把系统时钟提到
> **75 MHz**（只换 MMCM 抽头，VCO 不变）并再次上板 PASS ⇒ 当前权威数字请以
> **`CODE-REVIEW-PLAN.md` §8** 与 `README.md` 为准：
> fmax **76.2 MHz**、LUT **2734**、CoreMark/LUTs **8.855e-4**、绝对吞吐 **184.4**、
> 上板 tick **1,239,079,510** / **16.52 s** / 12:19:02。
> 本文的 §1 指标表保留为**那一轮的历史快照**（口径与证据链方法不变）。

> 本轮由 **Agent Team**（Lead + 4 泳道：`rtl-fix` / `sw-verify` / `docs-sync` / `build-repo`）执行，
> 依据是 `CODE-REVIEW-PLAN.md`（同轮产出的 75 项审查计划）。**12 个 commit**，
> 起于 `d6b48fe`，工作区最终干净。
>
> 每项都遵循同一条纪律：**先复现 → 再修 → 注入式自测 → `verify` 通过才提交**。

---

## 0. 一句话

修掉了 **2 处中断路径的架构级正确性缺陷** + **4 处"结论不可信"的度量缺陷** +
**1 处"回归绿灯是假的"缺陷** + **1 处上板证据可伪造**，并把整套度量与上板判据
变成**可复现、不可伪造**；代价是 `CoreMark/LUTs` −2.5%（自觉取舍，见 §4）。

---

## 1. 最终指标（唯一口径，已上板验证）

来源：`.fpga-cache/reports/20261011-111332-cm_hw/` + `results/coremark.csv` 行 `review-fixes-v1`
+ `results/ila_done.capture.json`（2026-10-11 11:19:07）。

| 评分指标 | 基线 | **最终** | 变化 |
|---|---|---|---|
| CoreMark/MHz | 0.8263 | **2.4209**（ticks 413,070） | **+193.0%** |
| fmax | 78.4 MHz | **74.4 MHz** | **−5.1%** |
| CoreMark/LUTs | 2.361e-4 | **8.848e-4** | **+274.8%** |
| 绝对吞吐 | 64.8 | **180.2** | **+178.1%** |
| 资源 | — | LUT **2736** / FF **1251** / BRAM **8** / DSP **8** | — |

fmax 口径：`sys_clk_70 @14.286 ns`，WNS **+0.854 ns**，`1000/(14.286 − 0.854) = 74.4 MHz`。

> ⚠ **fmax 从文档的 69.8 变成 74.4，是口径更正而不是本轮提升**：旧值走的是
> `1000/(20 − WNS)`（MMCM 之前的 50 MHz 约束），对基线的真实差距是 **−5.1%**，
> 不是文档原先写的 −11.0%。详见 `CODE-REVIEW-PLAN.md` M-01/X-01。

### 上板实测（ILA over JTAG，全自动闭环）

| 项 | 值 |
|---|---|
| `ila_ctrl` | `0xC2` → locked=1 done=1 pass=1 fail=0 **illegal=0** |
| `score_result` | `0xC9DADA56`（bit31=1 → **结果有效：CRC 匹配 且 时长 ≥ 10 s**） |
| tick | **1,239,079,510**（3000 迭代 @70 MHz，**17.70 s**） |
| 硬件 CoreMark/MHz | **2.4212**（仿真 2.4209，差 0.01%） |
| tick 与预期偏差 | **0.002%**（门限 0.5%） |
| 程序状态 | `dbg_pc` 稳定在 `0x80001C50`、停在结尾 `j .` → 确认跑完 |
| 判据 | `locked done pass crc secs>=10` 全 1，`fail illegal` 为 0 → **上板验证 PASS** |

---

## 2. 修了什么

### 2.1 架构级正确性（RTL）

| ID | 缺陷 | 症状 / 证据 |
|---|---|---|
| **R-01** | **中断可在流水线气泡上被接受 → `mepc = 0`**。`irq_take` 没有"EX 段指令有效"判据，而 `id_ex_reg` 在 flush/bubble 时把 `pc` 清 0 | 修前 `verify --only tb_soc_timer_irq` → `FAIL: test group 98 failed (tohost=99)`（handler 里 `mepc==0` 断言命中）；修后 PASS。`+irq_trace`：c=2505（EX=气泡）`irq_take` 由 1→0，c=2506 取得 `mepc=0x80000100` |
| **R48** | **陷阱只冲了 ID/EX，`ex_mem_reg` 没有 flush 口 ⇒ EX 里被抢占的指令照样提交，MRET 后再执行一次 = 中断"双执行"** | 逐拍 trace：`c=2509 s5=12345678`（提交）→ `c=2546 mret 回 mepc` → `c=2550 s5=2468acf0`（=2×）。`add` 变 2 倍、`sw` 写两次（MMIO 上 UART 发两次）。ecall/非法指令看不出来（`control_unit` 早把它们中性化），旧等待循环是 `li+bne`（幂等）⇒ 潜伏至今 |
| **R-02** | `mtval` 恒 0，与 `csr_file.sv` 头注释承诺不符 | 修前定向程序 `0x0000007F` → `tohost=103`（mcause/mepc 对、mtval=0）；修后 PASS，mtval=`0x7F` |
| **W-04 / R49** | **LR.W 把读到的字清零**（LSU 的写相派生信号 `amo_wr = amo_active & amo_phase` 与算子无关）；SC.W 写 0 且 rd 取旧内存值 | 定向探针位集合 `0x3E`（bit1=LR 改了内存，bit2–5=SC 全错）；修后 PASS。按规范实现为 **LR 只读 + SC 恒失败（rd=1，不写内存）** —— 规范允许 SC 恒失败，不是"未实现" |

两处修复都配了**机器化判据**：`core.sv` 新增 `` `ifndef SYNTHESIS `` 断言
`trap_enter && !id_ex_valid → $error`（不依赖测试里的 DELTA 标定值）；
`timer_irq.S` 新增测试 7/8，`amo.S` 新增第 12/13/14 组。

### 2.2 "结论不可信"（度量链）

| ID | 缺陷 | 修后行为 |
|---|---|---|
| **M-01/X-01** | `parse_reports()` 把 `sys_clk` 行的**脉宽余量 WPWS=7.000** 当成 WNS，再按硬编码 20 ns 换算 → 报 **76.92 MHz**（真值 74.64）。且 2026-10-09 起 30+ 次综合的 fmax **恒为 76.92** ⇒ 指标对 RTL 时序变化**零敏感** | 改为从**最差 setup 路径块**取 `(Slack, Requirement, Path Group)`，`fmax = 1000/(T − WNS)`，并把时钟名/周期/推导式一起打印。复算历史报告：74.45 / **69.81** / **76.00** / 74.99 —— 与 `coremark.csv` 历史行逐行吻合 |
| **M-02** | 缓存 skip 只比 fingerprint、**不看上次 status**，且汇总里 SKIP 不计入 bad ⇒ 第一次 FAIL(exit 1) → 第二次无改动重跑 → **SKIP + exit 0**（失败被洗成通过） | 仅 `status=="PASS"` 才 skip；缓存的 FAIL 强制重跑；清理矩阵外孤儿条目（实测有 `tb_core_timer_irq:FAIL` 孤儿）；全量 SKIP 时打印警告并新增 `--require-run`（返回非零） |
| **X-02** | `hw` 新鲜度只看 mtime，而 `results/ila_done.csv` **被 git 跟踪**（含一份完整 PASS 采集）⇒ 一次 `git checkout` 就把 mtime 刷成"现在"，**没有板子也打印"上板验证 PASS"**（R20 要防的事，触发条件却变成日常 git 操作） | 要求同一次采集写出的 `results/ila_done.capture.json`（被 `.gitignore` 忽略）且 `csv_sha256` 与 CSV 逐字节一致；缺失即拒绝（旁路需显式 `--allow-unwitnessed` 且结论降级 UNVERIFIED）。实测：伪造清单→PASS，篡改 CSV→BLOCK+exit 1。`check` 的 `[HIL]` 同源改造，**不再输出假新鲜度** |
| **X-03** | `latest_ticks()` 读"碰巧存在的那份日志"，与当前代码无绑定（R42.1 已出过一次事故） | `verify` 为每个测试写 `.fpga-cache/logs/<name>.meta.json`（含内容指纹），`latest_ticks` 重算核对，不一致则拒绝并回退 CSV + 告警 |
| **X-04** | `append_csv` 的 `status` 硬编码 `"keep"` ⇒ 工具**永远无法记录一个被否决的实验**（22 行 `rejected` 全是人工编辑）；CSV 内层引号未转义 | 新增 `--status {keep,rejected,measure}`（默认 `measure`）；`verdict()` 不再"失败开放"（可比指标 <2 项 → UNKNOWN），`cmd_report` 明确"锚点是谁" |
| **X-05** | `path_hotspot.py` 取第一个 `Period(ns):`（= `sys_clk` 脉宽块 20.000）→ 报 **52.32 MHz** | 改用最差 setup 路径自带的 `Requirement` → 74.45 / 69.81 |
| **X-07** | `check` 用 mtime 判 RTL 新鲜度（哈希其实已存在 JSON 里），`git checkout` 可把"内容已变"误判成"新鲜" | 改为比**内容哈希**，mtime 只兜底 |
| **M-03** | `hw` 的 `--iterations/--clk-hz` 默认值仍是 1200/50e6 ⇒ 不带参数跑报 CoreMark/MHz **0.9684**（真值 2.4211，少报 2.5 倍）且仍打印 PASS | 默认改为 None：命令行 > 采集清单 > 构建清单；三处都没有则拒绝给结论（BLOCK） |
| **M-06** | 本机无 verilator/slang/svlint；ModelSim 对全核只报 3 条无关警告。**Vivado 报的警告才是本工程的真 lint**，而从来没人看 | 新增 `check [7] 综合警告门`：警告归一化（去行号/路径/位下标）后与基线比，**新增即 FAIL**；首个基线 48 类/274 条。并把 R43 的判据机器化：`[Timing 38-1] ... without a feedback net` **出现即 FAIL** |

### 2.3 "回归绿灯是假的"（软件/验证层）

| ID | 缺陷 | 修后行为 |
|---|---|---|
| **W-01** | `tb_sw.sv` 无条件打印 `RESULT : PASS`，**从不检查程序算出的结果** ⇒ 11 项里 3 项（含 CoreMark 与 GEMM）在结果错时仍是绿灯 | 三个程序把结论编码进 `tohost`（失败=2 并自旋）；**TB 判定逻辑一行未改**（它本来就会把 `tohost∉{0,1}` 判 FAIL）。注入自测：nn_demo 期望值改错 → `FAIL tohost=0x2`；CoreMark CRC 注入 → `run_coremark.py` exit 1 |
| **W-02** | `CLOCKS_PER_SEC` 停在 50 MHz 而硬件跑 70 MHz ⇒ 时长/速率/以及"必须 ≥10 s"判定偏差 **1.4×** | `HW_CLK_HZ` 单开关（上板/评分构建打开：CLOCKS_PER_SEC=真实频率 + ≥10 s 自证，并把 `secs>=10` 并进 `MMIO_RESULT` bit31）；构建频率从 `top_a100t.sv` 的 `.CLK_HZ()` 读（单一来源） |
| **W-03** | 取指对齐自检只打印不判失败（"IMEM 寄存读"那次改动的唯一安全网形同虚设） | 加 `$fatal` |
| **W-05/W-06** | `sim/run.bat|sh` 只跑 2/11 却打印 `ALL TESTS PASSED`；且守卫判"存在"不判"新鲜"，汇编失败会静默测旧 hex | 重写：先 `build_sw.py --all`（先删旧镜像、失败非零退出）再转调 `verify`；`run.bat` 保持纯 ASCII |
| **W-07** | 全新克隆**无法复现 PASS 11**（`.hex` 被 ignore，且 cm_rv32im/nn_demo/hello 三个镜像没有任何构建命令） | `python tools/build_sw.py --all` 一条命令建全部 11 个镜像（`--with-hw` 再加上板镜像；nn_demo 钉死 `-O0`，因 GCC15 在 -Os/-O2 下编错 gemm_sw） |
| **W-09** | `tb_units` 的 26 条 AMO 译码 `chk()` 在 `` `ifdef A_EN `` 内而矩阵 defines 为空 ⇒ **死代码**（实测检查点 243→268，delta=25） | 矩阵补 `"defines": ("A_EN",)`；desc 里写死的 "194" 改成运行时口径 |
| **W-10** | CoreMark 的 CRC 失败打的是 `ERROR! list crc`，既非 `** Error` 也非 `Fatal` ⇒ **绿灯通过** | `verify` 判据扩展 `ERROR!`/`Errors detected`/`Cannot validate operation`；`run_coremark.py` 失败判据前移且不写 CSV |
| **W-11** | `+max_cycles=` 被 `tb_core`/`tb_soc` 静默忽略 ⇒ 矩阵传的 200000/400000 是**死配置** | 两个 TB 都 `$value$plusargs`；日志实测首次生效 |

### 2.4 构建 / 上板流程 / 仓库

| ID | 内容 |
|---|---|
| **X-06** | 构建链**没有时序收敛门**：`build.tcl` 只生成报告、从不检查，时序违约也照样写 bitstream 并被记成 `keep`。现在断言时序，违约 `BUILD_TIMING=FAIL` + **不写 bitstream**；harness 当致命错误 |
| **X-09** | 抓取窗口/预期 tick/时钟是**三处手工同步的魔数**。现在由 `sim/prog/<prog>.build.json` 单一承载，四个消费方都从它读；缺失时显式打 `*_JSON=absent` + 回退告警，**不静默** |
| **X-10** | R33 的"删 `ila_proj*` 才能重建"仍是人工步骤；R41 的哈希守卫未实现。现在 `build_ila.tcl` 自动清 5 个目录（实测 `ILA_PURGE×5`）并打印 `ILA_RTL_SHA`（与 `sha256_tree()` **逐字节一致**，两个独立实现互证）；ILA 版同样有时序门，违约时删 bit/ltx |
| **E-01** | 仓库跟踪 **60.9 MB 二进制**（而全部源码只有 3.2 MB）。出库 14 条共 **62.66 MiB** ⇒ 跟踪体积 **64.1 MB → 1.6 MB**；`.gitignore` 原本**不是合法 UTF-8**（第 83 行是 GBK），已修 |
| **E-02** | `build.tcl`/`build_ila.tcl` 等 6 个脚本硬编码 `D:/USER/Desktop/FPGA/FPGA` ⇒ 换机器即失败。改为由 `[info script]` 派生 `$root`；`build.tcl` 顺带转纯 ASCII（原 1736 个非 ASCII 字节，R21 地雷） |
| **E-03** | 交付版 LSU 的唯一等价性论证（675 万组穷举）活在**仓库之外、未被跟踪、无人运行**。已入库为 `tools/check_equiv.py` 并**接入 `verify` 作为前置检查**（失败即中止回归） |
| **D-01~D-13** | 文档口径全面换代（见 §1）+ 入口修正（`sim\run.bat` 依赖不存在的 iverilog）+ `code-map` 行号钉死 + QSPI Flash 章节 + 7 项 `check` 登记 |

---

## 3. 本轮**新增**发现（审查计划之外）

| ID | 内容 |
|---|---|
| **R48** | 陷阱未冲 EX/MEM ⇒ 中断双执行（见 §2.1）—— 是修完 R-01 之后**第二个更深**的缺陷 |
| **R49** | 多周期状态机的写相派生信号与算子无关 ⇒ LR.W 清零目标字（见 §2.1） |
| **X-08 被门直接命中** | 新加的 `check [7]` 首个基线里就有 `[Synth 8-3331] design mmio_subsys has unconnected port wstrb[3..0]` —— 端口声明了却没人读，**Vivado 报了 4 次从来没人看**。这正是 MMIO 写忽略 `wstrb` 的同一处 |
| **镜像布局 → ticks 漂 2 拍** | `tb_sw_coremark` 的 ticks 一度从 413070 变 413072。用 4 组对照实验 + `nm` 符号比对隔离到 **W-02 在 `stop_time()` 仿真路径加的一句 `ee_printf`**（`iterate/core_bench_*` 逐符号地址一致，只有 `core_portme.o` +0x1C、rodata +0x40）⇒ **本核 BTB 按 PC 索引，镜像布局一变测量区间就可能差 2 拍**。已删除那句，回到 413070 |
| **`RB36 async control check` × 36** | `u_core/u_dmem/mem_reg_0 has an input control pin ...`（BRAM 异步控制引脚）—— 已进警告门基线，**待评估，非本轮范围** |
| **`muldiv` 死寄存器 × 93** | `[Synth 8-3332] Sequential element (prod_ss_reg[*]/prod_uu_reg[*]) is unused and will be removed` —— 功能已验证，低优先 |

---

## 4. 代价与取舍（如实记录）

修 R-01 / R48 / R-02 合计 **+69 LUT / +17 FF / fmax −0.25%**，于是
`CoreMark/LUTs` 从 9.077e-4 降到 **8.848e-4（−2.5%）**。

**这是自觉取舍，不是测量误差**：中断/异常路径对评分三项**零贡献**，
但 R-01/R48 是两处架构级正确性缺陷（丢指令 / 双执行），R-02 是文档承诺与实现不符。
若要换回分数，可单独 `git revert` 对应 commit（`4186f13` 的 RTL + `d48945c` 的用例）。

另：**W-04 的 SC.W 实现为"恒失败"**（rd=1、不写内存）。这是规范**允许**的行为
（无 forward-progress 要求，单核无 cache 不需要预约寄存器），所以 README 写的是
"9 个 AMO + LR.W 完整；SC.W 按规范允许恒失败"，**不是**"SC 成功路径已打通"。

---

## 5. 遗留（未做，原因明确）

1. **X-08 本身未修**：警告门只是**发现了**它。MMIO 写忽略 `wstrb` 是真 bug（`sb`/`sh` 会写满 32 位），
   但当前软件只用字写，属潜伏项 —— 归入下一轮（`CODE-REVIEW-PLAN` R-03/R-04/P2 一并做）。
2. **`results/coremark.csv` 的历史 fmax 列混两种口径**：只做了标注 + 追加新行，
   **未逐行重算**（只有部分历史构建还留着 `timing.rpt`，硬算会引入不可复核数字）。
3. **`fpga/build_ila.bat` / `ila_cap_mark.bat` / `ila_info.bat` / `jtag_probe.bat` 与 3 个
   `flash_*.ps1` 仍硬编码绝对路径**：flash 脚本会写 QSPI，`CFG_PROGRAM/VERIFY` 配错会
   "打印成功却什么都没写"（R44/R45），且与紫光同创迁移无关 ⇒ **在有充分验证手段前不动硬件路径逻辑**。
4. **`trap_tval` 只覆盖非法指令**：访问错误异常（ACCESS_FAULT）尚未实现（`CODE-REVIEW-PLAN` R-03）。
5. **P2/P3 项未做**：`asm.py` 越界诊断、`hazard_unit`/`load_store_unit`/`csr_file` 独立单元测试、
   X 传播断言、`RB36 async` 警告评估、关键路径结构性优化（P-01）等。

---

## 6. 复现命令

```powershell
cd D:\USER\Desktop\FPGA\FPGA

# 全量回归 (默认配置 / A_EN) —— 期望各 PASS 11
python tools\fpga_workflow.py verify --force
python tools\fpga_workflow.py verify --a-ext --force
# 前置: LSU 字节通道等价性 (675 万组穷举) 会打印 CHECK_EQUIV=PASS

# 一致性检查 (7 项, 含综合警告门) —— 期望 exit 0 / 0 FAIL
python tools\fpga_workflow.py check

# 四项指标 (含 fmax 的完整推导)
python tools\fpga_workflow.py metrics

# 综合 -> 指标 (真实 Vivado, 串行)
python tools\fpga_workflow.py synth --force

# 上板闭环 (串行; build_ila 约 10 min, capture 约 1 min)
cmd /c fpga\build_ila.bat
cmd /c fpga\ila_cap_done.bat
python tools\fpga_workflow.py hw          # 期望: 上板验证 PASS, exit 0
```

**量具自证**（证明"量具本身没坏"）：
```powershell
# 用修好的解析器复算历史归档 -> 74.45 / 69.81 / 76.00 (与 coremark.csv 历史行吻合)
python tools\path_hotspot.py fpga\timing.rpt

# 缓存不再把 FAIL 洗成 SKIP: 篡改 verify-state.json 的 status=FAIL 后重跑, 会强制重跑而非 SKIP
# 全量缓存命中时 --require-run 返回 1, 不加开关返回 0 (向后兼容)
python tools\fpga_workflow.py verify --require-run
```
