# P6 · A 扩展 (原子指令) —— 编码 ✅ · 数据通路 ✅ · 译码 ✅ · 多周期 ❌

**日期**：2026-10-05（Round 19 更新）
**状态：数据通路与译码已完成并有单元检查覆盖；多周期"读-改-写"未做 ——
所以 A 扩展目前仍不能执行任何原子指令**

---

## 0.0 黄金向量生成器（Round 19 新增，为多周期实现做准备）

`tools/amo_vectors.py` —— 用**独立的 Python 参考实现**生成 AMO 语义的黄金向量。

**为什么需要**：A 扩展最凶的坑是 **min/max 有两套符号语义**
（`amomin/max` 有符号、`amominu/maxu` 无符号），而这个错误**只在边界值上暴露**
—— 用普通小正数测试会**全绿**。本人写 ALU 时就真把 `amo_max` 的三元方向写反过。

**输出**：`sim/prog/amo_vectors.hex`，**108 条**（9 个算符 × 12 组操作数），
每条 4 个字：`funct5, old, rs2, expect_new`（`rd` 应读到 `old`，单独校验）。

**12 组操作数里有 6 组能区分两套符号语义**，例如：
```
old=0xFFFFFFFF rs2=0x00000001 : amomin.w=0xFFFFFFFF  amominu.w=0x00000001
old=0x80000000 rs2=0x7FFFFFFF : amomin.w=0x80000000  amominu.w=0x7FFFFFFF  <- 完全相反
```

**已做的交叉验证（双向）**：
- 生成器的 Python 语义 vs **已通过单元检查的 RTL ALU 期望值** → **13/13 一致**；
- 生成的向量文件 vs 生成器语义 → **108/108 一致**。

> 这就是"**参考实现必须独立于被测实现**"的落实。本项目已经两次栽在
> "自己和自己比"上（`checksum_ref`、`nn_demo` 的 `gemm_hw_unpack`），
> 所以这次刻意用 Python 重写一遍语义，而不是复用 Verilog 的写法。
>
> 用途：多周期"读-改-写"实现后，用这 108 条做端到端校验（比手写几个用例
> 强得多，尤其是 min/max 的边界）。

---

## 0. 进度总览

| 层 | 状态 | 说明 |
|---|---|---|
| 工具链 | ✅ | `-march=rv32ia` 实测可用 |
| 编码表 | ✅ | 逐条反汇编确认（见第 2 节）|
| 包定义 | ✅ | `OPC_AMO` / 9 个 ALU 算符 / 11 个 funct5 常量 / `ctrl_s` 的 amo_* 字段 |
| ALU 数据通路 | ✅ | "待写回值"计算 + **14 条单元检查**（含 min/max 符号边界）|
| `control_unit` 译码 | ✅ **已实现**（`A_EN` 宏门控，默认关闭）| + **22 条译码检查** |
| **多周期读写控制** | ❌ | 见第 5 节的集成难点 —— **这是唯一还差的** |
| LR/SC 预留位 | ❌ | 单核一项即可 |
| 集成测试 `amo.S` | ❌ | |

> ⚠️ **当前 0x2F 由 `A_EN` 门控、默认关闭，所以 A 扩展还不能执行任何原子指令。**
> 译码与数据通路都已实现并有单元检查覆盖，但**多周期"读-改-写"没做**就执行不了。

## 0.2 为什么译码默认关闭（实测数据，Round 15）

打开 `A_EN` 对评分三项是**纯代价**：

| 指标 | A_EN 关 | **A_EN 开** | 变化 |
|---|---|---|---|
| fmax | 61.7 MHz | **58.8 MHz** | **−4.7%** |
| LUT | 4078 | 4104 | +26 |
| 绝对吞吐 | 145.6 | **138.9** | **−4.6%** |

而**收益为零**：CoreMark 不含任何原子指令（ticks 一位都不变），
且多周期控制未实现，所以即使打开也**执行不了** A 指令
（会按普通 load/store 走，静默出错）。

**真因**：funct5 的比较 + ALU 算符 mux 落在了**访存地址那条已经很紧的路径**上
（该路径 slack 本来就只有 3.783 ns）。

**处置**：与 `GEMM_EN`/`RAS_EN`/`BTB_GSHARE` 同样的方式 —— 宏门控、默认关、
保留复现开关（`verify --a-ext` / `synth --a-ext` / `set A_EN=1`）。
**两种配置都跑过回归**：A_EN 关 9 PASS、A_EN 开 tb_units PASS。


## 0.1 数据通路层已完成的细节 (Round 13)

**算子约定**：`a` = 从内存读回的**旧值**，`b` = `rs2` → `alu_out` = **应写回内存的新值**。
这样 AMO 的"读-改-写"里只有"改"落在 ALU 上，其余复用现有 LSU 与写回通路。

**自己犯并修掉的错**：第一版把 `amo_max` 写成 `(slt) ? a : b` —— `a<b` 时取 `a`，
即取成了**最小值**。min/max 的三元方向极易写反，已在 `alu.sv` 里注明。

**单元检查**（`tb_units.sv` 新增 14 条）用边界值分开覆盖两套符号语义：
```
旧值=-1(0xFFFFFFFF), rs2=1:
    有符号 min=-1 / max=1        无符号 minu=1 / maxu=0xFFFFFFFF
旧值=0x80000000, rs2=0x7FFFFFFF:
    有符号 min=0x80000000 / max=0x7FFFFFFF
    无符号 minu=0x7FFFFFFF / maxu=0x80000000
```

**四项指标**（A 扩展数据通路加入后）：CoreMark/MHz 2.3611（不变，CoreMark 不含
原子指令）/ fmax 61.6→**61.7**（噪声级）/ LUT 4019→**4078**（+1.5%）/
绝对吞吐 145.4→**145.6**。判定：**代价可接受**。

**上板**：ILA 版已重建（23:04）并抓取验证（23:05，`CSV_MTIME` 自证 `AGE_SEC=0`）：
`ila_ctrl=0x42`、CRC 判定=1、tick=508,155,404 → **PASS**。

---

## 5. 【关键】多周期"读-改-写"的集成难点（下一轮从这里接）

把 LSU 的地址来源查清楚了，这是一个**必须正面解决的数据通路问题**：

```
core.sv:585   .alu_out_in (ex_result)        // ex_mem_reg 在 EX 末尾锁存结果
core.sv:590   .alu_out    (ex_mem_alu_out)
core.sv:606   .req_addr   (ex_mem_alu_out)   // LSU 的地址 = ex_mem_alu_out
```

**即：MEM 段的访存地址来自 `ex_mem_alu_out`，而它在 EX 末尾就被锁存了。**

AMO 需要的是"在 MEM 段先读旧值、算出新值、再写回去"，可问题是：

1. **访存地址没问题** —— `ex_mem_alu_out` 已经装的是 AMO 的目标地址（EX 算出来的），
   所以第一拍读能正常发出；
2. **但"第二拍写回新值"没有通路** —— 新值是"旧值 op rs2"，而旧值要等 dmem 的
   寄存读回来（下一拍）才知道；此时 `ex_mem_alu_out` 已经锁死，LSU 的地址输入
   不能再改，**写数据与写使能也没有对应的多周期控制**；
