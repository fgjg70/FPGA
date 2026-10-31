# -*- coding: utf-8 -*-
"""R6 最终收尾: 全实现 87.5MHz MET 结果入报告 (TL;DR/§0.5.1/§0.5.9) + XDC R52 + 关键路径转移 R53。"""
import io

P = "../../engine-report.md"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


# 1) TL;DR 插入全实现行 (在资源行之后)
rep("""| 资源（同一 OOC 综合，engine+nn_mem 全上下文） | **LUT 16,859 / FF 10,840 / DSP48E1 39 / BRAM36 124**（124 = WQ 92 + ACT 32，符合预期） | `proto/engine/synth150_util.rpt` |""",
    """| 资源（同一 OOC 综合，engine+nn_mem 全上下文） | **LUT 16,859 / FF 10,840 / DSP48E1 39 / BRAM36 124**（124 = WQ 92 + ACT 32，符合预期） | `proto/engine/synth150_util.rpt` |
| **全实现（Vivado 2018.3，87.5MHz = `--nn-clk-div 12`，bc2 快照）** | **`BUILD_TIMING=PASS`：WNS +0.135 ns（MET），fmax 88.5 MHz**；LUT 25,212 / FF 12,782 / BRAM 133 / DSP 47（含 CPU 子系统）；board-ready 产物 `fpga/cpu_a100t_nn.bit`（sha256 `489510b8…d91d3c0`，不覆盖交付档） | Lead 全实现 2026-11-01 01:35：`results/ai-accel/impl/ai875_{util,timing}.rpt`、`ai875_metrics.json` |""")

# 2) "未达目标" 行 -> 验收达成 + 提频杠杆转移
rep("""| **未达目标** | 目标是 OOC **≥ +2.0 ns**，当前 **+0.121 ns，还差 1.88 ns**；卡点与下一步拆法见 §0.5.5（结论：剩余路径是"短链密集"的控制/状态 CE + nn_mem 地址 mux，OOC 的 route 估计占 60% 也放大了差距） | §0.5.5 |""",
    """| **验收结论** | Lead 把验收线改为"**全实现 WNS MET**"→ **已达成：87.5MHz 全实现 WNS +0.135 ns（MET）**。OOC ≥+2.0ns 的旧代理目标未达（bc2 +0.489），**不再作为验收线**；150MHz 全实现真实 fmax 95.6MHz、87.5MHz 的运行点余量 +0.135。下一轮提频杠杆已转移：87.5MHz 关键路径变成 `u_core/u_ex_mem/alu_out → nn_mem/u_wq/mem_a ADDRARDADDR`（10.87ns，route 71.8%），**不再在引擎内部**（bc2 引擎内部最差 6.18ns） | Lead 实测 + §0.5.9（R52/R53） |""")

# 3) "与上一轮全实现对比" 行补充最终版
rep("""| 与上一轮全实现对比 | v1 全实现 150MHz：WNS −18.416ns（fmax 39.9MHz）→ v2 OOC +0.121ns；关键链由 `d_ks→权重BRAM地址 24.5ns/32级` 拆成多级短链 | 本轮 §0.5.3/0.5.4 |""",
    """| 与上一轮全实现对比 | v1 全实现 150MHz：WNS −18.416ns（fmax 39.9MHz）→ v2/bc2：87.5MHz 全实现 **WNS +0.135ns（MET）**、150MHz 全实现 fmax **95.6MHz**；关键链由 `d_ks→权重BRAM地址 24.5ns/32级` 拆成多级短链 | §0.5.3/0.5.4 + Lead ai875 报告 |""")

# 4) §0.5.1 结果 bullet 补最终全实现
rep("""- R2 结果：**OOC 综合 150MHz WNS = +0.121 ns**（MET，`synth150_timing.rpt`），""",
    """- R2 结果（最终）：**全实现 87.5MHz（bc2 快照）WNS = +0.135 ns（MET），fmax 88.5MHz，board-ready**
  （`impl/ai875_{util,timing}.rpt`）；150MHz 全实现真实 fmax = 95.6MHz（记录在案）。
  以下是过程中 OOC 综合的数字（旧 v2 冻结版 WNS = +0.121 ns，`synth150_timing.rpt`），""")

# 5) §0.5.9 末尾追加最终结果 + R52/R53
rep("""**150MHz 全实现实测（Lead）**：post-place estimated WNS **−4.020ns**，route 中间 **−3.614ns**
（24K LUT + 124 BRAM 拥塞、route 占比高）→ 150MHz 不可行；Lead 改打 **87.5MHz（`--nn-clk-div 12`，
周期 11.43ns）**做 board-ready bitstream，再向 95.45/105MHz 迭代。OOC(+0.489) 与全实现的差距说明：
**OOC 综合的 route 是"未放置"估计，不能替代全实现**，本报告的 OOC 数字只用于相对改进。""",
    """**150MHz 全实现实测（Lead）**：post-place estimated WNS **−4.020ns**，route 中间 **−3.614ns**
（24K LUT + 124 BRAM 拥塞、route 占比高）→ 150MHz 不可行；真实 fmax = **95.6MHz**。
Lead 改打 **87.5MHz（`--nn-clk-div 12`，周期 11.43ns）**做 board-ready bitstream。

**最终结果（2026-11-01 01:35，bc2 快照 `27d59a87…`）：87.5MHz 全实现 `BUILD_TIMING=PASS`，
WNS +0.135ns（MET），fmax 88.5MHz**；资源 LUT 25,212 / FF 12,782 / BRAM 133 / DSP 47（含 CPU，
对比 v2@150 的 LUT 25,208/FF 12,945 → bc2 略降）；产物 `fpga/cpu_a100t_nn.bit`
（sha256 `489510b8…d91d3c0`）；集成 `verify --force` **PASS 15**；E2E `hw_bad=0`，
**npu_cycles = 1,290,062 = 逐 op 公式 0.00% 差**（§0.5.10）。

**两个集成坑（已记入 PITFALLS，供后续提频）：**
- **R52：Vivado 2018.3 的 XDC 不支持 `if/puts`**——第一次 87.5MHz 构建里 `create_clock` 条件段被
  **静默丢弃**（CRITICAL 20-1307），实际仍按 150MHz 布线、WNS 异常变差。修法：build.tcl 生成
  "字面量分频"的 XDC 副本 + `BUILD_NN_XDC_GEN=` 自证 + workflow 硬门。
- **R53：87.5MHz 的关键路径已换人**：`u_core/u_ex_mem/alu_out → u_nn/u_mem/u_wq/mem_a ADDRARDADDR`，
  10.87ns 中 **route 占 71.8%**。引擎内部（bc2 最差 6.18ns）已不是限制 → **下一轮提频的杠杆在
  nn_mem 的 CPU→WQ 地址路径/布局，不是再拆引擎**。bc3 草稿（+0.096 OOC）保留在 `draft/` 备用，
  **不应用到根目录**。

**OOC vs 全实现**：OOC(+0.489) 与全实现(+0.135@87.5MHz) 的差距说明 OOC 的 route 是"未放置"估计，
**不能替代全实现**；本报告的 OOC 数字只用于相对改进排序。""")

io.open(P, "w", encoding="utf-8").write(s)
print("report patched (R6 final)")
