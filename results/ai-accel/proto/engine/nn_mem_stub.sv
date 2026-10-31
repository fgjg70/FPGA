`timescale 1ns/1ps

// ============================================================================
// nn_mem_stub.sv — T-accel 自测用的**临时**行为级 nn_mem 替身
// ----------------------------------------------------------------------------
// 只用于 results/ai-accel/proto/engine/ 下跑 nn_conv_engine 的 TB;
// **不**进根目录 RTL 清单, 真实 nn_mem.sv 由 T-mem 实现。
//
// 行为口径 (与 T-mem 2026-10-31 确认):
//   · w 口: w_addr = NN 窗口内字节偏移; < WQ_BYTES -> WQ 32 位字阵列,
//           一次 64 位 = {WQ[addr/4+1], WQ[addr/4]} (低地址在低 32 位);
//           越界 -> 64'b0.  1 拍寄存读.
//   · a 口: a_sel=0/1 -> A/B 64 位字阵列; a_rdata = {word[idx+1], word[idx]}
//           (低地址 64 位在 [63:0]); a_addr[3:0] 忽略 (16 字节对齐). 1 拍读.
//   · b 口: 64 位整字写, 低地址字节落 b_wdata[7:0].
//   · CPU 窗口: 本 TB 不用, rdata 恒 0, 写忽略.
// ============================================================================

module nn_mem
  import nn_pkg::*;
#(
  parameter int W_BYTES = NN_W_BYTES,
  parameter int Q_BYTES = NN_Q_BYTES,
  parameter int A_BYTES = NN_ACT_BYTES
)(
  input  logic         clk,
  input  logic         rst,
  input  logic         cpu_re,
  input  logic         cpu_we,
  input  logic [31:0]  cpu_addr,
  input  logic [31:0]  cpu_wdata,
  input  logic [3:0]   cpu_wstrb,
  output logic [31:0]  cpu_rdata,
  input  logic         w_re,
  input  logic [23:0]  w_addr,
  output logic [63:0]  w_rdata,
  input  logic [1:0]   a_sel,
  input  logic         a_re,
  input  logic [23:0]  a_addr,
  output logic [127:0] a_rdata,
  input  logic [1:0]   b_sel,
  input  logic         b_we,
  input  logic [23:0]  b_addr,
  input  logic [63:0]  b_wdata
);

  localparam int WQ_WORDS  = (W_BYTES + Q_BYTES) / 4;
  localparam int ACT_WORDS = A_BYTES / 8;
  localparam logic [23:0] A_OFF = NN_A_OFF[23:0];
  localparam logic [23:0] B_OFF = NN_B_OFF[23:0];

  logic [31:0] wq   [0:WQ_WORDS-1];
  logic [63:0] amem [0:ACT_WORDS-1];
  logic [63:0] bmem [0:ACT_WORDS-1];

  // 上电清 0; TB 用 $readmemh 覆盖使用区 (其余保持 0, 与综合镜像一致)
  initial begin
    for (int i = 0; i < WQ_WORDS; i++) wq[i] = 32'd0;
    for (int i = 0; i < ACT_WORDS; i++) begin
      amem[i] = 64'd0;
      bmem[i] = 64'd0;
    end
  end

  wire [23:0] wq_bytes = W_BYTES[23:0] + Q_BYTES[23:0];

  always @(posedge clk) begin
    if (w_re) begin
      if ({1'b0, w_addr} < {1'b0, wq_bytes})
        w_rdata <= {wq[(w_addr >> 2) + 1], wq[w_addr >> 2]};
      else
        w_rdata <= 64'd0;
    end
  end

  wire [12:0] a_idx = a_sel[0] ? ((a_addr - B_OFF) >> 3) : ((a_addr - A_OFF) >> 3);
  always @(posedge clk) begin
    if (a_re) begin
      if (!a_sel[0]) a_rdata <= {amem[a_idx + 1], amem[a_idx]};
      else           a_rdata <= {bmem[a_idx + 1], bmem[a_idx]};
    end
  end

  wire [12:0] b_idx = b_sel[0] ? ((b_addr - B_OFF) >> 3) : ((b_addr - A_OFF) >> 3);
  always @(posedge clk) begin
    if (b_we) begin
      if (!b_sel[0]) amem[b_idx] <= b_wdata;
      else           bmem[b_idx] <= b_wdata;
    end
  end

  assign cpu_rdata = 32'd0;

endmodule
