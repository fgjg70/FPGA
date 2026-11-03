# M6b ISO 失败（dense + stream）· 引擎侧判据与最小修复建议

> 作者：`ddr3-feas`（engine owner，task-14）。日期：2026-11-04。
> 触发：rtl-stream 的 ISO 单 op 实验：`iso_op=0` PACKED3 k3s2 **PASS**；`iso_op=1` dense 1x1 16→64（4 tiles）**FAIL**；`iso_op=3` dense 1x1 64→16（1 tile）**FAIL**。
> 本文只给"引擎契约 + 判据 + 修复建议"，**不改 `nn_mem.sv`**（rtl-mem 写作用域）。

---

## 1. 引擎对 W/Q mem 的硬契约（码内事实）

| # | 契约 | 证据 |
|---|---|---|
| C1 | **W 读固定 2 拍延迟**：`w_re` 后第 2 拍 `wby_r` 采样 `w_rdata`；引擎**没有任何 wait/backpressure 输入** | `nn_conv_engine.sv:49`（`W_RD_LAT=2` 默认）、`nn_subsys.sv:421`（实例化未 override）、`LAT2=(W_RD_LAT>=2)` :84 |
| C2 | **Q 读固定 2 拍延迟**：`q_iss` 流水按"发出后第 2 拍数据有效"取数 | `nn_conv_engine.sv:988-1006`（`idx = q_iss-2`） |
| C3 | **A 读固定 1 拍延迟**（`a_re` 下一拍 `a_rdata`；`a_addr[3]` 选 8B 半窗，仅 8B/像素模式用） | `nn_conv_engine.sv:1190` `ld_half_d <= la[3]`、`:779` |
| C4 | **W 读 16B 窗口**、`w_addr` 低 3 位忽略；stream 模式 `w_addr` = **银行内**字节偏移 | `nn_mem.sv:37,248` |
| C5 | 引擎 bank 选择**只由 desc 派生**：`sel_a_src = d_src >= NN_B_OFF`、`sel_b_dst = d_dst >= NN_B_OFF` | `nn_conv_engine.sv:1053-1054` |

⇒ **推论**：只要 mem 在计算期对引擎的 W/Q 读插入任何 bubble、或使 `w_rdata` 出现 0/旧值/撕裂（低/高 64b 来自不同拍），dense/PACKED3 都会算错；**差别只在"读窗口是否与 fill 重叠"**。

## 2. 为什么"PACKED3 通、dense 不通"与 portB/fill 假设高度吻合

- PACKED3 op0：单 IC block（ic8=8）、W 读窗口短（9 tap × 8 ch × 16B = 1.1KB 量级），大概率在 fill 结束之后才开始/或与 fill 完全错开。
- dense op1/op3：**多 IC block**，MAC 期间 W 读持续（op3 ic8=64 → 8 个 ic 块，每块都要重读 W），与 fill（尤其"边算边填"下一层权重）长时间重叠。
- rtl-stream 已逐笔核验 W/Q/a/b 的**端口序列与数据**都正确——如果核验的是"地址序列"而非"引擎采样拍"，那正好对应"序列对、采样错"的仲裁症状。

## 3. 波形判读清单（给 rtl-stream，一锤定音）

导出 ISO op3 的下列信号（含 fill 并发期）：

| 组 | 信号 | 看什么 |
|---|---|---|
| W | `u_eng.w_re`, `u_eng.w_addr`, `u_mem.w_re_q`, `u_mem.w_cur_a/b/c/d`, `u_mem.w_nxt_*`, `u_eng.wby_r[*]`（或 `u_eng.prod`） | 每个 `w_re` 拍之后第 2 拍，`w_rdata` 是否**恰好**是对应地址的数据；有无 0/旧值/`{next,cur}` 拼接错半 |
| fill | `u_mem.wfill_we`, `u_mem.wfill_addr`, `u_mem.wfill_wdata`, `u_mem.w_bank_sel` | 是否存在 `wfill_we=1` 与 `w_re_q=1` **同拍**；是否有 bank 切换发生在读流水中间 |
| Q | `u_eng.q_re`, `u_eng.q_addr`, `u_mem.qfill_we`, `u_eng.q_rdata` | Q 读期间是否有 qfill 写；`q_rdata` 相对 `q_re` 是否恒定 2 拍 |
| 对照 | 同一份导出对 PACKED3 op0 | 比较"fill 与读重叠拍数"：op0 ≈ 0 而 op3 > 0 即实锤 |

**判据**：若 op3 出现"`wfill_we & w_re_q` 同拍"或"`w_rdata` 有效拍出现 0/旧值/撕裂" ⇒ 归 nn_mem 仲裁；若两者都干净而结果仍错 ⇒ 才回到 dense 语义（Q per-tile 装载时机 / `icb_more_r` 的 band 推进）。

## 4. 最小修复建议（给 rtl-mem，按代价从低到高）

1. **读优先 + fill 打嗝（推荐，改动最小）**：`wfill_we_eff = wfill_we && !(w_re_q || w_re_pipe)`，加一个 2 深 64b skid FIFO 兜住被推迟的 fill 写。引擎延迟**不变**；fill 只损失冲突拍（预取带宽有大量余量，实测 2 个 bank 160KiB 预取时间远小于 op 计算时间）。
2. **地址冲突检测**：fill 写地址与"读流水 2 拍窗口内的地址"做比较，命中就推迟填充 1 拍（比 1 更精确，但比较器要覆盖 4 个 segment 的地址映射，略复杂）。
3. **bank 切换 fence**：`w_bank_sel` 翻转发前保证 ≥2 拍无读（drain `w_re_q` 流水），避免 `{w_nxt, w_cur}` 跨 bank 拼接撕裂。Q 侧同理加读优先。
4. 若 pre-start/STREAM 下 **Q** 也有 qfill 并发：按 1 同样给 Q 读优先。

**验证判据**（rtl-mem 修完后由 rtl-stream 跑）：ISO op1/op3 PASS；`hw_bad=0`；全量 `tb_sw_nn_yolo`/`tb_sw_nn_slim` 的 `npu_cycles` 与修复前**逐位相同**（仲裁修复不应改变周期，只修数据）。

## 5. 备选判别（若实验 FAIL 且波形干净）

- 查 **Q 每 tile 装载**：dense 多 OC tile（op1 4 tiles）每个 tile 开始时重新读 Q（bias/M_pos/SHIFT），若 qfill 在这时插写，Q 数据会错 → 症状上与 W 仲裁同类。
- 查 **`icb_more_r` 的 band 推进**：dense 多 icb 时 `band_base += 8`（`nn_conv_engine.sv:1170-1173`），ROM 模式 ic=864 的多-icb TB 是 PASS 的，所以"多 icb 本身"没问题，只可能在 stream 地址口径下与 `woff` 组合出问题（op3 woff=0，理论 0 基址连续递增是允许的，见契约 Q4）。