3. **`ex_mem_reg` 的 `stall` 接的是 `hold_mem`** —— 它能冻结 MEM/WB，但冻结的是
   "保持旧值"，**不能把新算出来的值注入进去**。

### 可行的三条路（Round 22 更新：**已找到正确落点**）

#### ✅ 推荐路线（Round 22 发现）：扩展 **LSU 已有的多周期 FSM**

原先我打算在 `core.sv` 里加 mux + 给 hazard_unit 加 `amo_busy`（下面路线 A）。
**Round 22 读了 `load_store_unit.sv` 之后发现这是绕远路** —— LSU **已经有一套
完全够用的多周期机制**，正是为"非对齐跨字访存 2 拍拆分"建的：

```systemverilog
localparam S_IDLE=0, S_HEAD=1, S_TAIL=2;
logic [1:0] state;
assign dmem_addr  = (state == S_IDLE) ? head_addr  : tail_addr;   // 已能按相选地址
assign dmem_wdata = (state == S_IDLE) ? store_shifted[31:0] : store_shifted[63:32];
assign dmem_we    = req_write && (state != S_TAIL);               // 已能按相控写使能
assign dmem_wstrb = req_write && (state != S_TAIL) ? ... : 4'b0000;
output logic lsu_stall;                                           // 已能冻结流水线
```

**它已经具备 AMO 需要的全部要素**：按相选地址、按相控写使能、多周期冻结流水线、
并且在 `S_HEAD` 相**捕获读回的数据**。所以 AMO 应当作为**新增相**接进去，而不是
在 core.sv 里另起一套。

**要做的改动（很小，且集中在 LSU）**：

1. `rv32_pkg` 的 LSU 端口加两个输入：`amo_en`、`amo_op[4:0]`
   （或在 core 里先算出"新值"再送一个 `amo_newdata` 进来 —— 后者更简单，
   因为 ALU 已经在 EX 段算好了 AMO 的"待写回值"，见 `alu.sv` 的 `ALU_AMO_*`）。
2. 若走"送新值进来"：core 里只需把 `ex_mem_ctrl.amo_en` 与
   **EX 段算出的 AMO 新值**（需要随流水寄存下来，跟 `ex_mem_alu_out` 并列）
   接到 LSU。这比改内存路径的三个 mux 干净得多。
3. LSU 状态机加相：`AMO_READ`（送地址读旧值）→ `AMO_WAIT`（旧值到，
   此时把 `dmem_we` 拉高、`dmem_wdata` 换成新值）→ `AMO_DONE`（放行，
   `lsu_stall` 落低，rd 取旧值）。
4. LR/SC 预留：LSU 内加 `resv_valid`/`resv_addr`（单核一项即可）。
   **任何 store / trap / 中断都要清预留**；`sc.w` 失败时**不写内存且 rd=1**。
5. 校验：用 `tools/amo_vectors.py` 的 **108 条黄金向量**。

> **为什么这条路线更安全**：它**不动 `ex_mem_reg` 的语义**，也不动 `core.sv` 的
> 内存路径接线，只往一个**已经在正确工作**的状态机里加相。本项目在"改流水寄存器
> 语义"上吃过四轮亏（`IMEM_REG_READ`），所以这点很关键。

#### 路线 A（原计划，已被上面取代，保留供参考）

把 AMO 做成 EX 段的多周期单元（仿 `muldiv` 的 `ex_busy`）：EX 拉 `amo_busy` 冻结
流水线，内部自己发读地址、等 dmem 寄存读回来、算新值、在最后一个 EX 拍把地址送
`ex_result`，让 EX/MEM 正常锁存（此时 ctrl 需带 `mem_write`）。
代价：需要新增"读回来的旧值"绕回 EX 的通路 + AMO 自己的地址寄存器。

#### 路线 B（不推荐）

给 `ex_mem_reg` 加"注入端口"：会污染流水寄存器的接口语义，容易出隐蔽 bug。

#### 路线 C（不推荐）

新增 MEM 段写回缓冲：相当于在 LSU 侧再加一个状态机 —— 而 LSU 本来就有状态机，
不如直接扩展它。

### 还要一并处理的点

- **LR/SC 预留**：单核只需一项 `resv_valid` + `resv_addr`（LSU 内）。
  **任何 store / trap / 中断都必须清预留**（规范要求）。
  `sc.w` 关键副作用：**失败时不能写内存，且 rd 必须为 1**（成功为 0）。
- `aq`/`rl` 已译码但单核无 cache 无实际作用，代码里要注明"已处理、无副作用"，
  避免被当成漏实现。
- 集成测试 `sim/prog/amo.S`：每个 funct5 一组，**必须含负数与 0x8000_0000
  这类边界值**（min/max 的符号语义只在边界上暴露），再加 `lr`/`sc` 的
  成功与**失败**（中途插一次 store 让预留失效）两条路径。

---

## 5.1 【当前卡点 · Round 25 定位】`dmem_rdata` 读回恒为 0

`sim/prog/amo.S` + 回归项 `tb_core_amo` 已就绪（用 `.word` **手工编码** AMO 指令，
9 组自校验，含 min/max 的符号边界；迷你汇编器不认 AMO 助记符但支持 `.word`，
所以不必改汇编器）。当前标记为 **XFAIL** —— 它是一个可执行的验收标准。

**已打通的部分**（诊断打印为证，形如
`t=155000 st=3 act=1 ph=0 wr=0 stall=1 we=0 addr=90003114`）：

| 环节 | 状态 |
|---|---|
| 译码 → `amo_en` → LSU 进入 `S_AMO` | ✅ |
| 两相推进（读相 `ph=0` → 写相 `ph=1`）| ✅ |
| `lsu_stall`（读相停、写相放行）| ✅ |
| **AMO 地址锁存** | ✅ `addr=90003114`，与程序的 `sw` 目标一致 |
| 写使能 / 写相 | ✅ `we=1` |
| 程序能跑到 tohost（不再是 timeout）| ✅ |

**卡点**：`dmem_rdata` **每一拍都是 `00000000`**：
```
t=145000 st=0 ... addr=90003114 rdata=00000000   <- AMO 启动拍
t=155000 st=3 ... addr=90003114 rdata=00000000   <- 读相 (地址正确, 数据为 0)
t=165000 st=3 ... addr=90003114 rdata=00000000   <- 写相
```
于是 `amo_old` 恒为 0，`amo_newdata` 算成 `0+23=23` 而非 `100+23=123`，
第 1 组校验失败（`tohost=2`）。

**关键推论**：**这不是 AMO 特有的问题** —— 连"读回刚 `sw` 进去的值"都拿不到。
所以嫌疑集中在 **LSU 的 `dmem_rdata` 输入通路**（core 里 `dmem_rdata_g` 的译码，
以及"窗口内取 dmem / 窗口外取 ext_rdata"那一段），**而不是 AMO 状态机本身**。

**下一轮从这里查**（按能砍掉多少范围排序）：
1. 加一条诊断打印 `dmem_rdata_g` 与 `u_dmem.rdata` —— 这一步就能判断是
   **译码处**丢了还是 **dmem 本身**没输出，范围直接对半砍；
2. 若 dmem 本身没输出：确认 `dmem_addr` 真的到得了 `u_dmem`。注意 dmem 的地址
   位切片是 `addr[AW+1:2]`，而 AMO 相送的是 `amo_addr_r`（启动拍的 `head_addr`）
   —— 要确认这个 mux 没把 dmem 的地址选错；
