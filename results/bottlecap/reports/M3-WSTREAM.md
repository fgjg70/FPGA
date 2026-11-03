# M3 权重流式：`nn_wload` 预取引擎 + 行为级 DDR3 模型 + 权重镜像生成

> 作者：`rtl-stream`（task-8）。日期：2026-11-03（Asia/Shanghai）。状态：**完成**（6/6 TB case PASS，含与真 `nn_mem` 的对接）。
> 里程碑：`PLAN-V1.md` M3 = "权重流式链路：`nn_wload.sv` + 行为级 DDR3 模型 + 权重镜像生成器"。
> 定位：本文是 **M3 的接口契约 + 验证证据**。M5/M6 的 `nn_seq`/`nn_subsys` 集成按 §8 接线。
> 纪律：全部为**新文件**；未修改任何既有 RTL/ROM。所有数字都有日志/文件出处（§11）。

---

## 0. 结论摘要

| # | 事项 | 结论 | 证据 |
|---|---|---|---|
| 1 | DDR3 行为模型 | `sim/beh_ddr3.sv` 完成：128b 读/写口 + burst + 可配延迟 + `$readmemh` 初始化；**接口已定稿 v1.0**（§2.2），rtl-tile 可直接复用 | `sim/beh_ddr3.sv`；§2.2 |
| 2 | 预取引擎 | `nn_wload.sv` 完成：一条 `pre_start` 搬一层（W+Q）、双异步 FIFO、128b→2×64b 拆分、8B 对齐源自动跳过首 64b 字、字数自校验 | `nn_wload.sv`；§2.1 |
| 3 | 真实 YOLO 权重逐位一致 | **102 个流式层**（84 权重层 + 18 个 ADD_R Q 块）全部预取，`wfill/qfill` 逐 64b 字与镜像比对 **0 mismatch**；总字节 W=319,792 / Q=44,544 与 plan 完全一致 | `logs/tb_nn_wstream_sync.log` |
| 4 | 与真 `nn_mem` 对接 | **已对接**：real `nn_mem`（`w_mode=1`）填充 → 经 `w_re/w_addr`、`q_re/q_addr` 读回 816 W 字 + 38 Q 字**逐位一致**，活动银行未被污染 | `case_g`；`logs/tb_nn_wstream_nnmem_sync.log` |
| 5 | 异步时钟域 | `ddr_clk = clk/2` 下同样 **6/6 PASS**（2FF 握手 + 异步 FIFO 正确） | `logs/tb_nn_wstream_nnmem_async_div2.log` |
| 6 | 带宽/延迟 | 默认模型（BEAT_GAP=4）持续 **3.99 B/cycle ≈ 400 MB/s@100MHz**；满速 DDR（BEAT_GAP=1）下引擎自身上限 **5.27 B/cycle ≈ 527 MB/s**（设计目标 ≥300 MB/s ✓） | §6.2 |
| 7 | 镜像生成器 | `tools/bottlecap/gen_weights_image.py` 完成：64b/行 DDR 镜像 + 逐层偏移表 + 断言（Σwlen/Σqlen/逐层 offset/128KiB 上限/8B 对齐） | §4；`results/bottlecap/stream/` |
| 8 | 流式镜像（Lead 裁决 11-03） | 新增 **op 顺序连续** 的流式镜像（W/Q 逐层拼接、无 padding），使 `nn_seq` 用 `w_ptr += wlen / q_ptr += qlen` 即可，**ROM 不加字段**；YOLO 的 Q 被重排进 op 顺序（ADD_R 块从尾部插入），瓶盖 plan 本身已是 op 顺序；瓶盖镜像已一并产出 | §4.4、§8.3；`layer_stream_offsets.json` |

---

## 1. 交付物

### 1.1 代码 / 脚本（4 个新文件）

| 文件 | 说明 |
|---|---|
| `nn_wload.sv` | 预取引擎（新，根目录；含子模块 `nn_wload_afifo`） |
| `sim/beh_ddr3.sv` | 行为级 DDR3 模型（新） |
| `sim/tb_nn_wstream.sv` | 单元 TB（新；含 `tb_wload_mon` / `tb_wstream_inst` / `tb_wstream_nnmem`，`case_g` 需 `+define+HAVE_NNMEM`） |
| `tools/bottlecap/gen_weights_image.py` | 权重/Q 镜像生成器（新，纯 ASCII） |

### 1.2 产物（`results/bottlecap/stream/`）

| 文件 | 大小 | sha256（前 16） | 说明 |
|---|---:|---|---|
| `yolo_ddr_w.hex` | 327,680 B | `39cd00065853f20b` | W 区镜像，64b/行，字节等价于 `sim/prog/yolo/yolo_w.hex` |
| `yolo_ddr_q.hex` | 49,152 B | `19d90f87417bea8e` | Q 区镜像，64b/行，字节等价于 `yolo_q.hex` |
| `yolo_ddr_img.hex` | 376,832 B | `700771cbc50951fa` | W+Q 合并镜像（== `plan.wq_bytes`），一次 `$readmemh` 载入 |
| `layer_offsets.json` | 49,533 B | — | 102 层逐层偏移 + 约束 + 校验和（机器可读） |
| `yolo_layers.txt` | 4,258 B | — | `<op_id> <kind_code> <woff> <wlen> <qoff> <qlen>`（TB 读取） |
| `logs/tb_nn_wstream_{sync,async_div2}.log` | — | — | 纯 `nn_wload` 两种时钟配置日志 |
| `logs/tb_nn_wstream_nnmem_{sync,async_div2}.log` | — | — | 带真 `nn_mem` 的两种时钟配置日志 |

镜像完整 sha256：
- W：`39cd00065853f20b35f4b08915e638501a6ed707a6d14b2b5785f56e4d5d4a48`
- Q：`19d90f87417bea8e08d0c71f18bb1a3391410e602b7a817be2edfe74162be791`
- 合并：`700771cbc50951fa0ae3d821cdd967214e99d810836129cbee201cabdcc20472`

### 1.3 流式镜像（新增，Lead 裁决后；全部由同一生成器产出）

YOLO（`results/bottlecap/stream/`）：

| 文件 | 大小 | sha256（前 16） | 说明 |
|---|---:|---|---|
| `yolo_ddr_stream_w.hex` | 319,792 B | `51d6697847a31e5c` | W 按 op 顺序逐层拼接、无 padding（与 plan W payload 逐字节一致） |
| `yolo_ddr_stream_q.hex` | 44,544 B | `13d49f865d670aab` | Q 按 op 顺序拼接（**ADD_R 的 18 个 16B 块从尾部重排进 op 顺序**） |
| `yolo_ddr_stream_img.hex` | 364,336 B | `1deb3cf52bd63348` | W stream 后接 Q stream（Q 基址 = 319,792） |
| `layer_stream_offsets.json` | — | — | 每 op `{w_off,w_len,q_off,q_len}`（stream 坐标）+ 约束 + 统计 |
| `yolo_stream_layers.txt` | — | — | TB case_h 用的流式层表 |

瓶盖模型（`results/bottlecap/stream/bottlecap/`，plan = `results/bottlecap/plan/plan.json`，106 op，98 个流式层）：

