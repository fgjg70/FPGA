# perf-proto — 256-MAC 草稿的 OOC 探针（task-12 item 5，Lead 已批准）

> 只写本目录；**不改仓库任何 RTL/xdc/tcl**（`perf_probe.sv` / `probe_top.sv` 是本目录新增的综合探针）。
> 批准记录：Lead 2026-11-03 "③ 批准一次 256-MAC 草稿 OOC 综合（只出报告，不改仓库 RTL）；所有新文件只写
> results/bottlecap/perf-proto/；要出三份结论：资源、OOC fmax（100/122/150MHz 三档）、最差路径 top-5"。

## 登记（跑之前先登记来源）

| 项 | 内容 |
|---|---|
| **wrapper** | `probe_top.sv`（自包含激励 + `perf_probe` 实例；只有 clk/rst 输入 + 32bit 观测输出） |
| **DUT** | `perf_probe.sv`（与 `nn_conv_engine.sv` 同构的 4 级 MAC 流水 + requant 数据通路） |
| **时钟脚本** | `run_ooc.tcl` 内 `create_clock -period <ns> -name clk [get_ports clk]`；三档周期 = 6.667 / 8.182 / 10.000 ns（150 / 122.22 / 100 MHz） |
| **约束风格** | 沿用 `results/ai-accel/proto/engine/synth_eng_only.tcl`：`synth_design -mode out_of_context`、`report_utilization`、`report_timing -max_paths 5` |
| **runner** | `run_all.bat`（一档一次 vivado batch；日志 `ooc_<tag>.log`） |
| **part** | `xc7a100tfgg484-2`（与仓库一致） |
| **Vivado** | 2018.3 @ `D:\software\Learn\Xilinx\Vivado\2018.3`（与 `tools/fpga_workflow.py:65` 同源） |

## 与真实引擎的差异（解读数字时必须知道）

1. **不含控制 FSM / 地址生成 / Q 装载 / 输出打包**。真实引擎 OOC 的 LUT ≈16.9K（`engine-report.md:17-18`）
   里大部分是控制与地址逻辑；本探针只包含"乘法阵列 + 累加 + requant"。
   ⇒ **绝对 LUT 不可直接与引擎比；可用量是 Δ(256−128) 与 fmax 的相对退化。**
2. DSP 映射用 Xilinx `use_dsp` 属性**显式指定**：
   - MAC：前 `DSP_PX` 个像素行 → `use_dsp="yes"`（1 MAC = 1 DSP48E1，8×8 走 25×18）；
   - 其余 → `use_dsp="no"`（落 LUT，`PX16-STUDY.md §2` 估 26 LUT/个）；
   - requant：每 lane 2 个 17×16 乘（对齐 `nn_conv_engine.sv:239-247`），`use_dsp="yes"`。
3. 探针的 fmax 是**乐观上界**（无控制路径）；报告里同时给 P128 基线做参照。

## 配置网格（11 次综合）

| tag | period | PX×LANE | DSP_PX | REQ_LANES | 说明 |
|---|---|---|---|---|---|
| p128_150/122/100 | 6.667/8.182/10 | 8×16=128 | 8 | 16 | 基线校准（128 DSP + 32 requant DSP） |
| p192oc24_150/122 | 6.667/8.182 | 8×24=192 | 5 | 16 | OC24 方案（120 DSP + 72 LUT-MAC） |
| p256oc32_150/122/100 | 6.667/8.182/10 | 8×32=256 | 5 | 16 | OC32 方案（160 DSP + 96 LUT-MAC） |
| p256oc32req32_150 | 6.667 | 8×32=256 | 5 | **32** | DSP 擦边变体（requant +32 DSP） |
| p256px16_150 | 6.667 | 16×16=256 | 10 | 16 | PX16 方案对比 |

## 复现

```bat
cd D:\USER\Desktop\FPGA\FPGA\results\bottlecap\perf-proto
run_all.bat
rem 产物：ooc_<tag>.log / ooc_<tag>_util.rpt / ooc_<tag>_paths.rpt
```
