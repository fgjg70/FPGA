# NPU 核心 SV → Verilog 转换报告（可上板版本）

> 目标：把你的 SystemVerilog NPU 核心转成**可综合的 Verilog**，并**用行为级仿真证明与原版逐位一致**。
> 前提（按你的指示）：**假设 DDR3 可用、不做上板**，只做行为级仿真。
> 日期：2026-11-04。执行：Lead（本地 Xilinx Vivado 2018.3 xsim + sv2v v0.0.13）。

---

## 0. 结论速览

| 项 | 结果 |
|---|---|
| **转换方法** | `sv2v v0.0.13`（Windows 版，自动转换）+ **3 处手工修补** |
| **输入** | `nn_pkg.sv`(191 行) + `nn_conv_engine.sv`(1,574 行) + `nn_mem.sv`(867 行) = **2,632 行 SV** |
| **输出** | **`nn_core.v` 2,628 行纯 Verilog**（`nn_conv_engine` + `nn_mem` 两个模块） |
| **SV 特性残留** | `always_comb` / `always_ff` / `logic` / `typedef` / `struct` / `enum` / `package` / `import` / `int` / `bit` / `byte` / `unique case` / `->` **全部为 0** |
| **结构体端口** | `nn_desc_t desc` 被拍平为 **`input wire [210:0] desc`**（211 bit） |
| **编译** | `xvlog` 分析通过（`nn_conv_engine` + `nn_mem` 均 OK） |
| **仿真** | **`ENGINE_TB: PASS (58 cases, mismatch=0)`** —— 47 基线 + 9 M1 + 2 SA 全过 |
| **行为一致性** | 关键 case 周期与你 A7a 记录**逐拍一致**（见 §3） |

---

## 1. 转换链路

```
feat/ai-accel:nn_pkg.sv
feat/ai-accel:nn_conv_engine.sv   ──sv2v v0.0.13──▶  nn_core.v (2,628 行 Verilog)
feat/ai-accel:nn_mem.sv
```

工具获取：GitHub release `sv2v-Windows.zip`（v0.0.13）。**Linux 版在 WSL 未安装的情况下不可用**，
所以用的是 Windows 原生 exe。

### 3 处手工修补（sv2v 覆盖不到的部分）

| # | 问题 | 修补 |
|---|---|---|
| 1 | `nn_mem` 的 `initial` 块（`ifndef SYNTHESIS` 内，仿真用文件加载）里有 `string fname; string line;` | 改为 `reg [8*512-1:0] fname;` / `reg [8*4096-1:0] line;`（`$fopen/$fgets/$sscanf` 在 xsim 下接受定宽 reg 向量） |
| 2 | 转换结果缺 `` `timescale ``，导致 xelab 报 `nn_mem_default doesn't have a timescale` | 文件头加 `` `timescale 1ns/1ps `` |
| 3 | TB 是 SV，正常例化 `nn_desc_t` 结构体端口 | `.desc(desc)` → **`.desc({>>{desc}})`**（SV 流式拼接，把结构体打成 211 bit 总线） |

> 除此之外**未改任何 RTL 语义**：状态机、数值公式、周期公式、`ifdef SYNTHESIS` 保护全部原样。

---

## 2. 产物位置（已入库）

| 文件 | 说明 |
|---|---|
| `fpga_pg2l100h/vision/rtl/nn/nn_core.v` | **可上板的 Verilog 核心**（`nn_conv_engine` + `nn_mem`），2,628 行 |
| `fpga_pg2l100h/vision/rtl/nn/nn_pkg.sv` | 原 SV 包（仅 TB 需要；DUT 已不含 package） |
| `fpga_pg2l100h/vision/rtl/nn/sim/tb_nn_engine.sv` | 自校验 TB（只改了 desc 端口一处） |
| `fpga_pg2l100h/vision/rtl/nn/sim/sim.args` | xsim 参数文件（向量目录 + `misall`） |
| `fpga_pg2l100h/vision/rtl/nn/sim/xsim_pass.log` | **本次仿真的完整 90 行日志**（含 58 cases 逐条结果与 SUMMARY） |