| 文件 | 大小 | sha256（前 16） | 说明 |
|---|---:|---|---|
| `bottlecap_ddr_w.hex` / `bottlecap_ddr_stream_w.hex` | 2,020,960 B | `5737654664a8744a` | W（plan 已是 op 顺序 → 两版逐字节相同） |
| `bottlecap_ddr_q.hex` / `bottlecap_ddr_stream_q.hex` | 90,368 B | `c202fcde91551eb3` | Q（plan 的 `qoff` 已是 op 顺序 → 两版相同） |
| `bottlecap_ddr_img.hex` / `bottlecap_ddr_stream_img.hex` | 2,111,328 B | `d9006943f1133f8a` | W+Q 合并 |
| `layer_offsets.json` / `layer_stream_offsets.json` | — | — | 78 权重层 + 20 ADD-Q；max wlen **124,416** ≤ 131,072 ✓；max qlen **5,200** ≤ 8,192 ✓；**0** 层 8 mod 16 |

> 瓶盖模型：`sum(wlen)=2,020,960 = plan.w_bytes`、`sum(qlen)=90,368`，W/Q 区均无 slack；Q=90,368 > 64KiB 也**不需要 ROM 加宽**（运行期指针，不存偏移）。

---

## 2. 接口契约（v1.0，已定稿）

### 2.1 `nn_wload.sv` — DDR3→nn_mem 预取引擎

```
module nn_wload #(
  parameter int unsigned MAX_PRE_WLEN = 128*1024, // == nn_pkg 128KiB portB 规则
  parameter int unsigned W_FILL_W64   = 20480,    // == NN_W_BANK_W64
  parameter int unsigned Q_FILL_W64   = 1024,     // == NN_Q_BANK_W64
  parameter int unsigned FIFO_AW      = 5         // 2^5 x 144b = 576B / FIFO
)(
  // NPU 时钟域（控制 + 填充写口）
  input  logic         clk, rst,
  // DDR/MIG ui_clk 域（读命令 + 读数据）
  input  logic         ddr_clk, ddr_rst,
  // ---- 控制（clk 域）----
  input  logic         pre_start,        // 1 拍脉冲；pre_busy=0 时被接收
  input  logic [31:0]  pre_src_addr,     // W 的 DDR 字节地址（必须 8B 对齐）
  input  logic [17:0]  pre_wlen,         // W 字节数（≤131072）
  input  logic [31:0]  pre_qsrc_addr,    // Q 的 DDR 字节地址（qlen>0 时 8B 对齐）
  input  logic [12:0]  pre_qlen,         // Q 字节数（0 = 不搬 Q；≤8191）
  input  logic         pre_bank,         // 目的银行（校验/调试；见 §8.2）
  output logic         pre_busy,         // 从 pre_start 到最后一个 fill 写完成
  output logic         pre_done,         // 1 拍脉冲（clk 域，最后一个 fill 之后）
  output logic         pre_err,          // 电平，与 pre_done 同时有效；下次 pre_start 清零
  output logic         pre_fill_bank,    // pre_bank 的回显（调试）
  // ---- DDR 读口（ddr_clk 域，直连 beh_ddr3 / MIG 适配器）----
  output logic         ddr_rd_re,
  output logic [31:0]  ddr_rd_addr,      // 16B 对齐（引擎内部向下对齐）
  output logic [15:0]  ddr_rd_len,       // 128b beat 数
  input  logic         ddr_rd_ready,     // 命令 1 拍握手
  input  logic [127:0] ddr_rd_data,
  input  logic         ddr_rd_valid,
  input  logic         ddr_rd_last,      // 未使用（引擎按 beat 计数）
  output logic         ddr_rd_rready,    // 反压：FIFO 满时拉低
  // ---- nn_mem W 填充口（clk 域）----
  output logic         wfill_we,
  output logic [17:0]  wfill_addr,       // 银行内 64b 字索引，每层从 0 开始
  output logic [63:0]  wfill_wdata,
  // ---- nn_mem Q 填充口（clk 域）----
  output logic         qfill_we,
  output logic [12:0]  qfill_addr,       // Q 影子银行内 64b 字索引，每层从 0 开始
  output logic [63:0]  qfill_wdata
);
```

**语义**
1. 一条命令 = 一层：先搬 `pre_wlen` 字节 W，再搬 `pre_qlen` 字节 Q；两段都从目的银行 64b 字 0 开始写（层内相对寻址，见 `WEIGHT-STREAMING-DESIGN.md §3.1`）。
2. `pre_src_addr` **必须 8B 对齐**（plan 的 `woff/qoff` 都是 8 的倍数）；**16B 对齐不要求**——引擎把 DDR burst 向下对齐到 16B，并按 64b 字跳过首字。YOLO 有 **47/84** 层源地址是 `8 (mod 16)`，本引擎全部覆盖。
3. 非 8B 对齐源 → `pre_err=1`，不搬（64b 目的字无法表达字节旋转的层）。
4. `pre_wlen > 131,072`（128KiB）、`pre_qlen` 超出 Q 影子银行（>1024 字）、两者都为 0 之外的其他非法输入 → `pre_err=1`；`pre_wlen==0 && pre_qlen==0` 是合法空操作（立即 `pre_done`）。
5. 长度非 8 的倍数时，最后一个 64b 字**零填充**（nn_mem 填充口无字节使能）；真实层长度全是 8 的倍数。
6. `pre_start` 必须在 `pre_busy=0` 时发出（1 拍脉冲）；忙时脉冲被忽略。
7. `pre_done` 时**所有 fill 写已完成**（FIFO 排空 + 计数器自校验通过），因此 M5 可以安全地在 `pre_done` 后翻转 `w_bank_sel`/`q_bank_sel`。
8. `pre_err` 判据：DDR/长度描述符错误、FIFO 溢出、或 `fill 字数 != ceil(len/8)`（后者是丢失/多余字的兜底）。
9. 时钟：`clk` = NPU 域（控制、填充写口），`ddr_clk` = MIG `ui_clk` 域。两个 **真异步 FIFO**（144b×32 = 576B/条，W/Q 各一）跨域搬数据；控制用 level-payload + toggle 握手，完成用 done toggle。当前集成把 `rst`/`ddr_rst` 接同一个复位。

### 2.2 `beh_ddr3.sv` — 行为级 DDR3 模型（rtl-tile 可直接复用）

```
module beh_ddr3 #(
  parameter int unsigned MEM_BYTES     = 8*1024*1024, // 默认 8MB
  parameter int unsigned READ_LAT      = 40,          // 命令握手 -> 首 beat = READ_LAT+1 拍
  parameter int unsigned BEAT_GAP      = 4,           // 每 BEAT_GAP 拍 1 个 128b beat
  parameter bit          ZERO_INIT     = 1'b1,
  parameter string       INIT_FILE     = "",          // 64b/行 hex（$readmemh）
  parameter int unsigned INIT_WORD_OFF = 0
)(
  input  logic         clk, rst,
  // 读命令 / 读数据（AXI-like）
  input  logic         ddr_rd_re,
  input  logic [31:0]  ddr_rd_addr,     // 16B 对齐
  input  logic [15:0]  ddr_rd_len,      // 128b beat 数（1..65535）
  output logic         ddr_rd_ready,    // 命令接收（1 拍）
  output logic [127:0] ddr_rd_data,
  output logic         ddr_rd_valid,
  output logic         ddr_rd_last,
  input  logic         ddr_rd_rready,   // 反压（不用接 1）
  // 写命令 / 写数据
  input  logic         ddr_wr_re,
  input  logic [31:0]  ddr_wr_addr,     // 16B 对齐
  input  logic [15:0]  ddr_wr_len,      // 128b beat 数
  output logic         ddr_wr_ready,
  input  logic [127:0] ddr_wr_data,
  input  logic         ddr_wr_valid,
  output logic         ddr_wr_rready,   // 数据相位恒 1（每拍吃 1 beat）
  output logic         ddr_wr_done,     // 1 拍脉冲
  output logic         ddr_busy, ddr_err
);
// TB 后门：
//   task automatic load_hex(input string path, input int unsigned word_off = 0);
//   function automatic logic [63:0] peek_word(input int unsigned word_idx);
```

