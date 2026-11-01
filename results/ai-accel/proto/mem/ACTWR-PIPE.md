# 方案 A/B 写读时延流水（proto 自证）+ 契约变更说明（T-mem-R4）

> 交付人：T-mem。日期：2026-11-01。任务：Lead 批准的"nn_mem 侧 act 写命令打一拍（方案 A）"+
> 实测后的追加分析（方案 B）/ A+B 组合。**本文件与 proto/ 下变体均为验证用，不进根目录 RTL 清单。**
> 相关：`results/ai-accel/P3-DDR3-TILECACHE.md` §5（125MHz 时序评估）。

---

## 0. 一句话结论（重要修正）

1. Lead 原始判断"最差路径是 **act_mem 写地址**"经 OOC 实测修正为：**该端口是 A/B 阵列的读地址口**
   （`ADDRBWRADDR` 被 Vivado 用作 read port；路径源是引擎 `x_ld` → load/pad → `abuf` → `a_addr`）。
   ⇒ **方案 A（NPU 写命令打一拍）对该路径几乎无效**：A 变体 pipe@8ns WNS 只 **+1.299ns**，
   最差路径仍是 `x_ld → act_mem`（数据 6.136ns，route 70%）。
2. 真正对应这条路径的是 **方案 B：act 读地址打一拍**（读时延 1→2）。实测 A+B 与 B 变体的功能
   自证已 PASS（下方 §3）；OOC 三档 @100/125/150MHz 对比**因 Lead 要求暂停 Vivado 而尚未跑完**
   （已完成 pipe@100/+3.299、pipe@125/+1.299；其余配置见 §6 待跑清单）。
3. 契约代价（Lead 拍板时需知）：B 读时延 +1 → 引擎 LD 相位 +1 拍/块 = **周期 +2.2%**
   （C128 +25,200 拍；C320 同样 2.2%）；**CPU 窗口读共用同一读口，CPU 读时延也变 1→2**
   （写路径不变）。若要求 CPU 窗口保持 1 拍，则只能用**引擎侧预寄存**（方案 C，T-accel 域）。

---

## 1. 三个 proto 变体（均由根目录 nn_mem.sv 派生，端口完全一致）

| 变体 | 文件 | 改动 | 延迟变化 |
|---|---|---|---|
| **A** | `nn_mem_pipe.sv` | NPU 侧 `b_sel/b_we/b_addr/b_wdata/b_wstrb` 打一拍再进 act_mem | **b 写 1→2 拍**（CPU 写路径不打拍，仍 1 拍） |
| **B** | `nn_mem_piperd.sv` | `act_rd_idx` 打一拍再进 A/B 阵列（NPU+CPU 共用读口） | **a 读 1→2 拍**；CPU 窗口读也 1→2 拍 |
| **A+B** | `nn_mem_pipeab.sv` | 上述两者 | b 写 1→2 且 a 读 1→2 |

配套：`tb_nn_mem_{pipe,piperd,pipeab}.sv`（按变体调整等待拍数 + 新增"写时延契约"检查）、
`timing_wrap_{pipe,piperd,pipeab}.sv`（engine v3 + 变体，OOC 用）、`synth_pipe.tcl` /
`run_synth_pipe.bat`（variant × period 参数化 OOC，报告落 `proto/mem/reports/`）、
`wq_init/`（64-bit/行 的 W/Q 初始化镜像，随机 seed 以反映真实资源）。

根目录 `nn_mem.sv` / `sim/tb_nn_mem.sv` **未修改**（等 Lead 的 125MHz 全实现结果再决定是否落目录）。

---

## 2. 契约变更清单（供 Lead 更新 SPEC / CONTRACT / tb）

