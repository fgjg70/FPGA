# `rtl/nn/` 这份 NPU 能不能用 —— 体检结论

> 取证时间 2026-11-04 13:40。对象：`fpga_pg2l100h/vision/rtl/nn/`（提交 `3d50f04`，已入库、已推远端）。
> 全部结论从 RTL 与报告原文取证，不引用转述。

---

## 0. 一句话

**引擎可以一用，而且它是这个仓库里唯一一个"可编程"的 NPU；子系统现在还不行，缺三样东西；
要在紫光板上真跑，还差两笔资源账 + 一次紫光重综合。**

分层给结论：

| 层 | 对象 | 判断 | 一句话理由 |
|---|---|---|---|
| L1 | `nn_conv_engine`（引擎本体） | ✅ **可用** | 58 cases 0 mismatch、纯 Verilog、122.22 MHz WNS +1.108、真 128 MAC/拍 |
| L2 | `nn_subsys`（子系统） | ⚠ **还不能** | 没接 SoC、没有权重、微码 ROM 是别人的模型 |
| L3 | 板上跑真模型 | ❌ **现在不能** | BRAM 超 38.5 KB、APM 87.5%、且全部证据是 Artix 不是紫光 |

---

## 1. 核过的事实（与用户给的清单逐条对齐）

| 项 | 用户说 | 实测 | 判 |
|---|---|---|---|
| `nn_full.v` | 4,817 行 · 7 模块 | 4,817 行 · **7 模块**：`nn_conv_engine` / `nn_mem` / `nn_seq` / `nn_wload` / `nn_wload_afifo` / `nn_tilecache` / `nn_subsys` | ✅ |
| `nn_core.v` | 2,628 行 · 引擎+存储 | 2,627 行 · `nn_conv_engine` + `nn_mem` | ✅ |
| `nn_pkg.sv` | 166 行 | **191 行** | ⚠ 数字过期 |
| `tb_nn_engine.sv` | 1,168 行 | **1,197 行** | ⚠ 数字过期 |
| 仿真 | 58 cases mismatch=0 | `xsim_pass.txt` 尾：`SUMMARY cases=47 pass=47 fail=0 total_mismatch=0` + `M1SUMMARY 9` + `SASUMMARY 2` = **58**，`ENGINE_TB: PASS (58 cases, mismatch=0)`，`$finish` 于 5,654,160 ns | ✅ |
| 序列器 | PASS | `NN_SEQ_TB: PASS (legacy starts=112 cycles=336 \| band ops=112 bands=4242 ...)` | ✅ |
| tilecache / wstream | 7/7、6/6 | 有独立日志 | ✅ |
| LUT | 30,996 | 30,996，**但分母是 63,400（Artix-7）**，且是 **`nn_conv_engine` 单模块 OOC**，不含 `nn_mem` | ⚠ 口径要补 |
| FF | 19,759 | 19,759 / 126,800（Artix） | ✅ |
| DSP | 200 | 200 / 240 = 83.33% | ✅ |
| 时序 | Setup +1.108 / Hold +0.158 | 时钟 `clk` 8.182 ns = **122.220 MHz**，WNS **+1.108**、WHS **+0.158**、`All user specified timing constraints are met`、50,528 端点 | ✅ |

**并行度确认**：`OC_LANES = 16`、`PX_LANES = 8` ⇒ **128 MAC/拍**。

**语法纯度确认**：`nn_full.v` / `nn_core.v` 中 `always_ff` / `always_comb` / `typedef` /
`logic [` / `interface` / `.*` 出现次数 **全为 0** ⇒ sv2v 转换干净，确实是纯 Verilog，
`nn_pkg.sv` 只剩 TB 需要。这一条对 PDS 很重要（紫光综合器对 SV 支持弱）。

**仿真可复现**：`sim.args` 指向 `results/ai-accel/proto/engine/vec`，该目录**在本分支存在** ⇒ 能复跑。

---

## 2. 但这份证据不是紫光的

`synth/` 下两份报告的头部：

