# nn_conv_engine.sv — int8 卷积引擎交付报告

> 负责人：T-accel。契约：`results/ai-accel/CONTRACT.md` v0.4（§5 量化 / §6 权重布局 /
> §7 Q 区变长布局 / §8 激活布局 / §9.2 端口 / §11 op 精确语义）。
> 本文所有数字都带**出处**（命令 / 日志文件 / 报告文件），"看起来对"不构成证据。

---

## 0. TL;DR（v2 / T-accel-R2 之后的状态）

| 项 | 结果 | 出处 |
|---|---|---|
| 功能 | **`ENGINE_TB: PASS (46 cases, mismatch=0)`**（conv1x1/3x3/5x5、depthwise、maxpool K=2/3/5/9、copy、2x upsample、add；非法描述符报 err） | `proto/engine/tb_v3_19.log`（v2 最终版） |
| 官方回归 | `python tools\fpga_workflow.py verify --only tb_nn_engine --force` → **PASS 3.2s** | 该命令输出 |
| 位精确 | A/B 缓冲**全区逐字** `!==`（X 也算错）；T-model 逐层重放 6 op mismatch=0 | `tb_v3_19.log`、`e2e_v2.log` |
| 周期公式 | v2 公式与 46 case **逐 case 相等**（误差 0），见 §0.5.6 | `proto/engine/case_table.md`（v2） |
| **时序（OOC 综合 @150MHz）** | **当前根目录快照（= bc2 拆法）= WNS +0.489 ns（MET）**，LUT 16,859 / FF 10,840 / DSP 39 / BRAM 124；旧 v2 冻结版为 +0.121。（OOC 无布线，仅作相对判据；全实现 150MHz 实测 post-place −4.020 → 150MHz 不可行，Lead 改打 **87.5MHz**） | `proto/engine/synth150_timing.rpt`、`synth150_util.rpt`；`draft/synth150_bc2_*.rpt` |
| 资源（同一 OOC 综合，engine+nn_mem 全上下文） | **LUT 16,859 / FF 10,840 / DSP48E1 39 / BRAM36 124**（124 = WQ 92 + ACT 32，符合预期） | `proto/engine/synth150_util.rpt` |
| 全模型周期（128 输入，当前 plan 87 个 HW op；**E2E 实测对齐**） | **1,290,062 拍**（v2 公式逐 op 求和 = 实测，差 **+0**）；**@150MHz = 8.60 ms/帧**；同一 plan 上 v1 公式 = 1,186,704，v2 慢 **8.7%**（流水化代价） | Lead `tb_sw_nn_yolo`（HW-only，PASS，hw_bad=0）；`proto/engine/est_full_model.py` → `full_model_estimate.md` |
| 与上一轮全实现对比 | v1 全实现 150MHz：WNS −18.416ns（fmax 39.9MHz）→ v2 OOC +0.121ns；关键链由 `d_ks→权重BRAM地址 24.5ns/32级` 拆成多级短链 | 本轮 §0.5.3/0.5.4 |
| **未达目标** | 目标是 OOC **≥ +2.0 ns**，当前 **+0.121 ns，还差 1.88 ns**；卡点与下一步拆法见 §0.5.5（结论：剩余路径是"短链密集"的控制/状态 CE + nn_mem 地址 mux，OOC 的 route 估计占 60% 也放大了差距） | §0.5.5 |
| 交付物变更 | `nn_conv_engine.sv` 已重写为 v2（端口/语义不变）；`sim/tb_nn_engine.sv` 增加 `+misall` 调试开关（判据不变）；新增 OOC 150MHz 综合脚本与报告（§0.5.2） | §0.5.2 |

---

## 0.5 T-accel-R2：时序流水化（v2）

> 本轮唯一目标：**把 150MHz 下的时序救回来**，功能/接口/数值语义冻结。以下所有数字
> 都来自 `results/ai-accel/proto/engine/` 下的综合报告（出处写在每行）。

### 0.5.1 任务与结果

- 起点（Lead 上一轮全实现实测）：150MHz 全实现 **WNS −18.416 ns**，最差路径
  `u_nn/u_eng/d_ks_reg[1] → u_nn/u_mem/u_wq/mem_a_reg/ADDRARDADDR[12]`，24.5ns / 32 级 /
  17×CARRY4 + 2×DSP48E1（权重地址生成）；次差为 requant 的 64 位乘/饱和 + acc 行选择。
- R2 做法（全部在 engine 内部，端口/契约不变）：把"每拍算大公式"改成
  **"预计算常量 + 递增计数器 + 多级流水"**，见 §0.5.3。
- R2 结果：**OOC 综合 150MHz WNS = +0.121 ns**（MET，`synth150_timing.rpt`），
  资源 LUT 17,634 / FF 11,073 / DSP 40 / BRAM 124（`synth150_util.rpt`）；
  `ENGINE_TB: PASS (46 cases, mismatch=0)`，46 case 周期与 v2 公式逐 case 相等。
- **注意**：OOC 综合没有布局布线，其 route 估计是"未放置"的乐观/粗略值；本报告只用它
  做**相对**改进判据（Lead 指定目标）。真实 fmax 要看下一轮全实现（含 P&R）数据。

### 0.5.2 OOC 综合方法与两个坑（必须先修，否则数字全错）

文件：`proto/engine/timing_wrap.sv`（engine + nn_mem 顶层）、`synth150.tcl`、`synth150.bat`；
产物：`synth150_util.rpt` / `synth150_timing.rpt` / `synth150_paths.rpt` / `synth150.log`。

复现：`cd results\ai-accel\proto\engine && synth150.bat`（Vivado 2018.3，xc7a100tfgg484-2）。

**坑 1（Lead 已指出）**：nn_mem 的 `ifdef SYNTHESIS` 分支里 WQ 阵列靠
`NN_WQ_INIT_A..D` 宏 `$readmemh` 初始化；宏没传 → 全 0 → 引擎权重/乘法/累加被常量折叠，
综合只剩 ~500 LUT / 0 BRAM / 0 FF（首版实测就是这样，无意义）。
修法：`synth_design ... -verilog_define $wqdefs`，其中

```tcl
set wqdefs "NN_WQ_INIT_A=\"$wq/wq_A.hex\" NN_WQ_INIT_B=\"$wq/wq_B.hex\" NN_WQ_INIT_C=\"$wq/wq_C.hex\" NN_WQ_INIT_D=\"$wq/wq_D.hex\""
```

- 宏值必须是**带引号的字符串**（直接展开进 `$readmemh`，否则 "syntax error near /"）；
- 4 个 define 必须在**一个空格分隔字符串**里（给 Tcl list 会给每个 define 加花括号）；
- split 文件在 `.fpga-cache/nn_wq_split/wq_{A,B,C,D}.hex`（65536/16384/8192/4096 行）。

**坑 2（本轮新发现）**：顶层 wrapper 如果只有 `busy/done/cycles/err_code` 这类控制输出，
引擎"写回 nn_mem、但没有任何可观测输出"的整条数据通路会被当死代码删掉，同样塌成
~500 LUT。修法：`timing_wrap.sv` 增加 `a_rdata_o / w_rdata_o / b_wdata_o` 三个观测口
（打一拍输出，不参与时序判定）。

自证门槛（综合后必须看到）：`BRAM36=124`、`FDRE≈1.0e4`、`DSP≈40`、`LUT≈1.7e4`；
否则说明宏/观测口没生效。`synth150.log` 里的 `DBG_CELLS_*` 行就是这条自证。

### 0.5.3 v2 拆了什么（按路径类型）