**存储/时序语义**
- `mem[]` 是 64-bit 字数组（`MEM_BYTES/8` 字），小端：`beat[63:0] = mem[addr/8]`、`beat[127:64] = mem[addr/8+1]`。因此 **64b/行 hex 文件可零重排 `$readmemh`**（这正是生成器的输出格式；项目原有的 32b/行 hex 需生成器打包）。
- 读：命令握手后第 `READ_LAT+1` 拍出首个 beat；beat 间隔 `BEAT_GAP` 拍。`READ_LAT=40, BEAT_GAP=4` 相当于 400 MB/s @100MHz（32-bit DDR3-400 的保守有效带宽模型）。
- `ddr_rd_rready` 反压时当前 beat 保持（AXI R 通道行为）。写：数据相位恒接收，`ddr_wr_done` 收尾。
- 地址必须 16B 对齐、burst 不越界，否则 `ddr_err` 粘滞并打印。
- **限制**（非 DDR3 协议模型）：无 bank/row/refresh/DQS/ECC；写对读的可见性为"下一个周期"；同拍同 beat 读写未定义。

**给 rtl-tile 的话**：写口用 `ddr_wr_re/addr/len` + `ddr_wr_data/valid`，`ddr_wr_rready` 可忽略（恒 1），`ddr_wr_done` 为收尾脉冲；读口 `ddr_rd_rready` 不用就接 1。

### 2.3 填充写口时序（对接 rtl-mem 的 `nn_mem`，已实测）

| 信号 | 语义 | 与 `nn_mem` 的约定 |
|---|---|---|
| `wfill_we` | 单拍写使能 | 写**非活动**银行（`~w_bank_sel`，由 `nn_mem` 内部决定） |
| `wfill_addr[17:0]` | 64b 字索引，**每层从 0 开始**，0..20479 内合法 | 与 `nn_pkg::NN_W_BANK_W64=20480` 一致 |
| `wfill_wdata[63:0]` | 128b beat 拆成 2×64b（`+0`/`+1` 两拍） | — |
| `qfill_we/qfill_addr[12:0]/qfill_wdata` | 同上，Q 影子银行 0..1023 字 | 与 `NN_Q_BANK_W64=1024` 一致 |
| `pre_bank` | 仅校验/调试；不驱动银行选择 | 发命令时应满足 `pre_bank == ~w_bank_sel` |

目标偏移恒为字 0（16B 对齐 ✓）：每层按"层内相对"装填，引擎 `w_addr` 在流式模式下是**银行内字节偏移**（rtl-mem `nn_mem` 已按此实现）。

---

## 3. 逐层偏移表（YOLO-Fastest，plan.json 为准）

### 3.1 权重层（84 个，按 plan op 顺序连续排布；`lead` = 跳过首 64b 字数）

> 完整机器可读版：`results/bottlecap/stream/layer_offsets.json` → `layers[]`。
> 列说明：`seq` = 流式层序号（TB 按它交替 bank，`bank = seq % 2`）；`woff/wlen` 是 **W 区内**相对偏移；`qoff/qlen` 是 **Q 区内**相对偏移；`lead=1` 表示 `woff % 16 == 8`（源地址 8B 对齐、非 16B 对齐，引擎跳过 beat 低 64b 字）。

