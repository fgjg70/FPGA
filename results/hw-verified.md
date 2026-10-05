# 上板实测验证

> **两次上板记录**。下面第 1 节是**最新一次**（含 P1+P2+P3 全部 RTL 改动）；
> 末尾附第一次（P1 之前）的记录作为历史对照。

---

## 0. 最新一次上板 — 2026-10-05 16:43 ✅（含 P1 异常/中断 + P2 定时器 + P3 三项时序优化）

**触发原因**：P1（CSR/异常接线）、P2（定时器中断）、P3（三项时序优化）之后，
RTL 与上一次上板相比已大改，必须重新验证 —— ILA 版 bitstream 尤其容易与 RTL 脱节
（那是**静默失败**：抓到的是旧设计的信号，不报任何错）。

**核对与重建**（照 `HANDOFF-HW-LOOP.md` §3）：

```
ILA bit 原为 14:19，而 rv32_pkg.sv/core.sv/csr_file.sv/imem.sv/hazard_unit.sv/
top_a100t.sv/mmio_subsys.sv/build_ila.tcl 均在其后改动 -> STALE，必须重建
cmd /c fpga\build_ila.bat        -> 5.4 分钟, 新 bit + ltx @16:41
fpga/timing_ila.rpt              -> "All user specified timing constraints are met"
```

**读回结果**（`cmd /c fpga\ila_cap_done.bat`，2048 拍，16 s 后 arm）：

| 项 | 实测值 | 判定 |
|---|---|---|
| **运行时长** | **10.16 s** | ✅ 满足赛题 >=10 秒 |
| **CRC 判定位 (bit31)** | **1** | ✅ 三个数据类 CRC 全部匹配官方值 |
| **tick 数** | **508,155,404** | 与 P1 之前**逐位相同**，预期 508,232,400，偏差 **0.015%** |
| **CoreMark/MHz** | **2.3615** | 仿真 2.3611，吻合 **0.02%** |
| done / pass / fail / illegal | 1 / 1 / 0 / 0 | ✅ `ila_ctrl = 0x42` |
| ILA 版资源 | LUT 5434 / FF 3929 | 含 ILA + debug hub（评分版核身 LUT 2526）|

> **tick 与 P1 之前逐位相同**是关键证据：P1/P2/P3 三项改动都**不改变指令数与周期数**
> （P3 是纯时序优化，P1/P2 的陷阱逻辑不在热路径上）。硬件上逐位复现，说明
> **仿真与硬件在三次结构性改动后仍然一致** —— 这比"数值接近"强得多。

**流水线波形**（`cmd /c fpga\ila_cap_mark.bat` -> `results/ila_pipeline.csv`，2048 拍）：

| 观测量 | 本次实测 | 仿真对照 |
|---|---|---|
| 流水线停顿 (stall) | **237 / 2048 = 11.57%** | 仿真 9.6%（load-use 6.5% + muldiv 3.1%）|
| 分支预测错误 (redirect) | **14 / 2048 = 0.68%** | 仿真均值 4.9% |
| PC 热点 | `0x80001218 ~ 0x80001248` | CoreMark 热点循环 |
| 指令样例 | `0x00F383B3`(add) / `0x00089303`(lb) / `0x4027D313`(srai) | — |

> stall 11.57% vs 仿真 9.6% 量级一致；redirect 偏低是因为这 2048 拍**恰好落在一个
> 分支预测很准的紧凑循环里**（仿真值 4.9% 是全程序平均）——**不是矛盾，是采样窗口不同**。
> 这正说明"用 2048 拍窗口估全局占比"要谨慎。

**工具**：本次起 `hw` 子命令可直接解析并记账，不必手写脚本：

```bat
python tools\fpga_workflow.py hw --iterations 1200 --expect-tick 508232400 --tag <标签> --record
```

**踩到的两个坑（已修）**：
- `write_hw_ila_data` 在 `results/*.csv` 已存在时**必须加 `-force`**，否则报
  `Labtoolstcl 44-54`，而抓取本身是成功的 —— 表现为"CAPTURE 都 OK 了却没结果文件"。
  `ila_cap_done.tcl` / `ila_cap_mark.tcl` 已补 `-force`。
- `get_property REGISTER.IDCODE` 不是合法属性（报 44-56），要用 `IDCODE`。
  实测 IDCODE = `00010011011000110001000010010011` = **0x13631093** ✅ 与文档一致。

---

## 1. 第一次上板 — 2026-10-05（P1 之前）