### 2.1 方案 A（NPU act 写命令打一拍）
| 项 | 变更前 | 变更后 |
|---|---|---|
| NPU `b_*` 写入生效 | `b_we` 有效拍起，下一时钟沿写入（1 拍） | **2 拍**（多一级寄存；数据/使能/地址同拍） |
| CPU 窗口写 | 1 拍 | **不变（1 拍）** |
| 引擎影响 | — | **无功能影响、周期 0 成本**（fire-and-forget；下一 op 至少 BASE 拍后才可能读同址） |
| tb_nn_mem | 写后读等待 1 拍 | **写后读等待 +1 拍**（b_write task 末尾多等 1 个 negedge） |
| 资源 | — | FF 约 +170（实测 pipe@125：FF 14260，其中 A 级约 170） |
| 建议文档改法 | — | SPEC §3 / CONTRACT 端口时延表加一行："`b_*` 写生效时延 = 2 拍（PIPE_A=1）" |

### 2.2 方案 B（act 读地址打一拍）—— 实测更有效，需 Lead 拍板
| 项 | 变更前 | 变更后 |
|---|---|---|
| NPU `a_*` 读数据 | 地址拍 +1 拍有效（1 拍） | **地址拍 +2 拍有效（1→2 拍）** |
| CPU 窗口读 `cpu_rdata` | 1 拍 | **1→2 拍**（与 NPU 共用同一读口；若不可接受则改用方案 C：引擎侧预寄存 a_addr，mem 不动） |
| 引擎影响 | — | **LD 相位 +1 拍/块**；周期 **+2.2%**（C128 1,167,368 → 1,192,568 = +25,200 拍；C320 同样 2.2%）。需 T-accel 在 S_LD 加 1 拍等待 |
| tb_nn_mem | a/cpu 读等待 1 拍 | **a/cpu 读等待 +1 拍** |
| 资源 | — | FF 约 +21（读地址 13b + valid 2b + cpu sel/lane 6b） |
| 建议文档改法 | — | SPEC §3："`a_*` 读时延 = 2 拍（PIPE_B=1）；CPU 窗口读 = 2 拍"；CONTRACT 同步；engine-report 更新 LD 相位 |

### 2.3 组合
- A+B 可同时开（各自改动互不影响），契约叠加；
- **P3 tilecache 路线（独立模块）不需要这些改动**（P3 用 tile 模式下 a/b 口语义不变），本方案只影响 C128 BRAM-only 路线的时序余量。

---

## 3. 功能自证（ModelSim，2026-11-01 15:3x，**未占 Vivado**）

编译：`vlog -sv rv32_pkg.sv nn_pkg.sv nn_mem_<variant>.sv tb_nn_mem_<variant>.sv`；
运行：`vsim -c -do "run -all; quit -f" work.tb_nn_mem_<variant> +nnwq=<yolo_wq.hex>`。

| 变体 | +nnwq 模式 | 无镜像（verify 默认） | 说明 |
|---|---|---|---|
| A | **PASS checks=47148, mismatch=0, xerr=0** | PASS checks=42 | 含新增 2 条写时延契约检查 |
| B | **PASS checks=47146, mismatch=0, xerr=0** | PASS checks=40 | a/cpu 读等待 +1 |
| A+B | **PASS checks=47148, mismatch=0, xerr=0** | PASS checks=42 | 读/写等待都 +1 |

新增"写时延契约"用例（A / A+B 版本）：
- A：写驱动后 **+1 拍读仍读到旧值**（0）→ 提交后 **+2 拍读到新值**（`0xC0DE1234`）；
- A+B：读延迟 2 拍，**commit 前读旧值、commit 后读新值**；
- 两条 check 均 PASS（日志 `%TEMP%\nn_pipe\tb_{pipe,piperd,pipeab}\{a,c}.log`）。

---

## 4. OOC 实测（部分完成，Vivado 已按 Lead 要求暂停）

配置：engine v3（根目录 `nn_conv_engine.sv`）+ 变体 mem，`create_clock -period <P>`，
W/Q 用 64-bit 行随机镜像（`wq_init/`），wrapper 同 T-accel 的 `timing_wrap_v3.sv` 风格（输出探针防 DCE）。