| # | v1 的"一拍大公式" | v2 的拆法 | 直接效果 |
|---|---|---|---|
| 1 | 权重地址 `woff + ((tap*IC8+ic)*OC8 + ocb*8)`，每拍 32 位乘加 | 改成**递增计数器** `wa_r += delta`；delta 三种（+OC8 / +OC8*(IC8-7) / +OC8*(1-(K-1)IC8)，见 §0.5.7-bug1），全部在 S_CPREP 预计算成寄存器 | 权重地址链 24.5ns → ~2 级加法 |
| 2 | 激活读地址 `src + ((y*iw+x)*IC8 + cb*8)` 每拍乘加 | `blk_base/band_base/la` 三个递增基址（S_NEXT/S_LDCAP/S_BI 小步进维护）；band 内 `la += dx*IC8` | 激活地址链 → 计数器 |
| 3 | 目的写地址 `dst + (lin*OC8 + cb*8)` | `wr_base` 由 S_NEXT 维护 + `wpx += px_bytes` 计数器；写口整体打一拍（`b_we_q/b_addr_q/b_wdata_q`） | 写口 address/enable 链 → 寄存器直出 |
| 4 | copy/add 地址每拍算 `(iy*iw+ix)*IC8` | `src_la/dst_la` 递增（+8 / 像素步长；upsample 用 OC8+8 / (2iw+1)OC8+8） | 计数器 |
| 5 | Q 地址 `qoff + ocb*32 + 相位` 组合 | `qa_r` 计数器 + 预计算表头 `qmb_r/qtb_r` | 短加法 |
| 6 | requant 一拍：acc 行 mux → 32x32 乘 → 64 位右移 → +zp → 饱和 → 打包 → 写 | **5 级流水**：acc/M 选择 → 乘法 → 右移 → +zp → 饱和打包 → 写（8 像素逐拍串行，流水重叠） | requant 链 → 每级 1 个运算 |
| 7 | MAC：BRAM 输出 → 字节选择 → 8x8 乘 → 累加 | 4 级：issue(capture A) → BRAM 返回寄存(wby_r) → 乘法（a_pipe2 对齐） → 累加（drain 3 拍） | 乘法输入/输出全寄存 |
| 8 | 描述符校验组合进 state | 2 级：S_INIT 打 flag → S_VCHK 合并；pad/oh/ow/常量预计算在 S_CPREP（6 拍流水） | d_* → state/地址链拆散 |
| 9 | S_NEXT 一拍做"判断+2 个 24 位加" | 拆 S_NEXT（预加 `row_base_*_n` + 决策）→ S_NEXT2（选择写入） | 每拍 1 个加法器 |
| 10 | 激活 in-bounds 判定每拍算 `y*iw+x` 再比较 | x 用递增计数器 `x_ld`，y 用递增寄存器 `y_ld` + 每 band 寄存的 `y_ok_r`；a_re/fill 只依赖寄存器 | 判定链 → 2~3 级比较 |
| 11 | `M_neg = (M_pos*3277+16384)>>>15` 一拍 | S_QLOAD 拆 2 拍（乘法 / 加法移位分开） | 每 OC tile +1 拍 |
| 12 | `d_ic/d_oc/d_flags` 直接进数据通路 | `pad_r/ic8_r/oc8_r/st2_r/oc_limit_r` 等预计算寄存器；`p1=IC8*OC8` 一次乘法，`w_dgrp/w_sub/d_row_step2` 全用加法/移位导出（避免 DSP 共享把 d_ks 拉进地址链） | 去共享乘法 |

**周期代价（v2 vs v1，已计入 §0.5.6 公式）**：
- 每个 op 固定 **+7 拍**（S_VCHK 1 + S_CPREP 6；v1 只有 S_INIT 1）；
- conv/dw 每个 OC tile **+1 拍**（S_QLOAD 2 拍）；
- conv/dw 每个输出块 **+6 拍**（MAC drain 2→3、S_REQ 9→13、NEXT 1→2）；
- pool/copy/add 每个输出块/字只多 NEXT +1 与固定 +7（写口延迟 1 拍对 FSM 不可见）。

### 0.5.4 WNS 迭代记录（全部为 `synth150` OOC、150MHz 约束、MET/VIOLATED 如实记录）

| 步 | 改动 | WNS(ns) | LUT | FF | DSP | BRAM |
|---|---|---|---|---|---|---|
| 0 | harness 修好（宏 + 观测口），v2 初版 | −6.070 | 17,930 | 8,920 | 41 | 124 |
| 1 | S_CPREP 6 级（pad/oh/ow/常量流水） | −4.604 | 17,587 | 9,468 | 41 | 124 |
| 2 | requant 拆 4 级（移位/加zp/饱和打包/写） | −3.511 | 17,587 | 9,468 | — | 124 |
| 3 | a_re 提前一拍 + fill 标记改用寄存 | −2.475 | 18,844 | 9,434 | — | 124 |
| 4 | S_NEXT 拆 2 拍 | −1.340 | 17,292 | 9,424 | — | 124 |
| 5 | 权重返回寄存（wby_r + a_pipe2 对齐） | −1.350 | 18,857 | 10,044 | — | 124 |
| 6 | 激活 in-bounds 改递增计数 + 权重步长去 DSP | −0.884 | 18,163 | 10,160 | — | 124 |
| 7 | st2_r 寄存 | −0.770 | 18,194 | 10,165 | — | 124 |
| 8 | 写口整体打一拍 | −0.524 | 18,860 | 10,293 | — | 124 |
| 9 | y_ld 递增（去 y 长链） | **+0.112** | 17,164 | 10,285 | 40 | 124 |
| 10 | requant +zp 再拆一级（5 级） | **+0.224** | 17,218 | 10,774 | 40 | 124 |
| 11 | S_QLOAD 拆 2 拍 | **+0.273** | 17,493 | 11,043 | 40 | 124 |
| 12 | oc_limit_r 寄存（收尾） | **+0.121** | 17,634 | 11,073 | 40 | 124 |

（WNS 在最后几步的抖动来自"最差路径换队"：+0.224/+0.273 时最差路径是
`d_ic→qa CE`/`mpos_q→mneg_q`；第 12 步后最差路径换到 `d_flags→state CE`，6.306ns。
最终交付数字以最后一次综合为准：**+0.121ns**。所有中间报告未删除，可复查。）

### 0.5.5 还差 1.88ns：卡在哪 + 下一步拆法

最终 OOC 最差路径（`synth150_paths.rpt`）：

| 路径 | slack(ns) | 延迟 | 说明 |
|---|---|---|---|
| `d_flags_reg[0] → state_reg[*]/CE` | +0.121 | 6.306ns | 控制：d_flags 参与 init_err/S_VCHK → state 的 CE 锥 |
| `d_ic_reg[4] → qa_r_reg[*]/CE` | +0.31 | ~6.3ns | Q 地址计数器 CE（已用 oc_limit_r 收窄） |
| `y64_q → out_word` | +0.39 | ~6.3ns | requant 饱和/打包级（64 位比较） |
| `dst_la → u_act ADDR*` | +0.55 | ~6.6ns 中 route 4.4ns | nn_mem 输入侧地址 mux（引擎侧已全寄存器化） |

**结论**：R2 后已无"单条 20ns 级"长链；剩下的是**许多条 6.3~6.5ns 的短链同时贴线**
（OOC 下 route 估计占 50~66%），所以再拆需要"全局再降 1~2 级 + 减少跨模块 mux"。
下一步（按性价比排序，供 Lead 决定是否做）：
1. **nn_mem 输入侧加寄存器**（需 T-mem 配合，接口时延契约改 1 拍）：把 `a_addr/b_addr/w_addr`
   在 nn_mem 内先打一拍再进 BRAM，可去掉 `dst_la→BRAM`、`wa_r→BRAM` 这类跨模块 mux 链
   （当前这些路径 slack ≈ +0.5，收益 ~0.5ns，但要改接口时延→不建议轻易动）。
2. **state/CE 控制再拆**：把 `init_err` 的 priority 链改成 one-hot flag 与（或）把
   `is_conv/is_pool/is_copy/is_add` 做成 4 个 one-hot 寄存器，state 转移用查表；预计 +0.5~0.8ns。
3. **requant 饱和级**：`y2_q` 的 64 位 fits 判断可先在 48 位（prod64 有效位）上做归约，
   或用两级比较（高位 OR 树 + 低位比较），预计 +0.3~0.5ns。
4. **全实现（P&R）优先**：OOC route 估计是未放置的保守值；同一 RTL 在上一轮全实现里
   有些路径比 OOC 好 2~3ns（也有更差的）。建议下一轮先跑**一次全实现 150MHz** 拿到真实
   WNS，再决定是否继续拆（很可能全实现已经在 −1~+1ns 区间，比 OOC 更接近真实）。

### 0.5.6 v2 周期公式与 46 case 实测对照

记：`ICB=ceil(IC/8)`，`OCB=ceil(OC/8)`，`OH/OW` 为输出尺寸，
`NB=OH*ceil(OW/8)`（dense/dw），`BASE=8`（INIT 1 + VCHK 1 + CPREP 6），
`Q=10`（S_Q 8 + S_QLOAD 2），`DRN=3`（MAC 4 级流水 drain），`REQ=13`（requant 5 级 + 写尾），
`NEXT=2`（S_NEXT + S_NEXT2）。

