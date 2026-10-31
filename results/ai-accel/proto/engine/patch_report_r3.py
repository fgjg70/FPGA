# -*- coding: utf-8 -*-
"""R3 报告更新: 全模型口径纠正 + 冻结快照 + B/C 草稿实测 + E2E 实测对齐。"""
import io

P = "../../engine-report.md"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


# 1) TL;DR 全模型行（旧: 1,320,062 估算）
rep("""| 全模型周期估算（128 输入，plan.json 105 个 HW op） | v2 公式逐 op 求和：**1,320,062 拍 ≈ 10.06 ms @131.25MHz（≈99.4 fps 纯 NPU 计算）**；比 v1（1,216,578）慢 **8.5%**（流水化代价，见 §0.5.3 周期增量） | 本报告 §0.5.3 + plan.json 公式求和 |""",
    """| 全模型周期（128 输入，当前 plan 87 个 HW op；**E2E 实测对齐**） | **1,290,062 拍**（v2 公式逐 op 求和 = 实测，差 **+0**）；**@150MHz = 8.60 ms/帧**；同一 plan 上 v1 公式 = 1,186,704，v2 慢 **8.7%**（流水化代价） | Lead `tb_sw_nn_yolo`（HW-only，PASS，hw_bad=0）；`proto/engine/est_full_model.py` → `full_model_estimate.md` |""")