| 配置 | 周期 | WNS | BRAM | LUT | FF | DSP | 最差路径 |
|---|---|---|---|---|---|---|---|
| **A（pipe）** | 10.000ns | **+3.299** | 112 | 32,334 | 14,260 | 169 | `x_ld_reg → act_mem ADDRBWRADDR[10]`，data **6.136ns**（route 69.8%），9 级 |
| **A（pipe）** | 8.000ns | **+1.299** | 112 | 32,334 | 14,260 | 169 | 同上（路径未变） |
| base / B / A+B | 10/8/6.667 | **待跑**（见 §6） | — | — | — | — | — |

**解读**：A 后最差路径的源寄存器仍是 `x_ld`（不是新加的 `npu_wr_idx`）⇒ 该 `ADDRBWRADDR` 是**读地址口**，
A 只把 6.298→6.136ns（很小）；这也是追加 B 变体的依据。

---

## 5. 预期收益分析（方案 B / A+B，待 OOC 验证）

当前路径（基线）：`x_ld → ld_fill/pad → ld_inb → abuf mux → a_addr → act_mem 地址`，
data **6.298ns = logic 1.856 + route 4.442（route 70.5%）**、9 级逻辑。

- **B（mem 侧读地址打拍）**：把路径在 mem 边界切为两段：
  ① 引擎逻辑 → mem 读地址寄存器（logic ~1.86ns + 跨模块 route，估 1.5–2.5ns）⇒ 约 3.4–4.4ns；
  ② 寄存器 → BRAM 地址（~0.8–1.2ns）。
  预期 @8ns WNS **+3.2～+4.1ns**（相对当前 +1.299，**收益 +1.9～+2.8ns**），足以把 125MHz 做稳、
  150MHz（6.667ns）有机会过（需实测网表）。@10ns 预计 +5～+6ns。
- **C（引擎侧预寄存 a_addr，T-accel 域）**：若能把 load/pad 计算提前到 S_NEXT（前面有空拍），
  可做到 **周期 0 成本**且同样切分读地址路径 —— 比 B 更优（无 CPU 读 2 拍影响），但需要引擎改。
- **A+B**：B 已覆盖该路径，A 对总时序的增量收益预计 <0.2ns（但可为其他写侧路径留余量）。

建议（待 OOC 数据确认）：**优先 B（若 CPU 窗口 2 拍可接受）或 C（若引擎能零周期预寄存）**；
A 单独不足以解决 125MHz 瓶颈。

---

## 6. 待跑清单（Lead 说"125 全实现跑完"后执行）

```bat
rem 8 个关键配置: {base,pipe,piperd,pipeab} x {125,150MHz}
results\ai-accel\proto\mem\run_synth_pipe.bat
rem 追加 @100MHz: 共 12 个配置
results\ai-accel\proto\mem\run_synth_pipe.bat full
```
产物：`proto/mem/reports/<variant><mhz>_{util,timing,paths}.rpt`。
交付给 Lead：**@100/125/150 三档 × 四变体的 WNS/资源表 + A vs B vs A+B 收益结论**，
然后由 Lead 决定是否落根目录（并同步契约/SPEC/engine 的 LD 相位）。

---

## 7. 风险/注意

1. **B 的 CPU 窗口读 2 拍**：C128 的 SW/`tb_sw` 是否依赖"CPU 读 1 拍"需确认（`cpu_read` 使用点：
   yolo_demo 的 nn 窗口读、tb_sw 的窗口用例、verify 矩阵）。若不接受 → 走方案 C（引擎侧）。
2. **B 的引擎周期 +2.2%**：C128 1.167M→1.193M 拍 @125MHz = +0.19ms/帧（可接受）；但对 30fps 目标
   （C320）是 +1.3ms，需与 dw16/PX16 收益一起算总账。
3. **A 的写延迟 2 拍**对 SoC 无影响（引擎 fire-and-forget；CPU 写不打拍），但 tb_nn_mem 需 +1 拍；
   `tb_sw_nn_yolo` 的 op 间间隔远大于 2 拍，无需改。
4. 本文件所有数字均为 **proto/OOC 综合/仿真**，不是全实现后实测；最终以 Lead 的 125/150MHz 全实现为准。