```
conv (dense):
  count = (K==1) ? 8 : 7*ST+K
  sub   = (K==1) ? ICB : K*ICB
  per   = (count+1) + (K==1?0:1) + 8*K      # LD + LDCAP + WI + MAC
  cyc   = BASE + OCB*Q + OCB*NB*(1 + sub*per + DRN + REQ + NEXT)

depthwise:
  count = 7*ST+K
  per   = count + 2 + K                     # LD + LDCAP + WI + K MAC
  cyc   = BASE + OCB*Q + OCB*NB*(1 + K*per + DRN + REQ + NEXT)

maxpool:
  NB  = ICB * OH * ceil(OW/8)
  per = count + 2 + K
  cyc = BASE + NB*(1 + K*per + 8 + NEXT)

copy/upsample:  cyc = BASE + IH*IW*ICB*(5 if UP2X else 2)
add:            cyc = BASE + IH*IW*ICB*3
```

与 v1 的差异（每 op/块）：`+7`（BASE 1→8），conv/dw 每 OC tile `+1`（Q 9→10），
conv/dw 每输出块 `+6`（DRN 2→3、REQ 9→13、NEXT 1→2）。

**46 case 实测 vs 公式（全部相等；来源 `proto/engine/tb_v3_19.log` + `case_table.md`）**：

| case | op | k/st/pad | in HxW | out HxW | IC->OC | 实测 cyc | 理论 cyc | misA,misB |
|---|---|---|---|---|---|---|---|---|
| conv1x1_s1 | conv/dw | 1/1/0 | 8x10 | 8x10 | 8->8 | 594 | 594 | 0,0 |
| conv1x1_s1_i3o5 | conv/dw | 1/1/0 | 6x7 | 6x7 | 3->5 | 234 | 234 | 0,0 |
| conv1x1_s2 | conv/dw | 1/2/0 | 12x12 | 6x6 | 8->8 | 234 | 234 | 0,0 |
| conv1x1_oc24 | conv/dw | 1/1/0 | 5x20 | 5x20 | 8->24 | 1658 | 1658 | 0,0 |
| conv1x1_i13o13 | conv/dw | 1/1/0 | 6x6 | 6x6 | 13->13 | 664 | 664 | 0,0 |
| conv3x3_s1p1 | conv/dw | 3/1/1 | 9x10 | 9x10 | 8->8 | 2304 | 2304 | 0,0 |
| conv3x3_s1p0 | conv/dw | 3/1/0 | 7x5 | 5x3 | 8->8 | 653 | 653 | 0,0 |
| conv3x3_s2p1 | conv/dw | 3/2/1 | 14x13 | 7x7 | 8->16 | 2100 | 2100 | 0,0 |
| conv3x3_s2p0 | conv/dw | 3/2/0 | 12x11 | 5x5 | 16->8 | 1403 | 1403 | 0,0 |
| conv3x3_i13o13 | conv/dw | 3/1/1 | 8x9 | 8x9 | 13->13 | 7548 | 7548 | 0,0 |
| conv5x5_s1p2 | conv/dw | 5/1/2 | 9x8 | 9x8 | 8->8 | 2619 | 2619 | 0,0 |
| conv5x5_s2p2 | conv/dw | 5/2/2 | 14x13 | 7x7 | 8->8 | 2286 | 2286 | 0,0 |
| conv5x5_i16o16 | conv/dw | 5/1/2 | 8x8 | 8x8 | 16->16 | 8972 | 8972 | 0,0 |
| conv1x1_bigM | conv/dw | 1/1/0 | 5x5 | 5x5 | 8->8 | 198 | 198 | 0,0 |
| conv1x1_mixM | conv/dw | 1/1/0 | 6x6 | 6x6 | 8->8 | 234 | 234 | 0,0 |
| conv3x3_shift10 | conv/dw | 3/1/1 | 7x7 | 7x7 | 8->8 | 907 | 907 | 0,0 |
| conv1x1_srcoff8 | conv/dw | 1/1/0 | 5x6 | 5x6 | 8->8 | 198 | 198 | 0,0 |
| conv1x1_srcB | conv/dw | 1/1/0 | 6x6 | 6x6 | 8->8 | 234 | 234 | 0,0 |
| conv3x3_srcB | conv/dw | 3/1/1 | 8x8 | 8x8 | 16->8 | 1898 | 1898 | 0,0 |
| conv1x1_bigbias | conv/dw | 1/1/0 | 5x5 | 5x5 | 8->8 | 198 | 198 | 0,0 |
| dw3x3_c8 | conv/dw | 3/1/1 | 9x10 | 9x10 | 8->8 | 1170 | 1170 | 0,0 |
| dw3x3_c16 | conv/dw | 3/1/1 | 8x8 | 8x8 | 16->16 | 1052 | 1052 | 0,0 |
| dw3x3_c24 | conv/dw | 3/1/1 | 6x7 | 6x7 | 24->24 | 1190 | 1190 | 0,0 |
| dw3x3_c13 | conv/dw | 3/1/0 | 7x8 | 5x6 | 13->13 | 668 | 668 | 0,0 |
| dw3x3_s2 | conv/dw | 3/2/1 | 12x11 | 6x6 | 8->8 | 528 | 528 | 0,0 |
| dw5x5_c8 | conv/dw | 5/1/2 | 9x8 | 9x8 | 8->8 | 1044 | 1044 | 0,0 |
| dw5x5_c16 | conv/dw | 5/1/2 | 8x9 | 8x9 | 16->16 | 3676 | 3676 | 0,0 |
| dw5x5_s2 | conv/dw | 5/2/2 | 14x13 | 7x7 | 8->8 | 1061 | 1061 | 0,0 |
| pool2_s2p0 | pool | 2/2/0 | 8x8 | 4x4 | 8->8 | 212 | 212 | 0,0 |
| pool2_s2p1 | pool | 2/2/1 | 8x7 | 5x4 | 8->8 | 263 | 263 | 0,0 |
| pool3_s1p1 | pool | 3/1/1 | 7x9 | 7x9 | 8->8 | 792 | 792 | 0,0 |
| pool3_s2p1 | pool | 3/2/1 | 12x13 | 6x7 | 8->8 | 470 | 470 | 0,0 |
| pool5_s1p2 | pool | 5/1/2 | 8x8 | 8x8 | 16->16 | 1704 | 1704 | 0,0 |
| pool9_s1p4 | pool | 9/1/4 | 12x11 | 12x11 | 8->8 | 6104 | 6104 | 0,0 |
| pool9_c13 | pool | 9/1/4 | 10x10 | 10x10 | 13->13 | 10168 | 10168 | 0,0 |
| pool2_s2_c24 | pool | 2/2/0 | 9x9 | 4x4 | 24->24 | 620 | 620 | 0,0 |
| pool3_srcB | pool | 3/1/1 | 7x7 | 7x7 | 8->8 | 400 | 400 | 0,0 |
| copy | copy/up | 1/1/0 | 7x6 | 7x6 | 8->8 | 92 | 92 | 0,0 |
| copy_c16 | copy/up | 1/1/0 | 5x6 | 5x6 | 16->16 | 128 | 128 | 0,0 |
| copy_oc16 | copy/up | 1/1/0 | 4x5 | 4x5 | 8->16 | 48 | 48 | 0,0 |
| ups2x | copy/up | 1/1/0 | 5x4 | 10x8 | 8->8 | 108 | 108 | 0,0 |
| ups2x_c16 | copy/up | 1/1/0 | 4x5 | 8x10 | 16->16 | 208 | 208 | 0,0 |
| add | add | - | 6x7 | 6x7 | 8->8 | 134 | 134 | 0,0 |
| add_c24 | add | - | 5x5 | 5x5 | 24->24 | 233 | 233 | 0,0 |
| add_srcB | add | - | 6x6 | 6x6 | 8->8 | 116 | 116 | 0,0 |
| add_same_buf | add | - | 5x6 | 5x6 | 16->16 | 188 | 188 | 0,0 |

> 吞吐对照（v1→v2，同 case，纯 MAC/拍）：conv5x5_i16o16 409,600 MAC/(8867→8972 拍)
> = 46.2→45.7；全模型估算见 §0.5.8。