| seq | op | kind | k | ic | oc | woff | wlen | qoff | qlen | lead |
|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 0 | conv | 3 | 3 | 8 | 0 | 576 | 0 | 64 | 0 |
| 1 | 1 | conv | 1 | 8 | 8 | 576 | 64 | 64 | 64 | 0 |
| 2 | 2 | dwconv | 3 | 8 | 8 | 640 | 72 | 128 | 64 | 0 |
| 3 | 3 | conv | 1 | 8 | 4 | 712 | 64 | 192 | 64 | 1 |
| 4 | 4 | conv | 1 | 4 | 8 | 776 | 64 | 256 | 64 | 1 |
| 5 | 5 | dwconv | 3 | 8 | 8 | 840 | 72 | 320 | 64 | 1 |
| 6 | 6 | conv | 1 | 8 | 4 | 912 | 64 | 384 | 64 | 0 |
| 8 | 8 | conv | 1 | 4 | 24 | 976 | 192 | 448 | 160 | 0 |
| 9 | 9 | dwconv | 3 | 24 | 24 | 1168 | 216 | 608 | 160 | 0 |
| 10 | 10 | conv | 1 | 24 | 8 | 1384 | 192 | 768 | 64 | 1 |
| 11 | 11 | conv | 1 | 8 | 32 | 1576 | 256 | 832 | 208 | 1 |
| 12 | 12 | dwconv | 3 | 32 | 32 | 1832 | 288 | 1040 | 208 | 1 |
| 13 | 13 | conv | 1 | 32 | 8 | 2120 | 256 | 1248 | 64 | 1 |
| 15 | 15 | conv | 1 | 8 | 32 | 2376 | 256 | 1312 | 208 | 1 |
| 16 | 16 | dwconv | 3 | 32 | 32 | 2632 | 288 | 1520 | 208 | 1 |
| 17 | 17 | conv | 1 | 32 | 8 | 2920 | 256 | 1728 | 64 | 1 |
| 19 | 19 | conv | 1 | 8 | 32 | 3176 | 256 | 1792 | 208 | 1 |
| 20 | 20 | dwconv | 3 | 32 | 32 | 3432 | 288 | 2000 | 208 | 1 |
| 21 | 21 | conv | 1 | 32 | 8 | 3720 | 256 | 2208 | 64 | 1 |
| 22 | 22 | conv | 1 | 8 | 48 | 3976 | 384 | 2272 | 304 | 1 |
| 23 | 23 | dwconv | 3 | 48 | 48 | 4360 | 432 | 2576 | 304 | 1 |
| 24 | 24 | conv | 1 | 48 | 8 | 4792 | 384 | 2880 | 64 | 1 |
| 26 | 26 | conv | 1 | 8 | 48 | 5176 | 384 | 2944 | 304 | 1 |
| 27 | 27 | dwconv | 3 | 48 | 48 | 5560 | 432 | 3248 | 304 | 1 |
| 28 | 28 | conv | 1 | 48 | 8 | 5992 | 384 | 3552 | 64 | 1 |
| 30 | 30 | conv | 1 | 8 | 48 | 6376 | 384 | 3616 | 304 | 1 |
| 31 | 31 | dwconv | 3 | 48 | 48 | 6760 | 432 | 3920 | 304 | 1 |
| 32 | 32 | conv | 1 | 48 | 16 | 7192 | 768 | 4224 | 112 | 1 |
| 33 | 33 | conv | 1 | 16 | 96 | 7960 | 1536 | 4336 | 592 | 1 |
| 34 | 34 | dwconv | 3 | 96 | 96 | 9496 | 864 | 4928 | 592 | 1 |
| 35 | 35 | conv | 1 | 96 | 16 | 10360 | 1536 | 5520 | 112 | 1 |
| 37 | 37 | conv | 1 | 16 | 96 | 11896 | 1536 | 5632 | 592 | 1 |
| 38 | 38 | dwconv | 3 | 96 | 96 | 13432 | 864 | 6224 | 592 | 1 |
| 39 | 39 | conv | 1 | 96 | 16 | 14296 | 1536 | 6816 | 112 | 1 |
| 41 | 41 | conv | 1 | 16 | 96 | 15832 | 1536 | 6928 | 592 | 1 |
| 42 | 42 | dwconv | 3 | 96 | 96 | 17368 | 864 | 7520 | 592 | 1 |
| 43 | 43 | conv | 1 | 96 | 16 | 18232 | 1536 | 8112 | 112 | 1 |
| 45 | 45 | conv | 1 | 16 | 96 | 19768 | 1536 | 8224 | 592 | 1 |
| 46 | 46 | dwconv | 3 | 96 | 96 | 21304 | 864 | 8816 | 592 | 1 |
| 47 | 47 | conv | 1 | 96 | 16 | 22168 | 1536 | 9408 | 112 | 1 |
| 49 | 49 | conv | 1 | 16 | 96 | 23704 | 1536 | 9520 | 592 | 1 |
| 50 | 50 | dwconv | 3 | 96 | 96 | 25240 | 864 | 10112 | 592 | 1 |
| 51 | 51 | conv | 1 | 96 | 24 | 26104 | 2304 | 10704 | 160 | 1 |
| 52 | 52 | conv | 1 | 24 | 136 | 28408 | 3264 | 10864 | 832 | 1 |
| 53 | 53 | dwconv | 3 | 136 | 136 | 31672 | 1224 | 11696 | 832 | 1 |
| 54 | 54 | conv | 1 | 136 | 24 | 32896 | 3264 | 12528 | 160 | 0 |
| 56 | 56 | conv | 1 | 24 | 136 | 36160 | 3264 | 12688 | 832 | 0 |
| 57 | 57 | dwconv | 3 | 136 | 136 | 39424 | 1224 | 13520 | 832 | 0 |
| 58 | 58 | conv | 1 | 136 | 24 | 40648 | 3264 | 14352 | 160 | 1 |
| 60 | 60 | conv | 1 | 24 | 136 | 43912 | 3264 | 14512 | 832 | 1 |
| 61 | 61 | dwconv | 3 | 136 | 136 | 47176 | 1224 | 15344 | 832 | 1 |
| 62 | 62 | conv | 1 | 136 | 24 | 48400 | 3264 | 16176 | 160 | 0 |
| 64 | 64 | conv | 1 | 24 | 136 | 51664 | 3264 | 16336 | 832 | 0 |
| 65 | 65 | dwconv | 3 | 136 | 136 | 54928 | 1224 | 17168 | 832 | 0 |
| 66 | 66 | conv | 1 | 136 | 24 | 56152 | 3264 | 18000 | 160 | 1 |
| 68 | 68 | conv | 1 | 24 | 136 | 59416 | 3264 | 18160 | 832 | 1 |
| 69 | 69 | dwconv | 3 | 136 | 136 | 62680 | 1224 | 18992 | 832 | 1 |
| 70 | 70 | conv | 1 | 136 | 48 | 63904 | 6528 | 19824 | 304 | 0 |
| 71 | 71 | conv | 1 | 48 | 224 | 70432 | 10752 | 20128 | 1360 | 0 |
| 72 | 72 | dwconv | 3 | 224 | 224 | 81184 | 2016 | 21488 | 1360 | 0 |
| 73 | 73 | conv | 1 | 224 | 48 | 83200 | 10752 | 22848 | 304 | 0 |
| 75 | 75 | conv | 1 | 48 | 224 | 93952 | 10752 | 23152 | 1360 | 0 |
| 76 | 76 | dwconv | 3 | 224 | 224 | 104704 | 2016 | 24512 | 1360 | 0 |
| 77 | 77 | conv | 1 | 224 | 48 | 106720 | 10752 | 25872 | 304 | 0 |
| 79 | 79 | conv | 1 | 48 | 224 | 117472 | 10752 | 26176 | 1360 | 0 |
| 80 | 80 | dwconv | 3 | 224 | 224 | 128224 | 2016 | 27536 | 1360 | 0 |
| 81 | 81 | conv | 1 | 224 | 48 | 130240 | 10752 | 28896 | 304 | 0 |
| 83 | 83 | conv | 1 | 48 | 224 | 140992 | 10752 | 29200 | 1360 | 0 |
| 84 | 84 | dwconv | 3 | 224 | 224 | 151744 | 2016 | 30560 | 1360 | 0 |
| 85 | 85 | conv | 1 | 224 | 48 | 153760 | 10752 | 31920 | 304 | 0 |
| 87 | 87 | conv | 1 | 48 | 224 | 164512 | 10752 | 32224 | 1360 | 0 |
| 88 | 88 | dwconv | 3 | 224 | 224 | 175264 | 2016 | 33584 | 1360 | 0 |
| 89 | 89 | conv | 1 | 224 | 48 | 177280 | 10752 | 34944 | 304 | 0 |
| 91 | 98 | conv | 1 | 192 | 96 | 188032 | 18432 | 35248 | 592 | 0 |
| 92 | 99 | dwconv | 5 | 96 | 96 | 206464 | 2400 | 35840 | 592 | 0 |
| 93 | 100 | conv | 1 | 96 | 96 | 208864 | 9216 | 36432 | 592 | 0 |
| 94 | 101 | dwconv | 5 | 96 | 96 | 218080 | 2400 | 37024 | 592 | 0 |
| 95 | 102 | conv | 1 | 96 | 96 | 220480 | 9216 | 37616 | 592 | 0 |
| 96 | 103 | conv | 1 | 96 | 255 | 229696 | 24576 | 38208 | 1552 | 0 |
| 97 | 107 | dwconv | 5 | 120 | 120 | 254272 | 3000 | 39760 | 736 | 0 |
| 98 | 108 | conv | 1 | 120 | 120 | 257272 | 14400 | 40496 | 736 | 1 |
| 99 | 109 | dwconv | 5 | 120 | 120 | 271672 | 3000 | 41232 | 736 | 1 |
| 100 | 110 | conv | 1 | 120 | 120 | 274672 | 14400 | 41968 | 736 | 0 |
| 101 | 111 | conv | 1 | 120 | 255 | 289072 | 30720 | 42704 | 1552 | 0 |

合计：**Σwlen = 319,792 B = plan.w_bytes**，最大单层 30,720 B（≤131,072 ✓）；`lead=1` 的层 47 个。

### 3.2 ADD_R 的 Q 块（18 个，**在 Q 区尾部**，各 16 B）

| op | qoff | qlen |
|---:|---:|---:|
| 7 | 44256 | 16 |
| 14 | 44272 | 16 |
| 18 | 44288 | 16 |
| 25 | 44304 | 16 |
| 29 | 44320 | 16 |
| 36 | 44336 | 16 |
| 40 | 44352 | 16 |
| 44 | 44368 | 16 |
| 48 | 44384 | 16 |
| 55 | 44400 | 16 |
| 59 | 44416 | 16 |
| 63 | 44432 | 16 |
| 67 | 44448 | 16 |
| 74 | 44464 | 16 |
| 78 | 44480 | 16 |
| 82 | 44496 | 16 |
| 86 | 44512 | 16 |
| 90 | 44528 | 16 |

