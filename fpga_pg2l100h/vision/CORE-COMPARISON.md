# BTB/分支预测器差异对比：最终版 Pango vs Artix 参照核（CORE-COMPARISON.md）

> **结论先行**：**BTB 在 Pango 最终版上没有消失，而且完整生效**。Pango `rtl/cpu/btb.v` 有完整的 BTB（512 项）+ BHT（8192 项两级 gshare）实现，`core.v` 中也实例化并接入 2 级预测流水（`p2_pc / q_*`）；文件里 `assign pred_hit/pred_taken/pred_target = 0` 是**旧的一级预测兼容口**，Artix 参照核同样如此，不是"预测被关掉"。
> 实测证据：在本仓库最终版 RTL 上把方向预测强制关掉后，CoreMark 每迭代周期 **390,958 → 458,242（+17.2%）**，CoreMark/MHz **2.5578 → 2.1823（−14.7%）**，CRC 仍正确 ⇒ BTB 在 Pango 上是**真实生效**的。

## 1. 文件与例化证据（最终版 Pango，`main` 树）

| 证据 | 位置 |
|---|---|
| BTB 模块存在 | `fpga_pg2l100h/vision/rtl/cpu/btb.v`（132 行，含 BTB 阵列 + 内嵌 `u_bht`） |
| BHT 模块存在 | `fpga_pg2l100h/vision/rtl/cpu/bht.v`（8192×2bit gshare） |
| `core.v` 例化 BTB | `core.v:228-253`：`btb #(.IDX_BITS(9), .PC_TOP(14), .PC_BASE(...)) u_btb(...)` |
| 预测结果接入 PC | `core.v:459-460`：`assign pc_src = pred_taken; assign pc_target = pred_target;` |
| 2 级预测流水 | `core.v:240-246`：`.p2_pc(p2_pc_ns), .p2_hold(p2_hold), .p2_pc_pht(pc_next), .q_hit(pred_hit), .q_taken(pred_taken), .q_target(btb_pred_target)` |
| 旧一级兼容口未用 | `btb.v:94-96`：`assign pred_hit/pred_taken/pred_target = 0`（与 Artix `btb.sv:195-197` 完全相同） |

## 2. BTB/BHT 结构与参数对比（完全一致）

| 项 | Artix 参照核（`btb.sv` / `bht.sv`） | Pango 最终版（`rtl/cpu/btb.v` / `bht.v`） | 是否一致 |
|---|---|---|---|
| BTB 容量 | 512 项（`IDX_BITS=9`） | 512 项（`IDX_BITS=9`） | ✅ |
| BTB tag | 3 位（`PC_TOP=14`，`PAGE_BITS=IDX+2`） | 3 位（同） | ✅ |
| 方向表 PHT | 8192×2bit（`PHT_BITS=13`） | 8192×2bit（`PHT_BITS=13`） | ✅ |
| 全局历史 | 13 位 gshare（`GH_BITS=13`） | 13 位 gshare（`GH_BITS=13`） | ✅ |
| JAL/JALR 入历史 | `HIST_ALL_CTRL=1` | `HIST_ALL_CTRL=1` | ✅ |
| 预测流水 | 2 级：`p2_pc` → 寄存 BTB 输出 → `q_hit/q_taken/q_target` | 同（`btb.v:88-93`） | ✅ |
| 更新口 | `upd_en/upd_pc/upd_taken/upd_target/upd_is_ret/upd_is_cond` | 同（`btb.v:74-87`） | ✅ |
| 更新门控 | `is_ctrl_flow && !hold_mem && !rst && !redir_kill`（`core.sv:548`） | `((is_ctrl_flow && !hold_mem) && !rst) && !redir_kill`（`core.v:260`） | ✅ |
| 初始化值 | BTB 全 0；BHT 全 `2'b01`（弱不跳） | BTB 全 0（`btb_zero.hex`）；BHT 全 `2'b01`（`bht_init.hex` = 8192 行 `1`） | ✅ 值相同 |

> 唯一"看起来不同"的是**初始化写法**：Pango 用 `$readmemh("firmware/btb_zero.hex")` / `firmware/bht_init.hex`；Artix 根目录 `btb.sv`/`bht.sv` 删掉了 `ifdef SYNTHESIS` 的 readmemh 分支，改用 for 循环清零/置 `2'b01`。两者初始内容相同，不影响预测行为。

## 3. 真正的差异（都不涉及 BTB 结构）

