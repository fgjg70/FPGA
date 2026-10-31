`timescale 1ns/1ps

// ============================================================================
// nn_mem.sv — AI 加速子系统片上大存储 (NN 存储窗口, 512KB)
// ----------------------------------------------------------------------------
// 契约: results/ai-accel/CONTRACT.md §2/§3/§8/§9.1 (v0.3)
// 方案: results/ai-accel/PLAN.md §2
//
// 【窗口布局 (字节偏移, 相对 rv32_pkg::NN_BASE) —— v0.3.2】
//   0x00000 .. 0x4FFFF  W 区: int8 权重 (320KB)
//   0x50000 .. 0x5BFFF  Q 区: 每层量化参数 (48KB, 变长紧凑布局) —— 与 W 连续
//   0x5C000 .. 0x5FFFF  地址空洞 (16KB, 不分配 BRAM; 读 0 / 写忽略)
//   0x60000 .. 0x77FFF  激活缓冲 A (96KB) —— 128 输入最大单张量 24ch×64×64
//   0x78000 .. 0x7FFFF  激活缓冲 B (32KB) —— 残差/小张量
//   A/B 在窗口内**连续** (0x60000..0x7FFFF, 共 128KB), 合计 = 512KB = NN_BYTES,
//   CPU 窗口全程可达。
//
// 【WQ 为什么拆成 4 个子阵列 (v0.3.2, 综合实测驱动)】
//   Vivado 对 RAM 的 BRAM 映射有"深度粒度":
//     depth <= 16384 words 且为 2 的幂 -> 精确 4KB/BRAM36
//     depth >  16384 words            -> 按 32768 words(128KB) 向上取整
//     depth 非 2 的幂 (如 12288)       -> 按地址位宽向上取整到 16384
//   单个 94208 字阵列会被映射成 98304 words -> 96 BRAM36 (理论下限 92)。
//   按 2 的幂拆成 4 段后实测 92:
//     WQ_A = 256KB (65536 words) -> 64 BRAM36
//     WQ_B =  64KB (16384 words) -> 16 BRAM36
//     WQ_C =  32KB ( 8192 words) ->  8 BRAM36
//     WQ_D =  16KB ( 4096 words) ->  4 BRAM36   (Q 区 48KB = C+D)
//   合计 92。⇒ 综合初始化因此需要**最多 4 个镜像文件**
//   (NN_WQ_INIT_A/B/C/D, 由 build flow 从单一 yolo_wq.hex 顺序切分得到);
//   仿真仍然只吃契约规定的**单个** +nnwq=<file> (内部逐行分派到 4 段)。
//   若 Q_BYTES 变小 (旧 v0.2 配置 16KB): C=4096、D 段不用, 仍然成立。
//
// 【A/B 为什么合并在同一块物理阵列里 (v0.3.2, 综合实测驱动)】
//   A=96KB、B=32KB 各自单独做 128 位宽阵列时: Vivado 对 128 位宽存储体的映射
//   粒度是 16×4096 深 = 64KB/层, 即 A 96KB 要 ceil(96/64)=2 层 -> 32 BRAM36,
//   B 32KB -> 16 BRAM36, 合计 48 块, 直接撑爆预算。而 A/B 在地址空间里本来就
//   连续 (0x60000..0x7FFFF = 128KB), 合成一块 128 位宽、8192 字深的阵列后恰好
//   是 128KB/4KB = **32 块 BRAM36**, A/B 靠地址位天然隔离。逻辑接口 (a_sel/b_sel)
//   完全不变。实测证据见 results/ai-accel/mem-report.md。
//
// 【物理组织 (为什么这么分)】
//  1) WQ: 契约要求**单一 32 位字初始化镜像** (每行 8 hex), 而 w 读口每拍要
//     64 位 = 相邻两个 32 位字 (小端)。若把 WQ 做成 64 位宽阵列, 32 位字镜像
//     无法用 $readmemh 正确装载。所以 WQ 保持 32 位字阵列, 用**真双口 (TDP)**
//     BRAM: 口 A 只读 (取偶字), 口 B 读/写 (取奇字 or CPU 访问), 两口同拍各出
//     一个字拼 64 位。
//  2) 激活 A/B: NPU 读口每拍 128 位 (同一 16 字节组的两个 64 位字), 写口
//     64 位整字, CPU 还要能按字节写。物理字宽做成 **128 位 (16 字节)**,
//     一读一写 (SDP): NPU 写 64 位落在低半字/高半字 (b_addr[3] 选), 用 16 位
//     字节使能; CPU 32 位写落在 4 个 32 位 lane 之一 (cpu_addr[3:2] 选)。
//  3) 全部行为级推断 (`always @(posedge clk)` + 索引数组), **未例化任何厂商
//     原语**, 迁移紫光同创 PDS 时不需要改结构。
//
// 【BRAM 预算 (v0.3.2 实测)】
//   WQ 92 + 激活(A+B 合并 128KB) 32 = **124** BRAM36; 核心交付档另有 ~8~10 tiles
//   => 约 132~134 / 135 (余 1~3 块)。详情/证据见 mem-report.md。
//
// 【读写延迟口径】与 dmem 相同: 地址在第 N 拍给出, 数据在第 N+1 拍有效 (寄存读)。
//
// 【CPU / NPU 同拍冲突】nn_mem **不做仲裁**: NPU 端口优先, CPU 同拍访问同一
//   存储体时数据/写会被丢弃。契约 §2 规定 NPU busy 期间 CPU 不许访问该窗口
//   (nn_subsys 返回 0xDEADBEEF + STATUS.err), 冲突属软件违约。
//   注意 A/B 合并后激活读口是 NPU/CPU 共享的, 不存在"NPU 与 CPU 同拍各读一块"
//   的并行用法 —— 这与契约的 busy 门控一致。
//
// 【CPU 窗口语义】cpu_addr = NN 窗口内字节偏移:
//   - cpu_addr >= 2^CPU_AW (NN_BYTES=512KB) -> 读 0 / 写忽略 (绝不出 X);
//   - 未映射空洞 (如 0x5C000..0x5FFFF) -> 读 0 / 写忽略;
//   - 低 2 位忽略 (与 dmem 一致: 字节提取/符号扩展在 core 的 LSU/WB 完成);
//     激活区额外用 cpu_addr[3:2] 选 32 位 lane (128 位物理字内的位置)。
//   - cpu_re 不参与功能 (与 dmem 同口径: 地址每拍都在采样), 保留以满足契约。
//
// 【w 读口地址语义 (v0.2/v0.3)】w_addr = NN 窗口内字节偏移 (8 字节对齐, 低 3 位忽略):
//   w_addr < WQ_BYTES  -> 读 WQ 区 (权重 或 Q 量化参数), 返回 64 位
//                         = {WQ32[2k+1], WQ32[2k]}, 低地址字在 w_rdata[31:0]
//   A/B 区 / 空洞 / 越界 -> 返回 64'b0 (不是 X)
//
// 【初始化镜像】
//   WQ 综合: NN_WQ_INIT_A (65536 行) / _B (16384) / _C (8192 @v0.3) /
//            _D (4096 @v0.3), 每行 8 hex = 32 位字; 由 build flow 从单一
//            yolo_wq.hex 顺序切分得到。未定义的宏对应段保持 0。
//   WQ 仿真: +nnwq=<单文件> (契约格式: 94208 行 x 8 hex), 内部逐行分派。
//   激活 A/B **不初始化** (v0.3 取消 NN_ACT_INIT_FILE)。
// ============================================================================

module nn_mem
  import nn_pkg::*;
#(
  parameter int W_BYTES = 320*1024,   // 权重区容量 (字节)
  parameter int Q_BYTES = 48*1024,    // 量化参数区容量 (字节), 紧接 W 区
  parameter int A_BYTES = 96*1024,    // 激活缓冲 A 容量 (字节), 必须是 16 的倍数
  parameter int B_BYTES = 32*1024,    // 激活缓冲 B 容量 (字节), 必须是 16 的倍数
  parameter int CPU_AW  = 19          // CPU 窗口地址位宽 (512KB = 2^19)
)(
  input  logic         clk,
  input  logic         rst,
  // ---- CPU 窗口 (1 拍寄存读, 与 dmem 同口径) ----
  input  logic         cpu_re,
  input  logic         cpu_we,
  input  logic [31:0]  cpu_addr,
  input  logic [31:0]  cpu_wdata,
  input  logic [3:0]   cpu_wstrb,
  output logic [31:0]  cpu_rdata,
  // ---- NPU 权重/Q 参数读口 (64 位/拍, 1 拍延迟) ----
  input  logic         w_re,
  input  logic [23:0]  w_addr,        // NN 窗口内字节偏移 (8 字节对齐)
  output logic [63:0]  w_rdata,
  // ---- NPU 激活读口 (128 位/拍, 1 拍延迟) ----
  input  logic [1:0]   a_sel,         // 0=A, 1=B
  input  logic         a_re,
  input  logic [23:0]  a_addr,        // NN 窗口内字节偏移 (16 字节对齐)
  output logic [127:0] a_rdata,
  // ---- NPU 激活写口 (64 位/拍) ----
  input  logic [1:0]   b_sel,         // 0=A, 1=B
  input  logic         b_we,
  input  logic [23:0]  b_addr,        // NN 窗口内字节偏移 (8 字节对齐)
  input  logic [63:0]  b_wdata
);

  // --------------------------------------------------------------------------
  // 布局常量 (与 nn_pkg.sv / CONTRACT §3 对齐)
  // --------------------------------------------------------------------------
  localparam int WQ_BYTES  = W_BYTES + Q_BYTES;     // 368KB (默认)
  localparam int WQ_WORDS  = WQ_BYTES / 4;          // 94208 (默认)
  localparam int WQ_AW     = $clog2(WQ_WORDS);      // 17
  localparam int ACT_BYTES = A_BYTES + B_BYTES;     // A/B 连续区总容量 (128KB 默认)
  localparam int ACT_WORDS = ACT_BYTES / 16;        // 128 位物理字数 (8192 默认)
  localparam int ACT_AW    = $clog2(ACT_WORDS);     // 13 (128KB)

  localparam logic [31:0] A_OFF = nn_pkg::NN_A_OFF;            // 0x0006_0000
  localparam logic [31:0] B_OFF = nn_pkg::NN_A_OFF + A_BYTES;  // 默认 0x0007_8000
  localparam logic [31:0] WQ_END = WQ_BYTES;
  localparam logic [31:0] A_END  = A_OFF + A_BYTES;            // 0x0007_8000
  localparam logic [31:0] B_END  = B_OFF + B_BYTES;            // 0x0008_0000
  localparam logic [31:0] ACT_END = A_OFF + ACT_BYTES;         // = B_END
  localparam logic [31:0] WIN_BYTES = 32'h1 << CPU_AW;         // 512KB

`ifndef SYNTHESIS
  initial begin
    $display("[nn_mem] CONFIG W_BYTES=%0d Q_BYTES=%0d A_BYTES=%0d B_BYTES=%0d WQ=%0dKB (words=%0d)",
             W_BYTES, Q_BYTES, A_BYTES, B_BYTES, WQ_BYTES/1024, WQ_WORDS);
    $display("[nn_mem] CONFIG A_OFF=0x%05x A_END=0x%05x B_OFF=0x%05x B_END=0x%05x CPU_WIN=0x%05x",
             A_OFF, A_END, B_OFF, B_END, WIN_BYTES);
    if (B_END > WIN_BYTES) begin
      $display("[nn_mem] WARN: B 区尾 0x%05x 超出 CPU 窗口 0x%05x —— BRAM/窗口都放不下",
               B_END, WIN_BYTES);
    end
    if (B_OFF != nn_pkg::NN_B_OFF) begin
      $display("[nn_mem] WARN: B_OFF=0x%05x != nn_pkg::NN_B_OFF=0x%05x (需同步)",
               B_OFF, nn_pkg::NN_B_OFF);
    end
    if (ACT_BYTES % 16 != 0) begin
      $display("[nn_mem] WARN: A+B=%0d 不是 16 的整数倍, 物理阵列舍入", ACT_BYTES);
    end
    if (WQ_WORDS < 81920) begin
      $display("[nn_mem] WARN: WQ_WORDS=%0d < 81920, 4 段拆分假设 W>=320KB, 需重算",
               WQ_WORDS);
    end
  end
