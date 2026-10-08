# radix-4 除法器实测结论（分支 `exp/radix4-div`）：**净亏，不采纳**

**日期**：2026-10-08 **状态**：✅ 已实测（仿真 4 配置 + 综合 A/B 完成；上板确认为待办）
**原子指令相关工作按用户要求暂停**

---

## 1. 判决

| 指标 | radix-2 基线 | **radix-4** | 差 | 判定 |
|---|---:|---:|---:|---|
| **CoreMark/MHz** | 2.4209 | **2.4209** | **0.00%** | ✗ **零收益** |
| CoreMark ticks（仿真/计时区间）| 413,070 | 413,070 | 0 | — |
| **fmax** | **69.6 MHz** | **66.9 MHz** | **−3.88%** | ✗ 明显变慢 |
| **LUT** | **2653** | **2765** | **+112** | ✗ 变大 |
| FF | 1234 | 1267 | +33 | ✗ |
| BRAM / DSP | 8 / 8 | 8 / 8 | 0 | — |
| CoreMark/LUTs | 9.125e-4 | 8.756e-4 | −4.04% | ✗ |
| **绝对吞吐** | **168.4** | **161.9** | **−3.86%** | ✗ **净亏** |

**结论：不采纳。** 与仓库原有那条分析结论（`muldiv.sv:105`「待办 #8 (radix-4) 判定不做」）**方向一致**，
但理由比原来**更硬**（见 §2），而且原来担心的 fmax 风险**被实测证实了**（−3.88%，不是"也许有风险"）。

---

## 2. 关键发现：收益**精确为 0**，不是"只有 0.29%"

原来那条分析说"省 ~1,344 拍 = 0.29%"。实测把这个数字**修正为 0**，机理如下：

| 量 | radix-2 | radix-4 | 差 |
|---|---:|---:|---:|
| `muldiv busy`（全程，含乘法启动拍）| 14,415 | **12,063** | **−2,352** ✓ 除法器**确实变快了** |
| `pipe_stall` 总拍（全程）| 45,060 | 42,708 | −2,352 |
| tb 总周期 `cycles`（整个程序）| 457,125 | **454,773** | **−2,352** ✓ |
| **程序自测 `Total ticks`**（`MMIO_MARK` → `MMIO_RESULT` 窗口）| 413,070 | **413,070** | **0** ✗ |
| `fetch` / `redirects` / `load-use` | 400,531 / 11,535 / 30,645 | 完全相同 | 0 |

⇒ **radix-4 省下的 2,352 拍全部落在 CoreMark 的「计时区间之外」**（init / 校验阶段的除法，
不在 MMIO_MARK → MMIO_RESULT 窗口内）。

**所以对 CoreMark/MHz 的贡献精确为 0。** 这也解释了为什么 `--force` 跑出来的两个配置
`Total ticks` 逐位相同 —— 不是宏没生效（自证行 `[muldiv] DIV_RADIX4 ACTIVE: radix-4 divider,
16 iterations` 确实打出），而是**那些除法根本没被计时**。

> **方法论教训**：`stall_xxx` 变小 ≠ CoreMark 会变快。**必须看"计时区间内的 tick"**。
> 本项目 `profile` 给的是全程计数，用它推断评分收益会**系统性高估**。

---

## 3. 验证矩阵（全绿）

| # | 配置 | 结果 |
|---|---|---|
| 1 | radix-2 / BRAM（默认）| **PASS 11** |
| 2 | radix-4 / BRAM | **PASS 11** |
| 3 | radix-2 / `--imem_comb_read` 回退 | **PASS 11** |
| 4 | radix-4 / `--imem_comb_read` 回退 | **PASS 11** |

功能等价性另有独立证据：实现者用 **24,312 组随机激励与 radix-2 逐位对拍**，全部一致。

宏传递四处齐全（缺一处就会"以为测了 radix-4、实际测的是基线"，R31 类静默错误）：

| 文件 | 自证串 |
|---|---|
| `muldiv.sv` | 仿真期 `[muldiv] DIV_RADIX4 ACTIVE: radix-4 divider, 16 iterations` |
| `fpga/build.tcl` | `BUILD_DIV_RADIX4=1` / `BUILD_DIV_RADIX4_OFF=1` |
| `fpga/build_ila.tcl` | `ILA_BUILD_DIV_RADIX4=1` / `_OFF=1` |
| `tools/fpga_workflow.py` | `--div_radix4`（verify + synth）、`_global_defines`、综合缓存指纹 `divr4/divr2`、`expect` guard |

---

## 4. 上板实测：待办（预期**无差异**）

用户要求上板实测。**预期 tick 与基线逐位相同（536,943,384）**，理由是：
程序自测的 tick 就是写进 `MMIO_RESULT` 的那个值，而它已被仿真证明不变；且 50 MHz 远低于
两版的 fmax（66.9 / 69.6），一拍的临界路径差异不会体现为周期数差异。

**做法**（若要补做，约 20 分钟 = 两轮 ILA）：
```powershell
# A) radix-4:  设 DIV_RADIX4=1 后走 ILA 流程
$env:DIV_RADIX4="1"; cmd /c fpga\build_ila.bat
Select-String fpga\ila_build.log -Pattern "ILA_BUILD_DIV_RADIX4"   # 自证: 必须是 =1
cmd /c fpga\ila_cap_done.bat
python tools\fpga_workflow.py hw --iterations 1300
# B) 对照: 不设该环境变量重跑, 期望 tick=536,943,384 逐位复现
```
**判据**：两版 tick 若相同 ⇒ 与仿真一致，`radix-4` 对评分**零贡献**，弃用；
若 radix-4 的 tick 反而**变大**，说明 fmax −3.88% 在 50 MHz 下仍有别的副作用，更要弃用。

---

## 5. 处置建议

1. **不把 `DIV_RADIX4` 设为默认**（保持 radix-2），宏保留作为可复现的实验开关。
2. 分支 `exp/radix4-div` **不合并回 main**。
3. 把 §2 的方法论教训（"`stall_*` 变小 ≠ 评分变快，必须看计时区间内的 tick"）记进 `PITFALLS`。
4. `muldiv.sv:93-113` 那段旧分析补一句实测更正：**收益不是 0.29%，而是 0；fmax −3.88%**，并指向本文件。