3. 普通 `lw` 在仿真里是好的（`tb_core_basic` 等覆盖），所以更可能是
   **AMO 相把 dmem 的输入搞成了 0/x**，而不是 dmem 坏了。

> **验收标准是现成的**：修好后 `tb_core_amo` 由 XFAIL 翻成 XPASS。
> `verify` 对 XFAIL→XPASS 的翻转是敏感的（见 `fpga_workflow.py` 里
> `force`/`expect_fail_ok` 的处理），不会漏报。

### 本轮修掉的三个真 bug（都有诊断/警告依据）

1. **`amo_wr` 未复位 → 状态机卡死。** 第一版写成
   `if (state==S_AMO) amo_wr <= ~amo_wr;`。诊断打印给出根因 `st=3 wr=x` ——
   **`~x` 仍是 `x`**，于是永远停在 X：`dmem_we`/`wstrb`/`lsu_stall` 全是 X，
   状态机出不来（表现为 timeout）。改成两个**复位过**的寄存器
   `amo_active`/`amo_phase`，由 state 组合出 `amo_wr`。
   **这是本项目反复出现的同类坑**（PITFALLS R6/R8：多周期状态机的每个派生
   信号都必须有确定值，不能靠"反正会先经过某相"）。
2. **AMO 地址没有锁存。** `req_addr` 来自 EX/MEM 流水寄存器，跨多拍不稳定；
   诊断打印显示写相那拍 `addr=00000000`。改成启动拍把字地址锁进 `amo_addr_r`。
3. **`amo_newdata` 未声明 → 隐式 1 位网络。** `assign amo_newdata = ...` 在未
   声明时被 ModelSim 当成 **1 位**隐式网络，接到 32 位端口只驱动了 1 位 →
   **AMO 把 `Z` 写进内存**。唯一提示是 `vopt-2241 connection width does not
   match`。修法：在例化**之前**显式声明。（与 R8 同类：未声明的名字被隐式推断。）

### 一条工具教训

给测试加 `defines: ("A_EN", "AMO_TRACE")` 后**诊断打印没有出现** ——
`+define+X` 在 ModelSim 侧对 `ifdef` 的生效路径又不可靠（与 R17 同类，
本次是 `vlog` 与 `vsim` 两处都要传）。最后改成**无条件启用诊断**才拿到数据。

---

## 5.2 【Round 27-28】两个新结论 —— 比上一轮更接近根因

### 结论 A：`dmem` 的**写端口是好的**，问题在读侧

把 dmem 的写端口、内部存储阵列、读端口一次全打出来（`addr[13:2]` 是 16KB 的
正确字索引；`AW=12`，无别名问题）：

```
t=115000 WE=1 wdata=00000064 strb=f addr=90003100 | mem[3136]=00000000 rdata=00000000
t=175000 WE=1 wdata=00000000 strb=f addr=90003114 | mem[3141]=00000000 rdata=00000000
```

**`WE=1`、`wdata=0x64`（=100）、`strb=f`（整字）全部正确** —— 写请求没问题。
但同一拍 `mem[3136]` 仍读 0：这**不能**当作"没写进去"的证据（非阻塞赋值，
本拍读到的还是旧值）。**必须看下一拍的 `mem[3136]`** —— 这是下一步的判据。

### 结论 B：**AMO 的目标地址与 `sw` 不一致（差 0x14）** ← 更具体的线索

```
t=115000 ... addr=90003100   <- 程序里的 sw t1, 0(t0)    -> 字 3136
t=145000 ... addr=90003114   <- 同一个 t0 上的 AMO       -> 字 3141
```

**两条指令用同一个 `t0`，地址却是 `0x100` 与 `0x114`。** 而编码是核过的：
`amoadd.w t2,t1,(t0)` = `0x0062A3AF`，其中 `rs1=5`(t0)、`funct3=010`(.W)、
`imm[11:0]=0`（bits[31:20] 全 0）—— 所以偏移**应当是 0**。

**因此 `0x14` 这个偏移来路不明**。两个方向：

1. **AMO 的立即数没有被当 0** —— 查 `imm_gen` 对 `IMM_I` 的取值是否被 AMO
   分支的某个字段影响（AMO 用 I 型立即数，bits[31:20] = 0）。
2. **`ex_mem_alu_out` 这一路在 AMO 时不是加法的结果** —— 注意
   `ex_result = is_muldiv ? md_result : is_csr ? csr_rdata : ex_alu_out`，
   而 AMO 的 `alu_op` 是 `ALU_AMO_*`（**不是 `ALU_ADD`**）。**这一条最可疑**：
   AMO 的地址必须是 `rs1+imm`，但现在 `alu_op` 被占用来表达"新值怎么算"了，
   **地址计算与算子表达冲突**。

> **这可能改写前面的结论**：AMO 读的是一个**从来没被写过的字**（3141），
> 当然是 0。也就是说"读回 0"的根因**未必是读通路坏了，而可能是地址算错了**。
> 与"连 `sw` 的值都读不到"那条观察需要再复核一次 ——
> AMO 启动拍与 `sw` 的地址差异是本轮**新的事实**。

### 下一轮第一步（很具体）

1. 打**下一拍**的 `mem[3136]`，确认 `sw` 究竟写进去没有（区分"写不进"与"读不出"）；
2. 打 AMO 那条指令在 EX 段的 `ex_a` / `ex_b` / `ex_alu_out` 与 `imm_gen` 输出，
   看 `0x14` 从哪来；
3. **重点怀疑**：AMO 用 `alu_op` 表达"新值算子"，与"地址 = rs1+imm 必须走
   `ALU_ADD`"冲突。若证实，修法是让 AMO 的**地址**走独立加法
   （或把"新值算子"单独占一个字段），而不是复用 `alu_op`。

---

## 5.3 【Round 29】找到一个真 bug 并修掉：AMO 的 `alu_b_src` 没设 → 地址被算成 `rs1+rs2`

### 根因

`control_unit.sv` 的 `OPC_AMO` 分支**只设了 `alu_op`，没设 `imm_fmt` /
`alu_a_src` / `alu_b_src`**。而 `ctrl = '0` 的默认值恰好是：

| 字段 | 默认值 | 对 AMO 是否正确 |
|---|---|---|
| `alu_a_src` | `ALU_A_RS1` (0) | ✅ a 取 rs1 |
| `alu_b_src` | **`ALU_B_RS2` (0)** | ❌ **b 取 rs2，而不是立即数！** |
| `imm_fmt` | `IMM_I` (0) | 值对，但只有 b 选 IMM 时才用得上 |

所以 AMO 的访存地址被算成 **`rs1 + rs2`**，而不是 `rs1 + imm`（AMO 的 imm 恒 0，
正确结果应当就是 `rs1`）。

**实测症状**：`sw` 写 `0x90003100`，同一个 `t0` 上的 AMO 却访问 `0x90003114`
—— 差的正是当时 `t1` 的值 `0x14`。于是 AMO 去读一个**从没被写过的字**，
当然恒为 0。

> **这个 bug 的欺骗性值得记下来**：状态机、三相时序、写使能、写数据、
> `dmem` 写端口**全部正确**，只有**地址**是错的。而症状表现为"读回 0"，
> 看起来像读通路坏了 —— 我为此绕了整整三轮（Round 25/26/27）去查读通路。
> **教训：当"读回 0"时，先确认读的地址对不对，再怀疑读通路。**