### 0.5.7 v2 期间由 TB 抓出并修掉的 bug（全部是"位精确判据"抓到的）

| # | 症状 | 根因 | 修法 |
|---|---|---|---|
| 1 | conv/dw K>1 且 ICB>1 时输出大面积错 | 权重子块步长写错：从子块 (ky,icb) 末尾到下一个子块的地址增量不是 `8*OC8`，而是 `OC8*(1-(K-1)*IC8)`（可负） | `w_sub` 用 24 位补码预计算；kx 组边界用 `OC8*(IC8-7)` |
| 2 | copy 且 oc>ic 时 dst 整体错位 | copy 目的像素步长应是 `OC8-IC8+8`（目的 pixel stride 与源不同） | `cp_dst_pix` 预计算，ix/iy 前进用它 |
| 3 | requant 输出整块错 1~2 字节 | 加流水后 `a_pipe` 与 `wby_r` 相位差 1 拍 | 增加 `a_pipe2` 对齐（与 wby_r 同拍） |
| 4 | pool 全部 case 错 | `y_ld`（band y 递增寄存器）在 S_PINIT 没初始化（只有 conv 的 S_BI 有） | pool 首个 band 也置 `y_ld <= y_ky0` |
| 5 | 所有写口无写（全 0） | 写口打拍后忘记把 `b_we <= b_we_q` 接回端口（b_we 悬空=0） | 补 `assign b_we = b_we_q` |
| 6 | 首个 band 首字捕获 X → 一个像素错 | 组合 `ld_inb` 在复位后首拍含 X（变量比较/共享逻辑），fill 标记写进 abuf | fill/使能改由"已寄存的合法性"驱动（`a_re_r`）+ fill 用寄存器推导；后续版本直接用递增 x_ld/y_ok_r 彻底消除 |

### 0.5.8 v2 新增文件与复现命令

| 文件 | 作用 |
|---|---|
| `proto/engine/timing_wrap.sv` | OOC 顶层：engine + nn_mem + 3 个数据观测口 + CPU 自由计数器（让 WQ RAM 可写） |
| `proto/engine/synth150.{tcl,bat}` | 150MHz OOC 综合（含 WQ 宏、时钟/IO 约束、report） |
| `proto/engine/synth150_{util,timing,paths}.rpt`、`synth150.log` | 资源 / WNS / top-20 路径 / 综合日志 |
| `proto/engine/vec_e2e/`、`make_e2e_case.py`、`run_e2e.bat` | T-model 逐层"单 op 重放"（6 个代表层 mismatch=0，见 §11） |
| `proto/engine/case_table.md`（v2）、`calc_cycles.py`、`mk_table.py` | 46 行实测 vs 公式表 |

```bat
rem 1) 功能：TB（46 case）        -> ENGINE_TB: PASS (46 cases, mismatch=0)
cd results\ai-accel\proto\engine && run_tb.bat
rem 2) 官方回归
python tools\fpga_workflow.py verify --only tb_nn_engine --force
rem 3) 150MHz OOC 综合（先看 DBG_CELLS_* 自证 BRAM=124，再看 WNS）
cd results\ai-accel\proto\engine && synth150.bat
rem 4) 周期公式对照（v2）
python results\ai-accel\proto\engine\calc_cycles.py tb_v3_19.log
```

### 0.5.9 冻结快照、A 方案（全实现）与 E2E 实测

**（历史）v2 冻结快照**（R41 纪律；已按 Lead 指令于 2026-11-01 00:38 切换为 bc2，见下）：
`nn_conv_engine.sv` **44,071 B，SHA256 = `099D926118BE2F7368578A45D59F37433994CFF90AEDC310FA9FDED9A38E4171`**
（2026-11-01 00:11:04；本报告 §0.5.1–0.5.8 的所有 OOC 数字都对应这份文件；备份在
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
**OOC 综合的 route 是"未放置"估计，不能替代全实现**，本报告的 OOC 数字只用于相对改进。

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
| `nn_conv_engine_v2bc2.sv` | B+C + **base0_a 两级拆分**（`pad*row_step` 先寄存，下一拍只减法） | PASS 46/46 | **+0.489 → 已应用为当前根目录快照**（`27d59a87…`） | 16,859 / 10,840 / 124 |
| `nn_conv_engine_v2bc3.sv` | bc2 + `icb_n_r` 寄存 + **band 基址增量提前到 S_LD 末拍**（无新状态/无新流水段，46 周期不变） | PASS 46/46 | **+0.585（可选草稿，未应用）**；新瓶颈 `d_iw[0] → row_base_w_n`（6.08ns） | 16,410 / 10,859 / 124 |

- 每个草稿的 TB 证据：`draft/tb_b.log` / `tb_c.log` / `tb_bc.log` / `tb_bc2.log`；
- 综合证据：`draft/synth150_{b,c,bc,bc2}_{util,timing}.rpt`；
- bc2 的最差路径变成 `c_icb[4] → la_reg[23]`（6.18ns，band 基址选择/加法）；bc3 把它拆掉后最差变
  `d_iw[0] → row_base_w_n`（6.08ns，`row_step_w` 锥）；
- B 与 C 互不冲突，可叠加；**bc2 比冻结版 +0.37ns**，但离 OOC +2.0 仍差 1.5ns（剩余为 la/band 基址 + nn_mem 地址 mux + OOC 未放置 route 估计）。

复现草稿（不改根目录）：
```bat
cd results\ai-accel\proto\engine
python gen_drafts.py            rem B/C (会打印源 SHA256)
python gen_draft_bc2.py         rem B+C+base0 两级
draft\run_tb_draft.bat nn_conv_engine_v2bc2.sv
draft\synth150_bc2.bat
```

> **注意 (v1 §1-§11 的历史性)**：§1 起的正文是 v1（R1）交付时写的，其中的周期公式/资源
> 数字是 v1 的；v2 的最终数字以本节 §0.5 为准。v1 的架构描述（§2）与验证方法（§4）仍然
> 适用；v2 只改流水/地址生成，端口、Q/权重/激活布局、数值语义未变。

---

## 1. 交付物清单

| 文件 | 作用 |
|---|---|
| `nn_conv_engine.sv` | 引擎本体（根目录，已登记进 Lead 的 RTL 清单；**本文件已冻结**） |
| `sim/tb_nn_engine.sv` | 自校验 TB（46 case，阶段 A；已登记进 verify 矩阵） |
| `results/ai-accel/proto/engine/gen_vectors.py` | **独立** Python 全整数 golden + 向量生成器（期望值不来自 RTL） |
| `results/ai-accel/proto/engine/vec/` | 生成的向量（`manifest.txt` + `<case>.{wq,a,b,aexp,bexp}.wr`，46 case × 5 文件） |
| `results/ai-accel/proto/engine/run_tb.bat` | 跑 TB（ModelSim 命令行，env 显式补齐） |
| `results/ai-accel/proto/engine/run_dbg.bat` / `debug_tb.sv` | 临时调试入口（非交付，留作复现 bug） |
| `results/ai-accel/proto/engine/synth_engine.{tcl,bat}` + `synth_engine_util.rpt` | 资源估算的 Vivado 脚本与报告 |
| `results/ai-accel/proto/engine/compile.bat` | 只编译检查（vlib/vlog） |

---

## 2. 微架构

```
        desc (nn_desc_t) ──► 描述符锁存 + 合法性检查
                                   │
    ┌──────────────────────────────┴──────────────────────────────────┐
    │                              FSM                                │
    │ IDLE→INIT→[Q]→BI→(LD→WI→MAC)…→DRN→REQ→NEXT │ PINIT→(LD→WI→PMAX)…  │
    └──────┬───────────────┬──────────────────────┬───────────────────┘
           │w 口 64b/拍    │a 口 128b/拍          │b 口 64b/拍
           ▼               ▼                      ▼
      权重/Q 读地址    band 装载(1 字/拍)      requant/pool/copy/add 写
           │               │
           │          abuf[24]×64b ──► bshift[15]×64b (按 kx 移位)
           │                               │ win[8]×64b (px*stride 选)
           ▼                               ▼
      wp[8]int8 ──► 64× {8x8 有符号乘} ──► prod[8][8]int16 ──► acc[8][8]int32
      (1 拍延迟)          (每拍 64 MAC)         (+2 拍流水)      │
                                                               ▼
                          requant: 8 个宽乘法器(32×32→64) × 8 拍
                          out = clamp((acc*M)>>>SHIFT + zp_out)  ──► b 口写
```