## 结论: 硬件闭环完成, 赛题硬性要求全部满足

在**正点原子 达芬奇Pro (XC7A100T-FGG484-2, 50 MHz)** 上真实运行 CoreMark v1.0
**1200 次迭代 / 10.16 秒**, 并通过 ILA over JTAG 一次读回**打包判定**:

| 项 | 实测值 | 判定 |
|---|---|---|
| **运行时长** | **10.16 s** | ✅ 满足赛题 >=10 秒 |
| **CRC 判定位 (bit31)** | **1** | ✅ 三个数据类 CRC 全部匹配 CoreMark 官方值 |
| **tick 数** | **508,155,404** | 预期 508,232,400, 偏差 **0.015%** |
| **CoreMark/MHz** | **2.3615** | 仿真值 2.3611, 吻合到 **0.02%** |
| done / pass / fail / illegal | 1 / 1 / 0 / 0 | ✅ 正常结束, 无非法指令 |
| ILA 版时序 | WNS = 4.587 ns @20ns | ✅ 50 MHz 余量充足 |
| ILA 版资源 | LUT 5063 / FF 3677 / BRAM 10 | (含 ILA; 评分版 LUT 2481 / BRAM 4) |

## 怎么做到无人值守读回

本板串口收不到数据 (FT2232H 只有 D2XX 驱动, 无 COM 口), 所以走 MMIO 上报 + ILA over JTAG:

```
软件 --(MMIO)--> 硬件 --(ILA)--> JTAG --> PC
  MMIO_MARK   (0xA0000020) W: 单拍脉冲, 做触发点
  MMIO_RESULT (0xA0000024) W/R: 写锁存结果并置 done
```

**一个 32 位寄存器打包两件事** (上板只能回读一个数):
```
bit31   = 1 表示 crclist / crcmatrix / crcstate 全部等于官方参考值
bit30:0 = 实测 tick 数
```

**为什么用这三个 CRC 做判据**: 它们与迭代次数**无关** (实测 ITERATIONS=1 与 3 完全一致),
只有跨迭代累积的 crcfinal 会变。所以 10 秒要求改了迭代次数后, 判据依然成立。

## 流水线效率波形 (分析报告用)

results/ila_pipeline.csv — 在**测量区间内部** (程序启动 3 秒后) 抓取的 **2048 拍**:

| 观测量 | 窗口内统计 |
|---|---|
| 流水线停顿 (stall) | **181 / 2048 = 8.8%** |
| 分支预测错误 (redirect) | **22 / 2048 = 1.07%** |
| PC 活动范围 | 0x80000116c ~ 0x8000011a8 —— 稳定的 CoreMark 热点循环 |
| 指令样例 | 0x028282b3 = mul t0,t0,s0 (M 扩展) / 0xffd510e3 = 条件分支 |

探针: dbg_pc[31:0] / dbg_instr[31:0] / ila_ctrl[7:0] / score_result[31:0]

## 三项评分指标 (最终)

| 指标 | 基线 | 当前 | 相对基线 |
|---|---|---|---|
| **CoreMark/MHz** | 0.8263 | **2.3615 (硬件实测)** | **+186%** |
| **最高时钟频率** | 78.4 MHz | 74.6 MHz | -4.8% |
| **CoreMark/LUTs** | 2.361e-4 | **9.518e-4** | **+303%** |

## ILA 抓取踩的四个坑

1. **.tcl 用 7 位掩码编码写会毁掉中文注释** —— 非 ASCII 字节被掩码成控制字符, 其中一些
   正好是 0x0A, **把注释行劈成代码行**, 报 invalid command name。
   **Vivado 的 Tcl 一律纯 ASCII** (与 .bat 同规则, 但成因不同: 这是编码掩码, 那是代码页)。
2. **ILA 探针名是连接的网络名, 不是 probe0/probe1/...** —— 实际是
   dbg_pc / dbg_instr / ila_ctrl / score_result。先用 get_hw_probes 列出来。
3. **TRIGGER_COMPARE_VALUE 需要比较前缀且位宽必须匹配**:
   eq8'h40 可以; 8'h40 / 01000000 / eq16'h0040 都不行。默认值 eq8'hXX 就是提示。
4. **精确匹配触发很脆弱**: eq8'h40 要求 done=1 且其余 7 位全 0, 但程序结束时会同时
   置 pass (ila_ctrl = 0x42), 永远不匹配。**改用探针默认的 eq8'hXX (无条件触发)**:
   等程序跑完再 arm, 直接抓最终状态。
