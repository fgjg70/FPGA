# B/C 时序拆法草稿（未落盘根目录 RTL）

源：`nn_conv_engine.sv` 冻结版 v2（44,071 B / SHA256 `099D926118BE2F7368578A45D59F37433994CFF90AEDC310FA9FDED9A38E4171`，2026-11-01 00:11）。
生成器：上级目录 `gen_drafts.py`（B/C）、`gen_draft_bc2.py`（B+C+base0 两级）、`gen_draft_combined.py`（B+C，弃用）。
所有草稿 **PASS 46/46**（与根目录同一套 `sim/tb_nn_engine.sv`），OOC 150MHz 数字见下表。

| 文件 | 改动 | TB | OOC WNS | LUT/FF/BRAM |
|---|---|---|---|---|
| （根目录 v2 冻结） | — | PASS | +0.121 | 17,634 / 11,073 / 124 |
| `nn_conv_engine_v2b.sv` | 控制 one-hot：`is_conv/is_pool/is_copy/is_add/f_dw/f_up2x` 在 S_IDLE 打 one-hot 寄存器；`ld_count/ld_count-1` 在 S_CPREP 寄存 | PASS | **+0.313** | 16,908 / 11,057 / 124 |
| `nn_conv_engine_v2c.sv` | requant 窄化：`|acc*M|<2^46`，`y64_q/y2_q` 64→48 位，饱和判据 `[63:7]`→`[47:7]` | PASS | **+0.313** | 16,517 / 10,773 / 124 |
| `nn_conv_engine_v2bc.sv` | B+C+base0 移位/加法替代乘法 | PASS | −0.084（弃用） | 16,989 / 10,863 / 124 |
| `nn_conv_engine_v2bc2.sv` | B+C+**base0_a 两级拆分** | PASS | **+0.489（已应用为根目录 27d59a87…）** | 16,859 / 10,840 / 124 |
| `nn_conv_engine_v2bc3.sv` | bc2 + `icb_n_r` 寄存 + band 增量提前一拍（无新流水段/周期不变） | PASS 46/46 | **+0.585（可选，未应用）** | 16,410 / 10,859 / 124 |

## 复现
```bat
cd results\ai-accel\proto\engine
draft\run_tb_draft.bat nn_conv_engine_v2bc2.sv     rem -> ENGINE_TB: PASS (46 cases, mismatch=0)
draft\synth150_bc2.bat                              rem -> draft/synth150_bc2_{util,timing}.rpt
rem B/C/ bc 的 bat/tcl 同理 (synth150_b.bat / synth150_c.bat / synth150_bc.bat)
```

## 应用方式（决定要拆时，只改根目录 `nn_conv_engine.sv`）
1. `python gen_drafts.py` 会打印源 SHA256；对照根目录当前值，确认基线一致。
2. 建议直接应用到 **bc2**（= B+C+base0 两级，收益最大）：
   - 把 `nn_conv_engine_v2bc2.sv` 的内容覆盖根目录 `nn_conv_engine.sv`；
   - `cd results\ai-accel\proto\engine && run_tb.bat` → 期望 `ENGINE_TB: PASS (46 cases, mismatch=0)`；
   - `python tools\fpga_workflow.py verify --only tb_nn_engine --force` → PASS；
   - 然后让 Lead 重跑 150MHz 全实现。
3. 若只想要最小改动，应用 B 或 C 单独版（各自 +0.19ns），二者不冲突可叠加。
4. 注意：B/C 都只改流水/寄存器（不改变端口、Q/权重/激活布局、量化语义），但**周期公式不变**
   （B/C 只加寄存器/改位宽，不插入新状态）——应用后 46 case cycles 应完全一致（草稿已用同一 TB 验证）。

## bc3（可选）
bc3 在 bc2 基础上把 `icb_n` 寄存、band 基址增量提前到 S_LD 末拍（仍然不加状态/流水段，46 case cycles 与 bc2 完全相同）。
OOC 150MHz 从 +0.489 → **+0.585**（+0.096，新最差路径 `d_iw[0] → row_base_w_n` 6.08ns，`row_step_w` 锥的共享/retiming）。
应用方式同 bc2（覆盖根目录前先让 Lead 确认快照切换时机）。当前根目录保持 **bc2**，因为 Lead 的 87.5MHz
全实现按 bc2 快照启动；等拿到 MET 结果后如需再压 1ns 再切 bc3。

## 剩余瓶颈（供下一轮）
- bc2 最差路径：`c_icb[4] → la_reg[23]`（6.18ns，band 基址选择 + 加法 + S_CPREP 常量 mux）；
- 其后：nn_mem 输入侧地址 mux（OOC route 估计占 ~60%）与 YOLO 层 Q 参数装载（mpos/mneg）。
- 若允许改 nn_mem（T-mem 配合、读时延契约 1→2 拍），还能再拿 ~0.5ns，但不建议轻易动契约。
