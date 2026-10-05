# 上板闭环测试 — 你能自己做，不需要人

> 这是 `HANDOFF.md` 的**补充文档**，专讲一件事：**硬件闭环测试是全自动的**。
> `HANDOFF.md` 的 P4 节把上板复验写成了「待用户操作」—— **那是错的**。
> 你可以在真实板卡上完成「改 RTL → 综合 → 烧录 → 运行 → 读回结果」的全过程，
> **不需要用户看一眼 LED、也不需要串口**。本文给出可直接复制运行的命令。

---

## 0. 为什么这事儿容易被漏掉

板子上的 `led[1] = PASS` 是给**人**看的。上一轮的 AI 看到「PASS 灯」就以为验证必须由人完成，
于是把上板验证标成了「待用户操作」。

**实际上**：板上有 ILA 调试核，JTAG 线一直插着，Vivado 有 `hw_server`。
你可以用 Tcl 脚本让 Vivado **自己烧录、自己等程序跑完、自己把内部信号抓下来、自己写成 CSV**。
整个过程在一条 `cmd /c xxx.bat` 里完成，退出码和 CSV 文件就是判据。

**已在真实板卡上跑通并留下证据**（`results/hw-verified.md`）：

```
ila_ctrl     = 0x42  ->  done=1  pass=1  fail=0  illegal=0
score_result = 0x9E49D60C
  bit31 = 1  ->  crclist/crcmatrix/crcstate 全部匹配 CoreMark 官方参考值
  tick  =  508,155,404   (预期 508,232,400, 偏差 0.015%)
  时长  =  10.16 s       (满足赛题 >=10 秒硬性要求)
```

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

它做四件事：**烧录 → 等 16 秒（让 CoreMark 跑完 10.16 秒）→ 抓 2048 拍 → 写 `results/ila_done.csv`**。

脚本内容（`fpga/ila_cap_done.tcl`，已可用）：

```tcl
open_hw
connect_hw_server
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
set_property PROGRAM.FILE {D:/USER/Desktop/FPGA/FPGA/fpga/ila_proj.runs/impl_1/top_a100t.bit} [current_hw_device]
set_property PROBES.FILE  {D:/USER/Desktop/FPGA/FPGA/fpga/ila_proj.runs/impl_1/top_a100t.ltx} [current_hw_device]
program_hw_devices [current_hw_device]
puts "PROGRAMMED"
current_hw_device [lindex [get_hw_devices] 0]
refresh_hw_device -update_hw_probes true [current_hw_device]
after 16000                     ;# CoreMark 1200 迭代 ≈ 10.16 s, 留余量
set ila [lindex [get_hw_ilas -of_objects [current_hw_device]] 0]
if {$ila eq ""} { error "NO_ILA_FOUND" }
reset_hw_ila $ila
set_property CONTROL.TRIGGER_POSITION 0 $ila
run_hw_ila $ila                 ;# 不设触发值 = 探针默认 eq8'hXX = 无条件触发
wait_on_hw_ila -timeout 60 $ila
upload_hw_ila_data $ila
write_hw_ila_data -csv_file {D:/USER/Desktop/FPGA/FPGA/results/ila_done.csv} hw_ila_data_1
puts "CAPTURE_OK"
```

### 2.2 用 Python 解析读回的结果

```python
import re
lines = open(r'D:\USER\Desktop\FPGA\FPGA\results\ila_done.csv').read().splitlines()
hdr = [h.strip().strip('"') for h in lines[0].split(',')]
iC = next(i for i,h in enumerate(hdr) if 'ila_ctrl'     in h)
iR = next(i for i,h in enumerate(hdr) if 'score_result' in h)
def px(s): return int(s.strip().strip('"').replace('0x',''), 16)
c = lines[1].split(',')
ctrl, res = px(c[iC]), px(c[iR])
print('done=%d pass=%d fail=%d illegal=%d' % ((ctrl>>6)&1,(ctrl>>1)&1,ctrl&1,(ctrl>>2)&1))
print('CRC 判定 =', (res>>31)&1, ' tick =', res & 0x7fffffff)
print('CoreMark/MHz =', 1200e6 / (res & 0x7fffffff))
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
**`sys_clk` 的 WNS 必须 > 0**（50 MHz 约束满足），否则上板结果不可信。

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
- **精确匹配很脆**：`eq8'h40` 要求 8 位全部相等；程序结束时 pass 位也是 1（`0x42`）就不会命中

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

## 7. 当前硬件状态（接手时的真实情况）

| 项 | 状态 |
|---|---|
| 评分版 bitstream `fpga/cpu_a100t.bit` | ✅ 新（07:02，含 csr_file 与参数化镜像）|
| 评分版时序 | WNS 3.710 ns → fmax **61.4 MHz**（50 MHz 约束满足）|
| 评分版资源 | LUT 3923 / FF 1333 / BRAM 4 / DSP 8 |
| **ILA 版 bitstream** | ⚠️ **旧**（06:19，早于 core.sv 的 CSR 接线）|
| `fpga/cpu_a100t.bit` 里嵌的程序 | `cm_hw`（CoreMark 1200 迭代）|

**关于 LUT 数字对不上**：`results/coremark.csv` 里 `bram-v1` / `HARDWARE-VERIFIED`
两行写的 LUT=2481，用车**当前**代码复现不出来（现在是 3923）。原因不是测量错误，而是
**代码在那之后变了**：CSR 接线给 `ctrl_s` 加了 5 个字段（`sys_op`/`csr_addr`/`csr_cmd`/
`csr_src_imm`/`csr_uimm`），控制束变宽 → 流水线寄存器与布线都变多。
CSV 里那两行是**当时那版代码**的实测值，不该改；新代码的数字应当**追加新行**。

---

## 8. 注意事项

1. **Vivado 必须串行** —— 两个实例重叠会让 IP 生成器初始化失败并谎报缺文件。
   手动跑 `build_ila.bat` 前先确认没有别的 Vivado 在跑（`tasklist | findstr vivado`）。
2. **ILA 只应该在调试版里** —— CPU 核本身零厂商原语，ILA 被 ``ifdef USE_ILA`` 隔绝在顶层。
   评分版（`build.bat`）不带 ILA，别把带 ILA 的 bitstream 拿去当交付物。
3. **`after 16000` 是给 ITERATIONS=1200 的** —— 换迭代次数要同步改等待时间，
   否则会在 CoreMark 还没跑完时就抓，读到 `score_result = 0`。
4. **上板结果要落盘** —— 抓完的 CSV 写进 `results/`，并在 `results/` 里留一份文字结论
   （照 `results/hw-verified.md` 的格式）。不落盘就等于没测。