### 修复与效果

在 `OPC_AMO` 分支显式补上：
```systemverilog
ctrl.alu_a_src = ALU_A_RS1;   // a = rs1 (基址)
ctrl.alu_b_src = ALU_B_IMM;   // b = imm  (AMO 恒为 0)  <- 关键
ctrl.imm_fmt   = IMM_I;       // I 型立即数
```

**效果（实测地址）**：
```
修复前: addr=90003114   (被 rs2 污染)
修复后: addr=90003104   (污染消失, 但仍有 +4 的偏差)
```

### 仍未完成：还剩一个地址/读数的偏差

修复后地址稳定在 `0x90003104`（`rs2` 污染消失，证明 `alu_b_src` 修复是真的），
但 `rdata` 仍为 0。

---

## 5.4 【Round 30】再修一处：AMO 的**地址**不能复用 ALU 的算子通路

### 根因（第二层）

上一轮补了 `alu_b_src = ALU_B_IMM`，但**这只解决了"b 取立即数"**，
没解决更根本的冲突：

```systemverilog
ex_result = is_muldiv ? md_result : is_csr ? csr_rdata : ex_alu_out;
```

* AMO 的 `alu_op` 是 `ALU_AMO_*` —— 那是用来算 **"应写回内存的新值"**
  （`old op rs2`）的，**不是地址**；
* 而 `ex_result` 在 `is_muldiv`/`is_csr` 之外**直接取 `ex_alu_out`** ——
  于是 LSU 拿到的"地址"其实是 **AMO 的算子结果**（`old + imm`）。

**实测症状**：地址恒差一个 `+4`（当时 `imm=4` 被当成加法项加进了"地址"）。

### 修法：给 AMO 一个**独立的地址加法器**（与算子解耦）

```systemverilog
ex_amo_addr = ex_rs1 + id_ex_imm;          // AMO 是 I 型: 地址 = rs1 + imm
assign ex_result = is_muldiv ? md_result
                 : is_csr    ? csr_rdata
                 : id_ex_ctrl.amo_en ? ex_amo_addr   // ← AMO 走独立加法
                 :             ex_alu_out;
```

> 这正是本项目对**跳转目标**做过的同一件事（P3 的"独立加法器"，见
> `results/p3-fmax.md`）—— **同一个坑，第二次出现**：
> 只要一条指令需要同时算"算子"和"地址"，就不能让两者复用同一个 ALU 输出。

**效果**：地址不再随 `alu_op` 漂移，稳定为 `rs1 + imm`。

### 仍未完成：`rdata` 依旧为 0 —— 且现在有了一条**新的、更硬的线索**

诊断打印（Round 30）：
```
t=115000 WE=1 wdata=00000064 strb=f addr=90003100   <- 软件 sw 写入 100
t=145000 ... addr=90003104                           <- AMO 读的是 0x104, 不是 0x100
```

**两者相差 `0x04`。** 而 AMO 的 `imm[11:0]` 恒为 0，所以 `0x90003104`
对应的 `rs1` 应当是 `0x90003104` —— 也就是**当时 `t0` 的值就是 `0x104`**。

由此推断：**程序里的 `t0` 与 `sw` 用的 `t0` 并不是同一个值**
（或者 AMO 执行时 `t0` 已被改写）。下一轮第一步：
在测试程序里**用同一个寄存器、把 `sw` 与 AMO 紧挨着放**，排除中间指令对
`t0` 的影响；并打印 EX 段的 `ex_rs1`（AMO 时的 `t0`）。

`tb_core_amo` 仍是 **XFAIL** —— 修好后翻 XPASS，`verify` 对翻转敏感。

---

## 5.5 【Round 32】单步诊断程序：把失败环节直接上报，不再靠猜

### 为什么要另写一支程序

`amo.S` 一次测 9 组，失败时只知道"第 1 组错"，**不知道错在地址 / 读 / 写哪一环** ——
前四轮我都在这个模糊度里打转。

于是新增 `sim/prog/amo_diag.S`（回归项 `tb_core_amo_diag`）：只做**最小一组**
（`sw` 100 → `amoadd.w` 加 23 → 查 `rd` 与内存），并把**中间结论直接写进 tohost**：

| tohost | 含义 |
|---|---|
| 1 | 全部通过 |
| 2 | `sw` 后 `lw` 读不回刚写的值（基础读写就坏了）|
| 4 | AMO 读到的旧值是 0 |
| 5 | AMO 的 `rd`（旧值）不对 |
| 6 | AMO 写回的新值不对 |

### 实测结论（Round 32）：`tohost = 5`

**由此得到一条新的、很硬的线索**：

| 操作 | 地址 |
|---|---|
| `sw t1, 0(t0)` | `0x90003000` ✅ |
| `lw t4, 0(t0)` （**读回 100，通过**）| `0x90003000` ✅ |
| `amoadd.w t2, t1, (t0)` | **`0x90003004`** ❌ |

**即：同一个 `t0`、同一个偏移 0，`sw`/`lw` 都正确，只有 AMO 多 4。**

这条线索的价值在于它**排除了一大批可能**：
- ❌ 不是"`dmem` 读通路坏了" —— 同一程序里的 `lw` 好好的；
- ❌ 不是"`t0` 的值不对" —— `sw`/`lw` 用同一个 `t0` 且地址正确；
- ✅ **是 AMO 这条路径特有的、恒定的 +4 偏移**。

### 下一轮第一步（已经很窄了）

+4 是**恒定的**，所以最可能是：
1. `id_ex_imm` 在 AMO 时不是 0，而是 4 —— 查 `imm_gen` 对 `IMM_I` 在
   **AMO 那条编码**上的输出（`instr[31:20]` 确实是 0，所以要查是不是别的来源）；
2. `ex_rs1` 在 AMO 时拿到了**前递值**而不是 `t0` 的实际值 —— 查 `fwd_a`；
3. 汇总打印 `ex_rs1` / `id_ex_imm` / `ex_amo_addr` 三者，一次就能定位。

> 建议**先用 tohost 上报**（把 `ex_amo_addr` 低几位或用不同常量再试），
> 而不是加打印 —— 本轮证明了 tohost 上报比加打印更快定位。

---

## 5.6 【Round 33】AMO 读-改-写**打通** + 两个真 bug

### 结果：`amo_diag` → `RESULT : PASS`

即 AMO 的三件事全部正确：**读旧值 / `rd`=旧值 / 写回 `old op rs2`**。
回归由 `PASS 9 | XFAIL 1` 变为 **`PASS 10 | XFAIL 1`**。

### Bug 1：AMO 的偏移不能用 `id_ex_imm`（`imm_gen` 把 `rs2` 当成了立即数）

诊断打印 `[ex-amo]` 实测：
```
rs1=90003000  imm=00000006  addr=90003006
```
而 `amoadd.w t2,t1,(t0)` 的编码 `0x0062A3AF` 其 `imm[11:0]` **恒为 0**。

**原因**：`imm_gen` 的 I 型提取用 `instr[31:20]`，而 AMO 的 `[31:27]` 是 funct5、
`[24:20]` 是 **`rs2`** —— 于是**把 `rs2` 当成了立即数**（本例 rs2=t1 的编号 6）。
**历史上的 `+4` 是同一成因**（当时 rs2 编号恰好是 4）。

