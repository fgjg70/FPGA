# M6b 仲裁 · 最终结论（补充：与 rtl-mem 纯净室全张量结果合并）

> 日期：2026-11-04 晚。合并 `M6B-ARBITRATION.md`（我的 band/wall 实验）与 `M6B-PORTB-FIX.md §8`（rtl-mem 的 big-A 全张量实验）。

## 1. 最终裁决：**引擎 dense 路径位精确，M6b 问题在 tilecache A/B 数据通路**

| 实验 | 配置 | 结果 |
|---|---|---|
| 我的 wall/band | stock `nn_mem`（96KB A 窗口）+ op3 13 行 band | **PASS** mis=0、cyc=28,963 |
| 我的 vary-src | src=0x60000 / 0x70000 | 都 PASS |
| **rtl-mem 全张量（决定性）** | big-A（A_BYTES=802,816 / B_BYTES=262,144）+ **112 行全张量** | **PASS mis=0（50,176 字全对）、cyc=249,337 = plan exp_cycles** |

⇒ 引擎 dense 路径（k=1 / ic=64 多 icb / oc=16 / plan W/Q / 全量 A）**位精确**；M6b 的 op1/op3 失配**与引擎无关**。

## 2. 更正"引擎末拍 b_wdata 全 X"的归因（我此前的两个假设都不对）

- rtl-mem 实测：tilecache **a 侧尾窗口越界返回 X**（ADBG: op1 loc=0x030ff8 / op3 loc=0x0c3ff8，高 8B = X）→ 引擎最后像素高半通道含 X → 该像素所有 OC 累加器变 X → 末拍 b 数据整 128b 全 X。
- 纯净室里同一引擎的**末拍 b 数据与 golden 一致**（mis=0 含最后像素）⇒ **不是引擎 b 流水 bug，引擎可不动**。
- 修复在 `nn_tilecache`：越界字节返回 0 / IBUF 尾拍补 0（rtl-mem 报告 §8）。

## 3. 端口时序契约（我的逐拍 trace，A=1 / Q=1 / W=2）

`results/bottlecap/perf-proto/op3_stock_trace.log`（141 拍逐数据比对）：
- **A 读 = 1 拍**（56/56 beat 匹配）
- **Q 读 = 1 拍**（13/13 字匹配）
- **W 读 = 2 拍**（wpipe，50/52，2 个越 W 尾部属预期）

若 M6b 的 stream/tilecache 把 Q 接到 W 的 2 拍流水，bias/M_pos/SHIFT 会整体错位一个字 ⇒ dense 全错、PACKED3 的短 Q 窗口可能侥幸。rtl-stream 已按此优先验证。

## 4. 归属

- 引擎：**无需改动**（`ENGINE_TB: PASS (58 cases)` 保持）。
- P0 修复：`nn_tilecache` 越界返回 0/补零（rtl-mem/rtl-stream 写作用域）。
- 我的 task-20 结论与 rtl-mem 结论一致，实验证据互补（band/wall + 全张量）。