### 2.1 PE 阵列与并行度

- `PX_LANES=8` × `OC_LANES=8` = **64 个 int8 乘法/拍**（output-stationary，像素并行）。
- 每个输出块 = 8 个输出像素 × 8 个输出通道；被乘数 A 操作数按像素 lane 广播/逐字节，
  B 操作数 = 权重字 8 个字节（每拍 1 个 64 位权重读）。
- 累加器 `acc[8][8]` int32；乘积累加流水 = issue(读权重) → prod(寄存) → acc(加) 三级，
  **吞吐 1 拍/(tap,ic)，延迟 2 拍**（输出块结束的 2 拍 drain 已计入周期公式）。

### 2.2 激活的"转置"与窗口复用

激活 BRAM 布局是 NHWC + 8 通道字（CONTRACT §8），一个 64 位字 = 一个像素的 8 通道。
卷积需要"8 个像素的同一通道"广播到 8 个像素 lane，因此：

1. **band 装载**：`abuf[band_idx] = 一个像素的 8 通道字`（像素主序）。
   一次读 64 位（a 口 128 位只用其中一半，`a_addr[3]` 选半字）。
2. **bshift 移位窗口**：`bshift[i] = band[i+kx]`，每换一个 kx 把 bshift 整体移 1 位、
   尾部从 `abuf[15+kx]` 补入；`win[px] = bshift[px*stride]`。
   这样**每行 band 只装一次，K 个 kx 复用**，避免 K 倍重复读。
3. dense：`A[px][oc] = win[px]` 的第 `c` 字节（广播到 8 个 oc lane）；
   depthwise/pool：`A[px][oc] = win[px]` 的第 `oc` 字节（逐字节对应）。

### 2.3 requant（CONTRACT §5 v0.4，全整数 floor）

- Q 区只存 `M_pos` int16；引擎在 **OC tile 装载阶段**现算
  `M_neg = leaky_en ? (M_pos*3277 + 16384) >>> 15 : M_pos`（int32 运算，M_pos 符号扩展）。
- `y64 = (acc>=0 ? acc*M_pos : acc*M_neg)`（**64 位有符号乘积**，32×32→64）；
  `out = clamp((y64 >>> SHIFT) + zp_out, -128, 127)`；`>>>` = 算术右移 = floor。
- 8 个像素分 8 拍串行做乘法（8 个乘法器），打包/写回与乘法流水重叠
  → requant+write = **9 拍/输出块**（`c_p = 0..8`）。
- 输出 padding 通道（`oc` 到 `OC_pad`）写 `zp_out`（量化零，CONTRACT §8 "未用通道填 zp_a"）。
- **不存 M_neg、per-oc `sh[]` 不读**：SHIFT 取尾部 `[3]` 字节（本版全层统一 16；
  TB 里也测了 SHIFT=10 的 case）。若将来要支持逐 OC 不同 SHIFT，需扩 Q 读取（见 §8）。

### 2.4 Q 参数读取（v0.4 变长紧凑布局，走 w 口）

每个 OC tile 读 **7 次 64 位** + 1 拍算 M_neg：

| 读 | 地址 | 内容 |
|---|---|---|
| 0..3 | `qoff + ocb*32 + i*8` | `bias_adj[8]` int32（4×64b） |
| 4..5 | `qoff + 4*OC_pad + ocb*16 + i*8` | `M_pos[8]` int16（2×64b） |
| 6 | `qoff + 6*OC_pad` | tail：`[0]=zp_out [1]=zp_in [2]=leaky_en [3]=SHIFT` |

地址口径 = NN 窗口绝对字节偏移（CONTRACT §9.1 v0.2 起），8 字节对齐，小端。

### 2.5 FSM

| 状态 | 作用 | 周期 |
|---|---|---|
| `S_IDLE` | 等 start，锁存描述符 | - |
| `S_INIT` | 合法性检查（非法 → `S_FIN` + `err_code`，不写内存） | 1 |
| `S_Q` / `S_QLOAD` | 读 Q 参数 / 算 M_neg（每 OC tile 一次） | 8 + 1 |
| `S_BI` | `acc = bias_adj` | 1 |
| `S_LD` / `S_LDCAP` | band 装载（1 字/拍）+ 等最后返回 | L + 1 |
| `S_WI` | 初始化 bshift | 1（dense K=1 跳过） |
| `S_MAC` | 64 MAC/拍流水 | dense `8*K`；dw/pool `K` |
| `S_DRN` | MAC 流水 drain | 2 |
| `S_REQ` | requant（8 拍乘法）+ 打包写回（重叠） | 9 |
| `S_NEXT` | 推进 (oxg, oy, ocb) | 1 |
| `S_PINIT` / `S_PMAX` | pool：mx 清 -128 / 64 路 max | 1 / K |
| `S_PPACK` | pool 写回 8 个字 | 8 |
| `S_CP_RD`/`S_CP_WR` | copy：读 1 字 → 写 1 份（或 upsample 4 份） | 1 + (1 或 4) |
| `S_AD_R1/R2/WR` | add：读 src、读 dst、饱和加写 | 3 字/像素块 |
| `S_FIN` | `done` 单拍脉冲 | 1 |

`err_code`（0x00=OK）：0x11/12/13 conv k/stride/pad 非法；0x14/15 ic,oc/ih,iw 非法；
0x16 depthwise 但 oc≠ic；0x21..0x25 pool 参数非法；0x31..0x33 copy 参数非法；
0x41..0x43 add 参数非法；0x18 oh/ow 会算成 0。

---

## 3. 周期公式与实测对照

记：`ICB = ceil(IC/8)`，`OCB = ceil(OC/8)`，`ceil8(x)=ceil(x/8)*8`，
`OH=(IH+2PAD-K)/ST+1`，`OW=(IW+2PAD-K)/ST+1`，输出块 = 8 像素 × 8 通道。
所有"周期数"= `cycles` 输出寄存器的值（= 除 `S_IDLE/S_FIN` 外的状态拍数；`busy` 会多 1 拍）。

```
conv (dense):
  L  = (K==1) ? 8 : 7*ST+K                 # band 装载字数 (K==1 时按 stride 跳采)
  NB = OH*ceil(OW/8)                       # 每个 OC tile 的输出块数
  sub = (K==1 ? 1 : K)*ICB                 # (ky,icb) 子块数
  per_sub = (L+1) + (K==1 ? 0 : 1) + 8*K   # 装载 + 窗口初始化(可选) + MACN
  block = 1(BI) + sub*per_sub + 2(DRN) + 9(REQ) + 1(NEXT)
  cycles = 1(INIT) + OCB*(8+1)(Q) + OCB*NB*block

depthwise:
  L = 7*ST+K;  block = 1 + K*((L+1)+1+K) + 2 + 9 + 1
  cycles = 1 + OCB*9 + OCB*(OH*ceil(OW/8))*block

maxpool:
  L = 7*ST+K;  NB = ICB*OH*ceil(OW/8)
  block = 1(PINIT) + K*((L+1)+1+K) + 8(PPACK) + 1(NEXT)
  cycles = 1 + NB*block

copy/upsample:
  words = IH*IW*ICB;  cycles = 1 + words*(UPS2X ? 5 : 2)

add:
  words = IH*IW*ICB;  cycles = 1 + words*3
```

**实测 vs 理论（46 case 全等）**——来源 `proto/engine/tb_run10.log`（TB 逐 case 打印 `cyc=`）：
生成脚本 `proto/engine/calc_cycles.py`（理论公式）/ `mk_table.py`（本表）。