# 2) 在 v1 历史性注记之前插入 §0.5.9 / §0.5.10
anchor = """> **注意 (v1 §1-§11 的历史性)**：§1 起的正文是 v1（R1）交付时写的，其中的周期公式/资源"""
add = """### 0.5.9 冻结快照、A 方案（全实现）与 E2E 实测

**v2 根目录 RTL 冻结快照**（R41 纪律：Lead 全实现读这份快照，T-accel 期间不再改）：
`nn_conv_engine.sv` **44,071 B，SHA256 = `099D926118BE2F7368578A45D59F37433994CFF90AEDC310FA9FDED9A38E4171`**
（2026-11-01 00:11:04；本报告 §0.5.1–0.5.8 的所有 OOC 数字都对应这份文件）。

**A 方案（Lead 执行）**：全量回归（含 E2E）→ 150MHz 全实现
（`synth --nn --nn-clk-div 7 --prog yolo_board`，带 4 段 WQ 初始化，输出 `fpga/cpu_a100t_nn.bit`）。
验收口径按 Lead 本轮要求改为"**全实现 WNS ≥ 0（MET） = 任务完成**"（OOC +2.0ns 只是布线余量的代理指标）。
分支：`WNS≥0` → 150MHz 定稿；`−1.5<WNS<0` → 应用 §0.5.10 的 B/C 再拆 1 轮后重跑；`WNS≤−1.5` → 先
`--nn-clk-div 8/10`（131.25/105MHz）出版本，同时继续拆。

**E2E 实测（Lead，2026-11-01）——比 OOC 更有说服力**：
- `tb_sw_nn_yolo`（108 op 全模型，HW-only，含 18 个 `cpu_add`）：**PASS，hw_bad=0**，input_csum OK；
- **实测 `npu_cycles = 1,290,062` @150MHz = 8.60 ms/帧**；
- 与本节 §0.5.10 的逐 op v2 公式估算 **完全相等（差 0）**。

### 0.5.10 全模型估算口径修正（R42：报告数字必须能由实测解释）

**结论：1,290,062 拍，v2 公式逐 op 求和精确等于 E2E 实测（差 +0）。**
脚本：`proto/engine/est_full_model.py`（读当前 `sim/prog/yolo/plan.json`，逐 op 套 §0.5.6 公式）；
输出：`proto/engine/full_model_estimate.md`（含逐 op 明细表）。

| kind | ops | v2 cycles | v1 cycles | v2−v1 |
|---|---|---|---|---|
| conv | 55 | 842,462 | 777,430 | +65,032 |
| dwconv | 28 | 436,624 | 398,398 | +38,226 |
| pool | 3 | 10,008 | 9,915 | +93 |
| upsample | 1 | 968 | 961 | +7 |
| cpu_conv0 / cpu_concat / cpu_add | 1 / 2 / 18 | 0 | 0 | 0 |
| **HW 合计** | **87** | **1,290,062** | **1,186,704** | **+103,358（+8.7%）** |

**上一版 1,320,062 错在哪（已删除，不再作为结论）**：那是"v1 估算 1,216,578（**旧 plan**，105 个 HW op，
含 18 个 HW shortcut-add）+ v2 流水化增量 103,484"得到的。T-model 精度修复后的新 plan 把 18 个
shortcut-add 改成 **`cpu_add`（CPU 执行，不占 NPU）**，所以：
- NPU 侧 HW op = conv 55 + dwconv 28 + pool 3 + upsample 1 = **87**（不是 105）；
- 旧 v1 估算里 18 个 HW add 的周期（v1 公式合计 **29,874 拍**）被当作 NPU 周期带进基准；
  1,216,578 − 29,874 = 1,186,704（= 当前 plan 的 v1 公式合计），再加上 v2 增量 103,358 → 1,290,062。
- 差值 ≈ 30,000 拍（−2.3%）就是这 18 个 `cpu_add` 从 NPU 挪走的周期，**不是公式常数偏大**。
  （46/46 case 的公式本身就是精确的，§0.5.6 的实测对照未受影响。）

### 0.5.11 B/C 拆法草稿（只落盘 `proto/engine/draft/`，**未写根目录 RTL**）

由 `gen_drafts.py` 从冻结版生成，`draft/run_tb_draft.bat <file>` 跑同一套 46 case TB，
`draft/synth150_<tag>.bat` 跑同口径 OOC 150MHz 综合：

| 草稿 | 改法 | TB（46 case） | OOC WNS @150MHz | LUT / FF / BRAM |
|---|---|---|---|---|
| 冻结版 v2（根目录） | — | PASS 46/46 | +0.121 | 17,634 / 11,073 / 124 |
| `nn_conv_engine_v2b.sv` | **B：控制 one-hot**——`is_conv/is_pool/is_copy/is_add/f_dw/f_up2x` 改 S_IDLE 打 one-hot 寄存器；`ld_count/ld_count−1` 在 S_CPREP 寄存，S_LD 只比较寄存器 | PASS 46/46 | **+0.313** | 16,908 / 11,057 / 124 |
| `nn_conv_engine_v2c.sv` | **C：requant 窄化**——`|acc*M|<2^46`（int32×int16，右移只减），`y64_q/y2_q` 64→**48 位**，饱和判据 `[63:7]`→`[47:7]` | PASS 46/46 | **+0.313** | 16,517 / 10,773 / 124 |
| `nn_conv_engine_v2bc.sv` | B+C + base0 用移位/加法替代小乘法 | PASS 46/46 | −0.084（更差，**弃用**） | 16,989 / 10,863 / 124 |
| `nn_conv_engine_v2bc2.sv` | B+C + **base0_a 两级拆分**（`pad*row_step` 先寄存，下一拍只减法） | PASS 46/46 | **+0.489（当前最好草稿）** | 16,859 / 10,840 / 124 |

- 每个草稿的 TB 证据：`draft/tb_b.log` / `tb_c.log` / `tb_bc.log` / `tb_bc2.log`；
- 综合证据：`draft/synth150_{b,c,bc,bc2}_{util,timing}.rpt`；
- bc2 的最差路径变成 `c_icb[4] → la_reg[23]`（6.18ns，band 基址选择/加法）——即下一个可拆点；
- B 与 C 互不冲突，可叠加；**bc2 比冻结版 +0.37ns**，但离 OOC +2.0 仍差 1.5ns（剩余为 la/band 基址 + nn_mem 地址 mux + OOC 未放置 route 估计）。

复现草稿（不改根目录）：
```bat
cd results\\ai-accel\\proto\\engine
python gen_drafts.py            rem B/C (会打印源 SHA256)
python gen_draft_bc2.py         rem B+C+base0 两级
draft\\run_tb_draft.bat nn_conv_engine_v2bc2.sv
draft\\synth150_bc2.bat
```

""" + anchor
rep(anchor, add)

# 3) §6 v1 估算加"已作废"提示
rep("""## 6. 全模型周期/吞吐估算（128 输入，T-model `sim/prog/yolo/plan.json`）""",
    """## 6. 全模型周期/吞吐估算（v1 数字，**已被 §0.5.10 作废**，仅作历史）

> v1 的 1,216,578 拍是旧 plan（105 HW op，含 18 个 HW add）下的估算；当前 plan 的
> 准确口径见 §0.5.10：**v2 = 1,290,062 拍 @150MHz = 8.60ms/帧，且与 E2E 实测完全相等**。
> 下面这段只说明 v1 当时的算法，不再作为交付结论。""")

io.open(P, "w", encoding="utf-8").write(s)
print("report patched")
