# 256-MAC 草稿的 OOC 综合报告（Lead 批准的一次性验证）

> 作者：`ddr3-feas`（task-12 item 5）。日期：2026-11-03。
> **不改仓库 RTL**：所有新增文件都在 `results/bottlecap/perf-proto/`；只做 OOC 综合（无 P&R、无 bitstream）。
> 批准记录：Lead 2026-11-03 "③ 批准一次 256-MAC 草稿 OOC 综合（只出报告，不改仓库 RTL）；所有新文件只写
> results/bottlecap/perf-proto/；要出三份结论：资源、OOC fmax（100/122/150MHz 三档）、最差路径 top-5"。

---

## 0. 三份结论（先给答案）

### (1) 资源（综合；探针口径）

| 配置 | LUT | FF | DSP48E1 | BRAM | 说明 |
|---|---:|---:|---:|---:|---|
| **p128 基线**（8 px × 16 lane = 128 MAC，全 DSP） | **2,187** | 1,753 | **160** | 0 | 128 MAC-DSP + 32 requant-DSP |
| **p192 OC24**（8 × 24，120 DSP + 72 LUT-MAC） | 5,036 | 2,413 | **152** | 0 | 120 + 32 |
| **p256 OC32**（8 × 32，160 DSP + 96 LUT-MAC） | **6,951** | 3,606 | **192** | 0 | 160 + 32 |
| **p256 OC32 + 32-lane requant** | 8,077 | 3,742 | **224** | 0 | 160 + 64（DSP 擦边变体） |
| **p256 PX16**（16 × 16，160 DSP + 96 LUT-MAC） | 6,468 | 3,027 | **192** | 0 | 160 + 32 |

- **Δ(256 − 128) = +4,764 LUT / +1,853 FF / +32 DSP**（OC32/PX16 同量级）。
- **DSP 结论**：OC32 = **192 DSP**；加 CPU 的 8 个 = **200/240 = 83%** ✅ 可行。
  若 requant 用 32 lane（每 lane 2 个 17×16 乘）= 224+8 = **232/240 = 96.7%** ⚠️ 擦边 ⇒ **requant 必须保持 16 lane 时分复用**。
- 外推到真实引擎（当前整机 LUT 36,985 / FF 16,381 / DSP 168）：**LUT 37~42K（58~66%）、FF +2~5K（15~18%）、DSP 200/240（83%）**。

### (2) OOC fmax（三档约束下的 WNS）

| 配置 | 150MHz（6.667ns） | 122.22MHz（8.182ns） | 100MHz（10ns） | fmax 估计 |
|---|---:|---:|---:|---:|
| p128 基线 | **+0.055** MET | +1.570 MET | +3.388 MET | **151.2 MHz** |
| p192 OC24 | **+0.039** MET | +1.554 MET | — | **150.9 MHz** |
| **p256 OC32** | **+0.039** MET | +1.554 MET | +3.372 MET | **150.9 MHz** |
| p256 OC32 req32 | **+0.055** MET | — | — | 151.2 MHz |
| p256 PX16 | **+0.039** MET | — | — | 150.9 MHz |

> **关键结论：MAC 加宽不是 fmax 瓶颈。** 128/192/256/PX16 四种配置的 OOC fmax 全部落在 **150.9~151.2MHz**，
> 差异 <0.2%；**最差路径在每一种配置里都是 requant 的 17×16 DSP 乘法输出**，与 MAC 宽度无关。
> 三档频点全部 MET（150MHz 只剩 +0.039ns 余量，属"刚够"）。

### (3) 最差路径 top-5（p256 OC32 @150MHz）

| # | 起点 | 终点 | slack | 路径延迟 | 逻辑级数 |
|---|---|---|---:|---:|---:|
| 1 | `u_dut/g_req[0].u_lo/p_w/CLK`（requant lane0 的 17×16 DSP） | `u_dut/y_out_reg[0][0][7]/D` | +0.039 | **6.596ns** | 6 |
| 2 | `g_req[10].u_lo/p_w/CLK` | `y_out_reg[0][10][7]/D` | +0.039 | 6.596ns | 6 |
| 3 | `g_req[11].u_lo/p_w/CLK` | `y_out_reg[0][11][7]/D` | +0.039 | 6.596ns | 6 |
| 4 | `g_req[13].u_lo/p_w/CLK` | `y_out_reg[0][13][7]/D` | +0.039 | 6.596ns | 6 |
| 5 | `g_req[14].u_lo/p_w/CLK` | `y_out_reg[0][14][7]/D` | +0.039 | 6.596ns | 6 |

- 与 p128 基线对比：p128 的 top 路径也是 requant（6.58ns），**说明加宽 MAC 没有新增更差的路径**。
- 与真实引擎对比：真实 v3 引擎在 150MHz OOC 是 WNS +0.489（`engine-report.md:17`），但**全实现 125MHz 差
  0.077ns，最差路径是 `u_nn/u_eng/wa_r → u_nn/u_mem/w_cur_*` 纯 route 8.88ns**（`DELIVERY §9.2.1`）
  ⇒ **真实项目的 150MHz 风险在布线（route），不在本探针覆盖的数据通路上**。

---

