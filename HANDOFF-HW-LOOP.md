# 上板闭环测试 — 你能自己做，不需要人

> 这是 `HANDOFF.md` 的**补充文档**，专讲一件事：**硬件闭环测试是全自动的**。
> `HANDOFF.md` 旧版把上板复验写成了「待用户操作」—— **那是错的**（该表述已更正；
> `HANDOFF.md` 里现在只剩"物理插拔 USB/JTAG 线"和"断电上电看 DONE 灯"两处真的需要人）。
> 你可以在真实板卡上完成「改 RTL → 综合 → 烧录 → 运行 → 读回结果」的全过程，
> **不需要用户看一眼 LED、也不需要串口**。本文给出可直接复制运行的命令。
>
> **口径**：本文说的"上板验证"= JTAG 烧录 + ILA 读回，凭据是 `results/ila_done.csv`
> 与 `fpga/cap_done.log`（`CAPTURE_OK`）。**最后一次成功采集 = 2026-10-09 21:29:30**；
> 此后 `load_store_unit.sv` + `fpga/build.tcl`（`d6b48fe`，2026-10-11 00:50）**尚未上板**，
> 本次审查对 `core.sv`/`id_ex_reg.sv`/`csr_file.sv` 的改动**也未上板**。
> **本文里的任何时间/tick 数字都会过时 —— 一律现查，不要照抄**（R20/R28）；
> "哪些未上板"用 `python tools\fpga_workflow.py hw --stale` 查，不要读静态清单。

---

## 0. 为什么这事儿容易被漏掉

板子上的 `led[1] = PASS` 是给**人**看的。上一轮的 AI 看到「PASS 灯」就以为验证必须由人完成，
于是把上板验证标成了「待用户操作」。

**实际上**：板上有 ILA 调试核，JTAG 线一直插着，Vivado 有 `hw_server`。
你可以用 Tcl 脚本让 Vivado **自己烧录、自己等程序跑完、自己把内部信号抓下来、自己写成 CSV**。
整个过程在一条 `cmd /c xxx.bat` 里完成，退出码和 CSV 文件就是判据。

**已在真实板卡上跑通并留下证据。当前（2026-10-11 11:19:07 采集）**：

```
ila_ctrl     = 0xC2  ->  mmcm_locked=1  done=1  pass=1  fail=0  illegal=0
score_result = 0xC9DADA56
  bit31 = 1  ->  crclist/crcmatrix/crcstate 全部匹配 CoreMark 官方参考值
  tick  =  1,239,079,510   (预期 1,239,100,117 -> 偏差 0.002%)
  时长  =  17.70 s         (满足赛题 >=10 秒硬性要求, 3000 迭代 @70 MHz)
  CoreMark/MHz = 2.4212    (仿真 2.4209)
```

> 判据 = **采集清单 `results/ila_done.capture.json`**（`captured_at_local` / `csv_sha256` /
> `rtl_sha256` + 22 个 RTL 文件哈希 / `iterations=3000` / `expect_tick`）+ `fpga/cap_done.log` 的 `CAPTURE_OK`。
> ⚠️ **`results/ila_done.csv` 的 mtime 不是证据**（X-02：git 操作会刷新它而不产生新采集）。
> `ila_ctrl` 的位定义：bit7=`mmcm_locked` / bit6=`done` / bit5=`mark` / bit4=redirect / bit3=stall /
> bit2=`illegal` / bit1=`pass` / bit0=`fail`。
> 历史各次采集（`0x42` / tick 536,943,384 / 10.74 s 等）见 `results/hw-verified.md` 与第 7 节快照。

---

## 1. 三条通道的可用性（实测结论）

| 通道 | 状态 | 用途 | 怎么用 |
|---|---|---|---|
| **JTAG 烧录** | ✅ 可用 | 把 bitstream 下载进 FPGA | `program_hw_devices` |
| **JTAG 读回 (ILA)** | ✅ 可用 | 抓内部任意信号 / 读回软件上报的结果 | `run_hw_ila` + `upload_hw_ila_data` |
| 串口 (UART) | ❌ **不可用** | — | FT2232H 只有 D2XX 驱动、**无 COM 口**；CH340 也不在 |

所以：**想从上板实验里拿到结果，只能走 ILA**。这不是限制，只是换条路。

