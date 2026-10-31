# AI 加速子系统 · 交付摘要（2026-10-31 第一轮）

> 分支 `feat/ai-accel`（从交付 tag `deliv150-o2ira` = `main` @ d592067 拉出）。
> 契约与数据格式的唯一事实来源：[`CONTRACT.md`](CONTRACT.md)（v0.4）。方案与预算：[`PLAN.md`](PLAN.md)。
> 本文件只写**可复核的证据与口径**，每条都带命令/日志路径；数字不重复搬运（详细表在各自报告里）。

---

## 1. 本轮完成了什么（一句话）

在**不改变交付档**（无 `NN_EN` 时网表逐位相同）的前提下，给 RV32IM SoC 加了一条 **512KB 片上 NPU 存储窗口 + int8 卷积引擎**，
把 **YOLO-Fastest v1.1（int8 PTQ，128×128 输入，108 个 op）完整跑通并逐 op 位精确对齐 golden**，
并用 Vivado 综合证明大 BRAM 方案在 XC7A100T 上**放得下（133/135 块）**。

---

## 2. 证据总表

| # | 项 | 结果 | 证据（命令 / 文件） |
|---|---|---|---|
| E1 | 交付档回归（无 NN_EN） | ✅ **PASS 15**（12 项原回归 + 3 项新增 NN 测试）| `python tools\fpga_workflow.py verify --force`；日志 `.fpga-cache/logs/` |
| E2 | 交付档综合资源/时序不变 | ✅ **LUT 3098 / FF 1447 / BRAM 9 / DSP 8；fmax 150.2 MHz；WNS +0.007**，与交付行 `deliv150-o2ira-final` 逐项相同 | `synth --tag ai-nn-parity`，`results/coremark.csv` 行 `ai-nn-parity`，`.fpga-cache/reports/20261031-*/` |
| E3 | `nn_mem` 大 BRAM 自检 | ✅ `MEM_TB: PASS`（有合成镜像 47,157 checks / 无镜像 42 checks，mismatch=0, xerr=0）| `verify --only tb_nn_mem`；`results/ai-accel/mem-report.md` |
| E4 | `nn_conv_engine` 自检 | ✅ `ENGINE_TB: PASS (46 cases, mismatch=0)`；46/46 case 的 cycles 与理论公式**完全相等** | `verify --only tb_nn_engine`；`results/ai-accel/engine-report.md` |
| E5 | **端到端 YOLO 全模型硬件推理** | ✅ **`RESULT : PASS`（108 个 op，逐 op FNV 与 golden 位精确；input_csum 一致；`hw_bad=0`）**；**NPU 纯计算 `npu_cycles=1,216,578`**（@150 MHz = 8.11 ms/帧，@131.25 = 9.27 ms）| `verify --only tb_sw_nn_yolo`（约 186–210 s）；`logs/tb_sw_nn_yolo.log` 的 `[yolo]` 行；`sw/yolo_demo.c` |
| E6 | BRAM 可行性 | ✅ Vivado 综合实测 **`Block RAM Tile 124 / 135`**（WQ 92 + 激活 32），加交付档核心约 9.5 ⇒ **133.5/135（余 1~2 块）**；旧尺寸（Q16K/A=B=128K）实测 **296/270 超限**，已封死 | `results/ai-accel/mem-report.md` §4；`results/ai-accel/proto/mem/` |
| E7 | 引擎资源 | LUT 15,213 / FF 8,029 / DSP48E1 52 / **BRAM 0**（单独 OOC 综合）| `results/ai-accel/proto/engine/synth_engine_util.rpt` |
| E8 | 模型流水线 | 权重 319,792B（≤320K）；golden `mismatch=0`；yolo_wq.hex 94,208 行；MACs@128 = 20.07M | `results/ai-accel/model-report.md` |

> **口径提醒**：E1 的 "PASS 15" 是**本分支**（含 AI 测试）的回归数；交付分支（main）仍是 PASS 12。
> 新增的 3 项都带条件登记：镜像/向量不存在时自动退出矩阵，不会把交付回归拖红。

---

## 3. 架构落地形态

```
CPU (RV32IM, 交付档不变)            NPU
  │ LSU load/store                    │ w 口 64b/拍 + 激活读 128b/拍 + 写 64b/拍
  ▼                                   ▼
┌───────────────────────────────────────────────────────────┐
│ nn_mem  512KB @0x9004_0000（窗口内偏移）                      │
│  WQ  0x00000..0x5BFFF 368KB（W 320K + Q 48K，单一初始化镜像） │
│  A   0x60000..0x77FFF  96KB（最大单张量 98,304B）             │
│  B   0x78000..0x7FFFF  32KB（与残差并存）                     │
└───────────────────────────────────────────────────────────┘
       ▲ core 新增 nn_* 端口（与 dmem 同口径：1 拍寄存读，NN_EN 门控）
nn_subsys（MMIO 0xA000_0100..，描述符寄存器 + status/cycles/err）
  └ nn_conv_engine：8×8 = 64 MAC/拍，output-stationary，requant(64 位乘/floor)+leaky
```

- WP：**没有改 CPU 微架构**；交付档只在 `core.sv`/`top_a100t.sv` 里加了 `ifdef NN_EN` 分支（无宏时逐字等价，E2 已用综合资源/时序证明）。
- **"大 cache" = scratchpad**（权重常驻 + 激活 ping-pong），**不是** tag-based I/D Cache；
  `results/p7-cache-analysis.md` 的"Cache 无收益"结论不受影响。
- 权重在**综合时烧进 BRAM**（`$readmemh`，QSPI 自启动），不依赖 DDR/外部存储；本板没有这两样。

---

