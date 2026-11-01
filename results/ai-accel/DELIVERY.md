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
| **上板验证** | ⏳ 只差"烧进去"这一步：**bitstream 已就绪（87.5MHz, WNS +0.135，sha256 `489510b8…`）**，但 **2026-11-01 JTAG 探测仍 `no current hw_target`（板卡不在位）** | 板子接上后照 [`BOARD-RUN.md`](BOARD-RUN.md)：`UART_BIT=...cpu_a100t_nn.bit` → `prog_uart.bat` → `uart_capture.py`；判据 `RESULT : PASS` + `sw_cycles/hw_cycles/npu_cycles/speedup`（板上跑的是 yolo_board 双遍模式，会同时打印软件基线与加速比）|
| **SW 基线加速比（实测）** | ⏳ 未测（ModelSim 跑全 SW 基线要 ~2 亿拍，太慢）；但 **NPU 纯计算时间已实测**：`npu_cycles = 1,290,062`（@87.5 MHz = **14.74 ms/帧**；@150 = 8.60 ms；@131.25 = 9.83 ms），与 engine-report 的逐 op 周期公式**完全相等**（独立互证，0.00% 差）| 板上 `yolo_board` 镜像会同时打印 `sw_cycles` / `hw_cycles` / `npu_cycles` / speedup |
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
| 过程 bug | **XDC 里写 if/puts 被 Vivado 2018.3 静默丢弃**（CRITICAL 20-1307）→ 第一版 87.5MHz 构建其实仍按 150MHz 布线。已修：build.tcl 生成"字面量分频"的 XDC 副本 + `BUILD_NN_XDC_GEN=` 自证 + workflow 硬门；见 `skills/fpga-riscv-a100t/PITFALLS.md` R52 |

### 6.2 bc2 快照（B 控制 one-hot + C requant 48 位 + base0 两级）@150MHz 全实现

- `nn_conv_engine.sv` SHA256 **`27d59a87…b32413`**（44,923 B）；OOC 150MHz **WNS +0.489**，LUT 16,859 / FF 10,840 / DSP 39 / BRAM 124。
- 周期不变：`npu_cycles` 仍 **1,290,062**（46 case 逐 case cycles 与 v2 完全相同）。
- **87.5 MHz（`--nn-clk-div 12`）全实现：✅ PASS（2026-11-01 01:35）**：
  `BUILD_OK` + `BUILD_TIMING=PASS`，**WNS +0.135 ns，fmax 88.5 MHz**；
  资源 **LUT 25,212 / FF 12,782 / BRAM 133 / DSP 47**；
  产物 **`fpga/cpu_a100t_nn.bit`**（3,825,894 B，sha256 `489510b8…d91d3c0`）→ **board-ready**。
  报告归档：`results/ai-accel/impl/ai875_{util,timing}.rpt` + `ai875_metrics.json`。
- **关键路径已换成集成路径**：`u_core/u_ex_mem/alu_out → u_nn/u_mem/u_wq/mem_a ADDRARDADDR`
  （10.87ns，其中 **route 占 71.8%**，14 级逻辑）——引擎内部已经让位，下一轮提频的杠杆是
  **nn_mem 的 CPU→WQ 地址路径 + 布局（pblock/place）**，不是再拆引擎流水。
- 下一轮提频候选：95.45/105 MHz（需先把上面这条 CPU→WQ 路径或布局优化出 ~1.5ns）；
  t-accel 还有 bc3 草稿（+0.096 OOC），但它只修引擎内部,对当前瓶颈帮助有限。

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


---

## 8. v0.7 特化里程碑（2026-11-01 晚，**112-op 双模 E2E 全绿**）

> 目标：固定模型（`MODEL-FREEZE.md`）+ 128 MAC/拍 + LUTRAM 存储 + 微码 ROM 自主执行。
> 视频/显示由其他同学负责，本节只覆盖 NPU。

### 8.1 E2E（`verify --only tb_sw_nn_yolo`，PASS 65.5s）

```
[yolo] ops=112 in=128x128x3
[yolo] input_csum=0xcfd271c5 exp=0xcfd271c5 OK
[yolo] hw_bad=0      hw_cycles=10445588  npu_cycles=1167368     ← MODE_CPU：CPU 逐 op 下发 + 逐 op checksum
[yolo] auto_bad=0    auto_cycles=1167968 auto_npu_cycles=1167368 ← MODE_AUTO：nn_seq 按微码 ROM 自主跑完
[yolo] RESULT : PASS
```
- 两种模式 **NPU 周期完全相等（1,167,368）** ⇒ 双模等价性成立；
- 全模型 112 op 中 **0 个 CPU 执行 op**（conv0 由引擎 PACKED3、18 个 shortcut add 由引擎 ADD_R、6 个 copy 由引擎 COPY）。

