# AI 加速子系统 · 接口与数据契约 v0.1

> 本文件是**三条并行工作流之间的唯一契约**。任何一方要改字段/格式，必须先改这里并通知 Lead。
> 基线：分支 `feat/ai-accel`，从交付 tag `deliv150-o2ira`（= `main` @ d592067）拉出。
> **交付档（无 `NN_EN`）必须保持逐位不变**；AI 档用宏 `NN_EN` 打开，两者共用同一份源码。

---

## 1. 目标与顶层结构

```
top_a100t (AI 档)
├─ core.sv            ← 新增一组专用 NN 端口（1 拍读延迟，与 dmem 同口径）
└─ mmio_subsys.sv
    ├─ (原有) GPIO / 周期计数器 / UART / 定时器
    └─ nn_subsys.sv   ← 新增（Lead 负责）
         ├─ nn_mem.sv          ← 大容量 BRAM（权重 + 2 块激活缓冲）（T-mem 负责）
         └─ nn_conv_engine.sv  ← int8 卷积引擎（T-accel 负责）
```

**为什么 CPU 走专用端口而不是 MMIO 总线**：本核 MMIO 是**组合读**（外设同拍给 `ext_rdata`，
core 再寄存一拍），而 BRAM 是**同步读**（地址进、下一拍出）。若把大 BRAM 挂在 MMIO 总线上，
两者相差一拍，WB 取到的会是上一拍的旧数据（PITFALLS R32 那一类相位错误）。
所以给 core 加一组 `nn_*` 端口，用与 `dmem` **完全相同的寄存读口径**：
地址在 MEM 拍给出，数据在 WB 拍有效。代价是 core 里多一级选择 mux（`sel_nn_r`）。

---

## 2. 地址映射（AI 档新增项）

| 区域 | 地址 | 大小 | 访问 | 说明 |
|---|---|---|---|---|
| IMEM | `0x8000_0000` | 16 KB | 取指 | 不变 |
| DMEM | `0x9000_0000` | 16 KB | LSU | 不变（窗口 `DMEM_BASE..+16K`） |
| **NN 存储窗口** | `0x9004_0000` | **512 KB**（`NN_BYTES`） | LSU（`nn_*` 端口） | 权重 + 激活缓冲；1 拍读延迟 |
| MMIO | `0xA000_0000` | 4 KB | ext_* | 原有外设，不变 |
| **NPU 控制寄存器** | `0xA000_0100` | 128 B | ext_* | 见 §4 |

- `NN_BASE = 0x9004_0000`（256 KB 对齐，避开 DMEM 窗口），`NN_BYTES = 512*1024`。
- CPU 在 `[NN_BASE, NN_BASE+NN_BYTES)` 内的 load/store 由 `core` 译码成 `sel_nn`，
  **不经过** ext_* 总线（`ext_re/ext_we` 必须把 `sel_nn` 排除）。
- NPU busy 期间 CPU 访问该窗口：返回 `0xDEAD_BEEF` 并置 `STATUS.err`（软件契约：busy 时不许碰）。
  由 `nn_subsys` 做门控，**不是**靠 CPU 停等（本核 ext 通路没有 wait-state 机制）。
- 软件侧指针定义（`nn_pkg.sv` 的 v0.3 常量）：`NN_W_OFF=0x00000`、`NN_Q_OFF=0x50000`、
  `NN_A_OFF=0x60000`（96KB）、`NN_B_OFF=0x78000`（32KB）；WQ 368KB。

## 3. 存储布局（NN 窗口内，字节偏移；v0.3.1 按 BRAM 物理容量与实际张量峰值反推）

| 区 | 偏移 | 大小 | 内容 |
|---|---|---|---|
| W | `0x00000` | 320 KB | int8 权重（§6 布局，逐层拼接；实测 319,792 B） |
| Q | `0x50000` | 48 KB（**变长紧凑**，见 §7；实测 payload 44,256 B） | 每层量化参数，`qoff` 由 plan.json 逐层给 |
| — | `0x5C000` | 16 KB | **地址空洞**（不占 BRAM，读回 0） |
| A | `0x60000` | **96 KB** | 激活缓冲 A（NHWC，8 通道分块；须容纳 128 输入下最大单张量 24ch×64×64 = 98,304 B）|
| B | `0x78000` | **32 KB** | 激活缓冲 B（与残差并存的小张量）|