## 1. 登记（跑之前先登记，见 `perf-proto/README.md`）

| 项 | 内容 |
|---|---|
| **wrapper** | `results/bottlecap/perf-proto/probe_top.sv`（自包含激励 + 32bit 观测输出） |
| **DUT** | `results/bottlecap/perf-proto/perf_probe.sv`（与 `nn_conv_engine.sv` 同构的 4 级 MAC 流水 + requant） |
| **时钟脚本** | `run_ooc.tcl`：`create_clock -period <ns> -name clk [get_ports clk]`；三档 = 6.667 / 8.182 / 10.000 ns |
| **约束风格** | 沿用 `results/ai-accel/proto/engine/synth_eng_only.tcl`（`-mode out_of_context` + `report_utilization` + `report_timing -max_paths 5`） |
| **part / Vivado** | `xc7a100tfgg484-2`；Vivado 2018.3 @ `D:\software\Learn\Xilinx\Vivado\2018.3`（同 `tools/fpga_workflow.py:65`） |
| **runner** | `run_all.bat`（网格）/ `run_one.bat`（单次重跑） |
| **日志** | `ooc_<tag>.log`（每次完整 Vivado 日志）、`ooc_<tag>_util.rpt`、`ooc_<tag>_paths.rpt`；汇总 `ooc_results.json` |
| **运行计数** | 11 次计划 + 2 次失败重跑（Vivado helper 进程 flake：`couldn't read file .../unimacro_verilog.tcl`，与本设计无关，重跑即过） |

---

## 2. 解读边界（必读）

1. **探针 ≠ 完整引擎**：只含"MAC 阵列 + 累加 + requant"，**不含控制 FSM / 地址生成 / Q 装载 / 输出打包**。
   真实引擎 OOC 的 LUT ≈16.9K（`engine-report.md:17-18`）里大部分是控制与地址逻辑。
   ⇒ **绝对 LUT 数不可与引擎直接比；可用的量是 Δ(256−128) 与 fmax 的相对关系。**
2. **FF 是下界**：探针里累加器 `acc[px][lane]` 只有 16 个 lane 被 requant 读取，综合对未读部分做了剪枝
   ⇒ FF 增量（+1,853）**低于**完整引擎的真实增量（预计 +4~5K，含 8K acc FF）。DSP 数**不受影响**（全部 MAC 都喂到累加）。
3. **只有 synthesis（无 opt_design/place/route）**：Vivado 自带警告"最终 LUT 数通常低于综合值"。fmax 是综合估计，
   **真实 fmax 必须靠全实现**（这正是 Lead 关心的"125MHz route 差 0.077ns"那一层）。
4. 探针的 fmax 是**乐观上界**（无控制路径、无跨模块长走线）。

---

## 3. 对 P2 方案选择的影响

| 方案 | DSP（+CPU 8） | LUT 增量 | 探针 fmax | 接口风险 | 结论 |
|---|---:|---:|---:|---|---|
| **PX16（推荐）** | 192+8=**200/240（83%）** | +4,281（6,468−2,187） | 150.9 | **W 侧零改动**（仍 16B/拍）；A 侧 tilecache 读口 256b（新模块） | ✅ **首选** |
| OC32 | 192+8=200/240（83%） | +4,764 | 150.9 | W 读口 128→256b（4 银行，见 `NPU-PERF-OC32-REVISION.md`） | 备选 |
| OC24（192 MAC） | 152+8=160/240（67%） | +2,849 | 150.9 | W 读 24B/拍（非 2 的幂，最别扭） | 资源最省但周期只差 3% |
| 256 MAC + 32-lane requant | 224+8=**232/240（96.7%）** | +5,890 | 151.2 | — | ❌ 不推荐（DSP 擦边） |

---

## 4. 复现

```powershell
cd D:\USER\Desktop\FPGA\FPGA\results\bottlecap\perf-proto
run_all.bat                     # 网格：全部 <= 15 min
rem 单次: run_one.bat <tag> <period_ns> <PX> <LANE> <DSP_PX> <REQ_LANES>
rem 汇总: python -c "import json;print(json.load(open('ooc_results.json')))"
```
产物：`ooc_results.json`（10 个配置的 LUT/FF/DSP/BRAM/slack/fmax_est/最差端点）、`ooc_*_util.rpt`、`ooc_*_paths.rpt`、`ooc_*.log`。

---

## 5. 建议的下一步（若 P2 立项）

1. **把探针补成"带控制"的最小引擎**（加 S_LD/S_MAC/S_REQ 状态机与地址生成），再跑一次 OOC —— 这样 LUT 与 fmax 才有引擎级可比性。
2. **requant 路径治理**：OOC 显示它 6.596ns 是数据通路瓶颈（6 级逻辑，DSP 输出 + 移位/饱和）。
   若要冲 150MHz，优先把 requant 的移位/饱和再切一级（+1 拍/块，成本约 0.1% 周期）。
3. **全实现验证**：P2 落地后按 `DELIVERY §9.2.1` 的方法跑 100/122/150MHz 三档全实现，重点看
   `u_nn/u_eng/wa_r → u_nn/u_mem/*` 这条纯 route 路径（本探针覆盖不到）。