板卡身份（已验证）：
```
IDCODE 0x13631093, part xc7a100tfgg484-2
电缆: localhost:3121/xilinx_tcf/Digilent/210512180081  (FT2232H, 被 Digilent EEPROM 编程过)
```

---

## 2. 一条命令跑完上板验证

### 2.1 读回结果（最常用）

```bat
cmd /c D:\USER\Desktop\FPGA\FPGA\fpga\ila_cap_done.bat
```

它做四件事：**烧录 → 等待 CoreMark 跑完 → 抓 2048 拍 → 写 `results/ila_done.csv`**。

> **脚本内容不再抄在这里 —— 以 `fpga/ila_cap_done.tcl` 为准**。本文旧版抄过一份，
> 已经与脚本脱节并会误导：
> - 旧抄本写 `after 16000`，脚本**现在不是**这个值（迭代数与等待时间都变过）；
> - 旧抄本漏了 `write_hw_ila_data -force` —— 目标 CSV 已存在时**必须**加，否则
>   `Labtoolstcl 44-54` 报错（`HANDOFF.md` P4 节要点 2）；
> - 旧抄本把 `puts "CAPTURE_OK"` 写成无条件打印，而脚本现在会先校验 **CSV 的 mtime**
>   （打印 `CSV_MTIME=... AGE_SEC=...`，超过 120 s 直接 `error CAPTURE_STALE`）——
>   这正是 R20「验证工具可能制造虚假证据」的防线，**别把它删掉**；
> - 脚本还带 `-force` + 失败即 `error`，所以**判据是 `CAPTURE_OK` 出现且 `AGE_SEC` 很小**，
>   不是"命令没报错"。

**关于脚本里的等待时间/迭代数**：那是与本次 bitstream 里嵌的镜像绑定的魔数，
改性能后必须同步（R35）；三者必须一致：**镜像的 ITERATIONS ↔ 脚本的 `after` ↔
解析时的 `--iterations`**。脚本头部注释写明了它对应的值与预期时长，**改之前先读它**。

### 2.2 用 Python 解析读回的结果

> ⚠️ 这段手写解析只为说明格式；**正式判读请用 `python tools\fpga_workflow.py hw`** ——
> 它按 `命令行 > results/ila_done.capture.json > sim/prog/cm_hw.build.json` 推断
> `iterations` / `clk_hz`（当前 **3000 / 70e6**）并打印来源，三处都没有就拒绝给结论。
> **别在文档/脚本里硬编码迭代数**（M-03 那类静默错误：数字看起来很正常但全错）。

```python
import re
lines = open(r'D:\USER\Desktop\FPGA\FPGA\results\ila_done.csv').read().splitlines()
hdr = [h.strip().strip('"') for h in lines[0].split(',')]
iC = next(i for i,h in enumerate(hdr) if 'ila_ctrl'     in h)
iR = next(i for i,h in enumerate(hdr) if 'score_result' in h)
def px(s): return int(s.strip().strip('"').replace('0x',''), 16)
c = lines[1].split(',')
ctrl, res = px(c[iC]), px(c[iR])
print('mmcm_locked=%d done=%d pass=%d fail=%d illegal=%d'
      % ((ctrl>>7)&1,(ctrl>>6)&1,(ctrl>>1)&1,ctrl&1,(ctrl>>2)&1))
print('CRC 判定 =', (res>>31)&1, ' tick =', res & 0x7fffffff)
# CoreMark/MHz = ITERATIONS * CLK_HZ / tick   <-- 两个数都要用本次真实值, 不要写死
```

### 2.3 抓流水线波形（分析报告用）

```bat
cmd /c D:\USER\Desktop\FPGA\FPGA\fpga\ila_cap_mark.bat
```

`ila_cap_mark.tcl` 会**烧录后只等 3 秒就抓**（此时 CoreMark 正在测量区间内），
得到 2048 拍的真实执行窗口 → `results/ila_pipeline.csv`。
上一轮抓到的是：stall 8.8%、redirect 1.07%、PC 稳定在 `0x8000011xx` 热点循环。

---

## 3. ⚠️ 关键：ILA 版 bitstream 必须与当前 RTL 同步

**这是最容易踩的坑。** ILA 版 bitstream 是**独立于评分版**另一次构建的产物：