| 项 | Artix 参照核（SV 原核） | Pango 最终版（Verilog-2005） | 对 BTB 的影响 |
|---|---|---|---|
| RTL 生成方式 | 手写 SystemVerilog；`ctrl_s` 结构体 | `sv2v` 从 `fpga_mes50hp/src` 快照转换（`rtl/cpu/provenance.json`，19 文件 SHA256 可追溯） | 无：逻辑仍为同一套；sv2v 只把结构体/`always_ff` 展平（如 `id_ex_ctrl[44-:2]` = `pc_sel`） |
| 行数差异 | `btb.sv` 250 行（含大量注释） | `btb.v` 132 行（sv2v 去注释/展开语法） | 无：去的是注释，不是逻辑 |
| RAS（返回地址栈） | 源码有 `ifdef RAS_EN`（**默认关闭**） | sv2v 时 `RAS_EN` 未定义 ⇒ 整段被剥离，`ex_is_call/ex_is_ret=0`，`pred_target=btb_pred_target` | 无（Artix 默认构建同样关闭 RAS） |
| RV32A / GEMM | `ifdef A_EN`/`GEMM_EN`（**默认关闭**） | 同样被剥离（`amo_newdata=0`、无 GEMM） | 无 |
| MMIO 接口 | 组合读外部总线（无 `ext_ready`） | `EXTERNAL_WAIT=1` + `ext_ready` 握手（CPU 125 MHz ↔ MMIO 50 MHz） | 仅外设访问多等拍；CoreMark 测量窗口内几乎不触及 |
| 存储器初始化 | 仿真 `+imem/+dmem`，综合 `IMEM_INIT_FILE` 宏 | `imem.v/dmem.v` 固定 `$readmemh("firmware/vision_*.hex")` | 无 |
| `rv32_pkg` | 多 GEMM/MMIO 常量/注释 | 常量裁剪（见 diff） | 无 |

## 4. 实测：BTB 在 Pango 上"生效"的直接证据

同一官方 CoreMark 固件（10 迭代，CPU 125 MHz / 系统 50 MHz，最终版 `vision_soc`）：

| 配置 | 周期/迭代 | CoreMark/MHz | CRC 三项 |
|---|---:|---:|---|
| **BTB 正常（基线）** | **390,958** | **2.5578** | ✅ e714/1fd7/8e3a |
| 强制关闭方向预测（`btb.v` 的 `q_taken` 接 0） | 458,242 | 2.1823 | ✅ e714/1fd7/8e3a |

⇒ 关掉 BTB 方向预测后周期 **+17.2%**、CM/MHz **−14.7%**，功能仍正确。**若 BTB 真的"没了"，基线不可能比关掉预测快 17%。**

基线下的预测行为（10 迭代）：分支重定向（预测错误）**35,807 次**，占全运行周期 0.88%；错判主要集中在 state 相位（20,009 次）——预测器整体健康。

## 5. 为什么 Pango 与 Artix 线录得的 CoreMark 数字不同？

两者 **BTB 结构完全相同**，数字差异（如 Pango 2.5578 vs Artix 线 2.69）**不是 BTB 丢失**造成的，而是：
1. **CoreMark 固件/移植层不同**：Pango 用官方 EEMBC pinned revision + Pango 自己的 `core_portme.c`（MMIO UART/timer）；Artix 线用自己的 `sw/coremark` + 计时移植层，代码布局/分支模式不同（无 I-cache，代码布局会影响 BTB/PHT 命中）。
2. **测量计时域不同**：Pango 的 CoreMark tick 在 50 MHz 域计数（CPU 125 MHz，需 ×2.5 换算）；Artix 线在核心时钟域计数。
3. **主频/交付配置不同**：Pango CPU 125 MHz，Artix 交付档 150 MHz；CoreMark/MHz 已把频率约掉，但编译器配方/固件差异仍在。

## 6. 依据与复现

- 快照：`main` 树（本次对比基于 `fpga_pg2l100h/vision/rtl/cpu/{core,btb,bht}.v` 与根目录 `core.sv/btb.sv/bht.sv`）。
- 对比方法：`fpga_mes50hp/src/{core,btb,bht,regfile,imem,dmem,rv32_pkg}.sv`（`provenance.json` 记录的 sv2v 输入）与当前根目录同名 `.sv` 逐文件 diff；差异仅为注释/初始化/常量。
- BTB 实验：在 `work/pango_bl` 工作副本修改 `btb.v` 的 `q_taken`（不进入仓库主线），ModelSim 跑官方 CoreMark 10 迭代；日志保留在 `work/pango_bl/sim_btb_on`、`sim_btb_off`。
- 数据口径：A/B 级证据（仿真周期计数），见根 `COMPLIANCE.md`；上板正式跑分仍以 PDS/板卡实测为准。

> 版本：2026-11-03；对象 = 最终版紫光 PG2L100H 工程。若后续修改 `btb.v`/`core.v` 的预测逻辑，必须更新本文件并重新跑 §4 的对照实验。