**修法**：按规范 AMO 没有立即数字段 → `ex_amo_addr = ex_rs1`，从根上避开 `imm_gen`。

### Bug 2：`amo_rs2` 采样窗口差一拍

诊断打印 `[ex]` 实测：
```
t=175000  amo_en=1  rs2=00000017   <- AMO 在 EX，rs2 正确 (t1=23)
t=215000  amo_en=0  rs2=00000000   <- AMO 已在 MEM
```
`amo_rs2` 直接锁存 `ex_rs2` 会取到**下一拍**的值 —— 那时 EX 里已是后续指令。
**修法**：加一级 `ex_rs2_d` 延迟 + 用上一拍的 `amo_en_d` 对齐采样窗口。

---

## 5.7 【Round 34】定位到最后一个卡点：`amo_op` 在 EX→MEM 被丢掉

`amo.S` 的 9 组测试在第 2 组（`amoswap`）失败。新增
`sim/prog/amo_diag2.S`（同样用 tohost 上报）得到 `tohost=4`：
**`rd`（旧值 `0x1111`）正确，但内存没有被改成 `0x2222`** —— 即**新值写错了**。

打印 `[amo-w]` 看到：
```
op=00000  old=00001111  rs2=00002222  comb=00003333
```
`comb = 0x3333 = 0x1111 + 0x2222` —— 它算的是 **ADD**，而不是 SWAP！
而 `amoswap` 的 `funct5` 应当是 **`00001`**。

再并排打印 EX 与 MEM 两段：
```
t=175000  ex_en=1  ex_op=00001  mem_op=00000     <- EX 对, MEM 错!
```
**`ex_op` 是对的（`00001`），但到了 MEM 变成 `00000`。**

### 根因（本轮已定位到具体一行）

`ex_mem_reg.sv` 第 35-36 行：
```systemverilog
else if (!stall) begin
  ctrl <= ctrl_in;
```
`stall` 接的是 `hold_mem`。而 AMO 在 EX 段停留期间 `hold_mem` 有效 →
**`ctrl_in` 根本没被锁存进 `ex_mem_ctrl`** → MEM 段看到的还是上一个值
（复位或上一条指令的 `amo_op = 0`），于是"新值"按 ADD 算。

**下一轮修法方向**（未实施）：
- 让 AMO 在 EX 段**多停一拍**（地址与 `ctrl` 分两拍进入），使 `hold_mem`
  在需要锁存 `ctrl` 的那一拍为低；或
- 给 `ex_mem_reg` 一个"AMO 例外"——AMO 时即使 `hold_mem` 也锁存 `ctrl`
  （因为 AMO 的 `ex_result` 在第一拍就有效，而 `ctrl` 需要被带过去）；
- 两者都要注意**别破坏 `hold_mem` 对普通指令的语义**（这是本项目最敏感的地方）。

> **本轮方法上的收获**：四步定位**全靠诊断打印 + tohost 上报**，每加一条就砍掉一层
> （`[ex-amo]` → imm 被 rs2 污染；`[amo-new]` → old 对、rs2=0；`[ex]` → 采样窗口差一拍；
> `[amo-w]`+`[op]` → `amo_op` 跨段丢失）。比"读日志找相关性"快得多。

---

## 5.8 【Round 35】再修两处，**三个算子全部算对**；剩"写没落进内存"

### 修掉的两处

1. **`amo_op` 跨 EX→MEM 丢失**（Round 34 定位）：根因是 `ex_mem_reg.sv` 的
   `else if (!stall) ctrl <= ctrl_in;`，而 `stall` = `hold_mem` —— AMO 停在 EX
   期间 `ctrl` 根本锁不进去。修法：**自己锁存一份** `amo_op_r`，
   **完全不动 `hold_mem`/`ex_mem_reg` 的语义**（本项目最敏感处）。

2. **`amo_op_r` 的锁存条件错了**：第一版写成 `else if (amo_en_d) ...`，
   而诊断打印给出 `t=185000 amo_en_d=1` 时 `idex_op` **已经是 00000**
   （AMO 已离开 EX）。改成 **`else if (id_ex_ctrl.amo_en)`** —— 用 `amo_en`
   本身（AMO 正在 EX 的那一拍）。

### 修完后的实测（诊断打印 `[d]`，只列各组的写相）

```
t=175000  op_r=00000(ADD)   old=00000064 rs2=00000017 comb=0000007b   -> amoadd  ✅
t=325000  op_r=00001(SWAP)  old=00001111 rs2=00002222 comb=00002222   -> amoswap ✅
t=475000  op_r=01000(OR)    old=f0f0f0f0 rs2=0f0f0f0f comb=ffffffff   -> amoor   ✅
```

**三个算子的"新值"全部算对**（`amoadd`/`amoswap` 的整组校验已通过）。

### 仍剩最后一环：**写回没有落到内存**

`amo.S` 现在在**第 3 组（`amoor`）**失败（`tohost=4`），而该组的
`comb=ffffffff`、`nd=ffffffff` **都是对的** —— 说明**算子算对了，但那个值
没有真正写进内存**（随后 `lw` 读回的仍是旧值 `0xF0F0F0F0`）。

**下一轮第一步（很具体）**：在 AMO 写相那一拍打印 **LSU 的三件套** ——
`dmem_we` / `dmem_wstrb` / `dmem_wdata`，以及 `core.sv` 里的 `dmem_we_g`
（注意它还要 `&& sel_dmem`）。候选：
1. `amo_write_phase` 与 LSU 内部 `amo_phase` 之间存在一拍相位差
   （core 看到写相、LSU 还在读相，于是 `dmem_we` 没拉高）；
2. `dmem_wstrb` 在那一拍是 `0000`（参考 diag 里 `newdata` 是 `00000000`
   那几拍 —— 写相若是空转，写就不会发生）。

> **注意一个观察**：`amo_diag`(amoadd) 与 `amo_diag2`(amoswap) 都 **PASS**，
> 但 `amo.S` 的 `amoadd`/`amoswap` 组也过、第 3 组才挂 —— 说明**写回本身是
> 会发生的**，问题更可能是**特定组的时序/相位**而非普遍失效。
> 下一步把"写相那拍的 `dmem_we`/`wstrb`"打出来即可分辨。

---

## 5.9 【Round 36】LSU 的写信号**全部正确** —— 问题不在"写"，在别处

把 AMO 各相的写信号逐拍打出来（`[L]`），三组的写相都是**教科书式正确**：

```
t=175000  st=3 wr=1 stall=0 WE=1 strb=f WDATA=0000007b  nd=0000007b   -> amoadd
t=325000  st=3 wr=1 stall=0 WE=1 strb=f WDATA=00002222  nd=00002222   -> amoswap
t=475000  st=3 wr=1 stall=0 WE=1 strb=f WDATA=ffffffff  nd=ffffffff   -> amoor
```

**每一组都发出了正确的整字写**（`WE=1`、`strb=f`、写数据 = 正确的算子结果）。
相位推进也完全正确：`en=1 → wait → 读相 → 写相(wr=1, stall=0)`。

**所以"写回"这一环在 LSU 侧是对的**，前一轮"值没写进内存"的判断需要修正。