合计 Q：**Σqlen = 44,544 B = plan.q_total_payload**（其中 conv/dw 块 44,256 = `plan.q_conv_end`，ADD 块 288 B）。

---

## 4. 镜像生成器 `tools/bottlecap/gen_weights_image.py`

### 4.1 用法

```
python tools/bottlecap/gen_weights_image.py
# 默认：sim/prog/yolo/{plan.json,yolo_w.hex,yolo_q.hex}
#       -> results/bottlecap/stream/{yolo_ddr_w.hex,yolo_ddr_q.hex,yolo_ddr_img.hex,
#                                   layer_offsets.json,yolo_layers.txt}

# 换瓶盖模型（converter 产 results/bottlecap/plan/ 后）：
python tools/bottlecap/gen_weights_image.py \
  --plan results/bottlecap/plan/plan.json \
  --w-hex results/bottlecap/plan/w.hex --q-hex results/bottlecap/plan/q.hex \
  --out-dir results/bottlecap/stream --stem bottlecap \
  --w-base-byte 0x01400000 --q-base-byte 0x01600000
```

### 4.2 输入/输出格式

- 输入 `--w-hex` / `--q-hex`：**32-bit/行** hex（项目既有格式，`nn_mem` 的 `+nnw/+nnq` 同款）；文件大小 = W/Q **区**大小（YOLO：327,680 / 49,152 B）。
- 输出 `*_ddr_w.hex` / `*_ddr_q.hex` / `*_ddr_img.hex`：**64-bit/行**（16 hex 字符），与 `beh_ddr3.mem[]` 字宽一致 → 零重排 `$readmemh`。
- 输出 `*_layers.txt`：`<op_id> <kind_code> <woff> <wlen> <qoff> <qlen>`，给 SV TB 用（`kind_code`：conv=0, dwconv=1, add=2, pool=3, copy=4, upsample=5）。
- 输出 `layer_offsets.json` 关键字段：`regions.{w,q,combined}`（区大小/payload/slack/ddr 基址/镜像名/sha256）、`constraints`（`max_wlen_bytes=131072`、`max_qlen_bytes=8192`、`wfill_word_idx_max=20479`、`qfill_word_idx_max=1023`）、`counts`、`layers[]`（每层含 `woff/wlen/qoff/qlen`、`ddr_waddr/ddr_qaddr`、`wfill_word0=0`、`lead_words`）。

### 4.3 生成器断言（任一失败 → 非 0 退出）

1. `sum(wlen) == plan.w_bytes`（YOLO 319,792 / 瓶盖 2,020,960）；`sum(qlen) == plan.q_total_payload`（YOLO 44,544）或显式 `qlen` 之和（瓶盖 90,368）。
2. 权重的 `woff` **严格按 op 顺序连续且等于累计和**；Q 布局自动分类为 `op_order`（瓶盖）或 `two_run`（YOLO：conv/dw 块在前、ADD_R 块在尾部），两种都校验；其它布局直接 fail。
3. `w_bytes ≤ len(W 镜像)`、`sum(qlen) ≤ len(Q 镜像)`；两个镜像大小都是 16 的倍数。
4. 每层 `wlen ≤ 131072`、`qlen ≤ 8192`、`wlen/qlen % 8 == 0`。
5. **DDR 源地址 8B 对齐**：`wlen>0 → woff%8==0`；`qlen>0 → qoff%8==0`（引擎契约）。
6. 64b 镜像 round-trip 重读 == 源 32b 镜像字节（逐字比对）。
7. W+Q 合并镜像大小 == `plan.wq_bytes`（YOLO 有该字段；瓶盖无则记录实际值）。
8. 若 plan 提供显式 `wlen/qlen`（瓶盖 v0.8），与公式（`OC_pad×IC_pad×K²`、`6×OC_pad+16`）逐 op 交叉校验，不一致即 fail。
9. 流式镜像：每 op 偏移 8B 对齐、`Σwlen/Σqlen` 与 plan 一致、**W stream 字节 == plan W payload 前缀**（两种当前 plan 都成立）、64b round-trip。

### 4.4 流式镜像（新增；`<stem>_ddr_stream_*.hex` + `layer_stream_offsets.json`）

**目的**（Lead 裁决）：让 `nn_seq` 用两个运行指针 `w_ptr += wlen`、`q_ptr += qlen` 即可流式取权重/Q，**ROM 不需要 wlen/qlen/扁平偏移等新字段**；`qoff/woff` 在 ROM 里继续做层内相对（流式模式恒 0）。

**规则**
- 按 `plan.ops` 顺序，逐 op 把 **W payload**（`w.hex[woff : woff+wlen]`）拼进 W stream，把 **Q payload**（`q.hex[qoff : qoff+qlen]`）拼进 Q stream；**无 padding**（因此指针累加严格成立）。
- 每层起始地址只保证 **8B 对齐**（所有 payload 都是 8 的倍数）：YOLO 有 **47/84** 层起点是 `8 (mod 16)`，由 `nn_wload` 的"跳首 64b 字"机制覆盖（§2.1 第 2 条）；瓶盖 **0** 层。
- Q stream 会把 YOLO 的 18 个 ADD_R Q 块从 Q 区尾部**重排进 op 顺序**（这是 `q_ptr += qlen` 成立的前提）；瓶盖 plan 本来已是 op 顺序，故 stream == plan。
- 合并镜像 `<stem>_ddr_stream_img.hex` = W stream 后接 Q stream（`q_stream_base = len(W stream)`），供 TB/行为模型一次 `$readmemh`。

**验证**：TB `case_h` 用流式镜像 + 运行指针走完 YOLO 全部 102 层，`w_ptr` 终值 319,792、`q_ptr` 终值 44,544，且每层 `slay_woff == w_ptr`、`slay_qoff == q_ptr`（生成器表与累加一致），fill 逐字比对 0 mismatch。

**给 ROM v1 的结论**：无需为流式模式新增/加宽任何字段；`nn_seq` 只需在每条 op 后把两个 32-bit 指针各加 `wlen/qlen`。若未来要"按 op 存绝对偏移"的方案，`layer_stream_offsets.json` 也已给出每 op 的 `ddr_waddr/ddr_qaddr`（基址可配置）。

---

## 5. 行为级 DDR3 模型参数与实测

| 参数 | 默认 | 说明 | TB 用例 |
|---|---:|---|---|
| `MEM_BYTES` | 8 MB | 8M×64b 字数组；TB 实例用 2 MB（够放 377KB 镜像 + 测试区） | 全部 |
| `READ_LAT` | 40 拍 | 命令握手 → 首 beat = `READ_LAT+1` | A/B/C 实例分别 40/200/22；case_e 验 40 vs 200 |
| `BEAT_GAP` | 4 拍/beat | 16B/4cyc = 4 B/cyc ≈ 400 MB/s @100MHz（保守有效带宽） | A/B 用 4；C 用 1（满速压力测试） |
| `ZERO_INIT` | 1 | 初值 0（避免 X） | 全部 |
| `INIT_FILE` | "" | 64b/行 hex，`$readmemh` | 生成器产物格式 |
| `INIT_WORD_OFF` | 0 | 镜像装载字偏移 | 可选（Q 单独装载时 40,960） |

