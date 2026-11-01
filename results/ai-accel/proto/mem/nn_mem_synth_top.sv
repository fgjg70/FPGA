`timescale 1ns/1ps

// ============================================================================
// nn_mem_synth_top.sv — nn_mem v0.7 的 Vivado 综合取证专用小顶层
//                       (原型, 不进 RTL 清单)
// ----------------------------------------------------------------------------
// 目的: 证明 v0.7 的存储分解:
//         W  320KB 128-bit 读 -> BRAM36 (~75.5 tiles)
//         Q   48KB  64-bit 读 -> 分布式 ROM/LUTRAM (0 BRAM, ~7,000 LUT)
//         A/B 128KB 128-bit 读写 -> BRAM36 (32 tiles)
//       预期 nn_mem 合计 ~107.5 tiles; 加交付档核心约 9.5 => ~117/135。
// 激励: 自由运行计数器驱动全部端口 (动态地址/写使能), 读出数据异或进探针寄存器,
//       保证存储阵列不被优化掉。地址高位用慢计数器打通, 避免综合器按"地址可达
//       范围"裁剪 RAM 容量 (第一版取证踩过: 只喂窄地址得到虚假偏小的 BRAM 数)。
//       dbg 装载口按 SoC 集成口径 **tie 0**, 写口被常量传播剪掉 -> W/Q 落 ROM。
// ============================================================================

module proto_nn_mem_v07 #(
  parameter int W_BYTES = 320*1024,
  parameter int Q_BYTES = 48*1024,
  parameter int A_BYTES = 96*1024,
  parameter int B_BYTES = 32*1024
)(
  input  logic        clk,
  input  logic        rst,
  output logic [63:0] probe
);

  localparam logic [23:0] A_ADDR = 24'h060000;
  localparam logic [23:0] B_ADDR = 24'(32'h0006_0000 + A_BYTES);

  // ---- 自由运行计数器: cyc 快速 (低地址位), slow 每 65536 拍 +1 (高地址位) ----
  logic [15:0] cyc;
  logic [3:0]  slow;
  always @(posedge clk) begin
    if (rst) begin
      cyc  <= 16'h0;
      slow <= 4'h0;
    end else begin
      cyc <= cyc + 16'h1;
      if (cyc == 16'hFFFF) slow <= slow + 4'h1;
    end
  end

  // ---- CPU 窗口 (只 A/B) ----
  logic        cpu_re, cpu_we;
  logic [31:0] cpu_addr, cpu_wdata, cpu_rdata;
  logic [3:0]  cpu_wstrb;
  // ---- NPU 权重 128b 读 ----
  logic        w_re;
  logic [23:0] w_addr;
  logic [127:0] w_rdata;
  // ---- NPU Q 64b 读 ----
  logic        q_re;
  logic [12:0] q_addr;
  logic [63:0] q_rdata;
  // ---- NPU 激活 128b 读 ----
  logic [1:0]  a_sel;
  logic        a_re;
  logic [23:0] a_addr;
  logic [127:0] a_rdata;
  // ---- NPU 激活 128b 写 ----
  logic [1:0]  b_sel;
  logic        b_we;
  logic [23:0] b_addr;
  logic [127:0] b_wdata;
  logic [15:0] b_wstrb;

  logic [23:0] act_off, b_act_off;

  always_comb begin
    // 激活区地址: 覆盖 A+B 整个连续区 (128KB), 16 字节对齐
    act_off   = A_ADDR + {6'h0, slow[0], cyc[15:4], 4'h0};
    b_act_off = A_ADDR + {6'h0, slow[0], cyc[15:4], 4'h0};

    // CPU: 4 个 32-bit lane 都可写, 地址只落在 A/B (区域内滚动)
    cpu_re    = 1'b1;
    cpu_we    = cyc[4];
    cpu_addr  = 32'(act_off) + {29'h0, cyc[1:0], 1'b0};
    cpu_wdata = {cyc[7:0], cyc[7:0], cyc[15:0]};
    cpu_wstrb = cyc[9:6];

    // W: 128-bit 读, 覆盖 0..0x4FFFF (越界读回 0); 8B 对齐 (bit3 也动态 ->
    //    强制综合出 cur/next 两个读口, 验证 2 读口不额外占 BRAM)
    w_re      = cyc[2];
    w_addr    = {5'h0, slow[1:0], cyc[12:0], cyc[15], 3'h0};

    // Q: 64-bit 读, 13 位索引全域可达 (越界读回 0)
    q_re      = cyc[3];
    q_addr    = cyc[12:0];

    // 激活读: sel 由落在 A 还是 B 决定; 16B 对齐
    a_addr    = act_off;
    a_sel     = (a_addr >= B_ADDR) ? 2'd1 : 2'd0;
    a_re      = cyc[3];

    // 激活写: 128b + 16 字节使能 (全域可达)
    b_addr    = b_act_off;
    b_sel     = (b_addr >= B_ADDR) ? 2'd1 : 2'd0;
    b_we      = cyc[5];
    b_wdata   = {cyc, cyc, cyc, cyc, cyc, cyc, cyc, cyc};
    b_wstrb   = {cyc[15:8], cyc[7:0]} ^ {16{cyc[6]}};
  end

  // 读出数据必须被消费, 否则存储体会被优化掉
  always @(posedge clk) begin
    probe <= cpu_rdata
           ^ w_rdata[63:0] ^ w_rdata[127:64]
           ^ q_rdata
           ^ a_rdata[63:0] ^ a_rdata[127:64]
           ^ b_wdata[63:0];
  end

  nn_mem #(
    .W_BYTES (W_BYTES),
    .Q_BYTES (Q_BYTES),
    .A_BYTES (A_BYTES),
    .B_BYTES (B_BYTES),
    .CPU_AW  (19)
  ) u_dut (
    .clk       (clk),
    .rst       (rst),
    .cpu_re    (cpu_re),
    .cpu_we    (cpu_we),
    .cpu_addr  (cpu_addr),
    .cpu_wdata (cpu_wdata),
    .cpu_wstrb (cpu_wstrb),
    .cpu_rdata (cpu_rdata),
    .w_re      (w_re),
    .w_addr    (w_addr),
    .w_rdata   (w_rdata),
    .q_re      (q_re),
    .q_addr    (q_addr),
    .q_rdata   (q_rdata),
    .a_sel     (a_sel),
    .a_re      (a_re),
    .a_addr    (a_addr),
    .a_rdata   (a_rdata),
    .b_sel     (b_sel),
    .b_we      (b_we),
    .b_addr    (b_addr),
    .b_wdata   (b_wdata),
    .b_wstrb   (b_wstrb),
    // SoC 集成口径: debug 装载口恒 0 (module 级 TB 才用)
    .dbg_we    (1'b0),
    .dbg_space (1'b0),
    .dbg_addr  (17'd0),
    .dbg_wdata (32'd0)
  );

endmodule