| case | op | k/stride/pad | in HxW | out HxW | IC->OC | 实测 cyc | 理论 cyc | mismatch(A,B) |
|---|---|---|---|---|---|---|---|---|
| conv1x1_s1 | conv/dw | 1/1/0 | 8x10 | 8x10 | 8->8 | 490 | 490 | 0,0 |
| conv1x1_s1_i3o5 | conv/dw | 1/1/0 | 6x7 | 6x7 | 3->5 | 190 | 190 | 0,0 |
| conv1x1_s2 | conv/dw | 1/2/0 | 12x12 | 6x6 | 8->8 | 190 | 190 | 0,0 |
| conv1x1_oc24 | conv/dw | 1/1/0 | 5x20 | 5x20 | 8->24 | 1378 | 1378 | 0,0 |
| conv1x1_i13o13 | conv/dw | 1/1/0 | 6x6 | 6x6 | 13->13 | 583 | 583 | 0,0 |
| conv3x3_s1p1 | conv/dw | 3/1/1 | 9x10 | 9x10 | 8->8 | 2188 | 2188 | 0,0 |
| conv3x3_s1p0 | conv/dw | 3/1/0 | 7x5 | 5x3 | 8->8 | 615 | 615 | 0,0 |
| conv3x3_s2p1 | conv/dw | 3/2/1 | 14x13 | 7x7 | 8->16 | 2007 | 2007 | 0,0 |
| conv3x3_s2p0 | conv/dw | 3/2/0 | 12x11 | 5x5 | 16->8 | 1365 | 1365 | 0,0 |
| conv3x3_i13o13 | conv/dw | 3/1/1 | 8x9 | 8x9 | 13->13 | 7347 | 7347 | 0,0 |
| conv5x5_s1p2 | conv/dw | 5/1/2 | 9x8 | 9x8 | 8->8 | 2557 | 2557 | 0,0 |
| conv5x5_s2p2 | conv/dw | 5/2/2 | 14x13 | 7x7 | 8->8 | 2236 | 2236 | 0,0 |
| conv5x5_i16o16 | conv/dw | 5/1/2 | 8x8 | 8x8 | 16->16 | 8867 | 8867 | 0,0 |
| conv1x1_bigM | conv/dw | 1/1/0 | 5x5 | 5x5 | 8->8 | 160 | 160 | 0,0 |
| conv1x1_mixM | conv/dw | 1/1/0 | 6x6 | 6x6 | 8->8 | 190 | 190 | 0,0 |
| conv3x3_shift10 | conv/dw | 3/1/1 | 7x7 | 7x7 | 8->8 | 857 | 857 | 0,0 |
| conv1x1_srcoff8 | conv/dw | 1/1/0 | 5x6 | 5x6 | 8->8 | 160 | 160 | 0,0 |
| conv1x1_srcB | conv/dw | 1/1/0 | 6x6 | 6x6 | 8->8 | 190 | 190 | 0,0 |
| conv3x3_srcB | conv/dw | 3/1/1 | 8x8 | 8x8 | 16->8 | 1842 | 1842 | 0,0 |
| conv1x1_bigbias | conv/dw | 1/1/0 | 5x5 | 5x5 | 8->8 | 160 | 160 | 0,0 |
| dw3x3_c8 | conv/dw | 3/1/1 | 9x10 | 9x10 | 8->8 | 1054 | 1054 | 0,0 |
| dw3x3_c16 | conv/dw | 3/1/1 | 8x8 | 8x8 | 16->16 | 947 | 947 | 0,0 |
| dw3x3_c24 | conv/dw | 3/1/1 | 6x7 | 6x7 | 24->24 | 1072 | 1072 | 0,0 |
| dw3x3_c13 | conv/dw | 3/1/0 | 7x8 | 5x6 | 13->13 | 599 | 599 | 0,0 |
| dw3x3_s2 | conv/dw | 3/2/1 | 12x11 | 6x6 | 8->8 | 484 | 484 | 0,0 |
| dw5x5_c8 | conv/dw | 5/1/2 | 9x8 | 9x8 | 8->8 | 982 | 982 | 0,0 |
| dw5x5_c16 | conv/dw | 5/1/2 | 8x9 | 8x9 | 16->16 | 3475 | 3475 | 0,0 |
| dw5x5_s2 | conv/dw | 5/2/2 | 14x13 | 7x7 | 8->8 | 1011 | 1011 | 0,0 |
| pool2_s2p0 | pool | 2/2/0 | 8x8 | 4x4 | 8->8 | 201 | 201 | 0,0 |
| pool2_s2p1 | pool | 2/2/1 | 8x7 | 5x4 | 8->8 | 251 | 251 | 0,0 |
| pool3_s1p1 | pool | 3/1/1 | 7x9 | 7x9 | 8->8 | 771 | 771 | 0,0 |
| pool3_s2p1 | pool | 3/2/1 | 12x13 | 6x7 | 8->8 | 457 | 457 | 0,0 |
| pool5_s1p2 | pool | 5/1/2 | 8x8 | 8x8 | 16->16 | 1681 | 1681 | 0,0 |
| pool9_s1p4 | pool | 9/1/4 | 12x11 | 12x11 | 8->8 | 6073 | 6073 | 0,0 |
| pool9_c13 | pool | 9/1/4 | 10x10 | 10x10 | 13->13 | 10121 | 10121 | 0,0 |
| pool2_s2_c24 | pool | 2/2/0 | 9x9 | 4x4 | 24->24 | 601 | 601 | 0,0 |
| pool3_srcB | pool | 3/1/1 | 7x7 | 7x7 | 8->8 | 386 | 386 | 0,0 |
| copy | copy/up | 1/1/0 | 7x6 | 7x6 | 8->8 | 85 | 85 | 0,0 |
| copy_c16 | copy/up | 1/1/0 | 5x6 | 5x6 | 16->16 | 121 | 121 | 0,0 |
| copy_oc16 | copy/up | 1/1/0 | 4x5 | 4x5 | 8->16 | 41 | 41 | 0,0 |
| ups2x | copy/up | 1/1/0 | 5x4 | 10x8 | 8->8 | 101 | 101 | 0,0 |
| ups2x_c16 | copy/up | 1/1/0 | 4x5 | 8x10 | 16->16 | 201 | 201 | 0,0 |
| add | add | - | 6x7 | 6x7 | 8->8 | 127 | 127 | 0,0 |
| add_c24 | add | - | 5x5 | 5x5 | 24->24 | 226 | 226 | 0,0 |
| add_srcB | add | - | 6x6 | 6x6 | 8->8 | 109 | 109 | 0,0 |
| add_same_buf | add | - | 5x6 | 5x6 | 16->16 | 181 | 181 | 0,0 |

> 吞吐（MAC/拍）示例：conv5x5_i16o16 理论 409,600 MAC / 8,867 拍 = **46.2 MAC/拍**（峰值 64）；
> conv1x1 类约 40~55；depthwise 约 9~10（受激活带宽限制，见 §8）；pool 为纯比较无 MAC。

---

## 4. 功能验证（位精确）

### 4.1 方法（独立参考，非循环论证）

1. `gen_vectors.py` 用 **Python int** 重算全部整数语义（acc/bias 用 int、乘法不截断、
   `>>` 即 floor），生成期望值；**不使用任何 RTL 输出**。
2. TB 通过 **CPU 窗口**把 W/Q 与 A/B 初值逐字写进真实 `nn_mem.sv`，跑 1 个 op 后
   把 A/B 缓冲的**受测区域全区逐字读回**，用 `!==` 与期望比较（X 也算 mismatch）。
3. 每个 case 都覆盖：descriptor 装配 → start 单拍 → busy/done 握手 → 逐字节回读比较。
4. 额外验证：非法描述符（conv ks=2）→ `err_code=0x11`、不写内存、`done` 正常脉冲。

### 4.2 判据输出（`tb_run10.log` 原文摘要）

```
ERRCASE invalid-desc : PASS (err=11, cyc=1)
SUMMARY cases=46 pass=46 fail=0 total_mismatch=0
  op=0 ( conv/dw) cases=28 fail=0 mismatch=0 max_cycles=8867
  op=1 (    pool) cases=9  fail=0 mismatch=0 max_cycles=10121
  op=2 (copy/ups) cases=5  fail=0 mismatch=0 max_cycles=201
  op=3 (     add) cases=4  fail=0 mismatch=0 max_cycles=226
ENGINE_TB: PASS (46 cases, mismatch=0)
```

覆盖的边角：stride 1/2、pad 0/1/2（pool K=9 的 pad=4）、IC/OC 非 8 倍数（3/5/13/24）、
OW 非 8 倍数（10/7/5/9/11/13）、多 OC 块（oc=24）、多像素组（ow=20）、
src/dst 在 A 或 B、非 16 字节对齐的 src 偏移（+8 → 走 a 口高半字）、
SHIFT=10、M_pos 大/小/mix、bias 大幅值（饱和路径）、upsample、同 buffer 的 add。

