# -*- coding: utf-8 -*-
"""R5: 报告 + draft/README 追加 bc3 (可选, 未应用)。"""
import io

# ---------- draft/README.md ----------
rp = "draft/README.md"
r = io.open(rp, encoding="utf-8").read()
r = r.replace("""| `nn_conv_engine_v2bc2.sv` | B+C+**base0_a 两级拆分** | PASS | **+0.489（最好）** | 16,859 / 10,840 / 124 |""",
              """| `nn_conv_engine_v2bc2.sv` | B+C+**base0_a 两级拆分** | PASS | **+0.489（已应用为根目录 27d59a87…）** | 16,859 / 10,840 / 124 |
| `nn_conv_engine_v2bc3.sv` | bc2 + `icb_n_r` 寄存 + band 增量提前一拍（无新流水段/周期不变） | PASS 46/46 | **+0.585（可选，未应用）** | 16,410 / 10,859 / 124 |""")
r = r.replace("""## 剩余瓶颈（供下一轮）""",
              """## bc3（可选）
bc3 在 bc2 基础上把 `icb_n` 寄存、band 基址增量提前到 S_LD 末拍（仍然不加状态/流水段，46 case cycles 与 bc2 完全相同）。
OOC 150MHz 从 +0.489 → **+0.585**（+0.096，新最差路径 `d_iw[0] → row_base_w_n` 6.08ns，`row_step_w` 锥的共享/retiming）。
应用方式同 bc2（覆盖根目录前先让 Lead 确认快照切换时机）。当前根目录保持 **bc2**，因为 Lead 的 87.5MHz
全实现按 bc2 快照启动；等拿到 MET 结果后如需再压 1ns 再切 bc3。

## 剩余瓶颈（供下一轮）""")
io.open(rp, "w", encoding="utf-8").write(r)

# ---------- engine-report.md §0.5.11 ----------
P = "../../engine-report.md"
s = io.open(P, encoding="utf-8").read()
old = """| `nn_conv_engine_v2bc2.sv` | B+C + **base0_a 两级拆分**（`pad*row_step` 先寄存，下一拍只减法） | PASS 46/46 | **+0.489 → 已应用为当前根目录快照**（`27d59a87…`） | 16,859 / 10,840 / 124 |"""
new = old + """
| `nn_conv_engine_v2bc3.sv` | bc2 + `icb_n_r` 寄存 + **band 基址增量提前到 S_LD 末拍**（无新状态/无新流水段，46 周期不变） | PASS 46/46 | **+0.585（可选草稿，未应用）**；新瓶颈 `d_iw[0] → row_base_w_n`（6.08ns） | 16,410 / 10,859 / 124 |"""
assert old in s
s = s.replace(old, new, 1)
s = s.replace("""- bc2 的最差路径变成 `c_icb[4] → la_reg[23]`（6.18ns，band 基址选择/加法）——即下一个可拆点；""",
              """- bc2 的最差路径变成 `c_icb[4] → la_reg[23]`（6.18ns，band 基址选择/加法）；bc3 把它拆掉后最差变
  `d_iw[0] → row_base_w_n`（6.08ns，`row_step_w` 锥）；""")
io.open(P, "w", encoding="utf-8").write(s)
print("README + report updated (bc3)")