### 8.2 组成与资源（实测）

| 项 | 结果 |
|---|---|
| 引擎 v3（128 MAC/拍） | 47/47 单测（含全尺寸 l0 conv0 replay）+ 4/4 扩展模式，真 nn_mem 下 mismatch=0 |
| nn_seq 微码序列器 | ROM 112 项；单测 PASS（112 次启动/desc 映射/周期累加/错误注入）|
| nn_mem v0.7 R3 | W 80 BRAM36（4 段 64-bit 宽、双读口支持 8B 对齐 16B 窗口）、Q 0 BRAM/6,981 LUT、A/B 32 ⇒ **112 tiles**；tb_nn_mem 3 模式 47,146 checks PASS |
| 整机 BRAM | 112 + 核心 ~9.5 ≈ **121.5/135**（满足 ≤121.5 目标）|
| OOC @100MHz（engine+mem）| **WNS +0.807（MET）**；LUT 31,066（含 Q ROM 6,976 ⇒ 引擎逻辑 ≈24.1K）；FF 13,779；DSP 200 |
| C128 全模型周期 | **1,167,368 拍**（@100MHz 11.67ms ≈85.7fps 上限）|

### 8.3 本轮修掉的集成 bug

1. **W 读口对齐**：nn_mem 按 16B 粒度、引擎按 8B 粒度发 `w_addr` → 74/84 个 conv/dw 读错权重；修法：nn_mem 4 段 64-bit 双读口 + 1 位窗口 mux（1 拍、W 80 BRAM）。
2. **PACKED3 x-tile 步长**：`p3_ox` 误写 `(iw*3)<<4`，应为 `8*st*3`（48/24B）→ 每行第 2 个 tile 起全错（SoC op0 前 8 像素对、byte64 起错，27155/32768 字节）；已修并新增全尺寸 l0 replay。
3. **MODE_AUTO done/err 非粘滞**：`seq_done` 单拍脉冲直连 STATUS，CPU 轮询漏掉 → ROM 跑完 idx=112 但 CPU 卡死；改为 done_r/err_r 粘滞（MODE_CPU 一直如此，所以此前未暴露）。

### 8.4 剩余（NPU 优化主线）

1. 时序：WNS ≥ +1.0（当前 +0.807）、DSP ≤160（当前 200）、引擎逻辑 LUT ≤25K（当前 24.1K ✓）；
2. dw 16-lane（C128 阶段 dwconv 占 38.6% 周期）、conv0 loader 优化（129,555 → 目标 ~60k）；
3. C320 集成（DDR3 中间激活，P3）+ 30fps 路线决策（PX16 评估见 `PX16-STUDY.md`）；
4. 全实现 `synth --nn` ≥100MHz + bitstream（board-ready，板卡当前不在位）。


---

## 9. v0.7 AI 档交付（2026-11-01 晚，**100MHz 全实现 PASS + bitstream**）

### 9.1 交付物

| 文件 | 说明 |
|---|---|
| `fpga/cpu_a100t_nn.bit` | **v0.7 AI 档 bitstream，100MHz**，3,825,894 B，sha256 `6ab25b9bdf76c6cf3cd21396aee25a6312bf16786bd2989b6c79baddec22f0ee`（2026-11-01 20:26 写入）|
| `results/ai-accel/impl/ai100/cpu_a100t_nn_100mhz.bit` | 同上，归档副本 |
| `results/ai-accel/impl/ai80/cpu_a100t_nn_80mhz.bit` | 80MHz 版本（WNS +0.380，sha256 `dea6a1ee47a771ba300a9dd9221e6d13279460a2a0b101785afb307a7a75b6cb`），备选 |
| `results/ai-accel/impl/nn_mem_ooc/` | nn_mem OOC DCP（黑盒链接用）、8 个时钟变体、no-clock DCP、复现脚本/报告 |

### 9.2 全实现实测（100MHz）

```
BUILD_TIMING=PASS  WNS +0.049ns  WHS +0.051ns   fmax 100.5MHz
LUT 36,985 / FF 16,381 / BRAM 132 / DSP 168
CoreMark/MHz 2.7063（交付档 CPU 未受影响）
```
- 最差路径：`u_nn/u_eng/wa_r[*] → u_nn/u_mem/w_cur_*`（**route 8.881ns，logic 0 级**，纯物理距离）；
- 时钟：`sys_clk_core` 125→100MHz（`--nn-freq-mhz 100`，MMCM 12/6，XDC/CLK_HZ 三处同源自证）。

