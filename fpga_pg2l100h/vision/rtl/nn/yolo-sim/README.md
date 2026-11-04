# YOLO-Fastest v1.1 (COCO-80) · NPU 仿真包

> **一键可跑的 COCO-80 YOLO 仿真** —— 不需要 Python 工具链、不需要外部数据文件，只依赖 Vivado xsim。
> 被测模型：**YOLO-Fastest v1.1（darknet），COCO 80 类，131 层 → 112 op 微码 ROM**。
> 模型冻结记录：`results/ai-accel/MODEL-FREEZE.md`（2026-11-01 拍板）。

---

## 0. 一分钟上手

```powershell
cd fpga_pg2l100h\vision\rtl\nn\yolo-sim
powershell -ExecutionPolicy Bypass -File run_yolo_sim.ps1
```

期望输出（约 **10 秒**）：

```
[legacy] PASS starts=112 cycles=336 done_ops=112 rom_len=112
[legacy] err-inject PASS
[band] PASS ops=112 bands=4242 pre=112 eng=4242 cycles=72114
[band] err-inject wlen>128K -> E6 PASS
[band] err-inject pre_err -> E6 PASS
NN_SEQ_TB: PASS (legacy starts=112 cycles=336 | band ops=112 bands=4242 pre=112 eng=4242)

>>> YOLO 仿真 PASS
```

---

## 1. 这个仿真验证什么

**被测对象**：`nn_full.v` 里的 `nn_seq`（微码定序器）+ 真实 YOLO ROM（`nn_rom_pkg::NN_ROM`，112 项）。

| 验证项 | 判据 |
|---|---|
| **legacy 路径** | 恰好 `NN_ROM_LEN=112` 次 start；`cycles == 假引擎 cycles 之和`；每个 `desc.op` 与 ROM 表的 op 逐项映射；`busy/done/done_ops` 语义 |
| **err 注入（legacy）** | 引擎返回 err 时整条序列正确中止 |
| **band 路径（M6c）** | 112 个 op 展开成 **4,242 个 band**；每个 band 的 `in_rows/pad_top/rd_rows/in_base/out_base/row_bytes/out_rows/zp_in/add_mode` 与附录 A 公式**逐 band 一致**；`Σn_bands` 次引擎 start；周期累加正确 |
| **预取控制** | 每个 op 1 次 `pre_start`（共 112 次）；地址/长度/bank 交替正确 |
| **err 注入（band）** | `wlen > 128KiB` → `E6`；预取错误 → `E6` |

**关键意义**：这是**唯一能在合理时间内跑完整个 COCO-80 YOLO 层序列**的仿真 ——
它验证的是"**112 个 op 的调度/展开/预取是否正确**"，这正是全模型 E2E 的核心控制面。

---

## 2. 文件清单

| 文件 | 说明 |
|---|---|
| `run_yolo_sim.ps1` | **一键脚本**（编译 → elaborate → 运行 → 判 PASS） |
| `nn_full.v` | 被测 RTL：7 个模块的**纯 Verilog** 版（由 SystemVerilog 经 `sv2v` 转换，见 `results/NPU-SV2V-CONVERSION.md`）|
| `nn_rom_pkg.sv` | YOLO 的 112-op 微码 ROM（`NN_ROM_LEN=112`） |
| `nn_pkg.sv` | NPU 参数包（地址常量 / 结构体定义） |
| `rv32_pkg.sv` | CPU 类型包（`nn_subsys` 需要） |
| `tb_nn_seq.sv` | 自校验 TB（`NN_SEQ_TB: PASS` / `FAIL`） |
| `evidence/yolo_sim_pass.txt` | **本次实测日志**（含上面那 6 行 PASS） |

---

## 3. 它**不**验证什么（诚实说明）

| 未覆盖 | 原因 | 替代手段 |
|---|---|---|
| **每个 op 的计算数值** | 本 TB 用假引擎（stub）只验调度 | `rtl/nn/sim/tb_nn_engine.sv`（58 个 op 级 case，逐位对照 Python 金标） |
| **全模型端到端推理**（1,049,089 拍） | `tb_sw.sv:787` 记录：YOLO 全模型在 50 MHz 仿真时钟下需**上亿拍**，仿真不可行 | 单元级 + 分阶段验证（本包 + `tb_nn_engine` + `tb_nn_wstream`） |
| **精度（mAP）** | 属算法层 | 见 `results/ai-accel/model-report.md`、`MODEL-FREEZE.md` |

---

## 4. 模型规格速查（COCO-80 YOLO-Fastest v1.1）

| 项 | 值 |
|---|---|
| 类别数 | **80（COCO）** |
| 网络 | 131 层（84 conv / 28 dwconv / 18 shortcut / 3 maxpool / 5 route / 18 dropout / 2 yolo）|
| int8 权重 payload | **319,792 B**（≤320KB BRAM 预算）|
| 层序列 | **112 op**（conv 55 / dwconv 28 / maxpool 3 / upsample 1 / add 18 / copy 2 / conv0 1，含展开）|
| 算力需求 | C128 = **23.8 MMAC** / C320 = **149.0 MMAC** |
| 精度 | COCO mAP@0.5 ≈ **23.65**（官方值，320 输入）|
| 实测帧率 | C128 = **95.3 fps** @100 MHz（A7a）；C320 ≈ 13.7 fps（估）|

---

## 5. 环境要求

- **Vivado 2018.3**（xsim；脚本默认 `D:\software\Learn\Xilinx\Vivado\2018.3\bin`，如不同改脚本里的 `$X`）
- 无需 Python / 无需外部数据文件 / 无需预生成的向量

---

## 6. 相关文档

- [NPU-SV2V-CONVERSION.md](../../../../results/NPU-SV2V-CONVERSION.md) —— SV→Verilog 转换报告（含全子系统 4 套仿真结果）
- [NPU-CORE-COMPARISON.md](../../../../results/NPU-CORE-COMPARISON.md) —— 库内三个 NPU 家族对比
- [MODEL-FREEZE.md](../../../../results/ai-accel/MODEL-FREEZE.md) —— YOLO 模型冻结记录
- [NPU-PERF-UPGRADE.md](../../../../results/bottlecap/reports/NPU-PERF-UPGRADE.md) —— 周期分解与优化阶梯