TB 后门：`load_hex(path, word_off)` / `peek_word(idx)`。**调用时机**：模型 initial 阶段先零填充再按 `INIT_FILE` 装载；TB 在 time>0 调 `load_hex` 即可（本 TB 在 reset 释放后调用）。

---

## 6. TB 用例与结果

### 6.1 用例表（`sim/tb_nn_wstream.sv`，pass marker `WSTREAM_TB: PASS`）

| case | 内容 | 判据 | 结果 |
|---|---|---|---|
| a | 随机 1024 B @ DDR 0x1000（16B 对齐）→ 预取 bank0 | 128 个 wfill 字逐位一致、地址序列 0..127、无 Q 写、`pre_err=0`、`pre_done` 恰 1 个脉冲 | **PASS**，busy 315 拍 |
| b | **真实 YOLO 镜像**：102 个流式层（84 权重 + 18 ADD-Q）按 op 顺序、bank 交替（`seq%2`）预取 | 每层 wcnt/qcnt=ceil(len/8)、地址序列、逐 64b 字 == `yolo_ddr_img.hex`、`Σwlen=319792`、`Σqlen=44544`、`Σ 数据字节` | **PASS**，102 层总 busy 100,734 拍（平均 987 拍/层，3.62 B/cyc），最慢层 30,720 B |
| c1 | 1 B @ 0x2008（8B 对齐、非 16B 对齐） | 1 个字、内容正确 | **PASS** |
| c2 | 12 B（非 8 倍数）@ 0x3008 | 2 个字、末字高位零填充 | **PASS** |
| c3 | 7 B @ 0x4008（16B beat 的第二个 64b 字） | 1 个字、首 7 字节正确、其余 0 | **PASS** |
| c4 | **124,416 B**（瓶盖模型最大层）@ 0x100008（8B 非 16B 对齐） | 15,552 个字逐位一致 | **PASS**，31,167 拍（3.99 B/cyc） |
| c5 | `wlen=0, qlen=0` | 立即 done、无填充写、`pre_err=0` | **PASS** |
| c6 | Q-only：`wlen=0, qlen=100`（非 8 倍数） | 13 个 qfill 字、末字零填充 | **PASS** |
| c7 | `wlen=131,080`（>128KiB） | `pre_err=1`、无填充写 | **PASS**（错误路径） |
| c8 | 源地址 0x2001（非 8B 对齐） | `pre_err=1`、无填充写 | **PASS**（错误路径） |
| d | FIFO 压力：16 KiB @ BEAT_GAP=1（DDR 满速 16B/cyc） | 数据一致、`wr_ovf=0`、`pre_done` 恰 1 次、FIFO 满周期被观测到 | **PASS**，busy 3,106 拍（5.27 B/cyc，引擎自身吞吐上限），FIFO full 1,869 拍 |
| e | 延迟敏感性：同一 8 KiB 分别用 `READ_LAT=40` / `200` 实例 | 两份数据均正确；busy 差 ≈ 160 拍（= 200−40） | **PASS**，2107 vs 2267，差 **160** |
| h | **流式镜像 + 运行指针累加**（Lead 方案）：load `yolo_ddr_stream_img.hex`，用 `w_ptr += wlen / q_ptr += qlen` 走完 102 个流式层（无 ROM 偏移字段） | 每层 `slay_woff == w_ptr`、`slay_qoff == q_ptr`；fill 逐字 == stream 镜像；终值 `w_ptr=319,792 / q_ptr=44,544` | **PASS**，102 层总 busy 130,494 拍（u_ins_b，READ_LAT=200） |
| g | **真 `nn_mem` 对接**（`+define+HAVE_NNMEM`）：把 op 70 层（woff=63904, wlen=6528, qoff=19824, qlen=304）预取进非活动 bank，再经 `nn_mem.w_re/w_addr`、`q_re/q_addr` 读回 | 816 W 字 + 38 Q 字逐位一致；活动银行（bank0）保持 0 | **PASS**，readback 通过 |

### 6.2 四种配置的运行结果

| 配置 | 时钟 | 结果 |
|---|---|---|
| 纯 `nn_wload`（无 `nn_mem`） | `ddr_clk == clk`（100MHz） | **6/6 PASS**，errors=0 |
| 纯 `nn_wload` | `ddr_clk = clk/2`（+ddr_div=2） | **6/6 PASS**，errors=0 |
| +真 `nn_mem`（`HAVE_NNMEM`） | `ddr_clk == clk` | **7/7 PASS**，errors=0 |
| +真 `nn_mem`（`HAVE_NNMEM`） | `ddr_clk = clk/2` | **7/7 PASS**，errors=0 |

日志：`results/bottlecap/stream/logs/tb_nn_wstream{,_nnmem}_{sync,async_div2}.log`（每个日志最后两行分别是 `SUMMARY: …` 与 `WSTREAM_TB: PASS`）。

### 6.3 吞吐/延迟账

| 指标 | 实测 | 说明 |
|---|---|---|
| 默认模型持续吞吐 | 3.99 B/cycle ≈ **399 MB/s** @100MHz | case_c4：124,416 B / 31,167 拍；= 7,777 beat × 4 + 41 拍延迟 + 握手开销 |
| 引擎自身上限（DDR 满速） | 5.27 B/cycle ≈ **527 MB/s** | case_d；受限因素是按 128b→2×64b 展开的填充侧（每 FIFO 条目 3 拍：pop+lo+hi）。设计目标 ≥300 MB/s ✓ |
| 首 beat 延迟 | `READ_LAT+1` 拍（40→41） | case_e 证明 200 拍延迟仍正确（FIFO 512B 覆盖） |
| YOLO 整模型预取总量 | W 319,792 + Q 44,544 = 364,336 B | 100,734 拍（同步时钟）；相对 C128 YOLO E2E `npu_cycles=1,191,020` 是 8.5%（**完全不掩盖的悲观上界**；M5 双缓冲应几乎全掩盖） |
| 瓶盖模型外推 | 2,020,960 B 权重 @ ≈4 B/cyc ≈ **505k 拍**；相对 40,060,598 拍/帧 ≈ 1.3%（完全不掩盖上界） | 单层 124,416 B：31,167 拍；若与设计文档假设的 11.2 B/cyc 相比慢 2.8×，最坏层对缺口从 6,690 拍 → **约 26,700 拍 = 0.067%/帧**，仍可忽略 |

---

## 7. 与真 `nn_mem` 的对接状态（已对接）

`nn_mem`（rtl-mem，M2 版本，2026-11-03 23:30 工作区）新增端口与本文契约**完全一致**，`case_g` 已在同一 TB 中实例化真实 `nn_mem`（`w_mode=1`）并验证：

| `nn_wload` | `nn_mem` |
|---|---|
| `wfill_we` / `wfill_addr[17:0]` / `wfill_wdata[63:0]` | `wfill_we` / `wfill_addr[17:0]` / `wfill_wdata[63:0]` |
| `qfill_we` / `qfill_addr[12:0]` / `qfill_wdata[63:0]` | `qfill_we` / `qfill_addr[12:0]` / `qfill_wdata[63:0]` |
| `pre_bank`（仅校验/调试） | 目标银行由 `nn_mem` 内部取 `~w_bank_sel`（`qfill` 取 `~q_bank_sel`） |
| — | `nn_mem.w_mode` 置 1（流式）；`w_bank_sel`/`q_bank_sel` 由 `nn_seq` 驱动 |

