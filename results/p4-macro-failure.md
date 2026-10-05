# P4 · 宏失效事故与配置回退（**必读：它推翻了 P3 的两个结论**）

**日期**：2026-10-05  **结论：P3 的"零代价优化"不成立，已回退到上板验证过的配置**

---

## 1. 发现了什么

在给方向预测器加 gshare 时, 发现改动**完全没效果**。顺藤摸瓜查出工具的一个
静默 bug (`PITFALLS` R17):

```python
# tools/fpga_workflow.py 原代码
flags = ["+" + d for d in defines]        # -> vlog -sv +IMEM_REG_READ ...
```

**`vlog` 把 `+FOO` 当未知选项, 宏根本不会被定义, 而编译"成功"**。实测最小复现:

```
vlog -sv +FOO         ->  RESULT: FOO_NOT_DEFINED
vlog -sv +define+FOO  ->  RESULT: FOO_DEFINED
```

正确写法是 `+define+NAME`。

### 为什么后果严重

综合侧走的是 Tcl 的 `-verilog_define`，**那个是生效的**。于是形成
**"综合开了宏、仿真没开宏"** —— 两边跑的不是同一份设计：

| | 综合侧（宏生效）| 仿真侧（宏**未**生效）|
|---|---|---|
| `IMEM_REG_READ` | LUT 3945 → **2656** | 一直跑组合读版本 |
| `LOAD_RESULT_REG` | fmax 65.3 → **75.0** | 一直跑组合版本 |
| 结论 | 数字是真的 | **"ticks 逐位不变、零代价"是假的** |

也就是说 `results/p3-imem.md` 与 `results/p3-load-result.md` 里
**"CoreMark/MHz 逐位不变"这条证据是无效的** —— 它测的根本不是那份设计。

## 2. 修好宏传递后的实测

```
配置                     结果      ticks
------------------------------------------------------
三个宏全关 (基线)          PASS     423527
仅 IMEM_REG_READ          FAIL     仿真 timeout (取指与 PC 配对错位)
仅 LOAD_RESULT_REG        FAIL     仿真 timeout
仅 BTB_GSHARE             PASS     449317   <- 能跑, 但比基线慢 6%
三个全开 (原默认)          FAIL     仿真 timeout
```

即：两个所谓"零代价优化"实际是**坏的**，第三个（gshare）是**负优化**。

### 为什么上板还能 PASS

因为**上板跑的是 ILA 版 bitstream**，而 `build_ila.tcl` 的 `verilog_define`
**只给了 `USE_ILA` + 两个镜像路径，没带任何架构宏** —— 也就是上板验证的是
**"三个宏全不开"** 的配置。而评分版当时默认开宏。
**"上板验证通过"并不等于"评分版通过了"**（`PITFALLS` R18）。

## 3. 处置

1. `fpga/build.tcl` 与 `tools/fpga_workflow.py verify` 的默认值**统一改成三个宏全关**，
   与上板验证过的配置一致。要用必须显式指定（`IMEM_REG_READ=1` / `LOAD_REG=1` /
   `BTB_GSHARE=1`，仿真侧 `--imem_reg_read` / `--load_reg` / `--gshare`）。
2. 三个宏都**必须在仿真里跑通 `verify` 才允许综合**。
3. 加**自证标志**：宏生效时模块 `$display` 一行（如 `[btb] GSHARE ... ACTIVE`），
   否则"改了没效果"永远分不清是算法无用还是宏没定义。

## 4. 真实基线（重新综合，三宏全关）

| 指标 | 值 |
|---|---|
| CoreMark/MHz | **2.3611**（ticks 423,527）|
| fmax | **61.6 MHz**（WNS 3.763 ns）|
| LUT / FF / BRAM / DSP | **4019** / 1387 / 4 / 8 |
| CoreMark/LUTs | **5.875e-4** |
| 绝对吞吐 | **145.4** |

### 相对基线的真实提升

| 指标 | 基线 | 现在 | 变化 |
|---|---|---|---|
| CoreMark/MHz | 0.8263 | **2.3611** | **+185.8%** |
| fmax | 78.4 | 61.6 | −21.4% |
| CoreMark/LUTs | 2.361e-4 | **5.875e-4** | **+148.8%** |
| 绝对吞吐 | 64.8 | **145.4** | **+124.4%** |

> 此前宣称的 70.9 MHz / 2526 LUT / +158.5% **不可复现** —— 它对应的是
> "宏全开"的配置，而那个配置**仿真跑不过**。

## 5. 待重做（按收益排序）

### 5.1 `IMEM_REG_READ` —— 根因已定位（收益最大：LUT −1228, 占全核 31%）

**失败根因：取指相位错位，而且不止一处。**

`core.sv` 原来是：
```systemverilog
.pc_in    (pc),          // cycle N 的 PC
.instr_in (imem_rdata),  // 寄存读 -> instr(pc_{N-1})
```
寄存读让 `rdata` 比 `addr` 晚一拍，于是 `if_pc` 与 `if_instr` **不再是同一条指令的
PC 与指令字**。原先的注释写着"两者由同一个 if_id 寄存器锁存, 所以始终配对" ——
**这个推理是错的**：配对的前提是它们本来就同源，寄存读破坏了这个前提。

**第一处已修**（`core.sv`，`IMEM_REG_READ` 门控，组合读模式下 `pc_if = pc`
即零代价、行为不变）：给进 `if_id` 的 PC 也加一级寄存器。

修完的效果：**timeout 消失**，`tb_units` 通过，`tb_core_basic` 从"完全跑不动"
变成**只挂测试 2（load-use）** —— 说明取指已经基本对齐，但还没完全对。

**第二处尚未修**：BTB 预测。预测是**组合地**用当前 `pc` 做的
（`u_btb .pred_pc(pc)`），所以 cycle N 得到的是**对 pc_N 的预测**；
而寄存读下同拍 `imem_rdata` 是 **pc_{N-1} 的指令**。等 PC 延迟对齐后，
预测与指令虽然同拍进 `if_id`，但**预测对应的 PC 与指令对应的 PC 差一拍** ——
于是 `pred_taken`/`pred_target` 贴到了错误的指令上，误判与错误目标随之而来。

正确做法是把 BTB 的预测口也挂到**同一条延迟后的 PC** 上（即用 `pc_if` 查表），
或者把取指重构成标准的"取指地址寄存器 + 指令缓冲"结构（FAR + instruction queue）。
注意 `pred_target` 还要与 `pc_plus4` 的基准保持一致。

### 5.2 `LOAD_RESULT_REG` —— 收益 fmax +14.8%

`mem_load_data` 的有效拍需要重新对齐（dmem 寄存读下它晚一拍）。
修好 5.1 之后再动它，否则两个相位问题会混在一起难以分离。

### 5.3 `BTB_GSHARE` —— 实测慢 6%，需调参

已实现（`btb.sv` 的 `BTB_GSHARE` 宏，含自证 `$display`），但 6 位历史的 gshare
在 CoreMark 上**不如**纯局部 2 位 Smith（ticks 423527 → 449317）。可试：
只对条件分支记历史、缩短/加长历史、加 tournament 与 Smith 混合。
另：实测 **JALR 误判占全部误判的 37%**，RAS 是独立的收益点（历史记录 RAS+BTB128
那次是净亏，但那是**同时**改了 BTB 容量）。

> 教训：**"完全不变"往往是"没生效"的征兆，而不是"代价为零"的证据。**
