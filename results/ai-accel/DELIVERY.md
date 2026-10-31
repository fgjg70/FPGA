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
| E4 | `nn_conv_engine` 自检（v2 流水化版） | ✅ `ENGINE_TB: PASS (46 cases, mismatch=0)`；46/46 case cycles 与公式**完全相等**；OOC 综合 @150MHz **WNS +0.121（MET）**，LUT 17,634 / FF 11,073 / DSP 40 / BRAM 124 | `verify --only tb_nn_engine`；`engine-report.md` §0.5；`proto/engine/synth150_*.rpt` |
| E5 | **端到端 YOLO 全模型硬件推理**（v2 引擎 + v0.5 cpu_add 计划） | ✅ **`RESULT : PASS`（108 个 op，逐 op FNV 与 golden 位精确；input_csum 一致；`hw_bad=0`）**；**NPU 纯计算 `npu_cycles=1,290,062`**（@150 MHz = **8.60 ms/帧**；@131.25 = 9.83 ms）—— 与引擎"逐 op 公式求和"**完全相等**（`proto/engine/full_model_estimate.md`，0.00% 差）| `verify --only tb_sw_nn_yolo`（约 190–212 s）；`logs/tb_sw_nn_yolo.log` 的 `[yolo]` 行；`sw/yolo_demo.c` |
| E6b | AI 档全实现（v2 引擎，150MHz） | ⏳ 进行中（见 §6）| `synth --nn --nn-clk-div 7 --prog yolo_board` |
| E6 | BRAM 可行性 | ✅ Vivado 综合实测 **`Block RAM Tile 124 / 135`**（WQ 92 + 激活 32），加交付档核心约 9.5 ⇒ **133.5/135（余 1~2 块）**；旧尺寸（Q16K/A=B=128K）实测 **296/270 超限**，已封死 | `results/ai-accel/mem-report.md` §4；`results/ai-accel/proto/mem/` |
| E7 | 引擎资源（v2） | LUT 17,634 / FF 11,073 / DSP 40 / BRAM 0（引擎单独 OOC；含 nn_mem 的 wrapper 是 LUT 17.6K + BRAM 124）| `results/ai-accel/proto/engine/synth150_util.rpt` |
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
| **int8 精度**：逐层 cos ≥0.99 / 端到端框匹配 ≥90% | ❌ **判据本身不可达（已用理想 QDQ 上限证明）**：per-tensor int8 的理论上限 cos 均值 **0.9889**/最小 0.9670（float 累加+理想舍入），交付实测 0.9742/0.9174；端到端框匹配 128=**81.8%**（相对 float 的检测一致性；评测集 5 真实图+9 确定性增广）| Round-2 已实施 `cpu_add`（shortcut 改 CPU+per-tensor 源 requant，golden mismatch=0、apples-to-apples 证明无回归）但仍受方案上限限制。要过 0.99/90% 需改量化粒度（per-channel 激活或关键张量 16-bit）=契约+RTL 改动，**本轮决策：不做**。见 `model-report.md` §0/§6.2/§6.5 |
| **上板验证** | ⏳ 未做：**2026-11-01 JTAG 探测 `no current hw_target`（板卡不在位）**；步骤已写成可照做的清单 [`BOARD-RUN.md`](BOARD-RUN.md) | 板子接上后：AI 档 `synth --nn --prog yolo_board` → `prog_uart.bat`（`UART_BIT` 指 AI bitstream）→ `uart_capture.py`；判据 `RESULT : PASS` + `sw_cycles/hw_cycles/npu_cycles/speedup` |
| **SW 基线加速比（实测）** | ⏳ 未测（ModelSim 跑全 SW 基线要 ~2 亿拍，太慢）；但 **NPU 纯计算时间已实测**：`npu_cycles = 1,216,578`（@150 MHz = **8.11 ms/帧**，@131.25 MHz = 9.27 ms），与 engine-report 的逐 op 周期公式和 **完全相等**（独立互证）| 板上 `yolo_board` 镜像会同时打印 `sw_cycles` / `hw_cycles` / `npu_cycles` / speedup |
| 160/320 输入 | 物理放不下（单张量/输入超 A 容量），只做了精度数据 | **用户已确认板上有 2 片 DDR3 + 摄像头（接口待定）** → 这是"更高分辨率/更大模型"的正确外挂存储；演进路线见 PLAN §9（当前 BRAM-only 交付不受影响） |
| AI 档 fmax | ⏳ 综合中（150 MHz 目标）| 结果补进本文件 §6；若不够则按 131.25 MHz 重测并记录 |

---

## 6. AI 档实现结果