## 4. 本轮修掉的 6 个真 bug（都留了证据）

| # | 症状 | 根因 | 证据 |
|---|---|---|---|
| B1 | nn_mem B 缓冲读回"漂移" | B 读索引误用写口地址 `b_addr`（应为 `a_addr`）| `mem-report.md`，T-mem TB 捕获 |
| B2 | 引擎编译不过（14 errors） | 先使用后声明 + 对括号表达式位选 | 21:39 后的 vlog 日志 |
| B3 | 引擎 SHIFT 取错字节 → 右移 1 | Q 尾部字节索引 | `engine-report.md` §6 |
| B4 | ADD 从错误 buffer 读 dst | add 的 dst 读要按地址切 `a_sel` | 同上 |
| B5 | pool 走 MAC 路径 / upsample 读回只保 1 拍 | FSM 分支 | 同上 |
| B6 | **E2E 从 op2 起 106 个 op 全错** | `sw/yolo_demo.c` 把 C 枚举 `kind` 直接写进 `MMIO_NN_OP`（两者编码不同：C 的 1=dwconv，NN_OP 的 1=maxpool）；**引擎无罪** | `sw/yolo_demo.c` 的 `hw_op_code()` 注释；t-accel 用"op2 输入按 maxpool 算"的 FNV 反推 = 现场 got，精确命中 |

另有集成层口径错：`nn_subsys` 曾把**绝对地址**直接接给 nn_mem 的 `cpu_addr`（契约要求窗口内偏移）→ CPU 对 A/B 的读写全部静默变读 0。已修并在 `nn_subsys.sv` 留注释。

---

## 5. 当前**未**达成的目标（诚实清单）

| 项 | 现状 | 下一步 |
|---|---|---|
| **int8 精度**：逐层 cos ≥0.99 / 端到端框匹配 ≥90% | ❌ 实测 128 输入：cos 均值 0.9767（91/108 层 <0.99）、框匹配 **81.5%**；320=86.1% | 根因已定位（18 个 shortcut 的 raw-add 强制 branch/sum 共享激活 scale，branch 只用 ~20 个量化台阶）。**建议**：给 add op 增加 per-tensor 源 requant 标量 `R`（tail 扩 2B，引擎 add 路径乘 R），或把 shortcut add 改 CPU 执行（不动 RTL）。见 `model-report.md` §6 |
| **上板验证** | ⏳ 未做（本轮只到综合；上板需烧 AI 档 bitstream + UART 读结果）| 下一步：AI 档 `synth --nn --prog yolo_board` → `prog_uart.bat` → `uart_capture.py`；判据是程序打印的 `RESULT : PASS` + 加速比 |
| **SW 基线加速比（实测）** | ⏳ 未测（ModelSim 跑全 SW 基线要 ~2 亿拍，太慢）；但 **NPU 纯计算时间已实测**：`npu_cycles = 1,216,578`（@150 MHz = **8.11 ms/帧**，@131.25 MHz = 9.27 ms），与 engine-report 的逐 op 周期公式和 **完全相等**（独立互证）| 板上 `yolo_board` 镜像会同时打印 `sw_cycles` / `hw_cycles` / `npu_cycles` / speedup |
| 160/320 输入 | 物理放不下（单张量/输入超 A 容量），只做了精度数据 | 保持 128；如需更高分辨率要外挂存储（另一个系统形态） |
| AI 档 fmax | ⏳ 综合中（150 MHz 目标）| 结果补进本文件 §6；若不够则按 131.25 MHz 重测并记录 |

---

## 6. AI 档综合结果（`synth --nn --prog yolo_board`）

> 状态：本轮收尾时仍在后台跑（Vivado 全流程 ~7-10 分钟）。结果出来后补在这里，**不要用估算值冒充实测**。

- 命令：`python tools\fpga_workflow.py synth --nn --prog yolo_board --no-lc --fanout-limit 128 --pblock-range off --contain-routing --place-directive AltSpreadLogic_high`
- 预期：BRAM ≈ 133/135；LUT ≈ 3.1K（CPU）+ 15.2K（engine）+ 集成胶合；FF ≈ 1.4K + 8.0K；DSP ≈ 8 + 52。
- 判据：`BUILD_TIMING=PASS` 才算 150 MHz 达标；否则记录达成 fmax → 下一轮决定 AI 档用 131.25 MHz（XDC 21/8 档）。

---

## 7. 复现（从零到 E2E）

```powershell
# 0) 环境自检（Vivado 2018.3 / ModelSim 2020.4 / riscv-gcc 15.2）
cmd /c tools\doctor.bat
# 1) 模型流水线（T-model，会生成 sim/prog/yolo/*）
python tools/yolo/download_assets.py
python tools/yolo/convert_yolo_fastest.py
python tools/yolo/quantize.py --hw 128 --augment-calib 9
python tools/yolo/golden.py --hw 128
python tools/yolo/make_vectors.py --hw 128
# 2) 生成 C 头 + 软件镜像（Lead）
python tools/nn_gen_sw.py --plan sim/prog/yolo/plan.json -o sw/yolo_plan.h
python tools/build_sw.py --all --with-hw
# 3) 回归（含 3 项 AI 测试）
python tools/fpga_workflow.py verify --force          # 期望 PASS 15
# 4) 综合（交付档不变性 / AI 档资源时序）
python tools/fpga_workflow.py synth --prog cm_hw --tag ai-nn-parity --no-lc --fanout-limit 128 --pblock-range off --contain-routing --place-directive AltSpreadLogic_high
python tools/fpga_workflow.py synth --nn --prog yolo_board --no-lc --fanout-limit 128 --pblock-range off --contain-routing --place-directive AltSpreadLogic_high
```
