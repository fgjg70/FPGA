# M6b 仲裁实验（task-20）· 追加结论（Wall/Band 模式）

> 日期：2026-11-04 晚。接前一份 `M6B-ARBITRATION.md`。

## 1. 新证据 A：stock nn_mem + 真实 op3 数据（13 行 band）**PASS**

```
OP3ISO: start dir=.../op3_iso rows=13 AW=23296 GW=5824
OP3ISO: PASS rows=13 cyc=28963 err=00 mis=0
ENGINE_TB: PASS (58 cases, mismatch=0)
```

- 描述符：`op=CONV flags=0 ks=1 st=1 pad=0 ih=13 iw=112 ic=64 oc=16 src=0x60000 dst=0x78000 woff=qoff=0`
- W/Q/A 全部来自复现包（W 1024B、Q 112B、A 前 13 行 93,184B ≤96KB A 窗口），输出与 `op3_golden.hex` 前 13 行 **逐字节 0 失配**。
- 这覆盖 **dense + ic=64（icb_n=8）+ k=1 + pad=0 + Q 解析（zp_out=-27/SHIFT=23）+ requant + 16B/像素写回** 的完整数据通路。
- **⇒ 引擎 dense 数据通路在 wall 模式正确；op3 的 FAIL 与引擎无关。**

## 2. 结构性限制：**整张量 op3 无法用 wall 模式复现**（不是实验没做，是做不了）

`nn_mem.sv:508`：`assign a_in_a = (a_addr32 >= A_OFF) && (a_addr32 < B_OFF);`
⇒ A 窗口以 `NN_B_OFF=0x78000` 为硬上界，**固定 96KB**；`A_BYTES` 参数只影响总 `act_mem`，**不能扩大 A 窗口**。op3 的 A=802,816B 超出 12.8 倍；op1 的 out=802,816B 同理。
**⇒ 把 tb_nn_engine 的 `nn_mem #(.A_BYTES(...))` 单纯调大是无效的**（A 仍被 96KB 卡住）。要跑整张量只能改 `NN_B_OFF`/存储契约，不建议为调试动契约。
**可行替代**：banded wall test（本文件 §1，已 PASS）或静态大容量模型（我正在做，尚未可信，见 §4）。

## 3. 新证据 B：rtl-mem 报告"b 写末拍 b_wdata 全 X"的引擎侧判读

- 在 wall/band 模式（输入全 defined）下，**末拍 b_wdata 是 defined 的**（我的 band 测试与静态模型 dump 均未出现 X，输出与 golden 逐字节一致）。
- X 只可能来自**上游输入 X 的传播**：引擎 b_wdata 的组合路径 = `{out_hi[px], out_lo[px]}`（`out_lo/out_hi` 在复位时全清 0，`nn_conv_engine.sv:733`），其来源只有 `rq_pack`（由 `acc_sel/m_sel/y2_q/...` 全在复位清零）。若上游 `a_rdata/w_rdata/q_rdata` 有一拍为 X，就会污染对应像素/OC lane。
- 末拍对应**最后像素/最后 OC tile**，若 tilecache 在 band 收尾的最后一个 a 读返回 X（例如 band 边界/末行 fill 未完成），恰好只污染最后一拍 ⇒ 与"X 只在末拍"吻合。
- **建议 rtl-stream 检查**：band 收尾前最后一个 `a_re`（band 最后一行/最后一列附近的读）时 `a_rdata` 是否为 X（tilecache fill 未覆盖或 OBUF/IBUF 边界读），以及 `engine_done` 与最后一次 fill 的握手顺序。

## 4. 静态大容量模型（正在调，暂不作为证据）

我写了 `perf-proto/tb_op3_static.sv`（按 stock nn_mem 端口契约的自定义大容量存储），**当前整张量/13 行 band 都 100% mismatch**，但 **stock nn_mem band 却 PASS** ⇒ 我的模型在 W/Q 读流水或 X 初值上有 bug（未定位），**不能据此说引擎错**。若要继续这个实验，建议 rtl-mem 侧的"调大 nn_mem 参数"方案先确认 A 窗口限制（§2），否则建议直接采用 banded wall test 作为裁决。

## 5. 给 rtl-stream 的 tile 模式差异清单（症状指纹）

| 端口 | stock nn_mem（wall，PASS） | tilecache（tile，FAIL）需核对 |
|---|---|---|
| `a_re/a_addr/a_sel` | a_sel 必与地址窗口一致；a_addr 是 **NN 窗口绝对字节地址**（16B 对齐窗口；a_addr[3] 选 8B 半窗） | tilecache 里 `a_local = a_addr - base` 后 `a_word = a_local[IB_AW+3:4]`；**确认 base 减法前 a_addr 已是引擎给出的绝对地址**、且 16B 对齐窗口语义一致 |
| `a_rdata` 延迟 | **1 拍**（地址 N → 数据 N+1），有效窗口外/归属错 ⇒ **0**（不是 X） | 若 band 边界返回 **X**（而不是 0）会污染末拍 ⇒ 与 rtl-mem 的 X 现象一致 |
| `b_we/b_addr/b_wdata/b_wstrb` | 1 拍写；`b_wstrb` 逐字节；b_addr 16B 对齐 | 确认 strobe 逐字节生效、且 OBUF 地址不截断 |
| `w_q` 延迟 | W/Q 读固定 2 拍（引擎无 wait） | band 模式下若 W/Q 与 fill 重叠，必须保持固定 2 拍 |

**最可能的差异点（与"末拍 X"一致）**：tilecache 在 band 收尾时对 `a_rdata` 返回 X/未定义，而 stock nn_mem 对越界返回 0 —— 引擎对此没有容错（按契约输入必须 defined）。


## 6. vary-src 实验（wall 模式，回应 Lead 的绝对地址泄漏假设）

同一 W/Q/A、同一 band，只改 desc.src（A 数据同步搬到对应地址）：

| test | rows | src | 结果 |
|---|---:|---|---|
| A | 4 | 0x60000 | **PASS**（mis=0） |
| B | 4 | 0x70000（A 数据搬 0x10000） | **PASS**（mis=0） |
| C | 13 | 0x60000 | **PASS**（mis=0） |

⇒ **引擎在合法 A 窗口内对任意 base 都正确**（输出与 golden 逐字节一致），未发现 d_src 绝对值泄漏到数据路径的问题；sel_a_src 只是 bank 选择（契约）。
⇒ tile 模式（src=0x20000）不在 A 窗口内，stock nn_mem 会返回 0；tilecache 用 base 减法映射后引擎侧行为应与上表 B 等价。**tile 模式 96% 失配 + 末拍 X 不支持'引擎 dense 路径 bug'的假设**：wall 模式同一数据/同一描述符形态全部 PASS，且 X 只能来自上游 _rdata 未定义（引擎无 X 源，out_lo/out_hi/acc 全部复位清零）。

## 7. 结论（task-20 裁决）

1. **引擎 dense 数据通路（含 ic 多 block、k=1、pad=0、vary base）在纯净室逐字节正确** — 证据见 §1/§6。
2. **整张量 wall 实验结构性不可行**（A 窗口 96KB 硬上限，§2）。
3. M6b 的失败在 **tilecache 的 band 数据/地址路径**：优先查 (a) band 收尾 _rdata 是否 X/0（与末拍 X 现象吻合），(b) band 行数是否按 
ow_bytes 推导（IBUF 16KB/OBUF 12KB per bank）。
