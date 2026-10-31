`timescale 1ns/1ps

// ============================================================================
// nn_mem_synth_top.sv — nn_mem 的 Vivado 综合取证专用小顶层 (原型, 不进 RTL 清单)
// ----------------------------------------------------------------------------
// 目的: 证明 nn_mem 的存储体行为级推断成 BRAM36 (不是 LUTRAM), 并给出
//       v0.3.2 交付配置与旧契约(超限)配置两套 BRAM 数字。
// 激励: 自由运行计数器驱动全部端口 (动态地址/写使能), 读出数据异或进探针寄存器,
//       保证存储阵列不被综合优化掉 (有写口 + 动态读地址 + 输出被消费)。
//       地址高位用慢计数器打通, 避免综合器按"地址可达范围"裁剪 RAM 容量。
//
// 两个包装顶层 (tcl 用 -top 选择):
//   proto_nn_mem_v03 : W=320K, Q=48K, A=96K, B=32K
//                      → 预期 WQ 92 + 激活(A+B=128K) 32 = 124 BRAM36
//   proto_nn_mem_v02 : W=320K, Q=16K, A=B=128K (旧契约)
//                      → 预期 WQ 84 + 激活(256K) 64 = 148 BRAM36 (>135)
// ============================================================================

module proto_nn_mem #(
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

  // ---- 自由运行计数器 ----
  // cyc: 快速计数 (低地址位); slow: 每 65536 拍 +1 (高地址位)。
  // 为什么要慢计数器: 综合器会做"地址可达范围"裁剪 —— 如果读写地址永远只落在
  // 存储器的前 4KB, 它可以把整个 RAM 缩小, 从而得出偏小的 BRAM 数字。这里让
  // 全部地址位都动态可达 (覆盖整个阵列), 得到的是**真实容量对应的 BRAM 数**。
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

  // ---- CPU 窗口 ----
  logic        cpu_re, cpu_we;
  logic [31:0] cpu_addr, cpu_wdata, cpu_rdata;
  logic [3:0]  cpu_wstrb;
  // ---- NPU 权重/Q 读口 ----
  logic        w_re;
  logic [23:0] w_addr;
  logic [63:0] w_rdata;
  // ---- NPU 激活读口 ----
  logic [1:0]  a_sel;
  logic        a_re;
  logic [23:0] a_addr;
  logic [127:0] a_rdata;
  // ---- NPU 激活写口 ----
  logic [1:0]  b_sel;
  logic        b_we;
  logic [23:0] b_addr;
  logic [63:0] b_wdata;

  logic [23:0] act_off, b_act_off;

  always_comb begin
    // 激活区地址: 覆盖 A+B 整个连续区 (v0.3 128KB / v0.2 256KB), 16 字节对齐
    act_off   = {6'h0, slow[1:0], cyc[15:4], 4'h0};
    b_act_off = act_off + {20'h0, cyc[3], 3'h0};

    // CPU: 32 位地址覆盖整个 512KB 窗口 (bit[3:2] 也在变 -> 4 个 lane 都可写)
    cpu_re    = 1'b1;
    cpu_we    = cyc[4];
    cpu_addr  = {13'h0, slow[3:0], cyc[15:5], cyc[4:3], 2'h0};
    cpu_wdata = {cyc[7:0], cyc[7:0], cyc[15:0]};
    cpu_wstrb = cyc[9:6];
    // w 口: 8 字节对齐, 覆盖 0..0x7FFF8 (含整个 WQ 368KB; 其余区域读回 0)
    w_re      = cyc[2];
    w_addr    = {5'h0, cyc[15:0], 3'h0};
    // 激活读: 绝对地址, sel 由落在 A 还是 B 决定
    a_addr    = A_ADDR + act_off;
    a_sel     = (a_addr >= B_ADDR) ? 2'd1 : 2'd0;
    a_re      = cyc[3];
    // 激活写: 64 位整字, 覆盖整个 A+B 区; b_addr[3] 在变 (高低半字都写)
    b_addr    = A_ADDR + b_act_off;
    b_sel     = (b_addr >= B_ADDR) ? 2'd1 : 2'd0;
    b_we      = cyc[5];
    b_wdata   = {cyc, cyc, cyc, cyc};
  end

  // 读出数据必须被消费, 否则存储体会被优化掉
  always @(posedge clk) begin
    probe <= cpu_rdata ^ w_rdata ^ a_rdata[63:0] ^ a_rdata[127:64] ^ b_wdata;
  end

  nn_mem #(
    .W_BYTES (W_BYTES),
    .Q_BYTES (Q_BYTES),
    .A_BYTES (A_BYTES),
    .B_BYTES (B_BYTES),
    .CPU_AW  (19)
  ) u_dut (
    .clk      (clk),
    .rst      (rst),
    .cpu_re   (cpu_re),
    .cpu_we   (cpu_we),
    .cpu_addr (cpu_addr),
    .cpu_wdata(cpu_wdata),
    .cpu_wstrb(cpu_wstrb),
    .cpu_rdata(cpu_rdata),
    .w_re     (w_re),
    .w_addr   (w_addr),
    .w_rdata  (w_rdata),
    .a_sel    (a_sel),
    .a_re     (a_re),
    .a_addr   (a_addr),
    .a_rdata  (a_rdata),
    .b_sel    (b_sel),
    .b_we     (b_we),
    .b_addr   (b_addr),
    .b_wdata  (b_wdata)
  );

endmodule


// v0.3.2 交付配置
module proto_nn_mem_v03 (
  input  logic        clk,
  input  logic        rst,
  output logic [63:0] probe
);
  proto_nn_mem #(
    .W_BYTES (320*1024),
    .Q_BYTES (48*1024),
    .A_BYTES (96*1024),
    .B_BYTES (32*1024)
  ) u_proto (
    .clk  (clk),
    .rst  (rst),
    .probe(probe)
  );
endmodule


// 旧契约默认配置 (用于证明"旧尺寸会超器件预算": 148 > 135)
module proto_nn_mem_v02 (
  input  logic        clk,
  input  logic        rst,
  output logic [63:0] probe
);
  proto_nn_mem #(
    .W_BYTES (320*1024),
    .Q_BYTES (16*1024),
    .A_BYTES (128*1024),
    .B_BYTES (128*1024)
  ) u_proto (
    .clk  (clk),
    .rst  (rst),
    .probe(probe)
  );
endmodule
