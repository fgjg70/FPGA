`timescale 1ns/1ps

// ============================================================================
// nn_mem.sv — AI 加速子系统片上存储 (v0.7 + wpipe: NPU W 读输入寄存, W 读时延 1->2)
// [wpipe] 125MHz 全实现 worst path = u_eng/wa_r_reg -> W BRAM ADDRARDADDR 纯走线 8.98ns;
//   在 mem 边界插一级 w_re_q/w_addr_q 寄存器把长走线断成两段。引擎侧需 W_RD_LAT=2
//   (根 nn_conv_engine 默认 2, 参数化可回 1 配旧 mem)。其余端口/参数/初始化/行为不变。
// ----------------------------------------------------------------------------
// 规格: results/ai-accel/SPEC-SPECIALIZED.md §3 + MODEL-FREEZE.md (D1-D5)
//
// 【v0.7 相对 v0.3 的 5 个变化】
//   1. W 区独立 320KB, 只给 NPU 128-bit 读口 (w_re/w_addr/w_rdata[127:0], 1 拍);
//      CPU 不可访问。4 段 $readmemh 初始化 (NN_W_INIT_A..D, 每段 64-bit/行)。
//      读地址 **8B 对齐** (引擎 v3 的 8-lane tile 会发 w_addr[3]=1, 见 R3 修复)。
//   2. Q 区 48KB 拆成 **2 个子 ROM** (q_mem_lo 4096 深 + q_mem_hi 2048 深, 64-bit 宽);
//      q_re/q_addr[12:0]/q_rdata[63:0], 1 拍; CPU 不可访问。
//      仿真行为与"单块 6144 深 ROM"完全等价 (dbg 预装/loader 按 idx<4096 写 lo)。
//      [2026-11-01 build fix] 综合版: lo = **BRAM ROM (8 tiles)**;
//      hi = **分布式 ROM (实际落 LUT 逻辑, ~1.6K LUT, 0 BRAM)**。
//      为过 place: 整机 core 实占 12 tiles (124+12=136>135 差 1 tile),
//      故 hi 改 LUTRAM -> nn_mem **120 tiles**, 整机 120+12=132/135 ✓ (见 mem-report §3.7)。
//   3. 激活 A/B: 读 128-bit 不变; 写口升级 128-bit + b_wstrb[15:0] (配引擎 v3 的
//      16 lane 写回; copy/concat 的 8 字节半字写只写 half word, **不做 RMW**)。
//   4. CPU 窗口只映射 A(0x60000)/B(0x78000): 其余窗口地址读 0/写忽略 (1 拍寄存读)。
//   5. 新增 dbg 装载口 (dbg_we/dbg_space/dbg_addr[16:0]/dbg_wdata[31:0]): module
//      级 TB 用它初始化 W/Q; 写口**只存在于仿真** (综合由 ifndef SYNTHESIS 去掉),
//      SoC 里 W/Q 是纯 ROM, 两个 W 读口才能落 BRAM36 真双口 (0 额外 BRAM)。
//
// 【地址口径 (NN 窗口内字节偏移)】
//   W:  0x00000..0x4FFFF  (320KB)
//   Q:  0x50000..0x5BFFF  (48KB)  —— Q 只有 NPU 读, 参数由初始化预置
//   空: 0x5C000..0x5FFFF  (CPU 读 0 / 写忽略)
//   A:  0x60000..0x77FFF  (96KB)
//   B:  0x78000..0x7FFFF  (32KB)   —— A/B 连续, 共用一块 128-bit 宽物理阵列
//
// 【读口语义 (均 1 拍寄存读: 地址第 N 拍、数据 N+1 拍有效)】
//   w_re  + w_addr[23:0] (W 区字节偏移, **8B 对齐、低 3 位忽略**; 读 16B 窗口,
//           w_addr[3]=1 时窗口跨 128b 字边界 -> {下一字低 8B, 当前字高 8B})
//         -> w_rdata[127:0] = 16 字节小端 (低地址字节在 [7:0]); 越界 -> 0。
//   q_re  + q_addr[12:0] (64-bit Q 字索引 0..6143)
//         -> q_rdata[63:0] = {Q32[2k+1], Q32[2k]} (低地址 32 位字在 [31:0]);
//            q_addr >= 6144 -> 64'b0。
//   a_sel + a_re + a_addr (绝对窗口字节偏移, 16B 对齐; A=0x60000 起, B=0x78000 起)
//         -> a_rdata[127:0] = 16 字节小端; sel/地址归属不符或越界 -> 0。
//   b 写口: b_sel/b_we/b_addr(16B 对齐)/b_wdata[127:0]/b_wstrb[15:0];
//         b_wstrb 按字节使能 (copy 的 8B 写只置 [7:0] 或 [15:8])。
//
// 【物理组织与 BRAM 账 (v0.7 综合实测)】
//   W  : 4 段 **64-bit 宽** ROM: A=16384 字 (128KB), B/C/D=8192 字 (64KB);
//        每段两个读口 cur=mem[base] / next=mem[base+1] (base = 2*w_idx+w_addr[3]),
//        两个 64-bit 读数据都满宽使用 -> BRAM36 真双口, 综合 -> 80 RAMB36
//        (4KB/BRAM, 随机数据实测)。
//        为什么必须 64-bit 宽: 8B 窗口跨 128b 字时, 128-bit 宽阵列的第二读口只
//        用到 64-bit, Vivado 会额外复制 64-bit 存储 (实测 W 147.5 tiles 超预算;
//        用 keep 又会落 54K LUT)。64-bit 宽 + 满宽双读 = 80 tiles, 干净。
//        为什么必须拆 4 段: 64-bit 宽 ROM 深度 >16384 会按 32768 取整。
//   Q  : lo = 64-bit 宽 4096 深 **BRAM ROM (8 tiles)**;
//        hi = 64-bit 宽 2048 深 **分布式 ROM (LUT 逻辑, ~1.6K LUT, 0 tiles)**。
//        读时两路并行、按 q_addr[12] 选择 (hi 是异步读 + 输出寄存器, 时延仍 1 拍)。
//        历史: 单块 6144 深 BRAM 会被按 8192 取整 -> 16 tiles; 拆 4096+2048 BRAM -> 12;
//        最后因整机 place 差 1 tile, hi 改 LUTRAM -> 8 tiles (mem 120)。
//   A/B: 128KB 128-bit 宽一块阵列 -> 32 BRAM36 (精确 4KB/BRAM)。
//   => nn_mem 合计 **124 tiles**; + 交付档核心约 9.5 ≈ **133.5/135**。
//
// 【初始化镜像】
//   综合: W 4 段 `NN_W_INIT_A..D` (每行 16 hex = 64-bit 字, 行数 16384/8192/
//         8192/8192); Q 拆两段 `NN_Q_INIT_LO` (前 4096 行) + `NN_Q_INIT_HI`
//         (后 2048 行), 均 64-bit 字/行。
//         文件由 build flow 从 yolo_w / yolo_q 的 32-bit 行镜像打包 (低字在低 32 位)。
//   仿真: `+nnw=<yolo_w.hex>` (81920 行 32-bit) + `+nnq=<yolo_q.hex>` (12288 行
//         32-bit); 或旧 `+nnwq=<yolo_wq.hex>` (94208 行 = W 81920 + Q 12288 顺序)。
//         本模块内部用小 loader 打包成物理字宽 ($fgets/$sscanf, 仅非 SYNTHESIS)。
//   激活 A/B 不初始化 (仿真零填充仅为消除 X)。
//
// ============================================================================
// 【M2 (2026-11-03) 流式 W/Q: 双银行 + 填充写口 + Q 影子银行】
//   目标: W 从"综合期烧死的只读 ROM"变成**运行期可写的 2 银行 L2 缓存**;
//         Q 增加 2 x 8KiB 可写影子银行 (单层 Q <= 5,200 B)。
//   双模兼容硬门槛: w_mode=0 (默认) 时 W/Q 读时序与数据**逐拍/逐位等于 v0.7**,
//   C128 YOLO E2E 与 tb_nn_mem 原有 47,148 checks 不得回退。
//   新增端口 (全部是输入, 内部对 X/Z 归一为 0, 未接线的旧例化自动走 ROM 兼容路径):
//     w_mode (0=ROM / 1=STREAM), w_bank_sel (活动银行),
//     wfill_we/wfill_addr[17:0]/wfill_wdata[63:0]  (64b/拍, 写非活动银行,
//       地址 = 银行内 64b 字序号 0..20479),
//     q_bank_sel, qfill_we/qfill_addr[12:0]/qfill_wdata[63:0] (Q 影子银行填充)。
//   端口增量表/模式语义/双缓冲时序见 results/bottlecap/reports/M2-NNMEM.md。
//   BRAM: W 仍 80 tiles (4 段深度/字宽不变), Q lo 仍 8 tiles (ROM->RAM 容量不变),
//         Q hi 仍分布式 ROM; nn_mem 合计 120 tiles, 增量 0。
// ============================================================================

module nn_mem
  import nn_pkg::*;
#(
  parameter int W_BYTES = 320*1024,   // W 区容量 (字节) = 320KB
  parameter int Q_BYTES = 48*1024,    // Q 区容量 (字节)  = 48KB (LUTRAM)
  parameter int A_BYTES = 96*1024,    // 激活 A 容量 (字节)
  parameter int B_BYTES = 32*1024,    // 激活 B 容量 (字节)
  parameter int CPU_AW  = 19          // CPU 窗口地址位宽 (512KB = 2^19)
)(
  input  logic         clk,
  input  logic         rst,
  // ---- CPU 窗口 (只映射 A/B; 1 拍寄存读, 与 dmem 同口径) ----
  input  logic         cpu_re,
  input  logic         cpu_we,
  input  logic [31:0]  cpu_addr,
  input  logic [31:0]  cpu_wdata,
  input  logic [3:0]   cpu_wstrb,
  output logic [31:0]  cpu_rdata,
  // ---- NPU 权重读口 (128 位/拍, 1 拍延迟) ----
  input  logic         w_re,
  input  logic [23:0]  w_addr,        // W 区字节偏移 (16 字节对齐)
  output logic [127:0] w_rdata,
  // ---- NPU Q 参数读口 (64 位/拍, 1 拍延迟) ----
  input  logic         q_re,
  input  logic [12:0]  q_addr,        // 64-bit Q 字索引 (0..6143)
  output logic [63:0]  q_rdata,
  // ---- NPU 激活读口 (128 位/拍, 1 拍延迟) ----
  input  logic [1:0]   a_sel,         // 0=A, 1=B
  input  logic         a_re,
  input  logic [23:0]  a_addr,        // 绝对窗口字节偏移 (16 字节对齐)
  output logic [127:0] a_rdata,
  // ---- NPU 激活写口 (128 位/拍 + 字节使能) ----
  input  logic [1:0]   b_sel,         // 0=A, 1=B
  input  logic         b_we,
  input  logic [23:0]  b_addr,        // 绝对窗口字节偏移 (16 字节对齐)
  input  logic [127:0] b_wdata,
  input  logic [15:0]  b_wstrb,
  // ---- debug 装载口 (module 级 TB 用; SoC 恒 0) ----
  input  logic         dbg_we,
  input  logic         dbg_space,     // 0=W, 1=Q
  input  logic [16:0]  dbg_addr,      // 32-bit 字索引
  input  logic [31:0]  dbg_wdata,
  // ---- [M2] W 流式: 模式/活动银行/填充写口 (默认全 0 => v0.7 ROM 兼容路径) ----
  input  logic         w_mode,        // 0=综合期 ROM 烧死 / 1=运行期可写流式
  input  logic         w_bank_sel,    // 引擎读的活动银行 (0/1)
  input  logic         wfill_we,      // 填充写使能 (写非活动银行 ~w_bank_sel)
  input  logic [17:0]  wfill_addr,    // 银行内 64-bit 字序号 0..20479
  input  logic [63:0]  wfill_wdata,
  // ---- [M2] Q 影子银行: 活动银行/填充写口 (默认全 0 => v0.7 ROM 兼容路径) ----
  input  logic         q_bank_sel,    // 引擎读的活动 Q 影子银行 (0/1)
  input  logic         qfill_we,      // 填充写使能 (写非活动银行 ~q_bank_sel)
  input  logic [12:0]  qfill_addr,    // 影子银行内 64-bit 字序号 0..1023
  input  logic [63:0]  qfill_wdata
);

  // --------------------------------------------------------------------------
  // 布局常量
  // --------------------------------------------------------------------------
  localparam int W_WORDS  = W_BYTES / 4;        // 81,920 个 32-bit 字
  localparam int W64      = W_BYTES / 8;        // 40,960 个 64-bit 字
  localparam int Q_WORDS  = Q_BYTES / 4;        // 12,288 个 32-bit 字
  localparam int Q64      = Q_WORDS / 2;        // 6,144 个 64-bit 字
  localparam int QLO      = 4096;               // Q 低段 ROM 深度 (32KB)
  localparam int QHI      = Q64 - QLO;          // Q 高段 ROM 深度 (2,048 = 16KB)

  // W 4 段 (64-bit 字): A=16384, B/C/D=8192 (默认 40,960 = 320KB)
  //   byte 段边界与旧版一致: A=128KB, B/C/D=64KB (仅物理字宽变 64-bit)
  localparam int WSEG_A = 16384;
  localparam int WSEG_B = 8192;
  localparam int WSEG_C = 8192;
  localparam int WSEG_D = W64 - WSEG_A - WSEG_B - WSEG_C;   // 默认 8192

  localparam int ACT_BYTES = A_BYTES + B_BYTES;  // 128KB (A/B 连续)
  localparam int ACT_WORDS = ACT_BYTES / 16;     // 128-bit 物理字数
  localparam int ACT_AW    = $clog2(ACT_WORDS);  // 13

  localparam logic [31:0] A_OFF = nn_pkg::NN_A_OFF;            // 0x0006_0000
  localparam logic [31:0] B_OFF = nn_pkg::NN_A_OFF + A_BYTES;  // 0x0007_8000
  localparam logic [31:0] B_END = B_OFF + B_BYTES;             // 0x0008_0000
  localparam logic [31:0] Q_END = 32'h0005_0000 + Q_BYTES;     // 0x0005_C000
  localparam logic [31:0] WIN   = 32'h1 << CPU_AW;             // 512KB

  // --------------------------------------------------------------------------
  // [rtl-mem 2026-11-04] act_mem 索引口径 (为 TB 大张量实验支持"放大 A/B"):
  //   默认契约 (A_BYTES=96KB/B_BYTES=32KB): A_OFF 是 ACT_BYTES 的整数倍且
  //   ACT_WORDS 是 2 的幂 -> 用**绝对地址位选** addr[ACT_AW+3:4], 与 v0.7 逐位一致,
  //   综合后无额外逻辑 (常数剪枝)。
  //   若调用方覆盖参数使前提不成立 (如 tb_nn_engine -gA_BYTES=802816 的 op3 全张量
  //   实验), 则改用**相对 A_OFF 的偏移** ((addr-A_OFF)>>4)。该分支只在非常规参数下
  //   生效, 默认配置综合时被常数剪枝 -> 端口/契约/交付档行为/时序均不变。
  // --------------------------------------------------------------------------
  localparam bit ACT_ABS_OK = (((int'(nn_pkg::NN_A_OFF) % ACT_BYTES) == 0) &&
                               ((ACT_WORDS & (ACT_WORDS - 1)) == 0));

  // --------------------------------------------------------------------------
  // [M2] 流式 W/Q 布局常量 (名字取自 nn_pkg, 数值由参数推导 -> 参数覆盖仍自洽)
  //   W: 2 银行, 每银行 160KiB = 20480 个 64-bit 字; 引擎 w_addr 在流式模式是
  //      **银行内**字节偏移 (0..0x27FFF), 填充口地址是银行内 64b 字序号。
  //   Q: 2 个 8KiB 可写影子银行 (1024 个 64b 字/银行), 单层 Q <= 5,200 B。
  // --------------------------------------------------------------------------
  localparam int W_BANKS      = int'(nn_pkg::NN_W_BANKS);        // 2
  localparam int W_BANK_BYTES = W_BYTES / W_BANKS;               // 160KiB
  localparam int W_BANK_W64   = W_BANK_BYTES / 8;                // 20,480
  localparam int W_BANK_AW    = $clog2(W_BANK_BYTES);            // 18 (0..163839)
  localparam int Q_BANK_W64   = int'(nn_pkg::NN_Q_BANK_W64);     // 1,024
  localparam int Q_BANK_BYTES = int'(nn_pkg::NN_Q_BANK_BYTES);   // 8KiB
  localparam int Q_BANK_AW    = int'(nn_pkg::NN_Q_FILL_AW);      // 13 (qfill_addr 位宽)

  // --------------------------------------------------------------------------
  // [M2] 新模式输入的 X/Z -> 0 归一
  //   为什么: 旧例化 (tb_nn_engine / proto / 黑盒) 不接这些新端口, 未接线输入是 Z;
  //   若 Z 直接进地址 mux 会把读数据打成 X。这里用 if 语句归一 (X/Z 走 else),
  //   综合上等价于一根线 (mux 常 0), 0 LUT 增量; 默认 0 = v0.7 ROM 兼容路径。
  // --------------------------------------------------------------------------
  logic w_mode_i, w_bank_sel_i, wfill_we_i, q_bank_sel_i, qfill_we_i;
  always_comb begin
    w_mode_i     = 1'b0;
    if (w_mode)      w_mode_i     = 1'b1;
    w_bank_sel_i = 1'b0;
    if (w_bank_sel)  w_bank_sel_i = 1'b1;
    wfill_we_i   = 1'b0;
    if (wfill_we)    wfill_we_i   = 1'b1;
    q_bank_sel_i = 1'b0;
    if (q_bank_sel)  q_bank_sel_i = 1'b1;
    qfill_we_i   = 1'b0;
    if (qfill_we)    qfill_we_i   = 1'b1;
  end

`ifndef SYNTHESIS
  initial begin
    $display("[nn_mem] v0.7 CONFIG W=%0dKB(%0d words) Q=%0dKB(%0d x64b) A=%0dKB B=%0dKB",
             W_BYTES/1024, W_WORDS, Q_BYTES/1024, Q64, A_BYTES/1024, B_BYTES/1024);
    $display("[nn_mem] v0.7 A_OFF=0x%05x B_OFF=0x%05x B_END=0x%05x Q_END=0x%05x CPU_WIN=0x%05x",
             A_OFF, B_OFF, B_END, Q_END, WIN);
    if (B_END > WIN) $display("[nn_mem] WARN: B_END 0x%05x 超出 CPU 窗口", B_END);
    if (B_OFF != nn_pkg::NN_B_OFF)
      $display("[nn_mem] WARN: B_OFF=0x%05x != nn_pkg::NN_B_OFF=0x%05x", B_OFF, nn_pkg::NN_B_OFF);
    if (WSEG_D <= 0)
      $display("[nn_mem] WARN: W 4 段拆分不成立 (WSEG_D=%0d)", WSEG_D);
    $display("[nn_mem] M2 CONFIG W banks=%0d x %0dKB (%0d x64b words/bank) Q shadow=%0d x %0dKB, wlen<=128KiB",
             W_BANKS, W_BANK_BYTES/1024, W_BANK_W64, 2, Q_BANK_BYTES/1024);
    $display("[nn_mem] ACT CONFIG A=%0dKB B=%0dKB A_OFF=0x%05x B_OFF=0x%05x B_END=0x%05x words=%0d idx=%s",
             A_BYTES/1024, B_BYTES/1024, A_OFF, B_OFF, B_END, ACT_WORDS,
             ACT_ABS_OK ? "ABS-SLICE(default)" : "REL-OFFSET(big-A TB mode)");
    if (W_BANK_W64 != 20480)
      $display("[nn_mem] WARN: W_BANK_W64=%0d != 20480 (wfill_addr/双银行契约按 20480 定义)",
               W_BANK_W64);
    if (Q_BANK_W64 > QLO/2)
      $display("[nn_mem] WARN: Q_BANK_W64=%0d 超过 lo 阵列一半 (%0d)", Q_BANK_W64, QLO/2);
  end
