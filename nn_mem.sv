`timescale 1ns/1ps

// ============================================================================
// nn_mem.sv — AI 加速子系统片上存储 (v0.7 特化架构)
// ----------------------------------------------------------------------------
// 规格: results/ai-accel/SPEC-SPECIALIZED.md §3 + MODEL-FREEZE.md (D1-D5)
//
// 【v0.7 相对 v0.3 的 5 个变化】
//   1. W 区独立 320KB, 只给 NPU 128-bit 读口 (w_re/w_addr/w_rdata[127:0], 1 拍);
//      CPU 不可访问。4 段 $readmemh 初始化 (NN_W_INIT_A..D, 每段 128-bit/行)。
//   2. Q 区 48KB 迁**分布式 RAM/ROM (LUTRAM)** (q_re/q_addr[12:0]/q_rdata[63:0],
//      1 拍); CPU 不可访问; 不占 BRAM (实测约 7,000 LUT / 0 BRAM, 见 mem-report.md)。
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
//   W  : 4 段 128-bit 宽阵列 (8192/4096/4096/4096 个 128-bit 字), 每段 2 个读口
//        (cur/next, 复用 BRAM36 真双口, 0 额外 BRAM —— 实测 1 读口 vs 2 读口
//        同为 32 BRAM36 @8192x128);
//        段 A=128KB, B/C/D=64KB; 综合 -> 74 RAMB36 + 3 RAMB18 = 75.5 tiles
//        (随机数据实测; 见 mem-report.md)。为什么必须拆 4 段: 128-bit 宽 ROM
//        深度 >16384 时 Vivado 按 32768 取整 (单块 20480 深 -> 128 块)。
//   Q  : 64-bit 宽、6144 深的分布式 ROM (`ram_style="distributed"`),
//        综合 -> 0 BRAM, 约 7,000 LUT (ROM 内容 6144 LUT + 地址/输出逻辑)。
//   A/B: 128KB 128-bit 宽一块阵列 -> 32 BRAM36 (精确 4KB/BRAM)。
//   => nn_mem 合计 **107.5 tiles**; + 交付档核心约 9.5 ≈ 117/135 (≤121.5 目标)。
//
// 【初始化镜像】
//   综合: W 4 段 `NN_W_INIT_A..D` (每行 32 hex = 128-bit 字, 行数 8192/4096/4096/
//         4096); Q `NN_Q_INIT_FILE` (每行 16 hex = 64-bit 字, 6144 行)。
//         文件由 build flow 从 yolo_w / yolo_q 的 32-bit 行镜像打包 (低字在低 32 位)。
//   仿真: `+nnw=<yolo_w.hex>` (81920 行 32-bit) + `+nnq=<yolo_q.hex>` (12288 行
//         32-bit); 或旧 `+nnwq=<yolo_wq.hex>` (94208 行 = W 81920 + Q 12288 顺序)。
//         本模块内部用小 loader 打包成物理字宽 ($fgets/$sscanf, 仅非 SYNTHESIS)。
//   激活 A/B 不初始化 (仿真零填充仅为消除 X)。
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
  input  logic [31:0]  dbg_wdata
);

  // --------------------------------------------------------------------------
  // 布局常量
  // --------------------------------------------------------------------------
  localparam int W_WORDS  = W_BYTES / 4;        // 81,920 个 32-bit 字
  localparam int W128     = W_BYTES / 16;       // 20,480 个 128-bit 字
  localparam int Q_WORDS  = Q_BYTES / 4;        // 12,288 个 32-bit 字
  localparam int Q64      = Q_WORDS / 2;        // 6,144 个 64-bit 字

  // W 4 段 (128-bit 字): A=8192, B/C/D=4096 (默认 20,480)
  localparam int WSEG_A = 8192;
  localparam int WSEG_B = 4096;
  localparam int WSEG_C = 4096;
  localparam int WSEG_D = W128 - WSEG_A - WSEG_B - WSEG_C;   // 默认 4096

  localparam int ACT_BYTES = A_BYTES + B_BYTES;  // 128KB (A/B 连续)
  localparam int ACT_WORDS = ACT_BYTES / 16;     // 128-bit 物理字数
  localparam int ACT_AW    = $clog2(ACT_WORDS);  // 13

  localparam logic [31:0] A_OFF = nn_pkg::NN_A_OFF;            // 0x0006_0000
  localparam logic [31:0] B_OFF = nn_pkg::NN_A_OFF + A_BYTES;  // 0x0007_8000
  localparam logic [31:0] B_END = B_OFF + B_BYTES;             // 0x0008_0000
  localparam logic [31:0] Q_END = 32'h0005_0000 + Q_BYTES;     // 0x0005_C000
  localparam logic [31:0] WIN   = 32'h1 << CPU_AW;             // 512KB

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
  // W 区: 4 段 128-bit 宽阵列, 每拍 4 段并行读, 输出按段选择
  // ==========================================================================
  logic [127:0] w_mem_a [0:WSEG_A-1];
  logic [127:0] w_mem_b [0:WSEG_B-1];
  logic [127:0] w_mem_c [0:WSEG_C-1];
  logic [127:0] w_mem_d [0:WSEG_D-1];

  // 读地址: w_addr[18:4] = 128-bit 字索引 (低 4 位忽略; w_addr[3] 见下)
  //   v0.7 fix: 引擎按 **8B 粒度** 发 w_addr (8-lane tile 的 row + ic*8, 奇数 ic 时
  //   w_addr[3]=1)。所以 W 读口必须支持 8B 对齐的 16B 窗口: 低 3 位忽略,
  //   返回字节 [w_addr, w_addr+15] (小端)。实现: 每段两个读口 (BRAM36 真双口,
  //   0 额外 BRAM), cur = mem[idx] (A 口), next = mem[idx+1] (B 口),
  //   w_rdata = w_addr[3] ? {next[63:0], cur[127:64]} : cur。
  logic [14:0] w_idx;
  logic [1:0]  w_seg;
  logic        w_odd;
  assign w_idx = w_addr[18:4];
  assign w_odd = w_addr[3];
  always_comb begin
    w_seg = 2'd3;
    if (w_idx < 15'd8192)       w_seg = 2'd0;
    else if (w_idx < 15'd12288) w_seg = 2'd1;
    else if (w_idx < 15'd16384) w_seg = 2'd2;
  end

  // 写地址 (dbg): 32-bit 字索引 -> 128-bit 字索引 + lane
  logic [14:0] w_wr_idx;
  logic [1:0]  w_wr_seg, w_wr_lane;
  assign w_wr_idx  = dbg_addr[16:2];
  assign w_wr_lane = dbg_addr[1:0];
  always_comb begin
    w_wr_seg = 2'd3;
    if (w_wr_idx < 15'd8192)       w_wr_seg = 2'd0;
    else if (w_wr_idx < 15'd12288) w_wr_seg = 2'd1;
    else if (w_wr_idx < 15'd16384) w_wr_seg = 2'd2;
  end

  // next 读地址 (B 口):
  //   · 本段内: cur 局部索引 +1 (末字回绕, 该拍不使用);
  //   · 段边界 (A/B/C 末字): 让**下一段**的 B 口读它的第 0 个字, 供跨段窗口用;
  //   · 其余段不被选中, 地址给 0 即可 (数据不使用)。
  logic [12:0] w_nxt_ia;
  logic [11:0] w_nxt_ib, w_nxt_ic, w_nxt_id;
  assign w_nxt_ia = (w_idx < 15'd8192)                               ? (w_idx[12:0] + 13'd1) : 13'd0;
  assign w_nxt_ib = ((w_idx >= 15'd8192) && (w_idx < 15'd12288))     ? (w_idx[11:0] + 12'd1) : 12'd0;
  assign w_nxt_ic = ((w_idx >= 15'd12288) && (w_idx < 15'd16384))    ? (w_idx[11:0] + 12'd1) : 12'd0;
  assign w_nxt_id = (w_idx >= 15'd16384)                             ? (w_idx[11:0] + 12'd1) : 12'd0;

  logic [127:0] w_cur_a, w_cur_b, w_cur_c, w_cur_d;
  // 第二读口 (next) 的寄存器必须加 keep 保持 128-bit 数据宽度:
  //   功能上 odd 读只用 next[63:0], 若被综合裁成 64-bit, Vivado 会额外复制一份
  //   64-bit 存储 (实测 W 从 75.5 tiles 涨到 147.5 tiles, 超 135 预算)。
  //   keep 后两个 128-bit 读口共用 BRAM36 真双口, W 保持 75.5 tiles (实测见报告)。
  (* keep = "true" *) logic [127:0] w_nxt_a;
  (* keep = "true" *) logic [127:0] w_nxt_b;
  (* keep = "true" *) logic [127:0] w_nxt_c;
  (* keep = "true" *) logic [127:0] w_nxt_d;
  logic [14:0]  w_idx_r;
  logic [1:0]   w_seg_r;
  logic         w_odd_r;
  logic         w_rd_valid_r;

  always @(posedge clk) begin
    w_cur_a <= w_mem_a[w_idx[12:0]];
    w_nxt_a <= w_mem_a[w_nxt_ia];
  end
`ifndef SYNTHESIS
  // dbg 装载写口只存在于仿真: 综合时写口整体不存在 -> W 阵列是纯 ROM,
  // 两个读口才能映射成 BRAM36 真双口 (SoC 里 dbg 本来就 tie 0)。
  always @(posedge clk) begin
    if (w_dbg_we && (w_wr_seg == 2'd0)) begin
      if (w_wr_lane == 2'd0) w_mem_a[w_wr_idx[12:0]][31:0]   <= dbg_wdata;
      if (w_wr_lane == 2'd1) w_mem_a[w_wr_idx[12:0]][63:32]  <= dbg_wdata;
      if (w_wr_lane == 2'd2) w_mem_a[w_wr_idx[12:0]][95:64]  <= dbg_wdata;
      if (w_wr_lane == 2'd3) w_mem_a[w_wr_idx[12:0]][127:96] <= dbg_wdata;
    end
  end
`endif

  always @(posedge clk) begin
    w_cur_b <= w_mem_b[w_idx[11:0]];
    w_nxt_b <= w_mem_b[w_nxt_ib];
  end
`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (w_dbg_we && (w_wr_seg == 2'd1)) begin
      if (w_wr_lane == 2'd0) w_mem_b[w_wr_idx[11:0]][31:0]   <= dbg_wdata;
      if (w_wr_lane == 2'd1) w_mem_b[w_wr_idx[11:0]][63:32]  <= dbg_wdata;
      if (w_wr_lane == 2'd2) w_mem_b[w_wr_idx[11:0]][95:64]  <= dbg_wdata;
      if (w_wr_lane == 2'd3) w_mem_b[w_wr_idx[11:0]][127:96] <= dbg_wdata;
    end
  end
`endif

  always @(posedge clk) begin
    w_cur_c <= w_mem_c[w_idx[11:0]];
    w_nxt_c <= w_mem_c[w_nxt_ic];
  end
`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (w_dbg_we && (w_wr_seg == 2'd2)) begin
      if (w_wr_lane == 2'd0) w_mem_c[w_wr_idx[11:0]][31:0]   <= dbg_wdata;
      if (w_wr_lane == 2'd1) w_mem_c[w_wr_idx[11:0]][63:32]  <= dbg_wdata;
      if (w_wr_lane == 2'd2) w_mem_c[w_wr_idx[11:0]][95:64]  <= dbg_wdata;
      if (w_wr_lane == 2'd3) w_mem_c[w_wr_idx[11:0]][127:96] <= dbg_wdata;
    end
  end
`endif

  always @(posedge clk) begin
    w_cur_d <= w_mem_d[w_idx[11:0]];
    w_nxt_d <= w_mem_d[w_nxt_id];
  end
`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (w_dbg_we && (w_wr_seg == 2'd3)) begin
      if (w_wr_lane == 2'd0) w_mem_d[w_wr_idx[11:0]][31:0]   <= dbg_wdata;
      if (w_wr_lane == 2'd1) w_mem_d[w_wr_idx[11:0]][63:32]  <= dbg_wdata;
      if (w_wr_lane == 2'd2) w_mem_d[w_wr_idx[11:0]][95:64]  <= dbg_wdata;
      if (w_wr_lane == 2'd3) w_mem_d[w_wr_idx[11:0]][127:96] <= dbg_wdata;
    end
  end
`endif

  always @(posedge clk) begin
    if (rst) begin
      w_idx_r      <= 15'd0;
      w_seg_r      <= 2'd0;
      w_odd_r      <= 1'b0;
      w_rd_valid_r <= 1'b0;
    end else begin
      w_idx_r      <= w_idx;
      w_seg_r      <= w_seg;
      w_odd_r      <= w_odd;
      w_rd_valid_r <= w_re && (32'(w_addr) < 32'(W_BYTES));
    end
  end

  logic [127:0] w_cur_r, w_nxt_r;
  always_comb begin
    case (w_seg_r)
      2'd0:    w_cur_r = w_cur_a;
      2'd1:    w_cur_r = w_cur_b;
      2'd2:    w_cur_r = w_cur_c;
      default: w_cur_r = w_cur_d;
    endcase
  end

  // next 字: 正常用本段 B 口; 段边界用下一段 B 口读到的第 0 个字; W 末字越界给 0
  always_comb begin
    if (w_idx_r == 15'd8191)
      w_nxt_r = w_nxt_b;             // A 末字 -> B[0]
    else if (w_idx_r == 15'd12287)
      w_nxt_r = w_nxt_c;             // B 末字 -> C[0]
    else if (w_idx_r == 15'd16383)
      w_nxt_r = w_nxt_d;             // C 末字 -> D[0]
    else if (w_idx_r == 15'd20479)
      w_nxt_r = 128'b0;              // W 末字, 窗口后半越界 -> 0
    else case (w_seg_r)
      2'd0:    w_nxt_r = w_nxt_a;
      2'd1:    w_nxt_r = w_nxt_b;
      2'd2:    w_nxt_r = w_nxt_c;
      default: w_nxt_r = w_nxt_d;
    endcase
  end

  // 8B 对齐的 16B 窗口: w_addr[3]=1 时取 {下一 128b 字的低 64b, 当前 128b 字的高 64b}
  logic [127:0] w_win_r;
  assign w_win_r = w_odd_r ? {w_nxt_r[63:0], w_cur_r[127:64]} : w_cur_r;
  assign w_rdata = w_rd_valid_r ? w_win_r : 128'b0;

  // ==========================================================================
  // Q 区: 64-bit 宽、6144 深 -> 分布式 RAM/ROM (LUTRAM, 0 BRAM)
  //   读: q_addr = 64-bit Q 字索引; 写: 只给 dbg 装载 (SoC 恒 0 -> ROM)
  // ==========================================================================
  (* ram_style = "distributed" *)
  logic [63:0] q_mem [0:Q64-1];

  logic [63:0] q_rd;
  logic        q_rd_valid_r;
  // dbg 装载写口只存在于仿真: 综合时写块整体不存在 -> Q 推断成分布式 ROM
  // (若综合里保留写口, Vivado 落 12,288 LUTRAM, 比 ROM 的 6,981 LUT 多 76%)。
`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (q_dbg_we) begin
      if (dbg_addr[0]) q_mem[dbg_addr[13:1]][63:32] <= dbg_wdata;
      else             q_mem[dbg_addr[13:1]][31:0]  <= dbg_wdata;
    end
  end
`endif
  always @(posedge clk) begin
    q_rd <= q_mem[q_addr];
  end
  always @(posedge clk) begin
    if (rst) q_rd_valid_r <= 1'b0;
    else     q_rd_valid_r <= q_re && (q_addr < 13'(Q64));
  end
  assign q_rdata = q_rd_valid_r ? q_rd : 64'b0;

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

  // 读地址: NPU 优先, 否则 CPU (非 A/B 时读 0 号字, 数据不使用)
  logic [ACT_AW-1:0] act_rd_idx;
  assign act_rd_idx = a_val_act ? a_addr[ACT_AW+3:4]
                    : (cpu_sel_act ? cpu_addr[ACT_AW+3:4] : {ACT_AW{1'b0}});

  // 写通路: NPU 128b + strobe 优先, 否则 CPU 32b 字节写
  logic [15:0]       act_wr_en;
  logic [127:0]      act_wr_data;
  logic [ACT_AW-1:0] act_wr_idx;

  always_comb begin
    act_wr_en   = 16'b0;
    act_wr_data = 128'b0;
    act_wr_idx  = {ACT_AW{1'b0}};

    if (b_val_act) begin
      act_wr_idx  = b_addr[ACT_AW+3:4];
      act_wr_en   = b_wstrb;
      act_wr_data = b_wdata;
    end else if (cpu_we && cpu_sel_act) begin
      act_wr_idx = cpu_addr[ACT_AW+3:4];
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
  //   综合: W 4 段 128-bit/行 + Q 6144 行 64-bit/行
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
`ifdef NN_Q_INIT_FILE
    $readmemh(`NN_Q_INIT_FILE, q_mem);
`endif
`else
    begin : sim_init
      string fname;
      int    fd;
      int    code;
      int    widx;
      int    wlane;
      int    qidx;
      int    qword;
      logic [31:0]  v32;
      logic [127:0] acc128;
      logic [63:0]  acc64;
      string line;

      for (int i = 0; i < WSEG_A; i++)    w_mem_a[i] = 128'b0;
      for (int i = 0; i < WSEG_B; i++)    w_mem_b[i] = 128'b0;
      for (int i = 0; i < WSEG_C; i++)    w_mem_c[i] = 128'b0;
      for (int i = 0; i < WSEG_D; i++)    w_mem_d[i] = 128'b0;
      for (int i = 0; i < Q64; i++)       q_mem[i]   = 64'b0;
      for (int i = 0; i < ACT_WORDS; i++) act_mem[i] = 128'b0;

      // ---- 模式 1: 单个 WQ 文件 (94208 行 = W 81920 + Q 12288 顺序拼接) ----
      if ($value$plusargs("nnwq=%s", fname)) begin
        fd = $fopen(fname, "r");
        if (fd == 0) begin
          $display("[nn_mem] WARN: cannot open +nnwq file: %s", fname);
        end else begin
          widx = 0; wlane = 0; acc128 = '0;
          qidx = 0; qword = 0; acc64 = '0;
          code = $fgets(line, fd);
          while (code != 0 && widx < W128) begin
            if ($sscanf(line, "%h", v32) == 1) begin
              acc128[wlane*32 +: 32] = v32;
              if (wlane == 3) begin
                if (widx < WSEG_A)
                  w_mem_a[widx] = acc128;
                else if (widx < WSEG_A + WSEG_B)
                  w_mem_b[widx - WSEG_A] = acc128;
                else if (widx < WSEG_A + WSEG_B + WSEG_C)
                  w_mem_c[widx - WSEG_A - WSEG_B] = acc128;
                else
                  w_mem_d[widx - WSEG_A - WSEG_B - WSEG_C] = acc128;
                widx  = widx + 1;
                wlane = 0;
                acc128 = '0;
              end else begin
                wlane = wlane + 1;
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
                q_mem[qidx] = acc64;
                qidx = qidx + 1;
                acc64 = '0;
              end
              qword = qword + 1;
            end
            code = $fgets(line, fd);
          end
          $fclose(fd);
          $display("[nn_mem] WQ image loaded: %s (W %0d x128b, Q %0d x64b)", fname, widx, qidx);
          if ((widx != W128) || (qword != Q_WORDS))
            $display("[nn_mem] WARN: +nnwq line count W=%0d/%0d Q=%0d/%0d",
                     widx, W_WORDS, qword, Q_WORDS);
        end
      end else begin
        // ---- 模式 2: 分开的 W / Q 文件 (32-bit 行) ----
        if ($value$plusargs("nnw=%s", fname)) begin
          fd = $fopen(fname, "r");
          if (fd == 0) begin
            $display("[nn_mem] WARN: cannot open +nnw file: %s", fname);
          end else begin
            widx = 0; wlane = 0; acc128 = '0;
            code = $fgets(line, fd);
            while (code != 0 && widx < W128) begin
              if ($sscanf(line, "%h", v32) == 1) begin
                acc128[wlane*32 +: 32] = v32;
                if (wlane == 3) begin
                  if (widx < WSEG_A)
                    w_mem_a[widx] = acc128;
                  else if (widx < WSEG_A + WSEG_B)
                    w_mem_b[widx - WSEG_A] = acc128;
                  else if (widx < WSEG_A + WSEG_B + WSEG_C)
                    w_mem_c[widx - WSEG_A - WSEG_B] = acc128;
                  else
                    w_mem_d[widx - WSEG_A - WSEG_B - WSEG_C] = acc128;
                  widx  = widx + 1;
                  wlane = 0;
                  acc128 = '0;
                end else begin
                  wlane = wlane + 1;
                end
              end
              code = $fgets(line, fd);
            end
            $fclose(fd);
            $display("[nn_mem] W image loaded: %s (%0d / %0d words)", fname, widx, W_WORDS);
          end
        end else begin
          $display("[nn_mem] WARN: no +nnw / +nnwq; W arrays stay zero");
        end

        if ($value$plusargs("nnq=%s", fname)) begin
          fd = $fopen(fname, "r");
          if (fd == 0) begin
            $display("[nn_mem] WARN: cannot open +nnq file: %s", fname);
          end else begin
            qidx = 0; qword = 0; acc64 = '0;
            code = $fgets(line, fd);
            while (code != 0 && qword < Q_WORDS) begin
              if ($sscanf(line, "%h", v32) == 1) begin
                if ((qword % 2) == 0) begin
                  acc64[31:0] = v32;
                end else begin
                  acc64[63:32] = v32;
                  q_mem[qidx] = acc64;
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