窗口总长 `0x80000` = 512 KB，正好卡满 `NN_BYTES`，所以 **CPU 能访问全部 A/B**。

> **WQ 连续**（W 320KB + Q 48KB = 368KB）是刻意设计：引擎只用一个 `w` 读口就能读到
> 权重**与**量化参数（§9.1），nn_mem 里也只是同一块 32 位/64 位字阵列，只需要一个
> 初始化镜像 `NN_W_INIT_FILE`（368KB / 4 = **94208 行**，见 §10）。
>
> **BRAM 预算（物理硬约束）**：行为级推断下可按字节寻址的容量是
> **4KB/BRAM36**（32 位宽 1K×36、64 位宽 512×72，parity 位不能用于字节寻址）。
> XC7A100T = 135 块，交付档核心已用 9 块（imem4 + dmem4 + bht1）⇒ NPU 上限约 504KB。
> v0.3.1 占用：WQ 368KB(92) + A 96KB(24) + B 32KB(8) = 496KB ⇒ **合计 133/135，余 2 块**。
> **任何新增片上存储都必须先报 Lead**（余量是 2 块，不是"还有很多"）。
> 峰值激活实测（@128 输入）：A = 98,304 B（24ch×64×64）、B = 32,768 B，并发峰值 131,072 B。
> A=96KB/B=32KB 正好装下；A/B 之和仍是 128KB ⇒ **总 BRAM 与 v0.3 相同**。

---

## 4. NPU 控制寄存器（MMIO `0xA000_0100` 起，32 位字访问）

