---
name: fpga-workflow
description: 在本 FPGA/RISC-V 工程里改代码、跑回归、量指标、收尾时使用。把「改了 A 忘了同步 B」这类静默失败变成一条命令可查，并提供 ModelSim 增量回归与三项指标汇总。触发词：改 RTL、跑回归、跑仿真、验证、检查同步、量指标、CoreMark、fmax、收尾、提交前。
---

# 工作流：改 → 验 → 量 → 记

本工程的**静默失败**历史很重：49 条坑（`PITFALLS.md`，R1~R49）里最高频的是
「改了 A 忘了同步 B」，且**全部不报错**（结果不变、或结果错但看起来正常）。
所以在本工程里，**任何改动都必须经过 `check` + `verify`，不允许靠人眼确认**。

工具入口：`tools/fpga_workflow.py`（详见 `tools/README.md`）。

---

## 1. 三个命令，覆盖收尾全流程

```bat
rem 收尾: 环境自检 + R1 漂移检测 (约 2 秒, 必须先跑)
cmd /c tools\doctor.bat

rem 回归: ModelSim 增量 (只跑受影响的测试)
python tools\fpga_workflow.py verify

rem 指标: 三项指标 + 绝对吞吐
python tools\fpga_workflow.py report
```

Python 用 `C:\Users\19716\AppData\Local\Programs\Python\Python313\python.exe`。
`doctor.bat` 里已内置这个路径，交互式敲命令时优先用它。

---

## 2. 改动的标准动作

| 改了什么 | 必须做的 |
|---|---|
| 新增 `.sv` | **登记进 `tools/fpga_workflow.py` 的 `CORE_SV_ORDER`**（`check` 会拦），再跑 `check` 看三处清单是否都补上了 |
| 改 RTL | `verify` → `report` |
| 改 `sw/` | 重建 `.hex`，再 `check`（会查镜像新鲜度），上板还要重新综合 |
| 改 `.S` | 重新 `asm.py` 汇编（tb 用的是 `.hex` 不是 `.S`），再 `verify` |
| 改 `link.ld` 地址 | `check` 第 4 项会查；还要同步 portme.c / crt0.S / core_portme.c / top_a100t.sv / 三个 tb / `sim/prog/*.S` |
| 改基线数值或新增优化 | `report` 确认**三项 + 绝对吞吐**都量了，再写进 `results/coremark.csv` |

**不要**用 `sim\run.bat` —— 它是 iverilog 时代的遗留，本机没装 iverilog，且文件清单是旧的。

---

## 3. 判断标准（不要凭感觉）

**赛题记三项指标，改一项必须同时看三项 + 绝对吞吐（CoreMark/MHz × fmax）。**
`report` 会把四项变化率一次算出来。

> ⚠️ **先分清"仿真通过"与"上板验证"**：`verify` 的 `RESULT : PASS` 只证明**仿真**过了；
> **上板**必须另有 JTAG+ILA 读回（`results/ila_done.csv` + `fpga/cap_done.log` 的 `CAPTURE_OK`，
> 并写明采集时间）。两者不是一回事，**综合报告的数字也不是"上板实测"**。
> 另外 `fmax` 的自动解析曾因 MMCM 静默算错（`CODE-REVIEW-PLAN.md` M-01）——
> 修好并用真实报告复算之前，**不要相信任何工具给的 fmax**。

反例（真发生过）：RAS + BTB128 让 CoreMark/MHz **+1.0%**，但 fmax **−4.6%**、
CoreMark/LUTs **−4.4%** → 净亏，已回退。只看一项就会误判成"改进了"。

---

## 4. XFAIL 语义（**历史章节，当前已无 XFAIL 项**）

> ⚠️ 本节写于 `tb_core_trap` 还是 XFAIL 的时候。**现在 `expect_fail_ok` 已全部摘掉、
> 11 项全 PASS、无 XFAIL**（见 `tools/README.md`）。保留本节是因为这套语义仍适用于
> 未来任何"预期失败"的测试；**不要以为现在还有 XFAIL**。

`tb_core_trap` 标了 `expect_fail_ok`（异常/中断的 core 接线 = P1 待办）：

- `XFAIL` = 如预期失败，正常
- `XPASS` = **它开始通过了 → P1 做完了 → 去掉标记**，工具会以退出码 1 提醒

它**永不缓存**，否则"从失败翻成通过"这个信号会被缓存命中掩盖。

---

## 5. 读数时的小心

- **判定依据是 testbench 打印的 `RESULT : PASS`，不是 `vsim` 退出码** ——
  ModelSim 用 `quit -f` 退出时无论成败都返回 0。
- 回归失败时先看 `.fpga-cache/logs/<test>.log` 的完整输出。
- vsim 的中文输出常常是 mojibake（控制台编码），工具会把摘要里的乱码位清掉，
  要读原文就看 log 文件。
- `tools/run_coremark.py` 是**另一个入口**：它重新构建 CoreMark 并量指标，
  适合"专门测一次 CoreMark"。它的 RTL 清单也被 `check` 盯着。

---

## 6. 收尾自检清单（`check` 覆盖前 5 项，后 2 项要人判断）

- [ ] 所有 RTL 都在三处清单里？ → `check` 第 1 项
- [ ] 软件改了 → 镜像重建了？ → `check` 第 3 项
- [ ] 地址/布局改了 → 引用点都同步了？ → `check` 第 4 项
- [ ] `.bat`/`.tcl` 是纯 ASCII？ → `check` 第 5 项
- [ ] 全套回归跑过？ → `verify`
- [ ] CoreMark 三个数据类 CRC（0xe714 / 0x1fd7 / 0x8e3a）仍匹配？ → 人判断
- [ ] 三项指标 + 绝对吞吐都重新量并记进 `results/coremark.csv`？ → `report` + 人判断