`endif

  // --------------------------------------------------------------------------
  // 调试写使能 (W / Q)
  //   综合 (SYNTHESIS): dbg 装载口不参与硬件 (SoC 里恒 0) -> 写使能置常量 0,
  //     W/Q 才能推断成纯 ROM (Q: 6,976 LUT / 0 BRAM; 若保留写口会变 12,288 LUTRAM)。
  //   仿真: 写使能正常, module 级 TB 用 dbg 口初始化并回读。
  // --------------------------------------------------------------------------
  logic w_dbg_we, q_dbg_we;
  assign w_dbg_we = dbg_we && (dbg_space == 1'b0) && (32'(dbg_addr) < 32'(W_WORDS));
  assign q_dbg_we = dbg_we && (dbg_space == 1'b1) && (32'(dbg_addr) < 32'(Q_WORDS));

  // ==========================================================================
  // W 区: 4 段 64-bit 宽阵列 (深度/字宽与 v0.7 完全相同 => 仍是 80 个 RAMB36)
  //   a[0:16383] = 全局 64b 字 0..16383 (128KiB), b/c/d[0:8191] = 各 8192 (64KiB)
  //   v0.7 的 8B 窗口语义: base = 2*w_idx + w_addr[3], cur=mem[base], next=mem[base+1],
  //   w_rdata = {next64, cur64} (小端), W 读时延 2 拍 (wpipe 输入寄存)。
  // --------------------------------------------------------------------------
  // [M2] 双银行 (2 x 160KiB = 2 x 20480 个 64b 字; 物理仍是这 4 段, 0 tile 增量):
  //   bank0 = 全局字 0..20479     = a[0..16383] + b[0..4095]
  //   bank1 = 全局字 20480..40959 = b[4096..8191] + c + d
  //   w_mode=0 (默认): w_addr = W 区字节偏移 (0..0x4FFFF), 走全局字 w_base; 与 v0.7 逐拍一致;
  //   w_mode=1: w_addr = **银行内**字节偏移 (0..0x27FFF), 引擎读活动银行 w_bank_sel;
  //             wfill_* 写非活动银行 (~w_bank_sel), 64b/拍, 地址 = 银行内 64b 字序号。
  //   每段仍是 2 个 BRAM 访问口: port A = 活动银行 cur 读; port B = (活动银行 next 读)
  //     或 (非活动银行填充写) 分时 -> 不复制存储, 80 tiles 不变。
  //   读地址全部是位选 (无加法器), 缩短 w_addr_q -> BRAM 地址路径:
  //     wi = 2*w_addr[17:4] + w_addr[3] (银行内 64b 字序号 0..20479)
  //     bank0: a_addr = wi[13:0] (wi<16384) / b_addr = wi[11:0] (wi>=16384)
  //     bank1: b_addr = {1,wi[11:0]} (wi<4096) / c_addr = {wi[13],wi[11:0]} /
  //            d_addr = {wi[14],wi[11:0]}
  //   【约束】单层权重 wlen <= 131,072 B (128KiB): 否则 bank0 的 b 半区 (wi>=16384)
  //   会同时被"引擎 next 读"和"填 bank1 的写"占用 (共享 b 段的 port B 争用)。
  //   瓶盖模型最大层 124,416 B 满足; M3 的 nn_wload 必须检查 pre_wlen <= 131072。
  // --------------------------------------------------------------------------
  // [2026-11-01 build fix] 原为 (* rom_style="block" *): 320KB 常量 ROM 必须显式落 BRAM
  // (否则自动推断先展开成 5.2M 寄存器, 整机综合 3 小时)。M2 加写口后 W 是 RAM,
  // 改用 (* ram_style="block" *); 容量/字宽/端口数不变 => 仍推断 80 个 RAMB36。
  (* ram_style = "block" *) logic [63:0] w_mem_a [0:WSEG_A-1];
  (* ram_style = "block" *) logic [63:0] w_mem_b [0:WSEG_B-1];
  (* ram_style = "block" *) logic [63:0] w_mem_c [0:WSEG_C-1];
  (* ram_style = "block" *) logic [63:0] w_mem_d [0:WSEG_D-1];

  // --------------------------------------------------------------------------
  // [wpipe] NPU W 读输入寄存级: w_re/w_addr 先打一拍, BRAM 读用寄存后的地址
  //   => W 读时延 2 拍; 其余逻辑 (8B 窗口 cur/next、Q、A/B、CPU、dbg) 不变。
  //   引擎侧对应 W_RD_LAT=2 (根 nn_conv_engine 默认 2; =1 仍可配旧 mem)。
  // --------------------------------------------------------------------------
  logic        w_re_q;
  logic [23:0] w_addr_q;
  always @(posedge clk) begin
    if (rst) begin
      w_re_q   <= 1'b0;
      w_addr_q <= 24'd0;
    end else begin
      w_re_q   <= w_re;
      w_addr_q <= w_addr;
    end
  end

  // 读字索引: ROM 路径 = 全局 w_base (16b); 流式路径 = 银行内 w_wi (15b)
  logic [14:0] w_idx;
  logic        w_odd;
  logic [15:0] w_base, w_nbase;
  logic [14:0] w_wi, w_nwi;
  logic [1:0]  w_seg;
  assign w_idx   = w_addr_q[18:4];
  assign w_odd   = w_addr_q[3];
  assign w_base  = {w_idx, w_odd};            // 2*w_idx + w_odd (0..40959)
  assign w_nbase = w_base + 16'd1;
  assign w_wi    = {w_addr_q[17:4], w_odd};   // 2*w_addr_q[17:4] + w_odd (0..20479)
  assign w_nwi   = w_wi + 15'd1;

  // ROM 段选择 (v0.7 原逻辑, 逐位不变)
  always_comb begin
    w_seg = 2'd3;
    if (w_base < 16'd16384)      w_seg = 2'd0;
    else if (w_base < 16'd24576) w_seg = 2'd1;
    else if (w_base < 16'd32768) w_seg = 2'd2;
  end

  // 写地址 (dbg): 32-bit 字索引 -> 全局 64-bit 字索引 + half; 仅仿真使用
  logic [15:0] w_wr_idx;
  logic [1:0]  w_wr_seg;
  logic        w_wr_half;
  assign w_wr_idx  = dbg_addr[16:1];
  assign w_wr_half = dbg_addr[0];
  always_comb begin
    w_wr_seg = 2'd3;
    if (w_wr_idx < 16'd16384)      w_wr_seg = 2'd0;
    else if (w_wr_idx < 16'd24576) w_wr_seg = 2'd1;
    else if (w_wr_idx < 16'd32768) w_wr_seg = 2'd2;
  end

  // 每段 cur / next 读地址 (纯位选; next 的跨段/越界由输出 mux 处理)
  logic [13:0] a_ca, a_na;
  logic [12:0] b_ca, b_na, c_ca, c_na, d_ca, d_na;
  assign a_ca = w_mode_i ? w_wi[13:0]                         : w_base[13:0];
  assign a_na = w_mode_i ? w_nwi[13:0]                        : w_nbase[13:0];
  assign b_ca = w_mode_i ? (w_bank_sel_i ? {1'b1, w_wi[11:0]} : w_wi[11:0])
                         : w_base[12:0];
  assign b_na = w_mode_i ? (w_bank_sel_i ? {1'b1, w_nwi[11:0]} : w_nwi[11:0])
                         : w_nbase[12:0];
  assign c_ca = w_mode_i ? {w_wi[13],  w_wi[11:0]}            : w_base[12:0];
  assign c_na = w_mode_i ? {w_nwi[13], w_nwi[11:0]}           : w_nbase[12:0];
  assign d_ca = w_mode_i ? {w_wi[14],  w_wi[11:0]}            : w_base[12:0];
  assign d_na = w_mode_i ? {w_nwi[14], w_nwi[11:0]}           : w_nbase[12:0];

  // --------------------------------------------------------------------------
  // [M2] 填充写口解码: 目标银行 = ~w_bank_sel, 全局字
  //   G = w_bank_sel ? wfill_addr        (填 bank0, 活动=bank1)
  //                  : wfill_addr+20480  (填 bank1, 活动=bank0)
  // --------------------------------------------------------------------------
  logic        wfill_en, wfill_inr;
  logic [15:0] wfill_g;
  logic        fa_we, fb_we, fc_we, fd_we, fb_bwe;
  logic [13:0] fa_wa;
  logic [12:0] fb_wa, fc_wa, fd_wa;
  assign wfill_en  = wfill_we_i && (w_mode_i == nn_pkg::NN_W_MODE_STREAM);
  assign wfill_inr = (32'(wfill_addr) < 32'(W_BANK_W64));
  assign wfill_g   = w_bank_sel_i ? {1'b0, wfill_addr[14:0]}
                                  : (16'(wfill_addr[14:0]) + 16'(W_BANK_W64));
  assign fa_we = wfill_en && wfill_inr && (wfill_g < 16'(WSEG_A));
  assign fb_we = wfill_en && wfill_inr && (wfill_g >= 16'(WSEG_A)) &&
                 (wfill_g < 16'(WSEG_A + WSEG_B));
  assign fc_we = wfill_en && wfill_inr && (wfill_g >= 16'(WSEG_A + WSEG_B)) &&
                 (wfill_g < 16'(WSEG_A + WSEG_B + WSEG_C));
  assign fd_we = wfill_en && wfill_inr && (wfill_g >= 16'(WSEG_A + WSEG_B + WSEG_C));
  assign fa_wa = wfill_g[13:0];
  assign fb_wa = wfill_g[12:0];
  assign fc_wa = wfill_g[12:0];
  assign fd_wa = wfill_g[12:0];
  // b 段被两个银行共享 (bank0 的高 32KiB = b[0..4095]; bank1 的低 32KiB = b[4096..8191]):
  // 活动 bank=1 时 b 的 port B 必须留给引擎 next 读, 此时"填 bank0 高 32KiB"的写丢弃。
  // 该写只在单层权重 >128KiB 时出现 -> 由上面的 wlen 约束排除 (最大层 124,416 B)。
  assign fb_bwe = fb_we && ~w_bank_sel_i;

  logic [63:0] w_cur_a, w_cur_b, w_cur_c, w_cur_d;
  logic [63:0] w_nxt_a, w_nxt_b, w_nxt_c, w_nxt_d;
  logic [15:0] w_base_r;
  logic [14:0] w_wi_r;
  logic [1:0]  w_seg_r;
  logic        w_mode_r, w_bank_r;
  logic        w_rd_valid_r, w_addr_ok;

  // port A: 每段一个只读口 (cur)
  always @(posedge clk) w_cur_a <= w_mem_a[a_ca];
  always @(posedge clk) w_cur_b <= w_mem_b[b_ca];
  always @(posedge clk) w_cur_c <= w_mem_c[c_ca];
  always @(posedge clk) w_cur_d <= w_mem_d[d_ca];

  // port B: 每段一个 **读写同址的单口** (read-write port):
  //   pba = 填充写 ? 写地址 : next 读地址; 读数据始终寄存 (写拍读到的是旧值, 被忽略)。
  //   这样每段综合成 (1 只读口 + 1 读写口) = 2 个 BRAM 访问口 -> 不复制存储, 80 tiles。
  //   [坑, 2026-11-03 OOC 实测] 最初写成 `if (fill) 写 else 读` 且读写地址不同:
  //   Vivado 把它当 **3 个访问口** -> W 复制成 160 tiles (OOC 需求 ~200 tiles > 135,
  //   触发 "BRAM overutilized, implement using LUT-RAM", 实测 RAMB36=128 + 57,622 LUTRAM)。
  //   改成"同址读写单口"(下面这种写法)后 OOC 实测 RAMB36 = 120 (W 80 + Q 8 + A/B 32)。
  logic [13:0] a_pba;
  logic [12:0] b_pba, c_pba, d_pba;
  assign a_pba = fa_we   ? fa_wa : a_na;
  assign b_pba = fb_bwe  ? fb_wa : b_na;
  assign c_pba = fc_we   ? fc_wa : c_na;
  assign d_pba = fd_we   ? fd_wa : d_na;

  // 仿真 dbg 半字写也放在同一块里 (不同地址, 只影响仿真; 综合时该分支被去掉)
  always @(posedge clk) begin
    w_nxt_a <= w_mem_a[a_pba];
`ifndef SYNTHESIS
    if (w_dbg_we && (w_wr_seg == 2'd0)) begin
      if (w_wr_half) w_mem_a[w_wr_idx[13:0]][63:32] <= dbg_wdata;
      else           w_mem_a[w_wr_idx[13:0]][31:0]  <= dbg_wdata;
    end
`endif
    if (fa_we) w_mem_a[a_pba] <= wfill_wdata;
  end

  always @(posedge clk) begin
    w_nxt_b <= w_mem_b[b_pba];
`ifndef SYNTHESIS
    if (w_dbg_we && (w_wr_seg == 2'd1)) begin
      if (w_wr_half) w_mem_b[w_wr_idx[12:0]][63:32] <= dbg_wdata;
      else           w_mem_b[w_wr_idx[12:0]][31:0]  <= dbg_wdata;
    end
`endif
    if (fb_bwe) w_mem_b[b_pba] <= wfill_wdata;
  end

  always @(posedge clk) begin
    w_nxt_c <= w_mem_c[c_pba];
`ifndef SYNTHESIS
    if (w_dbg_we && (w_wr_seg == 2'd2)) begin
      if (w_wr_half) w_mem_c[w_wr_idx[12:0]][63:32] <= dbg_wdata;
      else           w_mem_c[w_wr_idx[12:0]][31:0]  <= dbg_wdata;
    end
`endif
    if (fc_we) w_mem_c[c_pba] <= wfill_wdata;
  end

  always @(posedge clk) begin
    w_nxt_d <= w_mem_d[d_pba];
`ifndef SYNTHESIS
    if (w_dbg_we && (w_wr_seg == 2'd3)) begin
      if (w_wr_half) w_mem_d[w_wr_idx[12:0]][63:32] <= dbg_wdata;
      else           w_mem_d[w_wr_idx[12:0]][31:0]  <= dbg_wdata;
    end
`endif
    if (fd_we) w_mem_d[d_pba] <= wfill_wdata;
  end

  // 输出侧流水寄存 (与读数据同拍; 模式/银行/字索引一起打拍)
  assign w_addr_ok = w_mode_i ? (32'(w_addr_q) < 32'(W_BANK_BYTES))
                              : (32'(w_addr_q) < 32'(W_BYTES));
  always @(posedge clk) begin
    if (rst) begin
      w_base_r     <= 16'd0;
      w_wi_r       <= 15'd0;
      w_seg_r      <= 2'd0;
      w_mode_r     <= 1'b0;
      w_bank_r     <= 1'b0;
      w_rd_valid_r <= 1'b0;
    end else begin
      w_base_r     <= w_base;
      w_wi_r       <= w_wi;
      w_seg_r      <= w_seg;
      w_mode_r     <= w_mode_i;
      w_bank_r     <= w_bank_sel_i;
      w_rd_valid_r <= w_re_q && w_addr_ok;
    end
  end

  // ---- ROM 路径输出 (v0.7 原逻辑, 逐位不变) ----
  logic [63:0] w_cur_rom, w_nxt_rom, w_cur_s, w_nxt_s, w_cur, w_nxt;
  always_comb begin
    case (w_seg_r)
      2'd0:    w_cur_rom = w_cur_a;
      2'd1:    w_cur_rom = w_cur_b;
      2'd2:    w_cur_rom = w_cur_c;
      default: w_cur_rom = w_cur_d;
    endcase
  end
  // next 64-bit 字: 正常用本段第二读口; 段边界用下一段读口读到的第 0 个字;
  // W 末字 (base=40959) 的 next 越界 -> 0
  always_comb begin
    if (w_base_r == 16'd16383)
      w_nxt_rom = w_nxt_b;             // A 末字 -> B[0]
    else if (w_base_r == 16'd24575)
      w_nxt_rom = w_nxt_c;             // B 末字 -> C[0]
    else if (w_base_r == 16'd32767)
      w_nxt_rom = w_nxt_d;             // C 末字 -> D[0]
    else if (w_base_r == 16'd40959)
      w_nxt_rom = 64'b0;               // W 末字, 高 8B 越界 -> 0
    else case (w_seg_r)
      2'd0:    w_nxt_rom = w_nxt_a;
      2'd1:    w_nxt_rom = w_nxt_b;
      2'd2:    w_nxt_rom = w_nxt_c;
      default: w_nxt_rom = w_nxt_d;
    endcase
  end

  // ---- 流式路径输出: 银行内 wi -> 段 (跨段 next / 银行末字由条件处理) ----
  always_comb begin
    if (!w_bank_r) begin
      w_cur_s = (w_wi_r < 15'd16384) ? w_cur_a : w_cur_b;
    end else begin
      w_cur_s = (w_wi_r < 15'd4096)  ? w_cur_b :
                (w_wi_r < 15'd12288) ? w_cur_c : w_cur_d;
    end
    if (w_wi_r == 15'd20479)          w_nxt_s = 64'b0;          // 银行末字
    else if (!w_bank_r)               w_nxt_s = (w_wi_r < 15'd16383) ? w_nxt_a : w_nxt_b;
    else                              w_nxt_s = (w_wi_r < 15'd4095)  ? w_nxt_b :
                                                (w_wi_r < 15'd12287) ? w_nxt_c : w_nxt_d;
  end

  assign w_cur = w_mode_r ? w_cur_s : w_cur_rom;
  assign w_nxt = w_mode_r ? w_nxt_s : w_nxt_rom;

  // 16B 窗口 = {高 8B (next), 低 8B (cur)}, 小端
  assign w_rdata = w_rd_valid_r ? {w_nxt, w_cur} : 128'b0;

  // ==========================================================================
  // Q 区: ROM 路径 (w_mode=0) 与 v0.7 完全相同 = lo(4096x64 BRAM) + hi(2048x64 分布式)
  //   读: q_addr = 64-bit Q 字索引; 写: 只给 dbg 装载 (SoC 恒 0 -> ROM)
  //   [2026-11-01 build fix] 综合落 ROM: lo 4096 深用 BRAM (8 tiles);
  //   hi 2048 深改分布式 LUTRAM (~2.1K LUT, 0 BRAM) —— r10 整机 place 报
  //   "272 units needed / 270 sites" (core 实占 12 tiles), 124+12=136 差 1 tile,
  //   hi 改 LUTRAM 后 mem 120 tiles, 整机 120+12=132/135 ✓。
  // --------------------------------------------------------------------------
  // [M2] 流式路径 (w_mode=1): lo 的前 2048 字改作 **2 x 8KiB 可写影子银行**
  //   bank0 = q_mem_lo[0..1023], bank1 = q_mem_lo[1024..2047];
  //   引擎读活动银行 q_bank_sel (索引 {q_bank_sel, q_addr[9:0]}, 单层 Q <= 5,200 B);
  //   qfill_* 写非活动银行 (~q_bank_sel), 64b/拍。
  //   lo 从 ROM 变 RAM 但容量/字宽不变 => 仍是 8 个 RAMB36 (增量 0); hi 仍是分布式 ROM。
  // ==========================================================================
  (* ram_style = "block" *) logic [63:0] q_mem_lo [0:QLO-1];        // 8 BRAM36
  (* rom_style = "distributed" *) logic [63:0] q_mem_hi [0:QHI-1];  // distributed ROM -> LUT 逻辑, ~1.6K LUT, 0 BRAM

  logic [63:0] q_rd_lo, q_rd_hi, q_rd;
  logic        q_hi_r, q_mode_r;
  logic        q_rd_valid_r;

  // 读地址: ROM = q_addr[11:0]; 流式 = {q_bank_sel, q_addr[9:0]}
  logic [11:0] q_lo_ra;
  assign q_lo_ra = w_mode_i ? {1'b0, q_bank_sel_i, q_addr[9:0]} : q_addr[11:0];

  // [M2] 影子银行写口: 目标银行 = ~q_bank_sel; ROM 模式恒关闭。
  //   与 dbg 装载口并入同一块 (仿真), 综合时 dbg 分支被去掉 => lo 是简单双口 RAM。
  logic        qfill_en, qfill_inr;
  logic [11:0] q_lo_wa;
  assign qfill_en  = qfill_we_i && (w_mode_i == nn_pkg::NN_W_MODE_STREAM);
  assign qfill_inr = (32'(qfill_addr) < 32'(Q_BANK_W64));
  assign q_lo_wa   = {1'b0, ~q_bank_sel_i, qfill_addr[9:0]};
  always @(posedge clk) begin
    if (qfill_en && qfill_inr) begin
      q_mem_lo[q_lo_wa] <= qfill_wdata;
    end
`ifndef SYNTHESIS
    else if (q_dbg_we) begin
      if (dbg_addr[13:1] < 13'(QLO)) begin
        if (dbg_addr[0]) q_mem_lo[dbg_addr[12:1]][63:32] <= dbg_wdata;
        else             q_mem_lo[dbg_addr[12:1]][31:0]  <= dbg_wdata;
      end else begin
        if (dbg_addr[0]) q_mem_hi[dbg_addr[11:1]][63:32] <= dbg_wdata;
        else             q_mem_hi[dbg_addr[11:1]][31:0]  <= dbg_wdata;
      end
    end
`endif
  end

  // 两段并行读 (各 1 读口), 按地址高位选择 -> 1 拍延迟不变
  always @(posedge clk) begin
    q_rd_lo  <= q_mem_lo[q_lo_ra];
    q_rd_hi  <= q_mem_hi[q_addr[10:0]];   // q_addr-4096 的低 11 位 (4096 = 2^12)
    q_hi_r   <= q_addr[12];
    q_mode_r <= w_mode_i;
  end
  logic q_addr_ok;
  assign q_addr_ok = w_mode_i ? (32'(q_addr) < 32'(Q_BANK_W64))
                              : (32'(q_addr) < 32'(Q64));
  always @(posedge clk) begin
    if (rst) q_rd_valid_r <= 1'b0;
    else     q_rd_valid_r <= q_re && q_addr_ok;
  end
  assign q_rd     = q_mode_r ? q_rd_lo : (q_hi_r ? q_rd_hi : q_rd_lo);
  assign q_rdata  = q_rd_valid_r ? q_rd : 64'b0;

  // ==========================================================================
  // 激活区 A+B (连续 128KB, 共用一块 128-bit 宽阵列)
  //   读: NPU 128b (a_*) 优先, 否则 CPU 32b; 写: NPU 128b+strobe 优先, 否则 CPU
  // ==========================================================================
  logic [127:0] act_mem [0:ACT_WORDS-1];

  logic [31:0] a_addr32, b_addr32, cpu_addr32;
  assign a_addr32   = {8'b0, a_addr};
  assign b_addr32   = {8'b0, b_addr};
  assign cpu_addr32 = cpu_addr;

  logic a_in_a, a_in_b, b_in_a, b_in_b;
  assign a_in_a = (a_addr32 >= A_OFF) && (a_addr32 < B_OFF);
  assign a_in_b = (a_addr32 >= B_OFF) && (a_addr32 < B_END);
  assign b_in_a = (b_addr32 >= A_OFF) && (b_addr32 < B_OFF);
  assign b_in_b = (b_addr32 >= B_OFF) && (b_addr32 < B_END);

  logic a_val_act, b_val_act;
  assign a_val_act = a_re && ((a_sel == 2'd0 && a_in_a) || (a_sel == 2'd1 && a_in_b));
  assign b_val_act = b_we && ((b_sel == 2'd0 && b_in_a) || (b_sel == 2'd1 && b_in_b));

  // CPU 窗口: 只映射 A/B (两者地址连续)
  logic cpu_sel_act;
  assign cpu_sel_act = (cpu_addr32 >= A_OFF) && (cpu_addr32 < B_END);

  // A/B 访问索引: 默认绝对位选 / 大配置相对 A_OFF 偏移 (见 ACT_ABS_OK 注释)
  logic [ACT_AW-1:0] a_idx, b_idx, cpu_idx, act_rd_idx;
  assign a_idx   = ACT_ABS_OK ? a_addr[ACT_AW+3:4]   : ACT_AW'((a_addr32   - A_OFF) >> 4);
  assign b_idx   = ACT_ABS_OK ? b_addr[ACT_AW+3:4]   : ACT_AW'((b_addr32   - A_OFF) >> 4);
  assign cpu_idx = ACT_ABS_OK ? cpu_addr[ACT_AW+3:4] : ACT_AW'((cpu_addr32 - A_OFF) >> 4);
  assign act_rd_idx = a_val_act   ? a_idx
                    : (cpu_sel_act ? cpu_idx : {ACT_AW{1'b0}});

  // 写通路: NPU 128b + strobe 优先, 否则 CPU 32b 字节写
  logic [15:0]       act_wr_en;
  logic [127:0]      act_wr_data;
  logic [ACT_AW-1:0] act_wr_idx;

  always_comb begin
    act_wr_en   = 16'b0;
    act_wr_data = 128'b0;
    act_wr_idx  = {ACT_AW{1'b0}};

    if (b_val_act) begin
      act_wr_idx  = b_idx;
      act_wr_en   = b_wstrb;
      act_wr_data = b_wdata;
    end else if (cpu_we && cpu_sel_act) begin
      act_wr_idx = cpu_idx;
      case (cpu_addr[3:2])
        2'd0: begin act_wr_en[3:0]   = cpu_wstrb; act_wr_data[31:0]    = cpu_wdata; end
        2'd1: begin act_wr_en[7:4]   = cpu_wstrb; act_wr_data[63:32]   = cpu_wdata; end
        2'd2: begin act_wr_en[11:8]  = cpu_wstrb; act_wr_data[95:64]   = cpu_wdata; end
        default: begin act_wr_en[15:12] = cpu_wstrb; act_wr_data[127:96] = cpu_wdata; end
      endcase
    end
  end

  logic [127:0] act_rd;
  // 用 always 而非 always_ff (initial 也写 act_mem; 与 dmem 同写法)
  always @(posedge clk) begin
    if (act_wr_en[0])  act_mem[act_wr_idx][7:0]     <= act_wr_data[7:0];
    if (act_wr_en[1])  act_mem[act_wr_idx][15:8]    <= act_wr_data[15:8];
    if (act_wr_en[2])  act_mem[act_wr_idx][23:16]   <= act_wr_data[23:16];
    if (act_wr_en[3])  act_mem[act_wr_idx][31:24]   <= act_wr_data[31:24];
    if (act_wr_en[4])  act_mem[act_wr_idx][39:32]   <= act_wr_data[39:32];
    if (act_wr_en[5])  act_mem[act_wr_idx][47:40]   <= act_wr_data[47:40];
    if (act_wr_en[6])  act_mem[act_wr_idx][55:48]   <= act_wr_data[55:48];
    if (act_wr_en[7])  act_mem[act_wr_idx][63:56]   <= act_wr_data[63:56];
    if (act_wr_en[8])  act_mem[act_wr_idx][71:64]   <= act_wr_data[71:64];
    if (act_wr_en[9])  act_mem[act_wr_idx][79:72]   <= act_wr_data[79:72];
    if (act_wr_en[10]) act_mem[act_wr_idx][87:80]   <= act_wr_data[87:80];
    if (act_wr_en[11]) act_mem[act_wr_idx][95:88]   <= act_wr_data[95:88];
    if (act_wr_en[12]) act_mem[act_wr_idx][103:96]  <= act_wr_data[103:96];
    if (act_wr_en[13]) act_mem[act_wr_idx][111:104] <= act_wr_data[111:104];
    if (act_wr_en[14]) act_mem[act_wr_idx][119:112] <= act_wr_data[119:112];
    if (act_wr_en[15]) act_mem[act_wr_idx][127:120] <= act_wr_data[127:120];
    act_rd <= act_mem[act_rd_idx];
  end

  logic a_valid_r;
  always @(posedge clk) begin
    if (rst) a_valid_r <= 1'b0;
    else     a_valid_r <= a_val_act;
  end
  assign a_rdata = a_valid_r ? act_rd : 128'b0;

  // ---- CPU 读数据: 1 拍延迟, 只 A/B 命中; 其余 0 (不产生 err) ----
  logic       cpu_sel_r;
  logic [1:0] cpu_lane_r;
  always @(posedge clk) begin
    if (rst) begin
      cpu_sel_r  <= 1'b0;
      cpu_lane_r <= 2'd0;
    end else begin
      cpu_sel_r  <= cpu_sel_act;
      cpu_lane_r <= cpu_addr[3:2];
    end
  end

  logic [31:0] cpu_lane_data;
  always_comb begin
    case (cpu_lane_r)
      2'd0:    cpu_lane_data = act_rd[31:0];
      2'd1:    cpu_lane_data = act_rd[63:32];
      2'd2:    cpu_lane_data = act_rd[95:64];
      default: cpu_lane_data = act_rd[127:96];
    endcase
  end
  assign cpu_rdata = cpu_sel_r ? cpu_lane_data : 32'b0;

  // ==========================================================================
  // 初始化
  //   综合: W 4 段 64-bit/行 (16384/8192/8192/8192 行) + Q 6144 行 64-bit/行
  //   仿真: 零填充 + loader 把 32-bit/行镜像打包 (nnw / nnq / 旧 nnwq)
  // ==========================================================================
  initial begin
`ifdef SYNTHESIS
`ifdef NN_W_INIT_A
    $readmemh(`NN_W_INIT_A, w_mem_a);
`endif
`ifdef NN_W_INIT_B
    $readmemh(`NN_W_INIT_B, w_mem_b);
`endif
`ifdef NN_W_INIT_C
    $readmemh(`NN_W_INIT_C, w_mem_c);
`endif
`ifdef NN_W_INIT_D
    $readmemh(`NN_W_INIT_D, w_mem_d);
`endif
`ifdef NN_Q_INIT_LO
    $readmemh(`NN_Q_INIT_LO, q_mem_lo);
`endif
`ifdef NN_Q_INIT_HI
    $readmemh(`NN_Q_INIT_HI, q_mem_hi);
`endif
`else
    begin : sim_init
      string fname;
      int    fd;
      int    code;
      int    widx;    // W: 已装入的 64-bit 字个数 (0..W64)
      int    whalf;   // W: 当前 64-bit 字内的 32-bit 半字 (0/1)
      int    qidx;
      int    qword;
      logic [31:0]  v32;
      logic [63:0]  acc64;
      string line;

      for (int i = 0; i < WSEG_A; i++)    w_mem_a[i] = 64'b0;
      for (int i = 0; i < WSEG_B; i++)    w_mem_b[i] = 64'b0;
      for (int i = 0; i < WSEG_C; i++)    w_mem_c[i] = 64'b0;
      for (int i = 0; i < WSEG_D; i++)    w_mem_d[i] = 64'b0;
      for (int i = 0; i < QLO; i++)       q_mem_lo[i] = 64'b0;
      for (int i = 0; i < QHI; i++)       q_mem_hi[i] = 64'b0;
      for (int i = 0; i < ACT_WORDS; i++) act_mem[i] = 128'b0;

      // ---- 模式 1: 单个 WQ 文件 (94208 行 = W 81920 + Q 12288 顺序拼接) ----
      if ($value$plusargs("nnwq=%s", fname)) begin
        fd = $fopen(fname, "r");
        if (fd == 0) begin
          $display("[nn_mem] WARN: cannot open +nnwq file: %s", fname);
        end else begin
          widx = 0; whalf = 0; acc64 = '0;
          qidx = 0; qword = 0;
          code = $fgets(line, fd);
          while (code != 0 && widx < W64) begin
            if ($sscanf(line, "%h", v32) == 1) begin
              if (whalf == 0) begin
                acc64[31:0] = v32;
                whalf = 1;
              end else begin
                acc64[63:32] = v32;
                if (widx < WSEG_A)
                  w_mem_a[widx] = acc64;
                else if (widx < WSEG_A + WSEG_B)
                  w_mem_b[widx - WSEG_A] = acc64;
                else if (widx < WSEG_A + WSEG_B + WSEG_C)
                  w_mem_c[widx - WSEG_A - WSEG_B] = acc64;
                else
                  w_mem_d[widx - WSEG_A - WSEG_B - WSEG_C] = acc64;
                widx  = widx + 1;
                whalf = 0;
                acc64 = '0;
              end
            end
            code = $fgets(line, fd);
          end
          while (code != 0 && qword < Q_WORDS) begin
            if ($sscanf(line, "%h", v32) == 1) begin
              if ((qword % 2) == 0) begin
                acc64[31:0] = v32;
              end else begin
                acc64[63:32] = v32;
                if (qidx < QLO) q_mem_lo[qidx] = acc64;
                else            q_mem_hi[qidx - QLO] = acc64;
                qidx = qidx + 1;
                acc64 = '0;
              end
              qword = qword + 1;
            end
            code = $fgets(line, fd);
          end
          $fclose(fd);
          $display("[nn_mem] WQ image loaded: %s (W %0d x64b, Q %0d x64b)", fname, widx, qidx);
          if ((widx != W64) || (qword != Q_WORDS))
            $display("[nn_mem] WARN: +nnwq line count W=%0d/%0d Q=%0d/%0d",
                     widx, W64, qword, Q_WORDS);
        end
      end else begin
        // ---- 模式 2: 分开的 W / Q 文件 (32-bit 行) ----
        if ($value$plusargs("nnw=%s", fname)) begin
          fd = $fopen(fname, "r");
          if (fd == 0) begin
            $display("[nn_mem] WARN: cannot open +nnw file: %s", fname);
          end else begin
            widx = 0; whalf = 0; acc64 = '0;
            code = $fgets(line, fd);
            while (code != 0 && widx < W64) begin
              if ($sscanf(line, "%h", v32) == 1) begin
                if (whalf == 0) begin
                  acc64[31:0] = v32;
                  whalf = 1;
                end else begin
                  acc64[63:32] = v32;
                  if (widx < WSEG_A)
                    w_mem_a[widx] = acc64;
                  else if (widx < WSEG_A + WSEG_B)
                    w_mem_b[widx - WSEG_A] = acc64;
                  else if (widx < WSEG_A + WSEG_B + WSEG_C)
                    w_mem_c[widx - WSEG_A - WSEG_B] = acc64;
                  else
                    w_mem_d[widx - WSEG_A - WSEG_B - WSEG_C] = acc64;
                  widx  = widx + 1;
                  whalf = 0;
                  acc64 = '0;
                end
              end
              code = $fgets(line, fd);
            end
            $fclose(fd);
            $display("[nn_mem] W image loaded: %s (%0d / %0d x64b)", fname, widx, W64);
          end
        end else begin
          $display("[nn_mem] WARN: no +nnw / +nnwq; W arrays stay zero");
        end

        if ($value$plusargs("nnq=%s", fname)) begin
          fd = $fopen(fname, "r");
          if (fd == 0) begin
            $display("[nn_mem] WARN: cannot open +nnq file: %s", fname);
          end else begin
            qidx = 0; qword = 0;
            code = $fgets(line, fd);
            while (code != 0 && qword < Q_WORDS) begin
              if ($sscanf(line, "%h", v32) == 1) begin
                if ((qword % 2) == 0) begin
                  acc64[31:0] = v32;
                end else begin
                  acc64[63:32] = v32;
                  if (qidx < QLO) q_mem_lo[qidx] = acc64;
                  else            q_mem_hi[qidx - QLO] = acc64;
                  qidx = qidx + 1;
                  acc64 = '0;
                end
                qword = qword + 1;
              end
              code = $fgets(line, fd);
            end
            $fclose(fd);
            $display("[nn_mem] Q image loaded: %s (%0d / %0d x64b)", fname, qidx, Q64);
          end
        end else begin
          $display("[nn_mem] WARN: no +nnq / +nnwq; Q stays zero");
        end
      end
    end
`endif
  end

endmodule