### 新观察（下一轮的入口）

1. `nd` 与 `WDATA` 存在**跨组的滞后**：第 3 组的写相打印出
   `WDATA=0f0f0f0f`（那是本组 `sw` 写进去的旧值）而 `nd=00000000` ——
   说明 `amo_newdata`（core 侧组合）与 LSU 侧看到的**不是同一拍的值**。
   这指向 **core 的 `amo_write_phase` 与 LSU 内部 `amo_phase` 的相位差**。
2. `amo.S` 在第 3 组失败，而 `amo_diag`/`amo_diag2`（各只测一组）都通过 ——
   **"单独一组能过、连测多组就挂"** 是典型的**跨组残留状态**特征
   （某个寄存器/预留位没有在组间清干净）。

**下一轮第一步（更窄了）**：检查 AMO 序列的**收尾**是否彻底 ——
`amo_active`/`amo_wait`/`amo_phase`/`amo_mode_r`/`amo_op_r` 在序列结束那一拍
是否都回到确定值；特别是 `amo_mode_r`（它会让 WB 拍选 `amo_old`，
若残留会让**下一条 lw 读到旧影子而不是真值** —— 这正好解释"第 3 组的 lw 读回旧值"）。

---

## 5.10 【Round 37】修掉 `amo_mode_r` 被过早清掉（真 bug），但 `amoor` 组仍挂

### 修掉的 bug：`amo_mode_r` 只保持了**一拍**

原代码：
```systemverilog
if (amo_en) begin
  ...
  amo_mode_r <= 1'b1;      // 启动拍置 1
end
else begin
  amo_mode_r <= 1'b0;      // **下一拍就被清掉!**
  ...
end
```
`amo_en` **只在启动拍有效**，所以 `amo_mode_r` 在**进入序列的第二拍就变 0** ——
而它本该让 **WB 拍**选 `amo_old`（AMO 的旧值）。等到真正的 WB 拍，它已经是 0，
WB 于是去读 `dmem_rdata`（那时 dmem 上早就是别的地址）→ `rd` 错误。

**修法**：只要序列还在进行（`amo_active`）就保持为 1，收尾那一拍才落下：
```systemverilog
if (amo_active) amo_mode_r <= 1'b1;
else            amo_mode_r <= 1'b0;
```
（同时给 `off_wb/size_wb/...` 的捕获加了 `!(state == S_AMO)` 守卫，
避免 AMO 期间被别的请求覆盖规格。）

### 结果

`amo_diag`（amoadd）与 `amo_diag2`（amoswap）**仍然 PASS**，
但 `amo.S` **仍在第 3 组（`amoor`）挂**（`tohost=4`）。

### 当前卡点（供下一轮）

`amoor` 组：`0xF0F0F0F0 | 0x0F0F0F0F` 期望 `0xFFFFFFFF`。
已有证据表明**该组的算子结果是对的**（`[L]` 打印 `WDATA=ffffffff strb=f WE=1`），
**而紧随其后的 `lw` 读回旧值**。所以问题集中在
**"AMO 之后紧接的那条 `lw` 为什么读到旧数据"**。

**下一轮第一步**：打印 AMO 序列结束后**紧接着那条 `lw`** 的 WB 拍
`rdata_eff` / `amo_mode_r` / `dmem_rdata` 三个值 —— 判断是不是
`amo_mode_r` 又多保持了一拍（把 `lw` 自己的数据挤掉了），
或者 `amo_old` 覆盖了 `lw` 的读值。

> 这是一次**"修了一个真 bug 但没解决现象"**的典型情况：
> `amo_mode_r` 的过早清零确实是个 bug（WB 拍选错来源），修掉它让
> 前两组更稳，但第 3 组的主因在别处。**两个 bug 叠在同一段逻辑上** ——
> 这与本项目之前"AMO 地址两个 bug 叠加"（`alu_b_src` + 独立加法器）是同一模式。

---

## 5.11 【Round 39】我自己引入的一个 bug，已回退 + 诊断数据

### 回退：`!(state == S_AMO)` 守卫是错的

Round 37 我为了"避免 AMO 期间规格被覆盖"，给 `off_wb/size_wb/uns_wb/split_wb`
的捕获加了守卫 `!(state == S_AMO)`。**这是错的**：

> **"请求离开 MEM"那一拍正是 AMO 的写相**（`state` 还是 `S_AMO`，写相把
> `lsu_stall` 拉低放行）。加了守卫 → **紧随 AMO 之后那条指令的
> `off_wb/size_wb/uns_wb/split_wb` 永远不被锁存** → 它的字节提取/符号扩展
> 用的是**上一条的规格** → 表现为"AMO 之后那条 `lw` 读回 0"（真值被按
> 旧规格错误截取/扩展掉了）。

**已回退该守卫**。这也解释了为什么 amoor 组一直挂：前面几轮查的是"写通路"，
方向错了 —— 真正的问题在 **AMO 之后那条指令的 WB 规格**。

### 诊断数据（`[M]` 打印，供下一轮直接用）

`amo_mode_r` 的生命周期**符合设计**：
```
t=175000 st=3 ph=1 mode_r=1   <- AMO 写相 (放行拍, state 仍 S_AMO)
t=185000 st=0 ph=1 mode_r=1   <- AMO 的 WB 拍, mode_r 仍为 1 -> rdata_eff=amo_old ✅
t=295000 st=0      mode_r=0   <- 已落下; 此时 rdata=00000000
```
即 `mode_r` 在 AMO 的 WB 拍确实为 1（选 `amo_old`），随后落下 —— **这段是对的**。

**下一轮第一步**：看 `t=195000`（紧随 AMO 的 `lw` 的 WB 拍）那几拍的
`off_wb/size_wb/uns_wb` 与 `rdata_eff` —— 回退守卫后它们是否被正确锁存。
若 `rdata_eff` 仍为 0，再查 dmem 是否真的收到了写（用 `u_dmem.mem[word]` 直接探阵列）。

### 本轮结论

- **回退了一个我自己引入的 bug**（这是净改进，且方向更明了）
- 回归 `PASS 10 | XFAIL 1`（`amo_diag`/`amo_diag2` 保持通过）
- 把"真正的问题在 AMO 之后那条指令的 WB 规格"这一判断**写进文档**

---

## 5.12 【Round 40】`amoor` 的真根因找到了：**AMO 停顿期间 PC 与 IF/ID 失步，释放时吞掉紧随的指令**

> **上面 5.11 的判断（"问题在 AMO 之后那条指令的 WB 规格"）是错的**，
> 与"写通路"一样属于方向性误判。逐拍实测把真根因钉死在**取指/停顿的失步**上。

### 决定性证据（`+amo_trace` 逐拍打印，`amo.S` 第 3 组）

第 3 组的代码布局（**关键：`lw` 紧贴 AMO**）：
```
0x80000084  4062a3af   amoor.w t2,t1,(t0)     <- 多周期读-改-写
0x80000088  0002ae83   lw t4, 0(t0)           <- 紧贴的读回
0x8000008c  00000e37   lui t3, 0xFFFFFFFF
0x80000090  fffe0e13   addi t3, t3, -1
0x80000094  1bce9a63   bne t4, t3, fail3
```