`endif

  // --------------------------------------------------------------------------
  // CPU 窗口区域译码 (组合, 与读数据/写通路共用)
  //   0=WQ  1=激活区(A/B 连续, 同一块物理阵列)  3=未映射/空洞/越界 (读 0 / 写忽略)
  // --------------------------------------------------------------------------
  logic [1:0] cpu_sel;
  always_comb begin
    cpu_sel = 2'd3;
    if (cpu_addr < WIN_BYTES) begin
      if (cpu_addr < WQ_END)                           cpu_sel = 2'd0;
      else if (cpu_addr >= A_OFF && cpu_addr < ACT_END) cpu_sel = 2'd1;
      else                                             cpu_sel = 2'd3;
    end
  end

  logic [WQ_AW-1:0] cpu_wq_word;
  assign cpu_wq_word = cpu_addr[WQ_AW+1:2];       // 32 位字地址

  // --------------------------------------------------------------------------
  // NPU 端口地址解析
  // --------------------------------------------------------------------------
  logic [31:0] w_addr32, a_addr32, b_addr32;
  assign w_addr32 = {8'b0, w_addr};
  assign a_addr32 = {8'b0, a_addr};
  assign b_addr32 = {8'b0, b_addr};

  logic w_npu_in_wq;
  assign w_npu_in_wq = (w_addr32 < WQ_END);

  logic a_in_a, a_in_b, b_in_a, b_in_b;
  assign a_in_a = (a_addr32 >= A_OFF) && (a_addr32 < A_END);
  assign a_in_b = (a_addr32 >= B_OFF) && (a_addr32 < B_END);
  assign b_in_a = (b_addr32 >= A_OFF) && (b_addr32 < A_END);
  assign b_in_b = (b_addr32 >= B_OFF) && (b_addr32 < B_END);

  // NPU 选通的区域判定 (sel 与地址归属必须一致, 否则视为非法/未映射 -> 0)
  //   A = [A_OFF, A_END), B = [B_OFF, B_END); 两块在窗口内连续, 共用一块物理阵列。
  logic a_val_act, b_val_act;
  assign a_val_act = a_re && ((a_sel == 2'd0 && a_in_a) || (a_sel == 2'd1 && a_in_b));
  assign b_val_act = b_we && ((b_sel == 2'd0 && b_in_a) || (b_sel == 2'd1 && b_in_b));

  // --------------------------------------------------------------------------
  // WQ 阵列访问 (32 位字, TDP: 口 A 读偶字 / 口 B 读奇字 + CPU 访问)
  //   64 位读 = {口B 的奇字, 口A 的偶字} —— 低地址字在 w_rdata[31:0]
  // --------------------------------------------------------------------------
  logic [WQ_AW-1:0] wq_ra_idx, wq_rb_idx;
  logic             wq_rb_we;
  logic [3:0]       wq_rb_wstrb;
  logic [31:0]      wq_rb_wdata;
  logic [31:0]      wq_ra_data, wq_rb_data;

  logic [WQ_AW-1:0] w_npu_even_word, w_npu_odd_word;
  assign w_npu_even_word = {w_addr[WQ_AW+1:3], 1'b0};   // 8 字节对齐 -> 偶字
  assign w_npu_odd_word  = {w_addr[WQ_AW+1:3], 1'b1};

  // 口 A: NPU 读时取偶字; 否则读 0 号字 (数据不使用, 只为寄存器输出口径统一)
  assign wq_ra_idx  = (w_re && w_npu_in_wq) ? w_npu_even_word : {WQ_AW{1'b0}};
  // 口 B: NPU 读时取奇字; CPU 访问 WQ 区时取 CPU 字地址; 其余读 0
  assign wq_rb_idx  = (w_re && w_npu_in_wq) ? w_npu_odd_word
                    : ((cpu_sel == 2'd0) ? cpu_wq_word : {WQ_AW{1'b0}});
  // 同拍 NPU 优先, CPU 写被丢弃 (busy 期间 CPU 不许访问, 契约 §2)
  assign wq_rb_we    = cpu_we && (cpu_sel == 2'd0) && !(w_re && w_npu_in_wq);
  assign wq_rb_wstrb = cpu_wstrb;
  assign wq_rb_wdata = cpu_wdata;

  logic w_rd_valid_r;
  always @(posedge clk) begin
    if (rst) w_rd_valid_r <= 1'b0;
    else     w_rd_valid_r <= w_re && w_npu_in_wq;
  end
  assign w_rdata = w_rd_valid_r ? {wq_rb_data, wq_ra_data} : 64'b0;

  // --------------------------------------------------------------------------
  // 激活区 (A/B 连续, 共用一块 128 位宽物理阵列)
  //   物理字索引 = addr[ACT_AW+3:4]; A/B 由地址区间自然隔离:
  //   A = [A_OFF, A_END), B = [B_OFF, B_END) = [A_END, ACT_END)
  // --------------------------------------------------------------------------
  logic [ACT_AW-1:0] act_word_addr;
  assign act_word_addr = a_addr[ACT_AW+3:4];       // NPU 读地址
  logic [ACT_AW-1:0] b_act_word, cpu_act_word;
  assign b_act_word   = b_addr[ACT_AW+3:4];        // NPU 写地址
  assign cpu_act_word = cpu_addr[ACT_AW+3:4];      // CPU 访问地址

  // 读口: NPU 优先, 否则 CPU (同一块阵列, 读口共享)
  logic [ACT_AW-1:0] act_rd_idx;
  assign act_rd_idx = a_val_act ? act_word_addr
                    : ((cpu_sel == 2'd1) ? cpu_act_word : {ACT_AW{1'b0}});
  logic [127:0] act_rd_data;

  // ---- 写口: NPU 64 位整字优先, 否则 CPU 字节写 (统一写通路) ----
  logic [15:0]       act_wr_en;
  logic [127:0]      act_wr_data;
  logic [ACT_AW-1:0] act_wr_idx;

  always_comb begin
    act_wr_en   = 16'b0;
    act_wr_data = 128'b0;
    act_wr_idx  = {ACT_AW{1'b0}};

    if (b_val_act) begin
      // NPU 写: 64 位整字, b_addr[3] 选低/高半字
      act_wr_idx  = b_act_word;
      act_wr_en   = b_addr[3] ? 16'hFF00 : 16'h00FF;
      act_wr_data = b_addr[3] ? {b_wdata, 64'b0} : {64'b0, b_wdata};
    end else if (cpu_we && (cpu_sel == 2'd1)) begin
      // CPU 写: 32 位 + 字节使能, cpu_addr[3:2] 选 lane
      act_wr_idx = cpu_act_word;
      case (cpu_addr[3:2])
        2'd0: begin act_wr_en[3:0]   = cpu_wstrb; act_wr_data[31:0]    = cpu_wdata; end
        2'd1: begin act_wr_en[7:4]   = cpu_wstrb; act_wr_data[63:32]   = cpu_wdata; end
        2'd2: begin act_wr_en[11:8]  = cpu_wstrb; act_wr_data[95:64]   = cpu_wdata; end
        default: begin act_wr_en[15:12] = cpu_wstrb; act_wr_data[127:96] = cpu_wdata; end
      endcase
    end
  end

  // ---- NPU 激活读数据: 1 拍延迟 + 区域合法性 (非法/越界 -> 0, 不是 X) ----
  logic a_valid_r;
  always @(posedge clk) begin
    if (rst) a_valid_r <= 1'b0;
    else     a_valid_r <= a_val_act;
  end
  assign a_rdata = a_valid_r ? act_rd_data : 128'b0;

  // --------------------------------------------------------------------------
  // CPU 读数据: 1 拍延迟后的区域/lane 选择 (与 dmem 同口径)
  // --------------------------------------------------------------------------
  logic [1:0] cpu_sel_r, cpu_lane_r;
  always @(posedge clk) begin
    if (rst) begin
      cpu_sel_r  <= 2'd3;
      cpu_lane_r <= 2'd0;
    end else begin
      cpu_sel_r  <= cpu_sel;
      cpu_lane_r <= cpu_addr[3:2];
    end
  end

  logic [31:0] act_lane_data;
  always_comb begin
    case (cpu_lane_r)
      2'd0:    act_lane_data = act_rd_data[31:0];
      2'd1:    act_lane_data = act_rd_data[63:32];
      2'd2:    act_lane_data = act_rd_data[95:64];
      default: act_lane_data = act_rd_data[127:96];
    endcase
  end

  always_comb begin
    case (cpu_sel_r)
      2'd0:    cpu_rdata = wq_rb_data;          // WQ 区 (32 位字)
      2'd1:    cpu_rdata = act_lane_data;       // 激活区 A/B
      default: cpu_rdata = 32'b0;               // 空洞/越界 -> 0 (不是 X)
    endcase
  end

  // --------------------------------------------------------------------------
  // 存储体例化 (行为级推断, 无厂商原语)
  // --------------------------------------------------------------------------
  nn_mem_wq #(
    .TOTAL_WORDS (WQ_WORDS),
    .AW          (WQ_AW)
  ) u_wq (
    .clk      (clk),
    .ra_idx   (wq_ra_idx),
    .ra_data  (wq_ra_data),
    .rb_idx   (wq_rb_idx),
    .rb_we    (wq_rb_we),
    .rb_wstrb (wq_rb_wstrb),
    .rb_wdata (wq_rb_wdata),
    .rb_data  (wq_rb_data)
  );

  // 激活区 A+B (连续 128KB) 共用一块 128 位宽阵列
  nn_mem_act #(
    .BYTES (ACT_BYTES),
    .AW    (ACT_AW)
  ) u_act (
    .clk     (clk),
    .rd_idx  (act_rd_idx),
    .rd_data (act_rd_data),
    .wr_en   (act_wr_en),
    .wr_idx  (act_wr_idx),
    .wr_data (act_wr_data)
  );

endmodule


// ============================================================================
// nn_mem_wq — WQ 区存储体 (32 位字, 真双口 TDP; 按 2 的幂拆 4 段优化 BRAM)
// ----------------------------------------------------------------------------
// 为什么拆 4 段: 见文件头 【WQ 为什么拆成 4 个子阵列】。
//   WQ_A: 65536 words (256KB) -> 64 BRAM36
//   WQ_B: 16384 words ( 64KB) -> 16 BRAM36
//   WQ_C:  8192 words ( 32KB) ->  8 BRAM36
//   WQ_D: TOTAL-90112 words (16KB @ v0.3; 旧 v0.2 配置下不用) -> 4 BRAM36
//   合计 92 (v0.3 默认)。
// 地址映射 (32 位字索引 n; 每段都是 2 的幂大小, 且起点按 2 的幂对齐):
//   0     <= n < 65536          -> WQ_A[n]
//   65536 <= n < 81920          -> WQ_B[n - 65536]      (n[13:0])
//   81920 <= n < 90112          -> WQ_C[n - 81920]      (n[12:0])
//   90112 <= n < TOTAL          -> WQ_D[n - 90112]      (n[11:0])
//
// 每个子阵列 = TDP (口 A 只读 / 口 B 读写 + 字节使能), 两个口同拍各出一个字,
// 下游拼成 64 位 (偶字在低 32 位)。
//
// 初始化:
//   综合: NN_WQ_INIT_A/B/C/D (每行 8 hex, 32 位字; 行数 = 各段字数), 由 build
//         flow 从单一 yolo_wq.hex 顺序切分。未定义的宏对应段保持 0。
//   仿真: +nnwq=<单文件> (契约格式), 内部逐行分派到 4 段。
// ============================================================================
module nn_mem_wq #(
  parameter int TOTAL_WORDS = 94208,   // 32 位字总数 (= WQ_BYTES/4)
  parameter int AW          = 17
)(
  input  logic              clk,
  // 口 A (只读): NPU 64 位读的偶字
  input  logic [AW-1:0]     ra_idx,
  output logic [31:0]       ra_data,
  // 口 B (读写): NPU 64 位读的奇字 / CPU 32 位访问
  input  logic [AW-1:0]     rb_idx,
  input  logic              rb_we,
  input  logic [3:0]        rb_wstrb,
  input  logic [31:0]       rb_wdata,
  output logic [31:0]       rb_data
);

  // ---- 4 段拆分 (均为 2 的幂大小; 只有 D 段大小随 TOTAL_WORDS 变化) ----
  localparam int WA_WORDS = 65536;
  localparam int WB_WORDS = 16384;
  localparam int REST     = TOTAL_WORDS - 65536 - 16384;      // v0.3: 28672
  localparam int WC_WORDS = (REST >= 8192) ? 8192 : REST;     // v0.3: 8192; v0.2: 4096
  localparam int WD_RAW   = REST - WC_WORDS;                  // v0.3: 4096;  v0.2: 0
  localparam int WD_WORDS = (WD_RAW > 0) ? WD_RAW : 1;        // 不允许 0 深度

  localparam int IAW = 16;                    // 65536 -> 16 位
  localparam int IBW = 14;                    // 16384 -> 14 位
  localparam int ICW = $clog2(WC_WORDS);      // 8192 -> 13; 4096 -> 12
  localparam int IDW = (WD_WORDS > 1) ? $clog2(WD_WORDS) : 1;  // D 段可能缺席(旧配置)

  logic [31:0] mem_a [0:WA_WORDS-1];
  logic [31:0] mem_b [0:WB_WORDS-1];
  logic [31:0] mem_c [0:WC_WORDS-1];
  logic [31:0] mem_d [0:WD_WORDS-1];

  localparam logic [AW-1:0] P_B = WA_WORDS[AW-1:0];
  localparam logic [AW-1:0] P_C = (WA_WORDS + WB_WORDS);      // 81920
  localparam logic [AW-1:0] P_D = (WA_WORDS + WB_WORDS + WC_WORDS);  // 90112

  // ---- 端口地址: 按区域取子阵列内的低位地址 ----
  logic [1:0]      ra_sel, rb_sel;
  logic [IAW-1:0]  ra_ia, rb_ia;
  logic [IBW-1:0]  ra_ib, rb_ib;
  logic [ICW-1:0]  ra_ic, rb_ic;
  logic [IDW-1:0]  ra_id, rb_id;
  logic            we_a, we_b, we_c, we_d;

  always_comb begin
    ra_sel = 2'd3;
    if (ra_idx < P_B)       ra_sel = 2'd0;
    else if (ra_idx < P_C)  ra_sel = 2'd1;
    else if (ra_idx < P_D)  ra_sel = 2'd2;

    rb_sel = 2'd3;
    if (rb_idx < P_B)       rb_sel = 2'd0;
    else if (rb_idx < P_C)  rb_sel = 2'd1;
    else if (rb_idx < P_D)  rb_sel = 2'd2;

    ra_ia = (ra_sel == 2'd0) ? ra_idx[IAW-1:0] : {IAW{1'b0}};
    ra_ib = (ra_sel == 2'd1) ? ra_idx[IBW-1:0] : {IBW{1'b0}};
    ra_ic = (ra_sel == 2'd2) ? ra_idx[ICW-1:0] : {ICW{1'b0}};
    ra_id = (ra_sel == 2'd3) ? ra_idx[IDW-1:0] : {IDW{1'b0}};

    rb_ia = (rb_sel == 2'd0) ? rb_idx[IAW-1:0] : {IAW{1'b0}};
    rb_ib = (rb_sel == 2'd1) ? rb_idx[IBW-1:0] : {IBW{1'b0}};
    rb_ic = (rb_sel == 2'd2) ? rb_idx[ICW-1:0] : {ICW{1'b0}};
    rb_id = (rb_sel == 2'd3) ? rb_idx[IDW-1:0] : {IDW{1'b0}};

    we_a = rb_we && (rb_sel == 2'd0);
    we_b = rb_we && (rb_sel == 2'd1);
    we_c = rb_we && (rb_sel == 2'd2);
    we_d = rb_we && (rb_sel == 2'd3);
  end

  // ---- 初始化 ----
  initial begin
    for (int i = 0; i < WA_WORDS; i++) mem_a[i] = 32'h0;
    for (int i = 0; i < WB_WORDS; i++) mem_b[i] = 32'h0;
    for (int i = 0; i < WC_WORDS; i++) mem_c[i] = 32'h0;
    for (int i = 0; i < WD_WORDS; i++) mem_d[i] = 32'h0;
`ifdef SYNTHESIS
`ifdef NN_WQ_INIT_A
    $readmemh(`NN_WQ_INIT_A, mem_a);