```
评分版:  fpga/cpu_a100t.bit                              (build.bat,   非工程模式, 快)
ILA 版:  fpga/ila_proj.runs/impl_1/top_a100t.bit         (build_ila.bat, 工程模式, 慢)
         fpga/ila_proj.runs/impl_1/top_a100t.ltx         (探针定义, 与 bit 配套)
```

**抓取脚本用的是 ILA 版**。如果 RTL 改过而没重建 ILA 版，你抓的是**旧设计的信号**，
而且不会报任何错 —— 又是一种静默失败。

**核对方法**（比 mtime）：
```python
import os
b = os.path.getmtime(r'D:\USER\Desktop\FPGA\FPGA\fpga\ila_proj.runs\impl_1\top_a100t.bit')
for f in ['core.sv','csr_file.sv','rv32_pkg.sv','fpga/top_a100t.sv','fpga/mmio_subsys.sv']:
    p = os.path.join(r'D:\USER\Desktop\FPGA\FPGA', f)
    print(('STALE ' if os.path.getmtime(p) > b else 'ok    '), f)
```

**重建：**
```bat
cmd /c D:\USER\Desktop\FPGA\FPGA\fpga\build_ila.bat
```
约 10 分钟（工程模式，含 ILA 的 IP 生成）。完成后看 `fpga/timing_ila.rpt`：
**所有时序约束必须满足（WNS ≥ 0）**，否则上板结果不可信。

> ⚠️ **别再按 `sys_clk` 这个时钟名去查** —— 引入 MMCM 之后核心跑在 MMCM 输出的
> **`sys_clk_70`** 域上，报告里 `sys_clk` 那一行**已经不再是设计主时钟**（它只剩脉宽余量），
> 照旧口径读会得出错误结论（这正是 M-01/X-01 那个 bug 的成因）。
> ✅ **现在不用手工判读了**：`build_ila.tcl` 已内建时序门（`br_timing_gate`），打印
> `ILA_TIMING_CONSTRAINTS_MET / ILA_TIMING_WNS / ILA_TIMING_WHS`，不满足则打印
> **`ILA_TIMING=FAIL`** 并 `error`（**同时删掉 ILA bitstream，防止误烧**）；
> 评分版 `build.tcl` 对应打印 **`BUILD_TIMING=PASS/FAIL`**，FAIL 时**拒绝写 bitstream**。
> **看这两个标记即可**（X-06/X-09 已落地）。

> 注意：`build_ila.bat` 用 `settings64.bat` + `-log cap_done.log` 的形式，
> 日志落在 `fpga/` 下，出错时先看它。

---

## 4. 完整闭环工作流（改 RTL → 上板验证）

```
1. 改 RTL (例如给 core.sv 加一个特性)
      |
2. python tools/fpga_workflow.py verify        <- ModelSim 增量回归, 期望 PASS
      |
3. cmd /c fpga\build_ila.bat                   <- 重建 ILA 版 (约 10 分钟)
      |  检查 fpga/timing_ila.rpt 的 WNS > 0
      |
4. cmd /c fpga\ila_cap_done.bat                <- 烧录 + 跑 + 读回 (约 2 分钟)
      |
5. 解析 results/ila_done.csv 得出结论
```

**第 3 步不能跳。** 只在改的是纯软件（`sw/` 下的 .c/.S）时例外 —— 但那样也必须
重新生成 `sim/prog/*.hex`，而 ILA 版 bitstream 里嵌的是**综合时**读入的镜像，
所以**软件一改，bitstream 一样要重建**。

---

## 5. 怎么给一个新测试加上闭环能力（可复用的模式）

现有闭环是为 CoreMark 搭的，但模式是通用的。三步：

### 第 1 步 · 软件侧：把结果写进 MMIO 上报寄存器

已有两个（`rv32_pkg.sv` 里的地址常量）：
```
MMIO_MARK   = 0xA0000020   W: 写任意值 -> 单拍脉冲 (可做 ILA 触发点)
MMIO_RESULT = 0xA0000024   W/R: 写锁存结果并置 done; 读回该值
```
在程序里：
```c
#define MMIO_RESULT (*(volatile unsigned int *)0xA0000024u)
MMIO_RESULT = 你的32位结果;      /* 顶层 score_result 探针就能看到 */
```
**一个 32 位寄存器可以打包多个结论**（CoreMark 就是这么做的）：
`bit31 = CRC 是否全对`，`bit30:0 = tick 数`。
要报更多就把新寄存器加进 `rv32_pkg.sv` + `fpga/mmio_subsys.sv`（照抄 `MMIO_RESULT` 的写法）。

