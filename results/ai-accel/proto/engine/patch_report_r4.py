# -*- coding: utf-8 -*-
"""R4 报告更新: bc2 已应用为根目录快照 (hash/verify/OOC 数字) + 150MHz 不可行->87.5MHz 方向。"""
import io

P = "../../engine-report.md"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


# 1) TL;DR 时序行 -> 当前根目录快照 (bc2)
rep("""| **时序（R2 核心）** | **OOC 综合 @150MHz（`create_clock -period 6.667`）WNS = +0.121 ns（MET）**；fmax≈151.8MHz（仅 OOC 综合估计，不含布线） | `proto/engine/synth150_timing.rpt`、`synth150_util.rpt` |
| 资源（同一 OOC 综合，engine+nn_mem 全上下文） | **LUT 17,634 / FF 11,073 / DSP48E1 40 / BRAM36 124**（124 = WQ 92 + ACT 32，符合预期） | `proto/engine/synth150_util.rpt` |""",
    """| **时序（OOC 综合 @150MHz）** | **当前根目录快照（= bc2 拆法）= WNS +0.489 ns（MET）**，LUT 16,859 / FF 10,840 / DSP 39 / BRAM 124；旧 v2 冻结版为 +0.121。（OOC 无布线，仅作相对判据；全实现 150MHz 实测 post-place −4.020 → 150MHz 不可行，Lead 改打 **87.5MHz**） | `proto/engine/synth150_timing.rpt`、`synth150_util.rpt`；`draft/synth150_bc2_*.rpt` |
| 资源（同一 OOC 综合，engine+nn_mem 全上下文） | **LUT 16,859 / FF 10,840 / DSP48E1 39 / BRAM36 124**（124 = WQ 92 + ACT 32，符合预期） | `proto/engine/synth150_util.rpt` |""")

# 2) §0.5.9 冻结快照段: 追加"已切换 bc2"说明
rep("""**v2 根目录 RTL 冻结快照**（R41 纪律：Lead 全实现读这份快照，T-accel 期间不再改）：""",
    """**（历史）v2 冻结快照**（R41 纪律；已按 Lead 指令于 2026-11-01 00:38 切换为 bc2，见下）：""")

rep("""（2026-11-01 00:11:04；本报告 §0.5.1–0.5.8 的所有 OOC 数字都对应这份文件）。""",
    """（2026-11-01 00:11:04；本报告 §0.5.1–0.5.8 的所有 OOC 数字都对应这份文件；备份在
`proto/engine/draft/nn_conv_engine_v2_frozen.sv`）。

**当前根目录快照（2026-11-01 00:38:50，= bc2 拆法，Lead 的 E2E/全实现按此跑）**：
`nn_conv_engine.sv` **44,923 B，SHA256 = `27d59a87451c97a1c750d4548ce17da03f476cef1ecabc2cb4f51b44bbd32413`**
（内容 = `draft/nn_conv_engine_v2bc2.sv`：B 控制 one-hot + C requant 48 位 + base0 两级拆分）。
自证：vlog 0 error；`run_tb.bat` **PASS 46/46**（`tb_bc2_applied.log`）；
`verify --only tb_nn_engine --force` **PASS 3.2s**；
OOC 150MHz 重跑 **WNS +0.489ns**（LUT 16,859 / FF 10,840 / DSP 39 / BRAM 124）；
**46 case 周期与冻结版逐 case 相同**（bc2 不加流水段/不加周期）→ 全模型 **npu_cycles 仍 = 1,290,062**。
新最差路径：`c_icb[4] → la_reg[23]`（6.18ns，band 基址选择）——下一拆点（草稿见 §0.5.11）。

**150MHz 全实现实测（Lead）**：post-place estimated WNS **−4.020ns**，route 中间 **−3.614ns**
（24K LUT + 124 BRAM 拥塞、route 占比高）→ 150MHz 不可行；Lead 改打 **87.5MHz（`--nn-clk-div 12`，
周期 11.43ns）**做 board-ready bitstream，再向 95.45/105MHz 迭代。OOC(+0.489) 与全实现的差距说明：
**OOC 综合的 route 是"未放置"估计，不能替代全实现**，本报告的 OOC 数字只用于相对改进。""")

# 3) §0.5.11 草稿表: bc2 行改为"已应用"
rep("""| `nn_conv_engine_v2bc2.sv` | B+C + **base0_a 两级拆分**（`pad*row_step` 先寄存，下一拍只减法） | PASS 46/46 | **+0.489（当前最好草稿）** | 16,859 / 10,840 / 124 |""",
    """| `nn_conv_engine_v2bc2.sv` | B+C + **base0_a 两级拆分**（`pad*row_step` 先寄存，下一拍只减法） | PASS 46/46 | **+0.489 → 已应用为当前根目录快照**（`27d59a87…`） | 16,859 / 10,840 / 124 |""")

io.open(P, "w", encoding="utf-8").write(s)
print("report patched (R4)")