`case_g` 结果：`op_id=70` 层（woff=63904/wlen=6528/qoff=19824/qlen=304）预取后，经 `nn_mem` 公共读口读回 **816 W 字 + 38 Q 字全部逐位一致**，且 `bank0`（活动银行）保持全 0（未被填充污染），预取 busy=1,808 拍。日志：`logs/tb_nn_wstream_nnmem_sync.log`。

> 注意：`case_g` 用 `+define+HAVE_NNMEM` 编译；默认（不定义宏）的 TB 不依赖 `nn_mem`，可独立编译运行。

---

## 8. 接线方案（M5/M6，交给 rtl-integ / Lead）

### 8.1 `nn_seq` → `nn_wload`（预取流水）

```
// 每条 op 开始前（当前层已在活动银行里），给"下一层"发预取：
pre_start     <= 1'b1;                       // 1 拍脉冲，且 pre_busy==0
pre_src_addr  <= W_STREAM_DDR_BASE + w_ptr;  // 流式镜像：运行指针累加
pre_wlen      <= wlen_of(op);                // 由描述符算：conv OC_pad*IC_pad*K^2; dw OC_pad*K^2
pre_qsrc_addr <= Q_STREAM_DDR_BASE + q_ptr;  // 流式镜像：运行指针累加（Q 已按 op 顺序重排）
pre_qlen      <= qlen_of(op);                // conv/dw: 6*OC_pad+16; add: 16; 其余 0
pre_bank      <= ~w_bank_sel;                // 目的 = 非活动银行（与 nn_mem 取 ~w_bank_sel 一致）
// 进入下一条 op 前检查 pre_done；若未来得及则等待（预取缺口）
// op 完成后: w_bank_sel <= ~w_bank_sel; q_bank_sel <= ~q_bank_sel;
//            w_ptr <= w_ptr + wlen;  q_ptr <= q_ptr + qlen;
```

要点：
1. **第一条 op 的预取**放到 `nn_seq` 启动/复位释放阶段做（或在 RUN 前做一次）。
2. `pre_done` 是 1 拍脉冲（`clk` 域）；`nn_seq` 用"电平锁存 + 单次消费"方式等待，不要用 `if(pre_done)` 轮询漏拍。
3. `pre_err` 一旦出现应作为致命错误上报（`nn_subsys` 状态位），并停止银行翻转。
4. 纯逐元素 op（pool/copy/upsample）`wlen=qlen=0`：可以**不发**预取（没有下一 op 需要的数据时）；若发也是合法空操作（case_c5 覆盖）。
5. ADD/ADD_R op：`wlen=0, qlen=16`，正是 case_b 中的一个流式层（op 7）已覆盖。
6. 时钟域：`nn_wload` 的 `clk` 与 `nn_mem`/`nn_seq` 同域；`ddr_clk` 接 MIG `ui_clk`。当前把 `rst` 与 `ddr_rst` 接同一复位；接 MIG 时建议给 `ddr_rst` 加 2FF 同步（异步 FIFO 内已有各自域的指针同步）。
7. **wlen/qlen 不需要新增 ROM 字段**：由现有描述符字段（kind/flags/oc/ic/k）组合算出（见 §4.4）；ROM 的 `woff/qoff` 在流式模式保持"层内相对/忽略"，引擎从银行字 0 读。
8. 首条 op 的 `w_ptr = q_ptr = 0`；`w_ptr`/`q_ptr` 只需 22-bit/18-bit 计数器（瓶盖 W stream 2,020,960 B、Q stream 90,368 B）。

### 8.2 与 `nn_mem` 的端口映射（已实测，见 §7）

`w_mode=1`、`w_bank_sel`/`q_bank_sel` = 当前活动银行；`wfill_*`/`qfill_*` 直连（已是同一 `clk` 域）。`pre_fill_bank` 可留空或接到 ILA。

### 8.3 Q 镜像布局（Lead 裁决 11-03：op 顺序连续，不改 ROM 宽度）

- 原发现：YOLO 样例 plan 的 Q 区不是 op 顺序（conv/dw 块 0..44,255 + 18 个 ADD_R 16B 块在尾部 44,256..44,543），按 op 顺序 `q_ptr += qlen` 会在 conv→add 处错位。
- **裁决**：不采用"ROM qoff 扁平偏移"（瓶盖 Q=90,368 B > 16bit，会逼 ROM 加宽）。改为**生成流式镜像**（§4.4）：W/Q 都按 `plan.ops` 顺序逐层拼接、无 padding → 硬件只用两个运行指针 `w_ptr += wlen / q_ptr += qlen`，**ROM 完全不加字段**。
- 已落：YOLO 流式镜像（Q 已重排，`layer_stream_offsets.json`）+ 瓶盖流式镜像（plan 本身 op 顺序，stream == plan）；兼容保留原 plan 布局镜像；TB `case_h` 证明运行指针方案 102 层逐字一致。
- 注意：流式镜像的层起点只保证 8B 对齐（YOLO 47/84 层为 8 mod 16），由 `nn_wload` 跳首 64b 字覆盖；若未来想省掉这个机制，可在生成器加"每层 16B 对齐 padding"模式（代价 ≤8B/层，且 `ptr += len` 需改用含 padding 的 len）。

### 8.4 权重镜像的 DDR 基址

设计文档 §3.1 规划：W @ `0x0140_0000`（2MB 窗口）、Q @ `0x0160_0000`（128KB 窗口）。生成器支持 `--w-base-byte/--q-base-byte` 把这两个基址写进 `layer_offsets.json`（默认 0 / 紧随 W 区，便于行为模型直接 `$readmemh`）。接 MIG 时用设计文档基址重生成即可。

### 8.5 其余文件的注册（Lead 做）

- `CORE_SV_ORDER`：在 `nn_mem.sv` 之后插入 `"nn_wload.sv"`（无 `nn_pkg` 依赖，位置只需在任何使用它的模块之前；综合流程 `build.tcl`/`build_ila.tcl` 若走 `canonical_rtl()` 会自动带上，但仍建议显式登记）。
- `fpga_workflow.py` 测试项（两种注册方式任选）：
```python
# 纯单元（不依赖 nn_mem，编译最快）
tests.append({
    "name": "tb_nn_wstream", "top": "tb_nn_wstream",
    "rtl": ["nn_pkg.sv", "nn_wload.sv", "sim/beh_ddr3.sv"],
    "tb": "sim/tb_nn_wstream.sv",
    "plus": ["+img=@REPO@/results/bottlecap/stream/yolo_ddr_img.hex",
             "+layers=@REPO@/results/bottlecap/stream/yolo_layers.txt"],
    "max_cycles": None, "timeout": 900,
    "pass_marker": "WSTREAM_TB: PASS",
    "desc": "M3: DDR3 模型 -> nn_wload -> nn_mem 填充口逐位预取（102 个真实 YOLO 层）",
})
# 含真 nn_mem 对接（覆盖 case_g；rtl 列表加 nn_mem.sv + defines）
tests.append({
    "name": "tb_nn_wstream_nnmem", "top": "tb_nn_wstream",
    "rtl": ["nn_pkg.sv", "nn_mem.sv", "nn_wload.sv", "sim/beh_ddr3.sv"],
    "tb": "sim/tb_nn_wstream.sv", "defines": ["HAVE_NNMEM"],
    "plus": [...同上...],
    "max_cycles": None, "timeout": 900,
    "pass_marker": "WSTREAM_TB: PASS",
    "desc": "M3: 同上 + 真 nn_mem(w_mode=1) 填充/读回对接",
})
```