`endif
`ifdef NN_WQ_INIT_B
    $readmemh(`NN_WQ_INIT_B, mem_b);
`endif
`ifdef NN_WQ_INIT_C
    $readmemh(`NN_WQ_INIT_C, mem_c);
`endif
`ifdef NN_WQ_INIT_D
    $readmemh(`NN_WQ_INIT_D, mem_d);
`endif
`else
    begin
      string init_file;
      string line;
      int    fd;
      int    idx;
      int    rcode;
      logic [31:0] v;
      if ($value$plusargs("nnwq=%s", init_file)) begin
        fd = $fopen(init_file, "r");
        if (fd == 0) begin
          $display("[nn_mem] WARN: cannot open +nnwq file: %s", init_file);
        end else begin
          idx = 0;
          rcode = $fgets(line, fd);
          while (rcode != 0 && idx < TOTAL_WORDS) begin
            if ($sscanf(line, "%h", v) == 1) begin
              if (idx < WA_WORDS)
                mem_a[idx] = v;
              else if (idx < WA_WORDS + WB_WORDS)
                mem_b[idx - WA_WORDS] = v;
              else if (idx < WA_WORDS + WB_WORDS + WC_WORDS)
                mem_c[idx - WA_WORDS - WB_WORDS] = v;
              else
                mem_d[idx - WA_WORDS - WB_WORDS - WC_WORDS] = v;
              idx = idx + 1;
            end
            rcode = $fgets(line, fd);
          end
          $fclose(fd);
          $display("[nn_mem] WQ image loaded: %s (%0d / %0d words)",
                   init_file, idx, TOTAL_WORDS);
          if (idx != TOTAL_WORDS)
            $display("[nn_mem] WARN: WQ image line count %0d != expected %0d",
                     idx, TOTAL_WORDS);
        end
      end else begin
        $display("[nn_mem] WARN: no +nnwq=<file>, WQ array stays all-zero");
      end
    end
`endif
  end

  // ---- 口 A: 只读 (4 个子阵列同拍读, 输出寄存器后按区域 mux) ----
  logic [31:0] ra_a, ra_b, ra_c, ra_d;
  logic [1:0]  ra_sel_r;
  always @(posedge clk) begin
    ra_a     <= mem_a[ra_ia];
    ra_b     <= mem_b[ra_ib];
    ra_c     <= mem_c[ra_ic];
    ra_d     <= mem_d[ra_id];
    ra_sel_r <= ra_sel;
  end
  assign ra_data = (ra_sel_r == 2'd0) ? ra_a
                 : (ra_sel_r == 2'd1) ? ra_b
                 : (ra_sel_r == 2'd2) ? ra_c : ra_d;

  // ---- 口 B: 读 + 字节写 (每个子阵列一个 always, 推断 TDP) ----
  logic [31:0] rb_a, rb_b, rb_c, rb_d;
  logic [1:0]  rb_sel_r;
  always @(posedge clk) begin
    if (we_a) begin
      if (rb_wstrb[0]) mem_a[rb_ia][7:0]   <= rb_wdata[7:0];
      if (rb_wstrb[1]) mem_a[rb_ia][15:8]  <= rb_wdata[15:8];
      if (rb_wstrb[2]) mem_a[rb_ia][23:16] <= rb_wdata[23:16];
      if (rb_wstrb[3]) mem_a[rb_ia][31:24] <= rb_wdata[31:24];
    end
    rb_a <= mem_a[rb_ia];
  end
  always @(posedge clk) begin
    if (we_b) begin
      if (rb_wstrb[0]) mem_b[rb_ib][7:0]   <= rb_wdata[7:0];
      if (rb_wstrb[1]) mem_b[rb_ib][15:8]  <= rb_wdata[15:8];
      if (rb_wstrb[2]) mem_b[rb_ib][23:16] <= rb_wdata[23:16];
      if (rb_wstrb[3]) mem_b[rb_ib][31:24] <= rb_wdata[31:24];
    end
    rb_b <= mem_b[rb_ib];
  end
  always @(posedge clk) begin
    if (we_c) begin
      if (rb_wstrb[0]) mem_c[rb_ic][7:0]   <= rb_wdata[7:0];
      if (rb_wstrb[1]) mem_c[rb_ic][15:8]  <= rb_wdata[15:8];
      if (rb_wstrb[2]) mem_c[rb_ic][23:16] <= rb_wdata[23:16];
      if (rb_wstrb[3]) mem_c[rb_ic][31:24] <= rb_wdata[31:24];
    end
    rb_c <= mem_c[rb_ic];
  end
  always @(posedge clk) begin
    if (we_d) begin
      if (rb_wstrb[0]) mem_d[rb_id][7:0]   <= rb_wdata[7:0];
      if (rb_wstrb[1]) mem_d[rb_id][15:8]  <= rb_wdata[15:8];
      if (rb_wstrb[2]) mem_d[rb_id][23:16] <= rb_wdata[23:16];
      if (rb_wstrb[3]) mem_d[rb_id][31:24] <= rb_wdata[31:24];
    end
    rb_d <= mem_d[rb_id];
  end
  always @(posedge clk) begin
    rb_sel_r <= rb_sel;
  end
  assign rb_data = (rb_sel_r == 2'd0) ? rb_a
                 : (rb_sel_r == 2'd1) ? rb_b
                 : (rb_sel_r == 2'd2) ? rb_c : rb_d;

endmodule


// ============================================================================
// nn_mem_act — 激活区存储体 (A+B 连续 128KB; 128 位物理字, 1 读 + 1 写, 字节使能)
// ----------------------------------------------------------------------------
// 128 位宽 = 同一 16 字节组的 2 个 64 位字 (契约 §8): NPU 128 位读 1 拍出两个
// 64 位字; NPU 写 64 位用 16 位字节使能只写其中一半; CPU 32 位写只写 4 字节。
// A(96KB)/B(32KB) 是这块阵列里的两个连续地址区间 (见文件头说明)。
// 128KB 时综合实测 32 个 BRAM36 (精确 4KB/BRAM), 见 mem-report.md。
// ============================================================================
module nn_mem_act #(
  parameter int BYTES = 128*1024,
  parameter int AW    = 13
)(
  input  logic          clk,
  input  logic [AW-1:0] rd_idx,
  output logic [127:0]  rd_data,
  input  logic [15:0]   wr_en,
  input  logic [AW-1:0] wr_idx,
  input  logic [127:0]  wr_data
);

  localparam int WORDS = BYTES / 16;

  logic [127:0] mem [0:WORDS-1];

`ifndef SYNTHESIS
  // 仿真: 全 0 初始化 (综合: BRAM INIT 默认全 0, 不需要 initial)
  initial begin
    for (int i = 0; i < WORDS; i++) mem[i] = 128'b0;
  end
`endif

  always @(posedge clk) begin
    if (wr_en[0])  mem[wr_idx][7:0]     <= wr_data[7:0];
    if (wr_en[1])  mem[wr_idx][15:8]    <= wr_data[15:8];
    if (wr_en[2])  mem[wr_idx][23:16]   <= wr_data[23:16];
    if (wr_en[3])  mem[wr_idx][31:24]   <= wr_data[31:24];
    if (wr_en[4])  mem[wr_idx][39:32]   <= wr_data[39:32];
    if (wr_en[5])  mem[wr_idx][47:40]   <= wr_data[47:40];
    if (wr_en[6])  mem[wr_idx][55:48]   <= wr_data[55:48];
    if (wr_en[7])  mem[wr_idx][63:56]   <= wr_data[63:56];
    if (wr_en[8])  mem[wr_idx][71:64]   <= wr_data[71:64];
    if (wr_en[9])  mem[wr_idx][79:72]   <= wr_data[79:72];
    if (wr_en[10]) mem[wr_idx][87:80]   <= wr_data[87:80];
    if (wr_en[11]) mem[wr_idx][95:88]   <= wr_data[95:88];
    if (wr_en[12]) mem[wr_idx][103:96]  <= wr_data[103:96];
    if (wr_en[13]) mem[wr_idx][111:104] <= wr_data[111:104];
    if (wr_en[14]) mem[wr_idx][119:112] <= wr_data[119:112];
    if (wr_en[15]) mem[wr_idx][127:120] <= wr_data[127:120];
    rd_data <= mem[rd_idx];
  end

endmodule