```
Tool Version : Vivado v.2018.3
Design       : nn_conv_engine
Device       : 7a100t-fgg484           <-- Artix-7 XC7A100T
Speed File   : -2 PRODUCTION
```

`eng_util.txt` 里 `Slice LUTs 63,400`、`Slice Registers 126,800`、`DSP48E1`、`BRAM36`
也全是 Xilinx 口径。

**问题不在于"用了 Vivado"，而在于这两份 Artix 报告被放在 `fpga_pg2l100h/.../synth/` 下。**
规则 3.4（交付主体必须落在紫光器件上，跨厂商只能做对比）下，这是最容易被判"以非合规器件
证据冒充合规器件"的一种摆法。命名与目录必须先改，否则别人引用时一定会误读。

另：这是 **OOC 单模块、post-synthesis** 报告（util 表里带
`Warning! The Final LUT count ... Run opt_design after synthesis`），不是板级布线后结果。
OOC 布通 ≠ 带 CPU/LCD/摄像头一起布通。

---

## 3. 资源账：两笔超支

PG2L100H 口径（LUT 66,600 / FF 133,200 / APM 240 / DRM 155），板上现役 4,469 / 3,706 / 10 / 64：

| 项 | 引擎 | 板上已用 | 合计 | 占比 | 判 |
|---|---|---|---|---|---|
| LUT | 30,996 | 4,469 | 35,465 | 53.2% | ✅ 宽松 |
| FF | 19,759 | 3,706 | 23,465 | 17.6% | ✅ 宽松 |
| **APM（DSP）** | **200** | 10 | **210** | **87.5%** | ⚠ 极紧，布线会很难 |
| **DRM（BRAM）** | 见下 | 64 | — | — | ❌ **装不下** |

### BRAM 账（这条最硬）

`nn_pkg.sv` 自己的预算：W 320 KB(BRAM) + A 96 KB + B 32 KB + Q 48 KB(LUTRAM)：

- **物理口径**：320 + 96 + 32 = 448 KB；板上已用 64 块 ≈ 288 KB ⇒ 合计 **736 KB > 697.5 KB**，
  **超 38.5 KB（约 9 块）**
- **行为级推断口径**（pkg 注释自述 4 KB/BRAM36）：80 + 24 + 8 = 112 块 ⇒ 64 + 112 = **176 > 155**，
  **超 21 块**

两条口径都超。这正是 v0.8 引入 DDR3 权重流式（`NN_W_MODE_STREAM`、双银行 L2）的原因 ——
但**流式那条路的前提完全没落地**：`MEMORY_ENABLE = 0`、顶层未例化 DDR3、FDC 里 0 条 DDR 引脚。

**唯一的解**：不走 320 KB 常驻，改单银行。若 W 单银行 160 KB(40 块) + A 裁到 64 KB(16) +
B 裁到 16 KB(4) ⇒ 60 块，64 + 60 = **124 / 155 ✅ 余 31 块**。这只需要改 `nn_pkg` 的
`NN_W_BYTES / NN_A_BYTES / NN_B_BYTES` 三个 localparam —— 但它是**跨文件牵连改动**，
按纪律必须开 `exp/` 分支、一次只改一项。

---

## 4. 子系统缺的三样

### 4.1 没接进 SoC

```
grep -rn "nn_full\|nn_subsys" fpga_pg2l100h/vision/rtl/ (排除 rtl/nn 自身)
→ 0 命中
```

`rtl/vision_soc.v:136` 例化的仍是 `vision_npu accelerator`。

`nn_subsys` 端口是齐的（`ctl_*` 控制口 + `cpu_*` 窗口 + `busy/done/err/cycles/err_code`），
说明它是按"能被 SoC 接"设计的，只是**没人接**。现在还只是一座孤岛。

### 4.2 没有权重

`nn_full.v` 全文 **零 `$readmemh`**。`nn_mem` 的 W 区只能靠 `wfill_we/dbg_we` 端口运行时灌，
或综合期由外层 ROM 提供。也就是说：**这份 RTL 里没有任何一个真实模型的权重。**

### 4.3 微码是别人的模型

