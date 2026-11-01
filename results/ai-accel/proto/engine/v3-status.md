# T-accel-R3 v3 状态备忘（原型在 proto/engine/，根目录未替换）

更新时间: 2026-11-01 13:40 左右

## 已完成
| 项 | 结果 | 证据 |
|---|---|---|
| 128 MAC 引擎（16 OC lane × 8 px）+ Q 独立口 + b_wstrb | 原 46 case 全 PASS | `v3_run_final.log` → `ENGINE_TB: PASS (46 cases, mismatch=0)` |
| PACKED3（conv0 3B/px）+ ADD_R（per-tensor R） | 新 4 case 全 PASS | `v3_extra.log` → `PASS 4/4, mismatch=0`；向量 `gen_vectors_v3extra.py` → `vec_v3extra/` |
| 周期公式 | 50/50 case 实测 == 公式（0 误差） | `calc_cycles_v3.py` |
| C128 全模型估算（当前 112-op plan） | **1,165,406 拍** @100MHz = 11.65ms (85.8fps)；同 plan v2 口径 1,321,892 | `est_full_model_v3.py` → `full_model_estimate_v3.md` |
| 文件 | `nn_conv_engine_v3.sv`（模块 `nn_conv_engine`，参数 OC_LANES/PX_LANES）、`nn_mem_v07_stub.sv`、`tb_nn_engine_v3.sv`、`run_v3.bat`、`timing_wrap_v3.sv`、`synth100_v3.{tcl,bat}`、`wq_init/`（4 段 W + Q 64b 初始化） | — |

## 接口口径（已按 Lead/T-mem 对齐）
- engine: `w_re/w_addr[23:0]/w_rdata[127:0]`、`q_re/q_addr[12:0]/q_rdata[63:0]`、`a_sel/a_re/a_addr/a_rdata[127:0]`、`b_sel/b_we/b_addr[23:0]/b_wdata_128[127:0]/b_wstrb[15:0]`、`desc`(flags 7bit)、start/busy/done/cycles/err_code。
- 写口：`b_addr` 16B 对齐；`b_wstrb[15:0]` 选字节；dense 16-lane tile 每像素 2 个 8B beat；非 dense（dw/pool/copy/add）8 通道粒度。
- ADD_R Q 块（16B）: `[0]=zp_s [1]=zp_d [2:3]=R(u16 LE) [4]=KADD`，无 zp_d 项；per-tensor。
- PACKED3: 输入 `y*iw*3 + x*3 + c`，引擎内二级窗缓冲提取（跨 16B 自己拼），权重 dense IC8=8 后 5 个 IC 为 0，输出 8ch。
- 数值语义与 v2 完全一致；`nn_pkg` 常量直接使用（NN_F_PACKED3/ADD_R、NN_Q_OFF 等）。

## OOC @100MHz 现状（第一版，不过）
`synth100_util/timing/paths.rpt`：WNS **−6.638ns**；LUT 43,823（logic 31,535 + LUTRAM 12,288Q）/ FF 14,591 / BRAM 112（W80+A/B32）/ **DSP 208**（超 160）。
- 最差路径 `u_eng/ocw_r → u_mem/q_rd_reg[0]` 16.6ns / 25 级（logic 9.7 + route 6.9）⇒ **q_addr 组合输出穿过 Q LUTRAM 译码**。
- 次因：requant 16×32×32 ≈ 80 DSP；变量移位/饱和/pack LUT 大。

## 下一步（按顺序）
1. **q_re/q_addr 打拍**（S_Q +1 拍/tile，公式同步）——修最差路径。
2. **requant 乘法 32×16 拆 2 DSP**（acc 高/低 16 位分别乘 M 后移位合并）→ DSP 128+32=160，LUT 大降。
3. **移位拆分**：`prod64 >>> shift_q` → 先固定 >>16 再 3-bit 变量（SHIFT=17/18/23），省桶形移位 LUT。
4. 重跑 OOC 100MHz，目标 WNS ≥ +1.0 / LUT ≤25K / DSP ≤160。
5. 提效（若 Lead 批准扩范围）：dw 16-lane（C8≥16 用 128b band word）、requant 16B 单 beat、conv0 loader 优化（129k→~60k）；再评估 PX16。

## 待 Lead 确认
- 上述 3 个时序修法（不改契约）。
- 30fps@320 的缺口方向（dw16/REQ 优化/PX16/更高主频）。
- t-mem 的 `nn_mem.sv` v0.7 TB PASS 后，再把根目录 `nn_conv_engine.sv` + `sim/tb_nn_engine.sv` 替换为 v3 版本（届时 TB 直接用真 nn_mem，不用 stub）。