### 9.3 构建流程修复（本轮关键工程突破）

1. **W 320KB / Q 常量 ROM 的 in-context 展开**：默认推断会把 W 展开成 **5,248,702 个未映射寄存器**，使综合卡 2.5~3 小时；
   修复：`nn_mem` 的 W 4 段 + Q 显式 `rom_style="block"`，并把 `nn_mem` 做成 **OOC DCP 黑盒**（`fpga/nn_mem_bb.sv` + `read_checkpoint -cell u_nn/u_mem`）→ **综合 3.5 分钟**；
2. **Q 拆分**：`q_mem_lo`(4096×64) 落 8 tiles BRAM + `q_mem_hi`(2048×64) 落分布式 ROM → mem 120 tiles（整机 132/135）；
3. **去掉 OOC DCP 内 `create_clock`**（`nn_mem_noclk.dcp`）：消除了 `sys_clk_core → clk` 跨时钟分析造成的 **−3.526ns 时钟偏斜**，整机 WNS 从 80MHz 的 +0.380 提升到 100MHz 的 +0.049。

### 9.4 时序收敛过程（实测轨迹）

| 阶段 | 频点 | WNS | 结论 |
|---|---|---|---|
| OOC 综合（engine+mem） | 125MHz | +1.371 | 模块级可行（不等于整机） |
| 整机全实现 | 125MHz | **−3.739** | FAIL（fmax ≈85MHz） |
| 整机全实现（no-clock DCP） | 80MHz | +0.380 | PASS（备选 bitstream） |
| **整机全实现（no-clock DCP）** | **100MHz** | **+0.049** | **PASS（当前交付）** |

> 下一步冲 125/131MHz：最差路径已是纯 route 8.88ns（engine→mem 物理距离），优化方向 = `u_nn` pblock/floorplan 让 engine 与 BRAM 同区 + 引擎侧 `wa_r/la` 前移流水（t-accel E 方案）。

### 9.5 验证证据

- **全量回归 `verify --force` → PASS 16**（12 项原回归 + `tb_sw_nn_demo` / `tb_sw_nn_yolo` / `tb_nn_mem` / `tb_nn_engine` / `tb_nn_seq`）；
- **112-op 双模 E2E**：`hw_bad=0 / auto_bad=0`，MODE_CPU 与 MODE_AUTO 的 NPU 周期均为 **1,177,320**（双模等价）；
  @100MHz ⇒ 11.77ms/帧（128×128 输入，理论 85fps 上限）；
- 交付档（无 `NN_EN`）功能回归包含在 PASS 16 内。

### 9.5.1 交付档 parity 实测（**逐项不变，已复现**）

用交付档合法配方 `--no-lc --fanout-limit 128 --pblock-range off --contain-routing --place-directive AltSpreadLogic_high` 在**当前分支**重建（无 `NN_EN`）：

```
BUILD_TIMING=PASS  WNS +0.007ns  WHS +0.038ns  fmax 150.2MHz
LUT 3098 / FF 1447 / BRAM 9 / DSP 8
CoreMark/MHz 2.7063 (369,506 ticks)
```
**与历史交付 invariant（LUT 3098 / FF 1447 / BRAM 9 / DSP 8 / fmax 150.2 / WNS +0.007）逐项相同** ⇒ AI 改动未改变交付档网表。

交叉验证：用 **AI 分支之前的基线提交**（`d592067`，2026-10-24）在干净 worktree 里按同样配方重建，得到与当前分支**完全相同**的 2892/1476/9/8（不加 R58 合法配方时）/ -0.382（150MHz）；加合法配方后两边均回到 3098/1447/+0.007 ⇒ 差异只来自构建配方，不来自 AI RTL。

### 9.6 板卡部署状态

**板卡不在位（2026-11-01 多轮 JTAG 探测均为 `no current hw_target`，无 USB-TTL 串口）**：
- bitstream 已就绪，接板即可按 `BOARD-RUN.md` 烧写；
- 上板判据（`yolo_board` 两遍镜像）：`sw_bad=0`、`hw_bad=0`、`RESULT : PASS`、`sw_cycles/hw_cycles/npu_cycles/speedup`；
- 无板替代证据：ModelSim 两遍仿真（软件基线+NPU）正在产出 `sw_cycles/speedup`；CPU 软件基线 vs 加速器逐层位精确比对已由 112-op E2E 的 per-op checksum（`hw_bad=0`）+ golden 向量证明。