`nn_seq` 里内联了 `nn_rom_pkg_NN_ROM`（32,768 bit = 4 KB），`NN_ROM_LEN = 112` ——
**这是 YOLO-Fastest 的 112 项微码**，不是坚果、不是瓶盖。
而生成微码的 `tools/nn_gen_rom.py` 与各模型的 `nn_rom_pkg_*.sv`
**只存在于 `feat/ai-accel` 分支**，本分支没有。

另有一条 v0.7 约束要注意：CPU 窗口已收缩为 **A/B only**，W/Q 不可由 CPU 访问
⇒ 权重只能"综合期烧 ROM"或"从 DDR3 流式进来"，没有第三条路。

---

## 5. 那它到底值多少

### 算力：即使只跑 50 MHz 也已经够用

板上现成的 `sys_clk` 就是 **50 MHz**（`top_pg2l100h_vision.v:31  wire clk_50m = sys_clk`），
另有一个 PLL 出的 `clk_125m`。

| 时钟域 | 峰值算力 | slim @224(63.7 MMAC) | 2M 检测器(2272 MMAC) |
|---|---|---|---|
| 50 MHz（现成） | **12.8 GOPS** | 9.96 ms → 100 fps | 355 ms → 2.8 fps |
| 125 MHz（现成 PLL） | 32.0 GOPS | 3.98 ms → 251 fps | 142 ms → 7.0 fps |

对比现役 `vision_npu` 4-lane @50 MHz：**0.4 GOPS**（4 MAC × 50 MHz × 2）。
**即使压到 50 MHz，这颗引擎也是它的 32 倍。**

⇒ 所以"提频"不是必要条件。这台引擎在 50 MHz 就已经能跑 slim 类模型到 100 fps 量级，
瓶颈全在存储与接线，不在算力。

### 但 2M 检测器仍然只有 3~7 fps

上一轮我按 122 MHz 报的 145 ms / 6.9 fps 是**最好情形**。若引擎落在 50 MHz 域（最省事），
2M 检测器是 **355 ms / 2.8 fps** —— 演示勉强，分拣传送带不行。
**这是一个必须先说清、否则答辩会被问死的数**。

---

## 6. 建议：三步，按性价比排

| # | 动作 | 为什么先做 | 完成判据 |
|---|---|---|---|
| **1** | **先改证据口径**：把 `synth/` 两份 Artix 报告改名/加红标（`artix7_*`），文档里禁止写成"紫光已验证" | 零成本，却决定它能不能进交付物。现在这个摆法有合规风险 | 文件名与报告内每处引用都标明 `7a100t` |
| **2** | **ROM 模式瘦身**：`NN_W_BYTES 320K→160K`、`A 96K→64K`、`B 32K→16K`，先让 BRAM 账成立（124/155） | 不解决这个，后面全是空谈；且不需要 DDR3 | 紫光综合后 DRM ≤ 155 |
| **3** | **接 SoC**：地址译码 + `vision_mmio_bridge` 加 NN 窗口 + `irq_ext` 从硬接 0 改成真中断 | 这一步之后才算"有 NPU" | 板上能读 `cycles_o`、能跑一次 112-op |

**同时并行的第 4 件事（不属于本文件范围但绕不开）**：重新生成坚果/瓶盖模型的
量化权重与 112 项（或 N 项）微码 —— 得把 `tools/nn_gen_rom.py` 从 `feat/ai-accel`
挑到当前分支。没有这个，接好了 SoC 也只能跑 YOLO。

---

## 7. 值得改的三个数字口径

1. `nn_pkg.sv` **191 行**（不是 166）、`tb_nn_engine.sv` **1,197 行**（不是 1,168）
2. `LUT 30,996` 必须带分母与范围：**30,996 / 63,400（Artix-7），且仅为 `nn_conv_engine`
   单模块 OOC，不含 `nn_mem`**。挪到紫光分母是 46.5%，不是 48.89%
3. `DSP 200 / 240` 是 Artix 的 DSP48E1；紫光 APM 也恰好 240，但**加上现役 10 个就是 87.5%**，
   不能只报 83.33%