### 第 2 步 · 硬件侧：把信号接到 ILA 探针

`fpga/top_a100t.sv` 里（被 `ifdef USE_ILA 包着）：
```systemverilog
`ifdef USE_ILA
  logic [7:0] ila_ctrl;
  assign ila_ctrl = {1'b0, score_done, score_mark, dbg_redirect, dbg_stall, dbg_illegal, pass_r, fail_r};
  ila_0 u_ila (
    .clk    (sys_clk),
    .probe0 (dbg_pc),        // 32
    .probe1 (dbg_instr),     // 32
    .probe2 (ila_ctrl),      //  8
    .probe3 (score_result)   // 32
  );
`endif
```
**探针的数量与宽度在 `fpga/build_ila.tcl` 里定义，改探针必须同步改那里：**
```tcl
create_ip -name ila -vendor xilinx.com -library ip -module_name ila_0
set_property -dict [list CONFIG.C_NUM_OF_PROBES {4} CONFIG.C_PROBE0_WIDTH {32} \
    CONFIG.C_PROBE1_WIDTH {32} CONFIG.C_PROBE2_WIDTH {8} CONFIG.C_PROBE3_WIDTH {32} \
    CONFIG.C_DATA_DEPTH {2048} CONFIG.C_INPUT_PIPE_STAGES {2}] [get_ips ila_0]
```
**探针的名字是连接的网络名**（`dbg_pc` / `ila_ctrl` / …），不是 `probe0..3`。
想知道确切的宽度和名字，不用猜：
```bat
cmd /c D:\USER\Desktop\FPGA\FPGA\fpga\ila_info.bat    REM 列出 ILA 与所有探针
```

### 第 3 步 · 抓取侧：复制一份 capture 脚本

复制 `fpga/ila_cap_done.tcl`，改三处：CSV 输出路径、等待时间、触发值。
再照抄 `ila_cap_done.bat` 做包装。

**触发值的注意事项**（踩过）：
- 不设触发值 = 探针默认 `eq8'hXX`（don't care）= **无条件触发**，arm 上就抓 —— 最简单可靠
- 想精确触发：格式必须是 `eq8'h40` 这种**带比较前缀**的，且位宽要匹配探针宽度
- **精确匹配很脆**：`eq8'h40` 要求 8 位全部相等；程序结束时 locked+pass 位都是 1（`0xC2`）就不会命中

---

## 6. 上板环节踩过的坑（完整版见 `skills/fpga-riscv-a100t/PITFALLS.md` 第四节）

| 症状 | 真因 | 修法 |
|---|---|---|
| `get_hw_probes probe2` 返回空 | ILA 探针名是**连接的网络名** | 用 `ila_info.tcl` 先列出来 |
| `Designutils 20-610 Invalid logic operator '8'` | `TRIGGER_COMPARE_VALUE` 需要比较前缀 | 写 `eq8'h40` |
| `Designutils 20-614 No apostrophe specified` | 裸二进制串不行 | 同样要 `eq` 前缀 |
| 触发值看着对却永不触发 | 精确匹配太脆弱 | 清空触发值用默认 `eq8'hXX` |
| Vivado Tcl 报 `invalid command name` | `.tcl` 里有中文，7 位掩码编码把注释行劈成了代码行 | **Vivado 的 Tcl 一律纯 ASCII** |
| IP 生成器 `::ipgen_iptclns` 初始化失败 | **两个 Vivado 实例重叠** | 构建必须串行（`fpga_workflow.py` 已加全局锁）|
| `create_project` 后找不到 runs 目录 | `create_project <dir>/<name>` 把最后一段当**工程名**，文件落在**父目录** | 按 `<dir>/<name>.runs/` 找 |

---

## 7. 当前硬件状态

> ⚠️ 下表是**快照**，且时间/mtime 类字段一定会过时 —— **别照抄，用工具查**：
> ```bat
> python tools\fpga_workflow.py hw --stale     REM ILA bit 与 RTL 的新鲜度
> python tools\fpga_workflow.py check          REM bitstream 是否比 RTL/镜像新
> ```
> （R20/R28：拿上一次的 CSV 当本次结论 = 虚假证据，所以新鲜度必须现查。）