| 偏移 | 名字 | 读写 | 语义 |
|---|---|---|---|
| `0x00` | `NN_CTRL` | W | bit0=start（只在 IDLE 受理）；bit1=irq_en |
| `0x04` | `NN_STATUS` | R | bit0=busy；bit1=done（读清）；bit2=err（读清，非法描述符/忙时 CPU 访问）；bit3=irq |
| `0x08` | `NN_CYCLES` | R | 上一次 op 的忙周期数（软件算加速比用） |
| `0x0C` | `NN_OP` | W | bit[1:0] op：0=conv/dwconv，1=maxpool，2=copy/upsample，3=residual-add |
| `0x10` | `NN_SRC` | W | 源激活缓冲基址（字节偏移，相对 NN 窗口） |
| `0x14` | `NN_DST` | W | 目的激活缓冲基址（字节偏移） |
| `0x18` | `NN_WOFF` | W | 该层权重区字节偏移 |
| `0x1C` | `NN_QOFF` | W | 该层量化参数区字节偏移 |
| `0x20` | `NN_IH` | W | 输入高（像素） |
| `0x24` | `NN_IW` | W | 输入宽 |
| `0x28` | `NN_IC` | W | 输入通道（真实值，非 padding） |
| `0x2C` | `NN_OC` | W | 输出通道（真实值） |
| `0x30` | `NN_KS` | W | 卷积核：1 / 3 / 5（pool 时=池化核 2/3/5/9） |
| `0x34` | `NN_ST` | W | 步长：1 / 2 |
| `0x38` | `NN_PAD` | W | 0 / 1（真实 padding 像素数；5×5 用 2 时写 2） |
| `0x3C` | `NN_FLAGS` | W | bit0=depthwise；bit1=leaky(斜率 0.1)；bit2=add-mode（输出累加到 DST 原值）；bit3=upsample 2×（op=2 时）；bit4=pool 取 max |
| `0x40` | `NN_DBG0` | R | 引擎状态机状态（排障用） |
| `0x44` | `NN_DBG1` | R | {cur_ic[15:0], cur_oc[15:0]} |
| `0x48` | `NN_DBG2` | R | {cycles[15:0], desc_err_code[7:0], 8'b0} |

- 每层软件流程：写 14 个描述符寄存器 → 写 `NN_CTRL.start` → 轮询 `NN_STATUS.done` → 读 `NN_CYCLES`。
- 层间缓冲 ping-pong 由软件决定（SRC/DST 写 A/B 基址）。
- 参数合法性在 start 拍检查：`IC/OC≥1`、`KS∈{1,3,5}`、`ST∈{1,2}`、`PAD∈{0,1,2}`、
  `IC≤256`、`OC≤256`、dst 尺寸不越界；不合法 → 不启动 + `STATUS.err=1`。

---

## 5. 量化契约（int8 PTQ，全整数，位精确可复现）

**权重**：int8 对称，逐输出通道（per-OC）：
`s_w[oc] = max|W[oc,:,:,:]| / 127`，`w_q = clamp(round(W/s_w), -127, 127)`（BN 已先折叠进卷积）。

**激活**：int8 **非对称**，逐张量（per-tensor）：
`zp_a = -128 - round(min/s_a)`、`s_a = (max-min)/255`、`a_q = clamp(round(a/s_a)+zp_a, -128, 127)`。
【v0.3.1 写死】这样 `min→-128`、`max→127` 同时成立；例：图像 `a∈[0,1]` ⇒ `s_a=1/255、zp_a=-128`、
`a_q = round(255a)-128`。**bias_adj 必须用同一个 zp_a**（见下）。

**BN 折叠**（仅 `batch_normalize=1` 的 conv）：
`W' = W * gamma / sqrt(var+eps)`，`b' = beta - mean*gamma/sqrt(var+eps)`。

**累加与偏置**（关键：把 zero-point 折进 bias，硬件只做原始 int8 乘加）：
```
acc[oc] = Σ_{ic,k} a_q[ic,k] * w_q[oc,ic,k]  +  bias_adj[oc]
bias_adj[oc] = round(b'[oc] / (s_a * s_w[oc]))  -  zp_a * Σ_{ic,k} w_q[oc,ic,k]
```

**requant（逐输出通道；v0.3：int16 M_pos + 每层 SHIFT + 现算 M_neg）**：
```
ratio      = s_a_in * s_w[oc] / s_a_out
SHIFT      = 每层一个整数 (1..30)：取使 max_oc( round(ratio*2^SHIFT) ) 落在 int16 正数区间
M_pos[oc]  = int16( round( ratio * 2^SHIFT ) )            # 正支
M_neg[oc]  = (M_pos[oc] * 3277 + 16384) >> 15             # 负支/leaky, 3277/2^15≈0.100006
y[oc]      = (acc >= 0 ? acc*M_pos[oc] : acc*M_neg[oc]) >> SHIFT   # 算术右移 = floor
out_q[oc]  = clamp(y + zp_a_out, -128, 127)
```
- 【v0.2 修正】`M_pos` 必须含 `s_a_in * s_w[oc]`（v0.1 漏了会整层错）。
- 【v0.3 压缩】`M_pos` 从 int32 降到 **int16**（每层独立 `SHIFT` 保精度）以把 Q 区压到 48KB；
  **`M_neg` 不存**，由引擎/软件在 OC tile 装载时按上面的整数公式现算 —— 两边逐位一致。
- 无 leaky 的层：`M_neg[oc] = M_pos[oc]`（linear）。
- **舍入口径统一为 floor**（Python `int64 >> SHIFT`、RTL `$signed(prod) >>> SHIFT`）。
- `acc` 量级上界：`|acc| ≤ K·127·127 + |bias_adj|`，最大 K≈IC·K²≈2016 ⇒ |acc| ≲ 2^25；
  乘积 `acc*M` 需要 40~43 位精度 —— **必须用 64 位（或两段 32 位）乘法**，不许截断 32 位。
- `SHIFT`、`zp_a_out`、`zp_a_in`、`bias_adj`、`M_pos` 存 Q 区（§7），`qoff` 由 plan.json 逐层给。
- T-model 的 golden 必须与以上**逐位一致**（同一份整数运算），并在 model-report 里贴出对拍 mismatch。

> **纪律**：量化脚本必须内置两种自检并打印 —— ① 反量化最大误差；② 逐层输出与浮点参考的
> 余弦相似度/最大绝对误差。任何"看起来对"的推理结果都必须有数值判据，不接受肉眼判定。

---

## 6. 权重 BRAM 布局（硬件读取顺序决定，必须逐字节一致）

两层布局，均按 `OC_pad = ceil(OC/8)*8`、`IC_pad = ceil(IC/8)*8` 补齐，padding 写 0。

**A. dense（普通卷积 / 1×1 / depthwise=false）**：`[tap][IC_pad][OC_pad]`，OC 在最低位（8 字节一组）
```
for tap in 0..K*K-1:            # tap = ky*K + kx
  for ic in 0..IC_pad-1:
    for oc in 0..OC_pad-1:
      byte  = w_q[oc][ic][tap]  # 0 if oc>=OC or ic>=IC
```
→ 每个 `(tap,ic)` 是一个 8 字节（OC 方向 8 通道）的权重字，引擎按此顺序每拍取一个权重字。

**B. depthwise（depthwise=true，OC==IC==C）**：`[tap][OC_pad]`
```
for tap in 0..K*K-1:
  for oc in 0..OC_pad-1:
    byte  = w_q[oc][tap]        # 0 if oc>=C
```

## 7. 量化参数区布局（**v0.3 变长紧凑布局**；每层大小 = `6*OC_pad + 16` 字节，`qoff` 由 plan.json 给）

| 相对偏移 | 类型 | 数量 | 内容 |
|---|---|---|---|
| `+0x000` | int32 | OC_pad | `bias_adj[oc]`（`4*OC_pad` 字节） |
| `+4*OC_pad` | **int16** | OC_pad | `M_pos[oc]`（`2*OC_pad` 字节；本层 `SHIFT` 见 tail） |
| `+6*OC_pad` | int8 | 16 | 尾部打包：`[0]=zp_out(int8) [1]=zp_in(int8) [2]=leaky_en(0/1) [3]=SHIFT [4..15]=0` |
| 每层 | | `6*OC_pad+16` | 全模型 84 个 conv ⇒ 实占 ≈43.2 KB（Q 区 48KB 留余量） |

> **v0.3**：不再有固定 0x1000/层（16KB 只够 4 层，v0.2 的算术是错的）；
> **不再存 M_neg**（现算，见 §5）；`M_pos` 用 int16（每层独立 SHIFT）。
> Q 区由引擎通过 **w 读口**读取（§9.1），读 `bias`/`M_pos` 时按 8 字节对齐批量取。
> 各数组后部（`oc` 从 OC 到 OC_pad）填 0。

---

## 8. 激活 BRAM 布局（NHWC，8 通道分块，64 位字）

一个张量 `(C, H, W)`（真实通道 C，`C8 = ceil(C/8)*8`）在缓冲里的字节偏移：
```
addr(C,H,W, c, y, x) = ((y*W + x) * C8 + c_block) * 8 + c_byte
其中 c = c_block*8 + c_byte, c_block ∈ [0, C8/8)
```
- 读口：**每拍 1 个 128 位读请求**（= 2 个 64 位字 = 同一像素的 16 通道，或 2 个相邻像素各 8 通道；
  由引擎按 `NN_FLAGS`/op 选择语义；nn_mem 只按线性 word 地址返回 2 个字）。
- 写口：每拍 1 个 64 位字（8 通道）。
- 未用通道填 `zp_a`（通常 0），引擎不读 padding 通道的结果。

---

## 9. 模块接口契约

### 9.1 `nn_mem`（T-mem 负责实现）

```systemverilog
module nn_mem #(
  parameter int W_BYTES = 320*1024,   // 权重区
  parameter int Q_BYTES = 16*1024,    // 量化参数区
  parameter int A_BYTES = 96*1024,    // 激活缓冲 A (最大单张量 98,304B)
  parameter int B_BYTES = 32*1024,    // 激活缓冲 B
  parameter int CPU_AW  = 19          // 512 KB / 4 → 17 位字地址 + 富余
)(
  input  logic         clk,
  input  logic         rst,
  // ---- CPU 窗口（1 拍寄存读，与 dmem 同口径）----
  input  logic         cpu_re,        // 读选通（地址已由 core 给出）
  input  logic         cpu_we,
  input  logic [31:0]  cpu_addr,      // 字节地址（NN_BASE 相对偏移）
  input  logic [31:0]  cpu_wdata,
  input  logic [3:0]   cpu_wstrb,
  output logic [31:0]  cpu_rdata,     // 下一拍有效
  // ---- NPU 权重/Q 参数读口（64 位/拍，1 拍延迟）----
  //  【v0.3 口径】w_addr 是**整个 NN 窗口内的字节偏移**（24 位足够 512KB）：
  //      w_addr < WQ_BYTES (=368KB)      -> 读 wq 阵列（W 权重 + Q 量化参数 连续）
  //      其他 (A/B 区 / 空洞 / 越界)      -> 返回 0
  //    引擎用 desc.qoff + §7 的相对偏移读 bias / M_pos / tail。
  input  logic         w_re,
  input  logic [23:0]  w_addr,        // NN 窗口内字节偏移（8 字节对齐）
  output logic [63:0]  w_rdata,       // 2 个 int32 / 8 个 int8 / 4 个 int16，小端
  // ---- NPU 激活读口（128 位/拍，1 拍延迟）----
  input  logic [1:0]   a_sel,         // 0=A,1=B（由 desc.src 的地址段决定）
  input  logic         a_re,
  input  logic [23:0]  a_addr,        // 字节偏移（16 字节对齐）
  output logic [127:0] a_rdata,
  // ---- NPU 激活写口（64 位/拍）----
  input  logic [1:0]   b_sel,         // 0=A,1=B（由 desc.dst 的地址段决定）
  input  logic         b_we,
  input  logic [23:0]  b_addr,
  input  logic [63:0]  b_wdata
);
```
- **v0.3.1 参数**：`W_BYTES=320KB`、`Q_BYTES=48KB`、`A_BYTES=96KB`、`B_BYTES=32KB`、`WQ_BYTES=368KB`；
  A 基址 `0x60000`、B 基址 `0x78000`（`B_OFF = NN_A_OFF + A_BYTES`；B 末尾正好 0x80000=512KB）。
- **v0.2 移除** `w_init_done` / `busy_npu` 两个观测口（busy 由引擎给出，初始化对引擎透明）。
- 权重/激活 BRAM 必须**行为级推断**成 BRAM，不得例化厂商原语（迁移 PDS 纪律，R 系列）。
- **WQ 初始化镜像（v0.3）**：W 与 Q 是**同一块阵列**（368 KB 连续），只需要一个初始化文件。
  综合：`ifdef SYNTHESIS` + `NN_W_INIT_FILE` 宏 + `$readmemh`（文件 = 32 位字/行，共 **94208 行**，
  见 §10 `yolo_wq.hex`）；仿真：`+nnwq=<file>` plusarg + `$readmemh`。
  沿用 imem.sv 的 `ifdef SYNTHESIS` 双路径写法；`string` 类型只允许出现在非 SYNTHESIS 分支
  （PITFALLS R33 / SKILL §6）；宏字符串里的路径**必须用正斜杠**（反斜杠是转义字符）。
- **不实现 A 缓冲初始镜像**（v0.3 取消 `NN_ACT_INIT_FILE`）：输入图由软件按 §10.1 公式生成。

### 9.2 `nn_conv_engine`（T-accel 负责实现）

```systemverilog
module nn_conv_engine #(
  parameter int OC_LANES = 8,     // 输出通道并行度
  parameter int PX_LANES = 8      // 像素并行度
)(
  input  logic        clk,
  input  logic        rst,
  // 描述符（由 nn_subsys 寄存，start 拍整体有效）
  input  nn_pkg::nn_desc_t desc,
  input  logic        start,
  output logic        busy,
  output logic        done,
  output logic [31:0] cycles,
  output logic [7:0]  err_code,
  // 权重端口（同 nn_mem.w_*）
  output logic        w_re,
  output logic [23:0] w_addr,
  input  logic [63:0] w_rdata,
  // 激活读（同 nn_mem.a_*）
  output logic [1:0]  a_sel,
  output logic        a_re,
  output logic [23:0] a_addr,
  input  logic [127:0] a_rdata,
  // 激活写（同 nn_mem.b_*）
  output logic [1:0]  b_sel,
  output logic        b_we,
  output logic [23:0] b_addr,
  output logic [63:0] b_wdata
);
```
- 引擎每拍最多 1 个权重读 + 1 个激活读 + 1 个激活写；所有读数据**下一拍**有效
  （引擎 FSM 必须按 1 拍延迟算等待，参考现有 `dmem` 用法）。
- 引擎内部 PE 寄存器阵列**不落 BRAM**（小规模），但不得用超大规模触发器数组
  ——上一版 GEMM 的教训：13K FF 是面积翻倍的直接原因（`results/p5-ai-accelerator.md`）。

### 9.3 `nn_pkg.sv`（Lead 负责，先行）

```systemverilog
package nn_pkg;
  localparam logic [31:0] NN_BASE  = 32'h9004_0000;
  localparam int unsigned NN_BYTES = 512*1024;
  typedef struct packed { ... nn_desc_t ... } nn_desc_t;
endpackage
```

---

## 10. 测试向量 / 文件格式（T-model 生成，T-accel/T-mem 使用）

目录：`sim/prog/yolo/`（**新建**；不要动 `sim/prog/*.hex` 现有镜像）。

| 文件 | 格式 | 内容 |
|---|---|---|
| `model.json` | JSON | 层表：每层 `{idx, op, k, stride, pad, ic, oc, ih, iw, oh, ow, flags, w_off, q_off, src, dst}` + 全局 `input_h/w`、校验和表 |
| `l<NN>_in.hex` | 每行 2 位十六进制（int8 补码） | 该层输入张量，NHWC 平坦序（**逻辑序：y-major, x, c**），长度 `H*W*C` |
| `l<NN>_w.hex` | 同上 | 该层权重，按 §6 布局（**含 padding**） |
| `l<NN>_q.hex` | 每行 8 位十六进制（int32） | 该层量化参数，按 §7（v0.3 变长：bias_adj → M_pos(int16 成对打包) → tail） |
| `l<NN>_out.hex` | 每行 2 位十六进制 | 该层输出（golden，int8，NHWC 逻辑序） |
| `checksums.txt` | 文本 | 每层输出 FNV-1a 32 位（`h=2166136261; for b: h^=b; h*=16777619`，对逻辑序字节） + 输入图 checksum |
| `yolo_wq.hex` | 每行 8 位十六进制（32 位字） | **硬件初始化镜像**：WQ 区 **376,832 B**（=0x5C000）的连续字节流（W 见 §6、Q 见 §7）。第 n 行的字 = `b[4n] | b[4n+1]<<8 | b[4n+2]<<16 | b[4n+3]<<24`；行数 = **94208**，不足补 0 |
| `plan.json` | JSON | **执行计划**（见 §10.1）：按执行顺序的原语清单 + 每步 src/dst/权重/量化参数偏移 + 期望 checksum。C 程序与 TB 都只读这一个文件 |

> `yolo_wq.hex` 的**行数必须精确等于** `(NN_W_BYTES+NN_Q_BYTES)/4 = 94208`（脚本内置断言）。
> 该文件同时用于：① Verilog `NN_W_INIT_FILE`（综合烧入）；② ModelSim `+nnwq=`（仿真装载）。
> **v0.3 取消 `yolo_act.hex` / `NN_ACT_INIT_FILE`**：输入图由软件按 §10.1 公式生成
> （可复现、无需 PC 参与；运行时可换图属于后续功能）。

### 10.1 `plan.json` 结构（执行计划，v0.3.1）

```json
{
  "input":  {"ih":128, "iw":128, "ic":3, "act_off":0, "packed":true,
             "gen":{"kind":"pattern_v1","seed":12345},
             "csum":<uint32>},
  "wq_bytes": 376832, "q_base": 327680,
  "ops": [
    {"id":0, "kind":"cpu_conv0", // conv | dwconv | pool | upsample | add | cpu_conv0 | cpu_concat | cpu_copy
     "k":3, "stride":2, "pad":1, "leaky":1,
     "ih":128,"iw":128,"ic":3,"oc":8,
     "src":{"buf":"A","off":0}, "dst":{"buf":"B","off":0},
     "woff":0, "qoff":327680,
     "csum":<uint32>},           // 该 op 输出（真实通道、紧凑布局）的 FNV-1a
    {"id":1, "kind":"conv", ...},
    ...
  ],
  "final_ops": [<op ids whose output the detector head reads>]
}
```
- **`cpu_conv0`（v0.3.1 新增，kind code = 7）**：第 0 层卷积由 **CPU 软件**执行，因为输入图若按
  §8 的 8 通道分块存储会占 `128×128×8 = 131,072 B`（A 缓冲 96KB，仍然放不下整个输入图）。
  输入图改用 **packed 3 字节/像素**（`packed:true`，stride=ic，无 padding）⇒ 49,152 B 放得下。
  CPU 读 packed 输入、写紧凑 8ch 输出（`ceil(oc/8)*8 = 8` 字节/像素）。量化/requant 规则与其他 conv 完全相同
  （weights 仍是 IC_pad=8 布局，CPU 只循环真实 ic）。MAC 数 ≈ 0.88M。
  **输入图 checksum 口径**：对 packed 布局（stride=3）的 y,x,c 逻辑序求 FNV-1a。
- **输入图（v0.2：确定性合成图，不存图像文件）**：`pattern_v1` 公式（C 与 Python 逐字节一致）：
  ```
  q[y][x][c] = int8( (x*13 + y*7 + c*29 + seed) & 0xFF )     # 实数→int8 的"已量化"图
  存到紧凑布局 offset = ((y*iw + x)*ceil(ic/8)*8 + c)；padding 通道 = 0
  input.csum = 对 y,x,c 逻辑序、真实通道的 FNV-1a
  ```
  好处：不需要 49 KB 图像存储，且"软件基线/硬件两遍运行"都可以在用前重新生成同一张图
  （真实图片走 UART/后续阶段，不在 v0.2 范围内）。
- **紧凑布局**：引擎/软件的每个 op 输出都是**紧凑张量**（pixel stride = `ceil(oc/8)*8` 字节；
  没有"目标张量总通道数"的概念）。`cpu_concat` 负责把多个紧凑张量按通道拼到目标张量
  （目标张量也是紧凑的，只是通道数 = 各源之和；CPU 用 `cpu_copy` 完成，不进硬件）。
- `cpu_concat`/`cpu_copy` 的字段：`{"kind":"cpu_concat","sources":[{"buf":..,"off":..,"c":..}],"dst":{...},"oc_tensor":<目标张量通道数>,"csum":..}`。
- `buf` ∈ {"A","B"}；`off` 是**缓冲内字节偏移**（相对 A/B 基址），由 T-model 按缓冲容量
  （各 128 KB）自行分配 —— 若放不下，先在报告里报 Lead，不要偷偷缩小模型。
- `qoff` 指向该层在 Q 区的绝对字节偏移（= `q_base + layer_q_index*0x1000`）。
- **checksum 口径**：对"真实通道 × H × W、紧凑布局（含通道 padding 字节? 不含）"的**逻辑序**
  （w-major, h, c）字节做 FNV-1a。**必须明确写进 model-report**（RTL TB 与 C 程序都按它比对）。

- **端序**：`.hex` 一律"字节直读"，不做字节交换；`.mem` 用于 `$readmemh` 的宽字镜像时由生成脚本
  同时输出（大端十六进制字，与 Vivado `$readmemh` 默认一致）。
- 权重 `.hex` 的 padding **必须真的存在**（0 填充），长度必须等于 `K*K*IC_pad*OC_pad`（dense）
  或 `K*K*OC_pad`（depthwise）；TB 会检查长度，长度不符直接 fail（不许"看起来跑通"）。

---

## 11. 引擎 v1 支持范围与精确语义（v0.2）

| op | 支持 | 精确语义 |
|---|---|---|
| conv / depthwise conv | K=1、3、5；stride 1、2；pad 0~2（`nn_desc_t.pad` 为 **3 位**）；leaky 可选 | 见 §5/§6/§8；**边界外像素填 `zp_in`**（不是 0）；`a_sel/b_sel` 由 `desc.src/dst` 落在哪一段决定 |
| **cpu_conv0（v0.3.1）** | 只第 0 层，由 **CPU 软件**执行（不走引擎） | 输入 packed 3B/像素、输出紧凑 8ch；量化/requant 同 conv。存在的唯一原因：8 通道分块的输入图 128KB 放不进 A 缓冲 |
| maxpool | K=2、3、5、9；stride 1、2；pad = K/2 | 逐 (pixel,channel) 取 int8 有符号最大值；窗口越界视为 `-128`（等价 darknet 的 -inf padding）；**不做 requant**；输出通道数 = 输入通道数，dst 布局同 src |
| copy / upsample | 2× 最近邻（`flags.UP2X`）；通道偏移拷贝（route/concat 用） | `desc.ic` = **源**张量通道数（算源 pixel stride），`desc.oc` = **目标**张量总通道数（算目标 pixel stride）；`desc.src` 的通道偏移/`desc.dst` 的通道偏移都必须是 **8 的倍数**；拷贝按 8 通道字（64 位）逐字进行；UPS2X 时按 `x2 = 2*x + dx, y2 = 2*y + dy` 写 4 份 |
| residual add | `dst = clamp(dst + src, -128, 127)`（int8 饱和） | 独立 op（不是 conv 的 add-mode）；两操作数的 scale/zp 必须相同（darknet shortcut 语义）；读 src、读 dst、写 dst |

- **buffer 选择规则（v0.2）**：`a_sel = (desc.src >= NN_B_OFF) ? 1 : 0`，
  `b_sel = (desc.dst >= NN_B_OFF) ? 1 : 0`。NN 窗口里 src/dst 就是 A/B 两块的字节偏移，
  所以引擎不需要额外的 buffer 编号端口。A/B 之外（W/Q 区）不会被当作激活区。
- **conv 的 add-mode（`NN_F_ADD`）保留但 v1 可以后置**：先用独立 add op 覆盖 shortcut。
- route/concat：**软件按"多个 op 写到同一 DST 的不同通道偏移"实现**，引擎不需要专门 op。
- yolo head 的 decode/NMS：**CPU 软件做**（10×10/20×20 网格，代价可忽略）。
- 合法 padding：conv 的 `pad ≤ K/2`；pool 的 `pad = K/2`。

**v0.2 变更记录**（Lead 2026-10-31）：
1. §5 的 `M_pos` 补回 `s_a_in*s_w`；明确 requant 右移是 **floor（算术右移）**；给出 M_neg 的
   整数公式 `(M_pos*3277+16384)>>15`（两边逐位一致，不依赖 Python round 语义）。
2. §9.1 的 `w` 读口地址空间改为**整个 NN 窗口**（W 区 + Q 区），解决"引擎读不到量化参数"的硬缺口；
   移除 `w_init_done/busy_npu`（用不到）。
3. §7 尾部字节布局写死；§11 给出 maxpool/copy/add 的精确语义与 buffer 选择规则。

---

## 12. 写作用域与纪律

| 角色 | 允许写 | 禁止写 |
|---|---|---|
| Lead | `rv32_pkg.sv`、`nn_pkg.sv`、`nn_subsys.sv`、`fpga/mmio_subsys.sv`、`fpga/top_a100t.sv`、`core.sv`、`fpga/build*.tcl`、`fpga/*.xdc`、`tools/fpga_workflow.py`、`sw/*`、`sim/tb_nn_soc.sv`、`results/ai-accel/PLAN*.md`、本文件 | T-mem/T-accel/T-model 的交付文件 |
| T-mem | `nn_mem.sv`、`sim/tb_nn_mem.sv`、`results/ai-accel/mem-*.md`、`results/ai-accel/proto/*` | 上表 Lead 列 |
| T-accel | `nn_conv_engine.sv`、`sim/tb_nn_engine.sv`、`results/ai-accel/engine-*.md` | 上表 Lead 列 |
| T-model | `tools/yolo/*`、`sim/prog/yolo/*`、`results/ai-accel/model-*.md` | 上表 Lead 列 |

**通用纪律（全部来自本仓库已付代价的教训）**：
1. 改一处必须同步另一处（R1）：RTL 清单三处（`fpga/build.tcl` read_verilog、`fpga/build_ila.tcl`、
   `tools/fpga_workflow.py` 的 `CORE_SV_ORDER`）。新增 `.sv` 由 Lead 统一登记，成员**不要**自己改。
2. `.tcl` / `.bat` 必须**纯 ASCII**（R2/R21）。
3. 仿真入口只认 ModelSim 统一工作流（`python tools\fpga_workflow.py verify`），
   不许用 `sim/run.bat`（它的 iverilog 不存在，且只跑 2 项却打印 ALL PASS）。
4. 数字必须带来源；"看起来对"不算证据。每项交付必须有**可自动判定**的判据（checksum/mismatch 计数）。
5. 中文注释只写在 `.sv`/`.md` 允许处；`.tcl`/`.bat` 不写中文。
6. 提交前自己跑一遍：能编译、TB 通过、无 X 传播（TB 里对关键输出加 `!==` 检查，不许 `==` 漏 X）。

**v0.3.1 / v0.4 变更记录**（Lead 2026-10-31 晚）：
1. **A/B 不等大**：A=96KB@0x60000、B=32KB@0x78000（128 输入下最大单张量 24ch×64×64=98,304B 放 A；
   残差并存的 32,768B 放 B）。A+B 之和仍 128KB ⇒ 总 BRAM 仍 133/135。
2. **Q 区变长**（v0.3）：每层 `6*OC_pad+16` 字节、M_pos int16、不存 M_neg、`qoff` 逐层给。
   v0.1/v0.2 的"每层固定 0x1000 / 16KB 放 16 层"作废（84 层会要 344KB）。
3. **`nn_desc_t.pad` 加宽到 3 位**（v0.4）：SPP 头 maxpool K=9 需要 pad=4，2 位装不下。
4. **输入图**：packed 3B/像素 + 第 0 层由 CPU 执行（`cpu_conv0`），原因见 §10.1。
5. 权重实测 319,792B（≤320KB）；Q payload 实测 44,256B（≤48KB）；yolo_wq.hex 恒 94,208 行。
