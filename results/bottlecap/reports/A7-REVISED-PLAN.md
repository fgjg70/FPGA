# A7 修订计划（dw 专用通路）· 实施前可行性复核

> 作者：`ddr3-feas`。日期：2026-11-04 晚。状态：**未改 RTL**（树保持绿，M6b 调试不受影响）。
> 关联：`M6-PERF-IMPL.md §2.9`（原设计）、Lead 拍板 "A7 只动 dw lane/写回，不碰 dense 读口/时序"。

## 1. 复核发现（原 A7 设计有一处低估）

原 A7-1..A7-9 假设"`ocw_r` 改成 16 + 放开 `a_pipe/wby_r` 的 lane8..15 门控"即可。复核 RTL 后发现：

- `nn_conv_engine.sv:227-228`：`abuf[0:BANDW-1]` / `bshift[0:WINW-1]` 都是 **64-bit（8 通道/像素）**；
- `:465`：`win_sel[0:PX-1]` 也是 **64-bit**；
- `:1145`：`ld_half_d <= la[3]`；`:1179`：`abuf[i] <= ld_half_d ? a_rdata[127:64] : a_rdata[63:0]` —— **每个 a 读只保留 16B 窗口的一半（8 通道）**。

⇒ dw 从 8 lane 扩到 16 lane 需要**每像素 16 字节的激活窗口**，即 `abuf/bshift/win_sel` 三套数组从 64b 扩到 128b（并把 `a_rdata` 全 128b 存入）。这会动到**dense 共用的装载/窗口流水**，与 Lead "不碰 dense 读口/时序" 的要求冲突。

## 2. 规避方案：**dw 专用 128b 窗口（dense 路径零改动）**

只给 dw 增加一套独立窗口寄存器，dense 路径一个字节都不动：

| # | 改动 | 作用域 | 规模 |
|---|---|---|---|
| A7a-1 | 新增 `logic [127:0] dwbuf[0:BANDW-1];` + `logic [127:0] dwbsh[0:WINW-1];` + `dw_win[0:PX-1][127:0]`；在 `S_LD` 出口**仅当 `f_dw`** 时把完整 `a_rdata` 存入 `dwbuf`（dense 分支保持原 64b `abuf`） | dw only | ~30 行 |
| A7a-2 | dw MAC 的 `a_pipe[px][oc]` 改为从 `dw_win[px][oc*8+:8]` 取 16 lane | dw only | ~10 行 |
| A7a-3 | `S_CPREP`：`ocw_r <= is_pool ? 8 : 16`；`oc_limit_r` dw 分支改 `ceil(oc8/16)`；dw tile 偏移 `c_ocb<<3 → <<4`（2 处） | dw only（`f_dw` 门控） | ~8 行 |
| A7a-4 | 写回：dw 且 `act_l==16` 时走 16B/像素单拍（`wr_dense16` 含 dw），`px_bytes=oc8` 已支持 | dw only | ~10 行 |
| A7a-5 | padding lane 屏蔽确认（`oc_base_w+l >= d_oc` 路径对 dw 生效） | 确认 | 0 行 |
| A7a-6 | `wby_r` lane8..15 只对 dw 放开（`(dense||f_dw_16lane)`） | dw only | ~3 行 |
| A7b | 行缓冲复用：dw 每输出行只装一次 band（复用 `band_ky_step`），B→×0.38 | dw only | ~40 行 |

- **存储代价**：BANDW/WINW 级 ×128b ≈ 8~16 个 64b→128b 条目 ≈ +0.5~1KB FF（可接受）。
- **dense 风险**：0（所有改动由 `f_dw` 门控；`a_pipe` 的 dense 分支原样保留）。
- **周期预期**：A7a = A/2 + C/2 = **-1,049,629 拍**（p0→38.99M；融合 plan 上 39.78M→**38.73M**）；A7b 再加 **-837,341 拍**（B×0.38）→ 全特性 33.92M（与 converter/Lead 口径一致）。
- **验证**：58 case bit-exact（旧 case 逐周期不变，因为 dense 不变）+ 新增 dw16 case（ic=16/72，16B 写 + 尾部 padding lane）+ YOLO E2E：预期 `npu_cycles` 1,191,020 → **≈1,090,000（A7a）**；逐 case before/after 表用 `tb_nn_engine_cycles_before_a7.csv`。
- **OOC**：dw 路径加 128b 窗口后引擎时序预计不变（窗口寄存器不是关键路径；仍要跑一次 122MHz OOC 复核）。

## 3. 建议排期

1. A7a-1..A7a-6（dw 专用窗口 + 16 lane + 16B 写回）→ `tb_nn_engine` 58 case + 新增 dw16 case → YOLO E2E → **before/after 周期表**；
2. A7b（行缓冲复用）→ 再对账；
3. 两步都完成后：`cycle_model` dwpath 已按 A7a+A7b 口径（`--scenario p1` 在 fused_a plan 上 = 33,924,318），用实测 `npu_cycles` 对 ±2%。

**当前状态**：本轮未改引擎 RTL，`ENGINE_TB: PASS (58 cases)`（树绿）。M6b 调试不受影响；若 rtl-stream 需要 tilecache a/b 波形判读我随时配合。