### 6.1 v2 引擎 @150MHz 全实现（2026-11-01 00:24–00:56，`--nn-clk-div 7`）

| 项 | 实测 |
|---|---|
| 时序 | ❌ **WNS −3.798 ns → 达成 fmax 95.6 MHz**（build.tcl 拒绝写 bitstream）|
| 资源 | LUT **25,208** / FF **12,945** / BRAM **133** / DSP **48** |
| 说明 | OOC 综合 +0.121 与全实现 −3.8 差距大：24K LUT + 124 BRAM 的拥塞使 route 占比远高于 OOC 估计 |

### 6.2 bc2 快照（B 控制 one-hot + C requant 48 位 + base0 两级）@150MHz 全实现

- `nn_conv_engine.sv` SHA256 **`27d59a87…b32413`**（44,923 B）；OOC 150MHz **WNS +0.489**，LUT 16,859 / FF 10,840 / DSP 39 / BRAM 124。
- 周期不变：`npu_cycles` 仍 **1,290,062**（46 case 逐 case cycles 与 v2 完全相同）。
- **87.5 MHz（`--nn-clk-div 12`）全实现**：⏳ 进行中（按 v2@150 的 10.465ns 路径 + bc2 的 ~+0.5ns 推算，11.43ns 周期应有 ≥+1ns 余量）。
- 若 87.5 MET → 产出 `fpga/cpu_a100t_nn.bit`（board-ready）；之后再按需往 95.45/105 MHz 迭代（t-accel 还有 bc3 草稿 +0.096 OOC）。

### 6.3 v1 引擎 @150MHz 全实现（历史，2026-10-31 22:19–23:07）

| 项 | 实测 | 与预期 |
|---|---|---|
| **Block RAM Tile** | **133.5 / 135（98.89%）** | 与预算 133/135 **逐块吻合** ⇒ 512KB 大 BRAM 方案**确认放得下** |
| LUT | 23,874（37.7%）= CPU 3098 + engine 15.2K + 集成胶合 | 符合，未超器件 |
| FF | 10,228（8.1%） | 符合 |
| DSP48E1 | 60（25%） | 符合（8 CPU + 52 engine） |
| **时序（150 MHz 约束）** | ❌ **WNS −18.416 ns → 达成 fmax 39.9 MHz**；21,531 个失败端点 → `BUILD_TIMING=FAIL`，**build.tcl 按纪律拒绝写 bitstream** | 未达标 |

**最差路径（决定性）**：`u_nn/u_eng/d_ks_reg → u_nn/u_mem/u_wq/mem_a_reg/ADDRARDADDR[12]`，
**24.5 ns / 32 级逻辑 / 17×CARRY4 + 2×DSP48E1** —— 是引擎的**权重地址生成组合链**
（`(tap*ic8+ic)*oc8` 等 32 位乘加全挤在一拍）。报告归档：`results/ai-accel/impl/ai150_{util,timing}.rpt`。

**AI 档可降频（已实现，交付档不受影响）**：AI 核心时钟已参数化 ——
`--nn-clk-div N`（VCO 1050MHz / N；标准档 7=150、8=131.25、10=105、11=95.45、12=87.5、14=75、21=50 MHz），
三处同源：`top_a100t.sv` 的 `CLKOUT0_DIVIDE_F`+`CLK_HZ`、`daVinciPro.xdc` 的 `-divide_by`（env `NN_XDC_DIV`）、
`build.tcl` 的 `NN_CLK_DIV`。所以"引擎最终只能跑到多少"决定 AI 档用哪个频点，**不必再改交付档**。

**结论与下一轮修法**（不做流水化就不可能上板演示）：
1. **timing 修复**（推荐）：把引擎的地址生成/描述符译码拆成 2~3 级流水（`d_ks*oc8`、`tap*ic8` 先打一拍；
   requant 的 64 位乘 + 右移 + 饱和再拆一级），目标先冲 **100~125 MHz**；
   引擎是模块级 OOC 综合、不依赖 CPU，改流水化不影响交付档。
2. **临时演示档**：若赶时间，AI 档锁 **35~39 MHz**（MMCM 21/30 = 35 MHz）也能跑通（NPU 1.22M 拍 ⇒ 35 ms/帧），
   但"150 MHz 交付档不受影响"这条不能破——AI 档本来就是独立构建。
3. 下一步**才**做上板：`synth --nn`（timing 修复后）→ `prog_uart.bat` → `uart_capture.py`，
   判据是 `[yolo] RESULT : PASS` + `sw_cycles/hw_cycles/npu_cycles/speedup` 行。

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