实测逐拍（`idex_pc` = ID/EX 里的指令，`if_pc` = IF/ID 里的指令）：
```
cyc39  st=0  idex_pc=0x80000084(AMO)  if_pc=0x80000088(lw)      <- lw 已进 IF/ID
       ==== AMO enters MEM ====
cyc41  st=1  idex_pc=0x8000008c        if_pc=0x80000090        <- lw 已不在 IF/ID
cyc42  st=1  idex_pc=0x8000008c        if_pc=0x80000090
cyc43  st=1  idex_pc=0x8000008c        if_pc=0x80000090
cyc44  st=0  idex_pc=0x80000090        if_pc=0x80000094        <- 释放: 直接进了 li
```

**`lw`（0x80000088）从未出现在 ID/EX 的 PC 序列里 —— 它被整条吞掉了。**

### 根因

**AMO 多周期停顿期间，`pc` 与 IF/ID 各自前进/冻结的节拍不同，于是失步：**

- 停顿期间 `pipe_stall=1` 冻结 `if_id`，但 `pc` 已经把**下一条**指令取进来了
  （cyc41 时 `if_pc` 已经是 0x80000090，而 PC 也停在 0x80000090）
- 停顿释放那一拍，流水线一次前进**两条**指令：
  ID/EX 拿到 0x80000090，IF/ID 拿到 0x80000094
- 夹在中间的 `lw`（0x80000088）**没有任何一拍被写进 ID/EX**

所以 `t4` 保持旧值 → `bne t4,t3,fail3` 失败 → `tohost=4`。

### 这也解释了此前的所有"诡异"现象

| 观察 | 现在有了统一解释 |
|---|---|
| `amo_diag`（AMO 后隔了 `li`）**PASS** | 间隔的 `li` 恰好吸收了那个被吞的槽位，`lw` 落在了正确的位置 |
| `amo.S` 第 1/2 组（AMO 后隔了 `li t3`/`bne`）**PASS** | 同上 |
| `amo.S` 第 3 组（`lw` 紧贴）**FAIL** | 没有任何间隔可吸收，`lw` 被吞 |
| 写通路诊断一直"看着是对的" | 因为**写通路本来就对**；错的是 `lw` 根本没执行 |

### 下一轮第一步（很具体）

**不要再查写通路、也不要再查 WB 规格** —— 两处都已证明正确。
要修的是**多周期停顿与取指前端的失步**。三个候选方向：

1. **释放时补一个气泡 + 把被吞的指令重新取回**：释放那拍让 `if_id` 注入 NOP，
   同时让 `pc` 回退到"IF/ID 里那条指令的后继"，下拍重新取回被吞的指令。
2. **让 `pc` 在停顿期间就不越过 IF/ID**（停顿期间把 `pc` 一并冻结在
   `if_pc` 的后继上）—— 本质是让前端在停顿期间保持"PC 与 IF/ID 差一拍"的不变量。
3. **给 LSU 的多周期请求做一次"取指侧冻结"**：`lsu_stall` 有效期间前端整体冻结
   （含 `pc`），释放后再统一前进。

**诊断手段**：`+amo_trace` 探针可直接看 `idex_pc / if_pc / if_i / pipe_stall /
pipe_release / if_id_flush` 的逐拍关系（本轮就是靠它定位的）。
建议先把它固化成一个正式的 plusarg 探针（本轮用完已移除）。

> **本项目已第四次出现同一族教训**：先怀疑"数据通路/写通路"，
> 真因却在"控制/时序对齐"。见 PITFALLS R24/R26。


---


## 1. 为什么要记这一篇

A 扩展是赛题"指令集扩展"这一项里唯一还没做的。我在动手前先把**前置条件**验证了
（工具链能不能编、编码长什么样），这样下一轮实现时不用再花时间确认这些。
**本轮没有写 RTL** —— 原因见第 4 节，宁可留清楚的设计，也不提交跑不通的代码。

## 2. 工具链验证（本轮实测）

```
riscv-none-elf-gcc -march=rv32ia -mabi=ilp32 -c a.S   ->  exit=0  (可用!)
```

反汇编（真实编码，已逐条确认）：

| 指令 | 编码 | opcode | funct5 | aq | rl |
|---|---|---|---|---|---|
| `amoadd.w t2,t1,(t0)` | `0x0062a3af` | `0x2F` | `00000` | 0 | 0 |
| `lr.w t3,(t0)` | `0x1002ae2f` | `0x2F` | `00010` | 0 | 0 |
| `sc.w t4,t1,(t0)` | `0x1862aeaf` | `0x2F` | `00011` | 0 | 0 |
| `amoswap.w t5,t1,(t0)` | `0x0862af2f` | `0x2F` | `00001` | 0 | 0 |
| `amoor.w t6,t1,(t0)` | `0x4062afaf` | `0x2F` | `01000` | 0 | 0 |

**字段布局**（与 RV32I 的 R 型一致，只是 opcode 换成 `0x2F`）：

```
 31      27 26 25 24    20 19    15 14  12 11     7 6      0
+----------+--+--+--------+--------+------+--------+--------+
|  funct5  |aq|rl|  rs2   |  rs1   |funct3|   rd   | opcode |
+----------+--+--+--------+--------+------+--------+--------+
   5 位      1  1   5 位     5 位   000    5 位     0101111
```

- `funct3 = 000`（.W 变体）
- `aq`/`rl` 在 bit26/bit25
- **`lr.w` 用 rs2 字段当 funct5 的高位**：`funct5=00010`，rs2 必须为 0

**funct5 完整表**：

| funct5 | 指令 | 语义 |
|---|---|---|
| `00001` | `amoswap.w` | mem <- rs2, rd <- 旧值 |
| `00000` | `amoadd.w` | mem <- 旧值 + rs2 |
| `00100` | `amoxor.w` | mem <- 旧值 ^ rs2 |
| `01100` | `amoand.w` | mem <- 旧值 & rs2 |
| `01000` | `amoor.w` | mem <- 旧值 \| rs2 |
| `10000` | `amomin.w` | mem <- min(旧值, rs2)（**有符号**）|
| `10100` | `amomax.w` | mem <- max(旧值, rs2)（**有符号**）|
| `11000` | `amominu.w` | mem <- min(旧值, rs2)（**无符号**）|
| `11100` | `amomaxu.w` | mem <- max(旧值, rs2)（**无符号**）|
| `00010` | `lr.w` | rd <- mem，置预留 |
| `00011` | `sc.w` | 有预留则 mem <- rs2 且 rd <- 0；否则 rd <- 1 |

> 注意 `amomin/max` 与 `amominu/maxu` 的**符号语义不同** —— 这是最容易写错的一处，
> 必须分开实现有符号与无符号比较。

## 3. 实现方案（下轮照这个做）

### 3.1 难点：AMO 是"读-改-写"，本核一次只能访存一拍

当前 LSU 只有 `req_read` **或** `req_write`，单拍完成。AMO 需要一个**多周期**序列：
读 -> 计算 -> 写。所以必须：

1. `rv32_pkg.sv`：`alu_op_e` 增加 9 个 AMO 操作；`ctrl_s` 增加
   `amo_op[4:0]` 与 `amo_en`（或复用 `alu_op`，看哪个更省走线）。
2. `control_unit.sv`：译码 `opcode==7'b0101111`，按 `funct5`/`funct3` 分发，
   **非法组合必须置 illegal**（现在整个 opcode 都会掉非法，别把它放松了）。