| 项 | 状态（**2026-10-11 冻结版**）|
|---|---|
| 评分版时序 | fmax **74.4 MHz**（`sys_clk_70` @14.286 ns，WNS **+0.854**；`All user specified timing constraints are met.`）|
| 评分版资源 | LUT **2736** / FF **1251** / BRAM **8** / DSP **8** |
| `fpga/cpu_a100t.bit` / ILA 版里嵌的程序 | `cm_hw`（CoreMark **3000** 迭代，`cm_hw.build.json` 记 `expect_tick=1,239,100,117`）|
| **ILA 版 bitstream** | 改过 RTL 就必须按 §3 重建（约 5–6 分钟），否则抓到的是旧设计 |
| 最后一次采集 | **2026-10-11 11:19:07**，tick **1,239,079,510**、`ila_ctrl=0xC2`、硬件 CM/MHz **2.4212** |

> 现查用：`fpga/timing.rpt` + `fpga/util.rpt` + `results/coremark.csv` 行 `review-fixes-v1` +
> `results/ila_done.capture.json`。**fmax 必须带时钟名与周期**（纪律见 `HANDOFF.md` §8）。

> ℹ️ **等待时间/迭代数不再写死在 `.tcl` 里**（X-09 已落地）：`mk_cm_hw.py` 把
> `sim/prog/cm_hw.build.json`（`iterations` / `expect_tick` / `wait_seconds` / `clk_hz`）写出来，
> `ila_cap_done.tcl` 读它再跑（读不到才退回旧常量并显式打印 `CAPTURE_MANIFEST_FALLBACK=1`）。
> 抓完还会写 **`results/ila_done.capture.json`** 采集清单并自校验（CSV 哈希 / RTL 哈希 / 必填键），
> 失败直接 `error` —— **别手改 `.tcl` 里的等待时间，改 `mk_cm_hw.py` 的产物**。

**关于历史 LUT 数字对不上**：`results/coremark.csv` 里 `bram-v1` / `HARDWARE-VERIFIED`
两行写的 LUT=2481，用**后来**的代码复现不出来（当时是 3923）。原因不是测量错误，而是
**代码在那之后变了**：CSR 接线给 `ctrl_s` 加了 5 个字段（`sys_op`/`csr_addr`/`csr_cmd`/
`csr_src_imm`/`csr_uimm`），控制束变宽 → 流水线寄存器与布线都变多。
CSV 里那两行是**当时那版代码**的实测值，不该改；新代码的数字应当**追加新行**。
当前最新一行是 **`review-fixes-v1`**（413,070 / 2.4209 / LUT 2736 / FF 1251 / fmax 74.4，`keep`）——
即 2026-10-11 冻结版；引用 `fmax` 列时配 **`fmax_src`** 列读（该列混两种口径）。

---

## 8. 注意事项

1. **Vivado 必须串行** —— 两个实例重叠会让 IP 生成器初始化失败并谎报缺文件。
   手动跑 `build_ila.bat` 前先确认没有别的 Vivado 在跑（`tasklist | findstr vivado`）。
2. **ILA 只应该在调试版里** —— CPU 核本身零厂商原语，ILA 被 ``ifdef USE_ILA`` 隔绝在顶层。
   评分版（`build.bat`）不带 ILA，别把带 ILA 的 bitstream 拿去当交付物。
3. **等待时间来自构建清单，不是写死在脚本里** —— 每次性能提升后按 R35 重算 `ITERATIONS`
   （`python tools\mk_cm_hw.py` → 写 `sim/prog/cm_hw.build.json` 的
   `iterations`/`expect_tick`/`wait_seconds`/`clk_hz`），`ila_cap_done.tcl` 读它执行。
   等待时间必须 > 实际运行时长再留余量，否则会在 CoreMark 还没跑完时就抓，
   读到 `score_result = 0`（当前：3000 迭代 @70 MHz → 17.70 s，等 22 s）。
4. **上板结果要落盘** —— 抓完的 CSV 写进 `results/`，并在 `results/` 里留一份文字结论
   （照 `results/hw-verified.md` 的格式）。不落盘就等于没测。