---

## 9. 已知限制与未做项

1. **无 MIG**：`beh_ddr3` 只建模用户侧（延迟/带宽/burst/反压），不是 DDR3 协议模型（无 bank/row/refresh/DQS/ECC）。上板时用 `nn_ddr_if` 把 `ddr_rd_*` 映射到 MIG AXI（`ddr_rd_rready` ↔ `rready`，`ddr_rd_last` ↔ `rlast`）。
2. **填充侧吞吐 5.27 B/cyc**（每 FIFO 条目 3 拍：pop+lo+hi）。>300 MB/s 设计目标；若 M5/M6 实测需要更高（例如 3 银行/更高频），可把 drain 改成"pop 与 lo 同拍"→ 2 拍/条目 = 8 B/cyc（M3 未做，接口不变）。
3. **源地址 8B 对齐**是硬契约（16B 对齐不要求，47/84 层实测覆盖）；非 8B 对齐报 `pre_err`。
4. `pre_wlen ≤ 131,072 B`（rtl-mem portB 仲裁规则）：引擎 + 生成器双重检查；瓶盖最大层 124,416 B ✓。
5. FIFO 深度 = 32 条 × 144b = 576B/条流（W/Q 各一）；`READ_LAT=200` 拍实测覆盖，MIG 典型 50~100 拍余量足够。
6. `ddr_rd_last` 未使用（引擎按 beat 数计数）；写口 `ddr_wr_done`/`busy` 仅 TB 用。
7. TB 的 `case_g` 依赖当前 `nn_mem` 端口（已在 M2 版本验证）；若 rtl-mem 后续再改端口，需同步该 ifdef 块。
8. 尚未跑整机 E2E（M5/M6 职责）；本任务判据是单元 TB + 与真 `nn_mem` 的对接。

---

## 10. 复现命令

```bat
set LM_LICENSE_FILE=D:/software/tools/Modelsim/win64/LICENSE.TXT
set MGLS_LICENSE_FILE=D:/software/tools/Modelsim/win64/LICENSE.TXT
set PROCESSOR_ARCHITECTURE=AMD64
set MSIM=D:/software/tools/Modelsim/win64

rem 1) 生成镜像（可重复运行，含断言；plan 布局 + stream 布局都产出）
python tools\bottlecap\gen_weights_image.py
rem    瓶盖模型（plan 布局 + stream 布局，输出到 stream\bottlecap\）：
python tools\bottlecap\gen_weights_image.py --plan results\bottlecap\plan\plan.json ^
  --w-hex results\bottlecap\plan\w.hex --q-hex results\bottlecap\plan\q.hex ^
  --out-dir results\bottlecap\stream\bottlecap --stem bottlecap ^
  --w-base-byte 0x01400000 --q-base-byte 0x01600000

rem 2) 纯 nn_wload（无 nn_mem）
%MSIM%\vlib.exe work
%MSIM%\vlog.exe -sv nn_pkg.sv nn_wload.sv sim\beh_ddr3.sv sim\tb_nn_wstream.sv
%MSIM%\vsim.exe -c -do "run -all; quit -f" work.tb_nn_wstream ^
  +img=results/bottlecap/stream/yolo_ddr_img.hex ^
  +layers=results/bottlecap/stream/yolo_layers.txt ^
  +stream_img=results/bottlecap/stream/yolo_ddr_stream_img.hex ^
  +stream_layers=results/bottlecap/stream/yolo_stream_layers.txt

rem 3) 含真 nn_mem 对接（case_g）
%MSIM%\vlog.exe -sv +define+HAVE_NNMEM nn_pkg.sv nn_mem.sv nn_wload.sv sim\beh_ddr3.sv sim\tb_nn_wstream.sv
%MSIM%\vsim.exe -c -do "run -all; quit -f" work.tb_nn_wstream ^
  +img=results/bottlecap/stream/yolo_ddr_img.hex ^
  +layers=results/bottlecap/stream/yolo_layers.txt ^
  +stream_img=results/bottlecap/stream/yolo_ddr_stream_img.hex ^
  +stream_layers=results/bottlecap/stream/yolo_stream_layers.txt

rem 4) 异步时钟域（DDR 半速）：在 2) 或 3) 的 vsim 上加 +ddr_div=2
```

通过判据：输出最后出现 `WSTREAM_TB: PASS`，且 `SUMMARY: N/N cases pass, errors=0`（无 nn_mem 6/6；含 nn_mem 7/7）。

---

## 11. 证据索引

| 证据 | 内容 |
|---|---|
| `results/bottlecap/stream/logs/tb_nn_wstream_sync.log` | 纯 `nn_wload`，同频：`SUMMARY: 6/6 cases pass, errors=0`、`WSTREAM_TB: PASS` |
| `results/bottlecap/stream/logs/tb_nn_wstream_async_div2.log` | 纯 `nn_wload`，`ddr_clk=clk/2`：`6/6 PASS` |
| `results/bottlecap/stream/logs/tb_nn_wstream_nnmem_sync.log` | +真 `nn_mem`：`7/7 PASS`（含 `case_g: read back 816 W words / 38 Q words`） |
| `results/bottlecap/stream/logs/tb_nn_wstream_nnmem_async_div2.log` | +真 `nn_mem`，`ddr_clk=clk/2`：`7/7 PASS` |
| `results/bottlecap/stream/layer_offsets.json` | plan 布局逐层偏移 + 约束 + 校验和（机器可读） |
| `results/bottlecap/stream/layer_stream_offsets.json` | **流式布局**每 op `{w_off,w_len,q_off,q_len}` + 约束 + 统计 |
| `results/bottlecap/stream/bottlecap/layer_stream_offsets.json` | 瓶盖模型流式偏移（98 层，Σw=2,020,960 / Σq=90,368） |
| `sim/prog/yolo/plan.json` | 蓝图：`w_bytes=319792`、`q_conv_end=44256`、`q_total_payload=44544`、`wq_bytes=376832`、`n_ops=112` |
| `results/bottlecap/plan/plan.json` | 瓶盖蓝图：`w_bytes=2020960`、`q_bytes=90368`、`n_ops=106`、显式 `wlen/qlen`、`tile_plan` |
| `nn_wload.sv` 头部注释 | 接口语义/限制（与 §2.1 一致） |
| `sim/beh_ddr3.sv` 头部注释 | 模型语义/限制（与 §2.2 一致） |
| `results/bottlecap/ddr3/WEIGHT-STREAMING-DESIGN.md §2.2/§4/§9` | 预取引擎/DMA 口/验证方案来源 |
| `results/bottlecap/ddr3/DDR3-FEASIBILITY.md §9` | 行为级 DDR3 模型 + 任务分解（T2）来源 |
| `results/bottlecap/reports/PLAN-V1.md` M3 行 | 里程碑判据 |
| RTL 侧契约（rtl-mem） | `nn_mem.sv` 的 `wfill_we/addr[17:0]/wdata[63:0]`、`qfill_we/addr[12:0]/qdata[63:0]`、`w_bank_sel/q_bank_sel/w_mode`；`nn_pkg.sv` 的 `NN_W_BANK_BYTES=160KiB`、`NN_W_BANK_W64=20480`、`NN_Q_BANK_W64=1024`、`NN_Q_FILL_AW=13` |