3. `core.sv`：新增一个小状态机 `S_AMO_IDLE -> READ -> MODIFY -> WRITE -> DONE`，
   期间拉高 `amos_stall`；把它并入 `pipe_stall`（和 `md_busy`/`lsu_stall` 并列）。
4. `load_store_unit.sv`：把读改写序列做完，`rd` 写回**旧值**。
5. LSU 里加**预留位** `resv_valid` + `resv_addr`（单核只需一项）：
   - `lr.w` 置位；
   - `sc.w` 检查预留且地址匹配 -> 成功（写 + rd=0），否则失败（不写 + rd=1）；
   - **任何 store / trap / 中断都要清预留**（规范要求）。

### 3.2 单核简化点（可以省，但要写进文档）

- 单 hart 下 AMO 天然原子（没有别的 master 竞争），所以**不需要总线锁**。
- `aq`/`rl` 位在单核 + 无缓存的情况下**无实际作用**，可以译码后忽略，
  但要在注释里写明"已译码、单核语义下无副作用"，避免被当成漏实现。

### 3.3 验证方式

- 新增 `sim/prog/amo.S`：对每个 funct5 各测一组（含**负数**用例，
  专门覆盖 `amomin/max` 的有符号语义）；
- `lr`/`sc` 成功路径 + **失败路径**（中间插一次 store 使预留失效）；
- 用 `tohost` 协议分组上报，接入现有回归矩阵（现在 9 项）。

## 4. 本轮为什么没写 RTL

A 扩展需要**改 `rv32_pkg.sv` / `control_unit.sv` / `core.sv` / `load_store_unit.sv`
四个文件并新增一个多周期状态机** —— 这与本项目已经踩过的教训高度重合：
一次改动跨 4 个文件 + 新增状态机，正是最容易做出"编译过、跑不通"的形态。

而且它在**评分三项（CoreMark/MHz、fmax、CoreMark/LUTs）上是零贡献**：
CoreMark 不含任何原子指令，加了 A 扩展 CoreMark ticks 一位都不会变，
LUT 反而增加。它只值"指令集扩展"这一项**功能完备性**。

**所以本轮选择：把验证过的前置条件与完整设计写成文档，不动 RTL。**
宁可不做，也不提交跑不通的东西 —— 这是本项目已经用三次事故换来的纪律。

---

## 5.13 【2026-10-06】✅ **打通了** —— 真根因是 LSU 在 AMO launch 拍漏拉 `lsu_stall`

> **本节推翻 5.12 的判断。** 5.12 把根因归为"AMO 停顿期间 pc 与 IF/ID 失步、
> 释放时吞掉紧随的指令"。**那个描述是错的** —— `lw` 并没有被吞掉，
> 它一直在流水线里，只是**读错了数据源**。

### 真正的根因（一行）

```systemverilog
// load_store_unit.sv — 修改前
assign lsu_stall = (state == S_HEAD) || (state == S_IDLE && needs_split)
                 || (state == S_AMO && (amo_wait || !amo_phase));
//                                             ^^^^^ 注意: S_IDLE 分支只处理 needs_split
```

**AMO 的 launch 拍（`state==S_IDLE && amo_en`）没有拉 `lsu_stall`** ——
而拆分的非对齐访存在同一位置（`state==S_IDLE && needs_split`）是**拉**的。
两者本该对称，AMO 这条路漏了。

后果是一条很隐蔽的错位：

```
launch 拍不拉 stall -> hold_mem=0 -> 流水线**多前进一拍**
  -> EX/MEM 被后一条指令顶掉、MEM/WB 提前一拍让出
  -> AMO 的 WB 落在 cyc41; 紧随 AMO 的那条 lw 的 WB 提前到 cyc44
  -> cyc44 恰好是 amo_mode_r 仍为 1 的那一拍
  -> lw 取的是 rdata_eff = amo_old 而不是 dmem_rdata
```

**决定性证据**（`amo.S` 第 3 组：`amoor` 后面紧贴 `lw t4,0(t0)`）：

```
cyc44  wb_rd=29(=t4, lw 的目的寄存器)   wb=0xf0f0f0f0   mode_r=1
       ^ 该写 0xFFFFFFFF, 实际写了旧值
```

### 修复

```systemverilog
assign lsu_stall = (state == S_HEAD) || (state == S_IDLE && (needs_split || amo_en))
                 || (state == S_AMO && (amo_wait || !amo_phase));
```

拉停 launch 拍后：AMO 的 WB 落在 cyc44（`mode_r=1`，正确取 `amo_old`），
lw 的 WB 推到 cyc45（`mode_r=0`，正确取 `dmem_rdata`）。

### 实测结果

| 项 | 结果 |
|---|---|
| `tb_core_amo` | **XFAIL → PASS**（摘掉了 `expect_fail_ok`）|
| 全量回归 | **PASS 11，无 XFAIL，exit=0** |
| `tb_core_amo_diag` | PASS（保持）|
| CoreMark ticks | **423527 不变**（A_EN 关闭时该项恒 0，逻辑等价）|
| 默认配置综合 | **逐项与基线相同**：2.3611 / 61.2 / 4079 / 5.788e-4 / 144.4 |

### 为什么前几轮方向全错（值得记）

| 轮 | 判断 | 实际 |
|---|---|---|
| 5.8~5.10 | "写通路有问题" | 写通路**一直是对的**（`WDATA=ffffffff` 打印正确）|
| 5.11 | "AMO 之后那条 lw 的 WB 规格没锁存" | 规格锁存**是对的**（回退守卫后已正常）|
| 5.12 | "停顿释放吞掉了 lw" | lw **没被吞**，只是读错数据源 |
| **5.13** | **LSU launch 拍漏拉 stall，WB 相位错开一拍** | ✅ 一行修好 |

**共性教训**：三次都把"值不对"归到**数据通路**，而真因是**时序/相位**。
一条 `wb_rd=29 wb=0xf0f0f0f0 mode_r=1` 的打印，比三轮猜测都值钱 ——
**打印里要带"这是哪条指令（rd/pc）"，否则看到错值也不知道是谁的**。

### A_EN 现在的代价（重新实测，2026-10-06）

功能打通后重测（此前 61.7→58.8 MHz 是**多周期未实现时**的数字）：

| # | 配置 | CM/MHz | fmax | LUT | CM/LUTs | 绝对吞吐 |
|---|---|---|---|---|---|---|
| 1 | comb（默认）| 2.3611 | 61.2 | 4079 | 5.788e-4 | 144.4 |
| 2 | **comb + A** | 2.3611 | **63.1** | 4321 | 5.464e-4 | **148.9** |
| 3 | regread | 2.3611 | 58.9 | **2820** | **8.373e-4** | 139.1 |
| 4 | regread + A | 2.3611 | 59.7 | 3069 | 7.693e-4 | 141.0 |

`verify --a-ext`（全局开 A_EN）也是 **PASS 11**。
**A_EN 反而让 fmax 更高**（61.2→63.1）—— 这是新增逻辑改变了布局后的关键路径移动，
不是架构性提升，不要当成"A 扩展能提频"来解读。
`A_EN` 仍默认关闭：它值"指令集扩展"那一栏，对 CoreMark 三项指标零贡献。

