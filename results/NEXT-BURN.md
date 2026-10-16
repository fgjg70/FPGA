# 当前交付档（2026-10-16 起）—— 138.75 MHz 已上板验证 PASS

> 本文件由 Lead 维护：**每次换档就更新这里**。它只写"要做什么、期望看到什么、出问题怎么办"。
> 轨迹与"为什么"在 `results/CHANGELOG.md`，主频差距核实与结论在 `results/FREQ-VERDICT.md`。

## 1. 烧什么（已就绪、已上板验证过）

| 项 | 值 |
|---|---|
| 频率 | **138.75 MHz**（VCO = 50 × 22.2 = 1110 MHz, N=8；XDC `-multiply_by 111 -divide_by 40`） |
| 迭代 | **4600**（C-12c 后每迭代 463,366 拍） |
| 预期 tick | **2,131,483,600**（31 位占用 99.3%） |
| 采集等待 | **20 s**（内置） |
| 实测 | tick **2,128,330,451**（偏差 0.148%）／**15.34 s**／CoreMark/MHz **2.1613**／299.9 迭代/秒 |
| 两条流 | 评分流 WNS **+0.033** PASS；ILA 流 `ILA_TIMING=PASS`（WNS **+0.010**） |
| RTL 指纹 | `ca43541eeae9b4d42baa9652069ce4c53144b197547a691ba6b1d8f0333c2eca` |

**综合选项：两条流都用默认值。**（`-no_lc`/`-fanout_limit` 只在 150 档工具挣扎时有效，
在 138.75 档反而让余量变小；而且 Vivado 2018.3 的工程流**无法**通过
`STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS` 传选项 —— 两种拼写都报 `Common 17-170`，已实测。）

## 2. 命令（板子上电后）

```powershell
cd D:\USER\Desktop\FPGA\FPGA
cmd /c fpga\jtag_probe.bat        # 应识别到 xc7a100t_0 (Digilent/210512180081)
cmd /c fpga\ila_cap_done.bat      # 烧写 + 采集（内置 20 s 等待）
python tools\fpga_workflow.py hw  # 判读
```
全部满足才算 PASS：`ila_ctrl=0xC2`（locked/done/pass=1）· `score_result` bit31=1 ·
tick 偏差 ≤0.5% · 时长 ≥10 s · `dbg_pc` 静止在结尾 `j .`（`dbg_instr=0x0000006F`）。
**采集后尽快判读**（超过 20 分钟会判 STALE 并拒绝作为结论）。

## 3. 回退与对照（已上板验证过的档位，可随时回退）

| 档 | 迭代 | 配置要点 |
|---|---|---|
| **138.75 MHz** | 4600 | 当前交付（C-12c + 候选 E′） |
| 128.125 MHz | 3000 | 候选 B 树（无 C-12c，CoreMark/MHz 2.2063，10.61 s） |
| 118.75 / 105 / 75 MHz | 3000 | 更早的档位 |

**换档三处必须同源**（改一处就要改三处）：
`fpga/top_a100t.sv` 的 `.CLKFBOUT_MULT_F` / `.CLKOUT0_DIVIDE_F` / `.CLK_HZ` +
`fpga/daVinciPro.xdc` 的 `create_generated_clock -multiply_by/-divide_by`。
改完必须重跑 `python tools\mk_cm_hw.py <iters>`（它会重建镜像与 `cm_hw.build.json`），
再 `cmd /c fpga\build_ila.bat`。

## 4. 150 MHz 还差多少（诚实状态）

```
150 档: 评分流 WNS -0.172 (差 0.172ns) ; ILA 流还要再差 ~0.02~0.16 => 实际差 ~0.35ns
绑定族(150档, 做到 -0.172 时): 24 条 u_ex_mem/alu_out_reg/D + 13 条 u_imem/rdata_reg/ADDRARDADDR
```
已经用掉的手段（每项都实测）：C-12c（机制收益 +0.47ns 但 +2.08% ticks）、`-no_lc`、候选 E′、`-fanout_limit 128`。
**剩余可选手段**：①复位网走 BUFG／同步复位重构（第 3 族）②`alu_out_reg/D` 那 24 条＝EX 数据通路本体
（结构出路只有 ALU 流水化，代价远超 C-12c ⇒ 不建议）③取指地址锥（13 条，`C-8` 的老地盘）。

## 5. 已知环境坑（务必先看，避免误判）

1. **`IP_Flow 19-3505` 间歇故障**：建 ILA 像前必须**彻底清掉** `fpga/ila_proj.xpr` /
   `.srcs` / `.cache` / `.hw` / `.ip_user_files` / `.Xil`，并确认没有别的 Vivado 在跑；
   清干净后重试通常就过。**别把 IP 故障误记成"这一档时序不够"**（会白白降档）。
2. **Vivado 在"目标几乎不可行"时会确定性崩溃**（`EXCEPTION_ACCESS_VIOLATION`，
   rc=3221225477，常在 Phase 11 增量布局）：实测 `--fanout-limit 64` 与 `--retiming` 都触发。
   **崩溃有时是"设计不可行"的症状，不是工具坏了**。
3. **非单调性**：约束放松反而可能更差（工具早停）⇒ 选档只能实测，不能插值。
   实测：150 → −0.172；142.1875 → **−0.307**；138.75 → +0.033。
4. 编排脚本（`.ps1`/`.tcl`）**必须纯 ASCII**：Vivado 会把含中文的注释按 GBK 解码搞乱，
   而且**注释里别写方括号伪代码**（如 `Common 17-170` 那种带方括号的错误号）——
   回显时会被当命令替换。
5. `mk_cm_hw.py` 的**31 位 tick 闸门**：C-12c 使每迭代拍数升到 463,366 ⇒ 迭代上限降到 **4611**。
   越过它 `mk_cm_hw` 会 BLOCK 并提前返回（**镜像与 build.json 都不会更新**，看起来像"没报错"）。