### 4.3 阶段 B（T-model 逐层向量）

Lead 正在做 E2E（`tb_sw_nn_yolo`，108 ops）。本 TB 结构（manifest + 逐 case 描述符）可以
直接扩展到逐层向量：把 T-model 的 `l<NN>_*.hex` 按 §6/§7/§8 打包成 `wq.wr/a.wr/b.wr/aexp.wr`
即可复用同一 compare 框架（每个 op 独立 case，mismatch 计数不变）。

---

## 5. 资源实测

命令：`results/ai-accel/proto/engine/synth_engine.bat`
（Vivado 2018.3，`synth_design -top nn_conv_engine -part xc7a100tfgg484-2 -mode out_of_context`，
**无时钟约束** → 本报告不引用 fmax；报告文件：`proto/engine/synth_engine_util.rpt` / `synth_engine.log`）

| 资源 | 用量 | 器件总量 | 占比 | 任务/PLAN 预算 |
|---|---|---|---|---|
| Slice LUTs | **15,213** | 63,400 | 24.0% | PLAN 估 "+6~10K" → **超估**（Lead 已接受） |
| Slice Registers | **8,029** | 126,800 | 6.3% | ≤10K ✓ |
| DSP48E1 | **52** | 240 | 21.7% | ≤240 ✓（PLAN 估 72；Vivado 把 8×8 MAC 部分收进 LUT） |
| Block RAM Tile | **0** | 135 | 0% | PE 阵列不落 BRAM ✓（GEMM 教训不重犯） |
| F7 Muxes | 397 | 31,700 | 1.3% | - |

> LUT 偏高的主要来源（按模块分解的推断，未逐项做 report_hierarchy）：
> ① requant 的 `acc` 行选择（8 拍 × 8 lane × 32 位 8:1 mux）；
> ② bshift 窗口 + 可变字节选择 + pool 的 64 路 max；
> ③ 8×8 乘法有相当部分被综合成 LUT 乘法（DSP 仅 52）。
> **优化路径**（未做，留给后续）：给 MAC 乘寄存器加 `(* use_dsp = "yes" *)` 强行落 DSP；
> requant 的 8 拍行选择改成"转置累加器 + 列选择"或流水化；窗口选择改成 shift-register 直连。

整机预算（Lead 口径）：交付档 CPU ~3.1K LUT + 引擎 15.2K = ~18.3K / 63.4K，余量充足。

---

## 6. 全模型周期/吞吐估算（v1 数字，**已被 §0.5.10 作废**，仅作历史）

> v1 的 1,216,578 拍是旧 plan（105 HW op，含 18 个 HW add）下的估算；当前 plan 的
> 准确口径见 §0.5.10：**v2 = 1,290,062 拍 @150MHz = 8.60ms/帧，且与 E2E 实测完全相等**。
> 下面这段只说明 v1 当时的算法，不再作为交付结论。

按 §3 公式逐 op 求和（`cpu_conv0` / `cpu_concat` 由 CPU 做，不计；pool 的 pad=0 时按
(K-1)/2 推——plan 里 K=9 pool 显式 pad=4，v0.4 起可直接传）：

| op 类 | 个数 | 周期 | MAC |
|---|---|---|---|
| conv（含 1x1/3x3/dw 之外的 dense） | 55 | 777,430 | 16,279,552 |
| dwconv | 28 | 398,398 | 3,701,376 |
| add | 18 | 29,874 | 0 |
| pool | 3 | 9,915 | 0 |
| upsample | 1 | 961 | 0 |
| **合计（NPU 计算）** | 105 | **1,216,578** | **19,980,928** |

- @131.25 MHz：**9.27 ms/帧 ≈ 107.9 fps**（纯算力上限；E2E 还要加 CPU 层调度/搬运开销）
- @150 MHz（交付档 CPU 主频可到 150MHz，NPU 建议 131.25）：8.11 ms ≈ 123 fps
- 平均效率 16.4 MAC/拍（峰值 64）：dense 20.9、depthwise 9.3（详见 §8）
- 软件基线（PLAN §3）：逐 MAC 约 1.2~1.7 s/帧 → 预期 **≥100×** 加速

---

## 7. 已修 bug 记录（都是"数字不对"才发现，值得留档）

| # | 症状 | 根因 | 修法 | 定位方法 |
|---|---|---|---|---|
| 1 | 所有 conv/dw 输出近似"只有 bias"，但逐通道不同 | Q tail 的 `SHIFT` 取错字节：`w_rdata[23:16]` 是 `leaky_en` 字节，SHIFT 在 `[31:24]`；SHIFT 读成 1 导致右移错 | `shift_q <= w_rdata[31:24]` | 单 case 调试 TB dump `prod64`，发现 prod64 与手算一致但输出饱和；再看 QLOAD 打印 SHIFT=1 |
| 2 | 所有 ADD op 输出 = src（dst 读回 0） | ADD 要读 src 和 dst，但 `a_sel` 只由 `desc.src` 决定；src 在 A、dst 在 B 时 dst 读会返回 0（nn_mem 对 sel/地址不一致返回 0） | ADD 的 dst 读（`S_AD_R2`）把 `a_sel` 切到 dst 所在 buffer | 对比 src/dst 分处 A/B 的 case 全错、同 buffer 的正确 |
| 3 | pool 输出全错且与输入无关 | `S_WI` 无条件跳 `S_MAC`，pool 走进 MAC 路径（还读了 woff=0 的假权重 + 用上次 Q 参数 requant） | `S_WI: state <= is_pool ? S_PMAX : S_MAC` | dump FSM：pool case 从未进入 `S_PMAX` |
| 4 | upsample 只有 1/4 写出（其余 0） | nn_mem 的 `a_rdata` 只在 `a_re` 下一拍有效（之后回 0）；COPY 的 4 份写里后 3 份读到 0 | 读返回拍锁存 `cp_word_q`，c_wr=0 用 a_rdata、其后用锁存 | dump `S_CP_WR`：c_wr=1/2/3 的 `b_wdata=0` |
| 5 | OC 非 8 倍数时输出 padding 通道 = 0x03/0x00 | 打包 padding 通道写 `{zp_out[7],zp_out[7]}`（2 位拼接被零扩展） | `bb = zp_out` | 对比 exp/got 只在通道 5..7 不同 |
| 6 | pool K=9 输出尺寸算成 1x1（SPP 全错） | `nn_desc_t.pad` 原为 2 位，`pad=4` 被截成 0；oh/ow 公式用错 pad | v0.4 Lead 已加宽到 3 位；引擎 `d_pad[2:0]` 直接用 `desc.pad`（另留 `pad==0 → (K-1)/2` 防御分支） | 对照 T-model plan 的 pool pad=4 |

> 另：**Python golden 自身的 dw 语义 bug** 也修了一个（最初把 depthwise 写成"每个输出通道
> 累加所有输入通道"，正确是"输出通道 c 只用输入通道 c"）。TB 先红后发现是 golden 错而不是
> RTL 错——说明"独立参考"也要接受审查（但方向正确：先让 golden 与手算对，再比 RTL）。

---

## 8. 已知限制与优化路径

1. **性能（未做流水重叠）**
   - band 装载与 MAC 串行（`L+1` 拍装载 / `8*K` 拍 MAC）；dense 1x1 时装载占约 1/2 时间。
     优化：双 buffer（`abuf` 双份）把下一 (ky,icb) 的装载藏进当前 MAC；预计 dense +80~90%。
   - requant 8 个宽乘法串行 8 拍；可扩到 16 个乘法器（2 像素/拍）→ 5 拍。
   - depthwise 吞吐只有 ~9.3 MAC/拍：每个 (8px,8ch) 块要装 `7*stride+K` 个字才做 `K` 次
     64-lane MAC。优化：128 位读口一次取 2 个相邻像素（stride=1 时 band 装载减半）、
     或加"2 像素/拍 + 通道并行"模式（PLAN §7 已列风险）。
   - 128 位 a 口当前只用 1 个 64 位字（另一个空闲）；dense 且 `ICB==1` 时可用双字一次取
     2 个相邻像素，把装载减半（本次未做，TB 的 a 口口径已按"只用半字 + 半字选择"验证）。