---

## 3. 仿真结果（与原版行为逐位一致）

```
SUMMARY   cases=47 pass=47 fail=0 total_mismatch=0
M1SUMMARY cases=9  pass=9  fail=0 mismatch=0
SASUMMARY cases=2  pass=2  fail=0 mismatch=0
ENGINE_TB: PASS (58 cases, mismatch=0)
```

**关键 case 与你 A7a 文档对账**（`A7A-RESULTS.md`）：

| case | 本次转换版（周期） | A7a 文档记录 | 一致性 |
|---|---|---|---|
| `dw3x3_c16` | **569** | 1118 → **569**（−49.1%） | ✅ |
| `dw5x5_c16` | **1913** | 3806 → **1913**（−49.7%） | ✅ |
| `m1_ic864_dw3x3` | **22958** | 45260 → **22958**（−49.3%） | ✅ |
| `replay_l0_conv0` | **130067** | （conv0 PACKED3 基线） | — |

> 这说明：**转换后的 Verilog 不只是"能编译"，而是与你的 SV 原版在数值与周期上都逐位一致。**

---

## 4. 仿真怎么复现（3 条命令）

```powershell
# 1) 编译（DUT 是 Verilog，TB 是 SV）
xvlog -sv nn_pkg.sv tb_nn_engine.sv nn_core.v

# 2) elaborate
xelab -L work tb_nn_engine --snapshot tb_sim --debug typical

# 3) 跑（向量目录用正斜杠，反斜杠会被 xsim 吃掉）
xsim tb_sim -R --testplusarg "vec=<repo>/results/ai-accel/proto/engine/vec" --testplusarg misall
```
向量目录 `results/ai-accel/proto/engine/vec/`（241 个 `.wr` 文件 + `manifest.txt`）本机已存在；
若需重生成，用 `results/ai-accel/proto/engine/gen_vectors.py`（它从 `nn_pkg.sv` 现场解析地址常量）。

---

## 5. 可上板性评估（诚实版）

| 项 | 状态 |
|---|---|
| 语言 | ✅ 纯 Verilog（无 SV 语法），`xvlog` 用**默认 Verilog 模式**即可分析 |
| 综合保护 | ✅ 文件加载逻辑在 `ifndef SYNTHESIS` 内（综合时自动去掉 `$fopen/$fgets/$sscanf`） |
| 存储器推断 | ✅ `(* ram_style = "block" *)` 属性保留（Xilinx 语义；Pango PDS 会按普通 RAM 推断，需要复核） |
| 已知未做 | ❌ **未跑综合**（本轮只做行为级仿真）；❌ **未在 Pango PDS 上验证**；❌ 配套的 `nn_seq/nn_subsys/nn_wload/nn_tilecache`（DDR3 流式那条链）**尚未转换** |
| DDR3 | 按你的指示**假设可用**；本轮仿真用片上 `nn_mem` ROM 路径，未接 `nn_wload` |

---

## 6. 下一步（同一条链路可直接复用）

1. **同法转换剩余 4 个模块**：`nn_seq.sv`(540) / `nn_subsys.sv`(672) / `nn_wload.sv`(638) / `nn_tilecache.sv`(503) —— 用同一 sv2v 命令 + 同样的 3 类修补。
2. **接 DDR3 行为模型**：仓库已有 `sim/beh_ddr3.sv`（在 `feat/ai-accel` 分支），可与 `nn_wload` 一起做流式仿真。
3. **综合验证**：先用 Vivado 2018.3 综合 `nn_core.v` 确认可收敛（资源/时序），再交 Pango PDS 工程。
4. **把 TB 也转 Verilog**（可选）：`string`/`int` 在 TB 里较多，sv2v 转换后仍需少量修补；保持 SV TB 也能被 xsim/ModelSim 正常编译。
