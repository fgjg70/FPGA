# P4 · 宏失效事故与配置回退（**必读：它推翻了 P3 的两个结论**）

> ⚠️ **历史记录（2026-10-05）**：本文里的 `11 项`/`PASS 11` 是**当时**的回归基线；
> 现在是 **PASS 12**（新增 `tb_sw_lu_bench`）。正文不改，引用时注意口径。

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

### 5.1 `IMEM_REG_READ` —— ✅ **2026-10-06 打通：零周期代价，LUT −30.9%**

> **2026-10-06 更新：已从"可选宏"提升为默认路径。** 宏语义已反转 ——
> **不定义任何宏**就是"imem/dmem 全 BRAM"，`IMEM_COMB_READ` 才是回退开关。
> 交付配置：`imem` = RAMB36 ×4、`dmem` = RAMB36 ×4（合计 **8 块**）。
> 实测 2.3611 / 58.9 MHz / LUT 2820 / 8.373e-4 / 139.1，上板 PASS、
> tick **508,155,404**（与历史各版本逐位相同）。见 `gap-analysis.md` 的存储策略小节。

**结果**：LUT **4079 → 2820**（**−1258，−30.9%**），imem 落进 **RAMB36 ×4**，
而 **CoreMark/MHz 逐位不变（2.3611）**、**CoreMark ticks 逐位不变（423527）**。
代价：fmax 61.2 → 58.9 MHz（**纯布线**，见 5.1.4）。

#### 5.1.0 一句话答案（前五轮都没看到的那一点）

> **取指地址要接"下一拍的 pc"（组合推出），而不是当前 pc。**

```systemverilog
wire [31:0] pc_next = fetch_hold ? pc : (pc_src ? pc_target : pc_plus4);
assign imem_addr = pc_next;          // 仅 IMEM_REG_READ 时；组合读仍接 pc
```

imem 是寄存读，`imem_rdata(N) = mem[addr(N-1)]`。令 `addr = pc_next`：

| 情形 | `pc_next(N-1)` | `imem_rdata(N)` |
|---|---|---|
| 未停顿 | `pc(N)` | `mem[pc(N)]` ✓ |
| 停顿中 | `pc(N-1) = pc(N)`（pc 被冻结） | `mem[pc(N)]` ✓ |

**两种情况下都得到 `imem_rdata(N) == mem[pc(N)]`** —— 与组合读**逐位同口径**。于是：

- **IF/ID 的接线一行都不用改**（仍用当前 `pc` / `pc_plus4` / `pred_taken`）
- **不需要** `pc_d1` 之类的延迟副本
- **不需要**停顿释放气泡
- **重定向代价仍是 2 拍**：目标由 EX 在 cycle N 组合算出，当拍就送进 IMEM，
  N+1 数据出来，ID/EX 在 N+2 拿到 —— 与组合读相位**完全一致**（不是平移）

**另一处必须的配套**：复位后**冻结取指一拍**。否则 pc 复位后立即前进，
`PC_RESET` 处的第一条指令**从来没有任何一拍被送进 IMEM**，整条被跳过
（实测症状：`reg` 卡在测试 1，`tohost=2`）。冻结一拍后 IMEM 才有机会锁存它。

#### 5.1.1 为什么前五轮全败（三种错路，都留了实测）

| 轮 | 做法 | 实测 |
|---|---|---|
| ①②③④ | 在"pc 的延迟副本"上做重定向/停顿补偿 mux | **0 PASS，全 timeout** |
| ⑤ | 统一 FAR：IMEM 与 IF/ID 共用寄存器（`addr = pc_d1`） | **1 PASS**（比 ⑥ 差） |
| ⑥ | **`addr = pc_next` + 复位冻结一拍** | **10 PASS \| XFAIL 1，ticks 逐位一致** ✅ |

**错路 ①②③④ 的病根**：以为要"让延迟副本跟着 pc 一起转"。但 pc 寄存器在寄存读
结构下**本身就已经是取指地址寄存器**；再叠一层补偿 = 把同一个作用施加两次 ——
症状是跳转目标整体偏移。

**错路 ⑤ 的病根**：`addr = pc_d1`（寄存过的 pc_next）自身自洽，但让 IF/ID
**整整晚一条指令**（实测 reg 的 `if_pc`/`idex_pc` 恒定落后 comb 一条），
于是停顿释放那拍出现"同一指令执行两次、后一条被跳过"。它比组合读多错开了一拍，
而 ⑥ 恰好把这个偏差消掉。

**我自己犯过的一个诊断错误**（值得记）：早期试 `addr = pc_src ? pc_target : pc_plus4`
**却仍配 `pc_d1`**，失败后我得出"pc_next 会提前一拍取指"的结论 —— **那是错的**。
真正的原因是**配错了对象**：`addr = pc_next` 必须配**当前 pc**。
`pc.sv` 内部那句 `pc <= pc_src ? pc_target : pc_plus4` 算的是"下一拍装什么"，
而取指地址要的正是这个值 —— 两件事其实是一件事，我当初把它们当成了两件事。

#### 5.1.2 已验证的负结果（不要再试）

- **无条件注入停顿释放气泡** → 把组合读路径也弄坏（`tohost=3`）
- **`addr = pc_d1`（统一 FAR）** → IF/ID 恒落后一条指令，停顿释放吞指令
- **在延迟副本上做重定向/停顿补偿 mux** → 跳转目标整体偏移（前四轮）
- **`LOAD_RESULT_REG`** → 实测更差，已否决（见 5.2）