2. **接口/契约口径**
   - `a_sel` 对 ADD 是**按当前读地址动态切**的（src 读用 src buffer，dst 读用 dst buffer）。
     CONTRACT §11 只给了"a_sel=(desc.src>=NN_B_OFF)"的规则，对"src/dst 分处 A/B 的 ADD"
     必须动态切；对 conv/pool/copy 与契约完全一致。已在代码注释里写死。
   - pool 输出 padding 通道（`c>=IC`）写 `0`；conv/dw 输出 padding 通道写 `zp_out`。
   - `NN_F_POOLMAX` 不参与逻辑（v1 只做 max，pool 一律取 max）。
   - conv 的 add-mode（`NN_F_ADD`）**未实现**（CONTRACT §11 允许 v1 后置，shortcut 用独立
     ADD op 覆盖）。
   - **per-OC `sh[]` 不读**：SHIFT 取 tail 的 `[3]`（全层统一）；Q 区 `+0xC00` 的 sh 数组不用。
   - `M_neg` 现算依赖 `leaky_en`（tail`[2]` 的 bit0）：非 leaky 层 M_neg=M_pos，
     否则 `(M_pos*3277+16384)>>>15`。
   - pool 的 `pad` 防御分支：`desc.pad==0` 时按 `(K-1)/2` 推（v0.4 起主路径用 desc.pad=4）。
3. **规模限制**
   - `band` 寄存器组 24 字：支持 `7*stride+K ≤ 24`，即 conv/dw K≤5,stride≤2（19）与
     pool K≤9,stride 1（16）/K≤2,stride 2 等；**pool K=9 stride=2 需要 24**（=23+1 富余，可用）。
   - `IC/OC ≤ 256`（ICB/OCB ≤ 32）；engine 内部用 16 位计数器，最大张量按 64KB/96KB 缓冲
     假设（不检查越界，由 nn_subsys 的 desc_ok + 软件契约保证）。
   - 单层 Q 块 `6*OC_pad+16` 字节（变长），qoff 由 T-model/C 软件按 Q 区顺序分配。

---

## 9. 复现命令

```bat
rem 1) 生成向量（自动从 nn_pkg.sv 解析地址/容量, 布局改了就重跑, R1）
cd results\ai-accel\proto\engine
python gen_vectors.py
rem 2) 跑 TB（ModelSim；env 由 bat 显式补齐, 不依赖会话 env）
run_tb.bat
rem 期望输出: ENGINE_TB: PASS (46 cases, mismatch=0)

rem 3) 官方入口（仓库根）
python tools\fpga_workflow.py verify --only tb_nn_engine
rem 期望: PASS tb_nn_engine

rem 4) 资源
synth_engine.bat
rem 期望: synth_engine_util.rpt 里 LUT 15213 / FF 8029 / DSP 48E1 52 / BRAM 0

rem 5) 理论周期对照
python calc_cycles.py   (读 tb_run10.log + vec/manifest.txt)
```

* `tb_run10.log` 是上面命令 2 的输出（UTF-16 重定向），`cycle_table.md`/`case_table.md`
  是周期对照表生成结果。
* 向量重新生成的唯一触发条件：`nn_pkg.sv` 的地址/容量常量变化（脚本自动解析，不手写死）。

---

## 10. 结论

引擎按 CONTRACT v0.4 实现并通过 46 个独立参考向量的**位精确**自检（mismatch=0），
周期行为与理论公式逐 case 一致；资源 FF/DSP/BRAM 在预算内，LUT 超 PLAN 估算但器件充足；
已接入 `nn_subsys` + `nn_mem`，E2E（`tb_sw_nn_yolo`）通路已通。
后续若 E2E 出现某个 op 的 mismatch，请把 op 编号 + 该层 `plan.json` 条目发给 T-accel，
按 §4/§11 框架可直接复现到具体 cycle。

---

## 11. 阶段 B：用 T-model 真向量**逐层重放**（并已用此定位一次 E2E mismatch）

### 11.1 工具

`results/ai-accel/proto/engine/make_e2e_case.py` + `run_e2e.bat`：
直接把 `sim/prog/yolo/l<op>_{in,w,q,out}.hex` 按 CONTRACT §6/§7/§8 打包成
单 op 重放的 A/B + W/Q 镜像（自动从 `nn_pkg.sv` 解析地址/容量），复用
`sim/tb_nn_engine.sv` 的装载/比较框架（`+vec=vec_e2e`）。覆盖 conv/dwconv/pool/upsample；
add/cpu_concat 需要 dst 初值，暂未支持。

### 11.2 重放结果（引擎部分**全部位精确**）

| op | kind | shape | k/s/p | 引擎 cycles | mismatch |
|---|---|---|---|---|---|
| 2 | dwconv | 64x64x8→8 | 3/1/1 (leaky, zp_in=-93, SHIFT=18) | 29,706 | **0** |
| 70 | conv | 4x4x136→48 | 1/1/0 | 7,303 | **0** |
| 93 | pool | 4x4x48→48 | 9/1/4 (pad=4, SPP) | 6,073 | **0** |
| 96 | dwconv | 4x4x96→96 | 5/1/2 | 5,293 | **0** |
| 100 | conv (head) | 4x4x96→255 | 1/1/0 (OC_pad=256) | 28,065 | **0** |
| 101 | upsample | 4x4x96→96 | 2/2 (2x) | 961 | **0** |

结论：**引擎对 T-model 的逐层期望输出是位精确的**（含 zp_in≠0 的空间 padding、逐层
SHIFT 17/18/23、OC=255 的通道 padding、pool pad=4）。因此 E2E 的 mismatch 只能来自
集成层（C 程序 / MMIO 描述符装配 / 调度）。

### 11.3 2026-10-31 E2E op2 mismatch 的根因（集成层，非引擎）

现场：`tb_sw_nn_yolo` HW-only，op0/op1 PASS，op2（dwconv k3 s1 p1）got=0xedb78029
exp=0x9985162c，之后 106 op 级联失败。

1. 用 §11.1 工具原样重放 op2（同一份 `l2_in/w/q/out`、同 woff/qoff、同 src/dst）：
   **PASS，mismatch=0，29,706 拍** → 引擎无罪。
2. 把 got checksum 反推：对 op2 的输入执行 **maxpool k=3, stride=1, pad=1**，
   其紧凑输出 FNV-1a 恰好 = **0xEDB78029**（= got）。即**引擎实际收到的是 op=1（POOL）**。
3. 根因：`sw/yolo_demo.c:271` 把 C 侧 `kind` 枚举**原样**写进 `MMIO_NN_OP`：
   ```c
   REG(MMIO_NN_OP) = o->kind;   /* 错: kind 0=conv,1=dwconv,2=pool,3=upsample,4=add */
   ```
   而 `NN_OP` 编码（CONTRACT §4）是 `0=conv/dwconv, 1=maxpool, 2=copy/upsample, 3=add`。
   于是 op2(dwconv) 被当成 pool 执行，后续全部级联错。
4. 建议修复（`sw/` 属 Lead 作用域，未由 T-accel 修改）：
   ```c
   static u32 hw_op_code(const yolo_op_t *o) {
       switch (o->kind) {
           case YK_CONV: case YK_DWCONV: return 0u;   /* NN_OP_CONV */
           case YK_POOL:                 return 1u;   /* NN_OP_POOL */
           case YK_UPSAMPLE:             return 2u;   /* NN_OP_COPY */
           default:                      return 3u;   /* YK_ADD -> NN_OP_ADD */
       }
   }
   ...
   REG(MMIO_NN_OP) = hw_op_code(o);   /* hw_run() 第 271 行 */
   ```
   其余描述符字段核对无误：C 表里 op2 flags=0x03(depthwise|leaky)、pool op91/92/93
   flags=0x10(poolmax) pad=1/2/4 k=3/5/9、op101 flags=0x08(UP2X) 都与契约一致；
   depthwise 由 `NN_FLAGS.bit0` 表达，不需要单独 op 码。
5. 修复后按 §11.2 的重放证据，剩下的 conv/dw/pool/upsample/add op 预期都能过；
   若仍有 mismatch，把 op id 发 T-accel，可 5 分钟内重放到具体像素。

> 纪律说明：本轮只改/新增了 `results/ai-accel/proto/engine/` 下的重放工具与本文档，
> `nn_conv_engine.sv` / `sim/tb_nn_engine.sv` **未改动**（engine 保持冻结），
> `tools\fpga_workflow.py verify --only tb_nn_engine --force` 仍 PASS。