#### 5.1.3 落地的改动与实测

| 改动 | 位置 | 说明 |
|---|---|---|
| `pc_next = fetch_hold ? pc : (pc_src ? pc_target : pc_plus4)` | `core.sv` | 仅 `IMEM_REG_READ` 时 `imem_addr` 接它；组合读仍接 `pc` |
| `fetch_hold = pipe_stall \|\| !boot_done` | `core.sv` | 复位后冻结取指一拍，让 IMEM 锁存 `PC_RESET` |
| `pc.stall` / `if_id.stall` | `core.sv` | 改用 `fetch_hold` |
| IF/ID 的 `pc_in`/`pc_plus4_in`/`pred_taken_in` | `core.sv` | **改回当前 pc / pc_plus4 / pred_taken**（不再用延迟副本） |
| `IMEM_REG_READ` 拦截 | `fpga/build.tcl` | **解禁**（删掉 `exit 1`） |

**仿真实测**：

| 配置 | 前五轮 | 现在 |
|---|---|---|
| 默认（组合读） | PASS 10 \| XFAIL 1 | **PASS 10 \| XFAIL 1** |
| `--imem_reg_read` | **全部 timeout** | **PASS 10 \| XFAIL 1** |
| CoreMark ticks | — | **两种配置逐位一致：423527** |
| `MMIO_RESULT` | — | 两者均为 2147907175 |

**综合实测**（`synth --imem-reg-read --tag regread-v1 --record`）：

| 指标 | comb 基线 | regread | 变化 |
|---|---|---|---|
| CoreMark/MHz | 2.3611 | **2.3611** | 0（逐位一致）|
| LUT | 4079 | **2821** | **−30.8%** |
| FF | 1377 | 1345 | −32 |
| BRAM | 4 | **8** | **imem 落进 RAMB36 ×4** |
| CoreMark/LUTs | 5.788e-4 | **8.370e-4** | **+44.6%** |
| fmax | 61.2 MHz | 58.9 MHz（最佳 place 策略）| −3.8% |
| 绝对吞吐 | 144.4 | 139.1 | −3.7% |

#### 5.1.3b ✅ 上板闭环（2026-10-06 17:25，真实硬件）

用带宏的 ILA 构建（`build_ila.tcl` 新增 `IMEM_REG_READ` 的 env 门控，
并打印自证行 `ILA_BUILD_IMEM_REG_READ=1` —— 防 R18 那种"上板验证的其实是没开宏的版本"），
编程后跑 10 秒 CoreMark 再读回：

| 项 | comb（默认，历史） | **regread（本次）** |
|---|---|---|
| `ila_ctrl` | 0x42（done+pass）| **0x42** ✅ |
| CRC 判定 | bit31=1 | **bit31=1** ✅ |
| **tick** | 508,155,404 | **508,155,404（逐位相同）** |
| iterations | 1200 | 1200 |
| 时间 @50MHz | 10.16 s | **10.16 s**（满足 ≥10 s）|
| CoreMark/MHz | 2.3615 | 2.3615 |

**tick 与 CRC 都与组合读版逐位相同** —— 这不是"能跑"，是**语义等价性在硅上被证明**。

#### 5.1.4 fmax 代价的定位（纯物理，待办 #3 处理）
新关键路径（与基线相比**逻辑级数不变**，**布线变长**）：

```
Source:      u_core/u_dmem/mem_reg_1/CLKBWRCLK           (RAMB36_X1Y5)
Destination: u_core/u_imem/rdata_reg_0/ADDRARDADDR[12]   (RAMB36_X2Y4)
              <= 基线是 u_core/u_pc/pc_reg[7]/D
Data Path:   16.598ns (logic 5.425 = 32.7%, route 11.173 = 67.3%)
基线:        16.045ns (logic 5.542 = 34.5%, route 10.503 = 65.5%)
```

同一条 `dmem 输出 → LSU 提取 → 前递 → 分支比较（5 级 CARRY4）→ pred_ok →
pc_src → pc_next mux` 的链，现在**还要驱动 imem 的 BRAM 地址脚**。
两块 BRAM 本身就相邻（X1Y5 / X2Y4），所以不是"放太远"，而是这条链末端多了一个
较难到达的目的地。**逻辑反而略降（5.542→5.425），纯布线问题**。

#### 5.1.5 顺带修掉的工具缺陷（同族坑）

`verify` 的 `test_fingerprint()` 原来**不含宏配置**，于是跑完默认配置再跑
`verify --imem_reg_read`，11 项全部被判"缓存命中"而 **SKIP** ——
明明换了一整套架构宏、跑的根本不是同一份设计。
这与 PITFALLS R17（宏没传到 ModelSim）是**同一族**：两边跑的不是同一个东西。
已抽出 `_global_defines(args)`，`verify` 与指纹共用同一份口径。

> 教训补充：**增量缓存必须包含"配置"维度**，否则它会把配置差异伪装成"未受影响"。

#### 5.1.6 仍然有效的后续想法

把 BTB 预测也寄存一级（`pc <= pred_target_r`），这样 **BTB 的组合查表也就不在
`pc` 路径上了** —— 那才是寄存读最大的时序收益（当前关键路径 route 占 67%）。

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
