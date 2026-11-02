`timescale 1ns/1ps
// ============================================================================
// nn_mem_v07_stub.sv —— 引擎 v3 开发用 **行为级** v0.7 内存模型（不进 RTL 清单）
//
// 目的：t-mem 的真 nn_mem v0.7 未落地前，给 128 MAC 引擎提供同口径端口：
//   W  320KB : NPU 128-bit 读 (w_re/w_addr/w_rdata[127:0], 1 拍), 4 段 $readmemh 不做,
//              改由 TB 通过 dbg 端口预装 (向量来自 gen_vectors 的 wq.wr)
//   Q   48KB : NPU 64-bit 读 (q_re/q_addr[12:0]/q_rdata), 1 拍; q_addr = 64b 字索引
//   A/B 128KB: NPU 128b 读 (a_sel/a_re/a_addr/a_rdata) + 128b 写 + b_wstrb[15:0]
//              CPU 窗口只映射 A/B (1 拍寄存读/字节写)
//
// 地址口径与 CONTRACT v0.7 一致：
//   w_addr = W 区字节偏移 (8 字节对齐, 低 3 位忽略); 返回 w_addr..w_addr+15 共 16B,
//            低地址字节在 w_rdata[7:0] (…w_rdata[127:120] = 最高字节)
//   q_addr = Q 区 64-bit 字索引
//   a/b_addr = NN 窗口内字节偏移 (A=NN_A_OFF, B=NN_B_OFF); a 读 16B 对齐窗口
// ============================================================================
module nn_mem_v07_stub
  import nn_pkg::*;
#(
  parameter int W_BYTES = 320*1024,
  parameter int Q_BYTES = 48*1024,
  parameter int A_BYTES = 96*1024,
  parameter int B_BYTES = 32*1024,
  parameter int W_LAT   = 1        // 1=1 拍; 2=额外寄存 w_re/w_addr 一拍 (模拟 nn_mem_pipe)
)(
  input  logic         clk,
  input  logic         rst,
  // ---- CPU 窗口 (仅 A/B) ----
  input  logic         cpu_re,
  input  logic         cpu_we,
  input  logic [31:0]  cpu_addr,
  input  logic [31:0]  cpu_wdata,
  input  logic [3:0]   cpu_wstrb,
  output logic [31:0]  cpu_rdata,
  // ---- NPU 权重读口 (128 位/拍) ----
  input  logic         w_re,
  input  logic [23:0]  w_addr,
  output logic [127:0] w_rdata,
  // ---- NPU Q 读口 (64 位/拍, 64b 字索引) ----
  input  logic         q_re,
  input  logic [12:0]  q_addr,
  output logic [63:0]  q_rdata,
  // ---- NPU 激活读口 (128 位/拍) ----
  input  logic [1:0]   a_sel,
  input  logic         a_re,
  input  logic [23:0]  a_addr,
  output logic [127:0] a_rdata,
  // ---- NPU 激活写口 (128 位/拍 + 字节 strobe) ----
  input  logic [1:0]   b_sel,
  input  logic         b_we,
  input  logic [23:0]  b_addr,
  input  logic [127:0] b_wdata,
  input  logic [15:0]  b_wstrb,
  // ---- TB debug 预装口 (W/Q 初始化; 行为模型专用, 不进真 nn_mem) ----
  input  logic         dbg_we,
  input  logic         dbg_space,        // 0=W, 1=Q
  input  logic [16:0]  dbg_addr,         // 32-bit 字索引
  input  logic [31:0]  dbg_wdata
);

  localparam int W_WORDS   = W_BYTES / 4;        // 81,920
  localparam int Q_WORDS   = Q_BYTES / 4;        // 12,288
  localparam int ACT_BYTES = A_BYTES + B_BYTES;  // 128KB
  localparam int ACT_WORDS = ACT_BYTES / 16;     // 8192 (128b 物理字)

  logic [31:0]  w_mem [0:W_WORDS-1];
  logic [31:0]  q_mem [0:Q_WORDS-1];
  logic [127:0] act_mem [0:ACT_WORDS-1];

  // ---------------------------------------------------------------- 地址译码
  // a/b: 窗口内偏移 -> A/B 连续阵列的 128b 字索引; 越界返回 0 / 写忽略
  function automatic logic [12:0] act_idx(input logic [1:0] sel,
                                          input logic [23:0] addr,
                                          input int unsigned total_words);
    logic [31:0] off;
    off = (sel == 2'd1) ? (32'(addr) - NN_B_OFF) : (32'(addr) - NN_A_OFF);
    if (sel == 2'd1) begin
      if (32'(addr) < NN_B_OFF || 32'(addr) >= NN_B_OFF + B_BYTES) return 13'd0;
      off = off + A_BYTES;
    end
    else begin
      if (32'(addr) < NN_A_OFF || 32'(addr) >= NN_A_OFF + A_BYTES) return 13'd0;
    end
    if ((off >> 4) >= total_words) return 13'd0;
    act_idx = 13'(off >> 4);
  endfunction

  // A/B 窗口内平坦字节偏移 (A/B 连续阵列)
  function automatic logic [31:0] act_flat(input logic [1:0] sel, input logic [23:0] addr);
    begin
      if (sel == 2'd1) act_flat = 32'(addr) - NN_B_OFF + A_BYTES;
      else             act_flat = 32'(addr) - NN_A_OFF;
    end
  endfunction

  function automatic logic act_ok(input logic [1:0] sel, input logic [23:0] addr);
    begin
      act_ok = (sel == 2'd1)
               ? ((32'(addr) >= NN_B_OFF) && (32'(addr) < NN_B_OFF + B_BYTES))
               : ((32'(addr) >= NN_A_OFF) && (32'(addr) < NN_A_OFF + A_BYTES));
    end
  endfunction

  wire [31:0] a_flat = act_flat(a_sel, a_addr);
  wire [31:0] b_flat = act_flat(b_sel, b_addr);
  wire        a_ok   = act_ok(a_sel, a_addr);
  wire        b_ok   = act_ok(b_sel, b_addr);
  wire [12:0] a_idx  = 13'(a_flat >> 4);
  wire [12:0] b_idx  = 13'(b_flat >> 4);
  wire [3:0]  b_boff = 4'(b_flat[3:0]);

  // ---------------------------------------------------------------- CPU 窗口
  wire cpu_in_a = (cpu_addr >= NN_A_OFF) && (cpu_addr < NN_A_OFF + A_BYTES);
  wire cpu_in_b = (cpu_addr >= NN_B_OFF) && (cpu_addr < NN_B_OFF + B_BYTES);
  wire cpu_ok   = cpu_in_a || cpu_in_b;
  wire [31:0] cpu_flat = cpu_in_b ? (32'(cpu_addr) - NN_B_OFF + A_BYTES)
                                  : (32'(cpu_addr) - NN_A_OFF);
  wire [12:0] cpu_w128 = 13'(cpu_flat >> 4);
  wire [3:0]  cpu_lane = 4'(cpu_flat[3:0]);

  logic [31:0] cpu_rdata_r;
  always @(posedge clk) begin
    if (!cpu_ok) cpu_rdata_r <= 32'd0;
    else begin
      case (cpu_lane)
        4'd0, 4'd4, 4'd8, 4'd12: cpu_rdata_r <= act_mem[cpu_w128][cpu_flat[3:0]*8 +: 32];
        default:                 cpu_rdata_r <= 32'd0;
      endcase
    end
  end
  assign cpu_rdata = cpu_rdata_r;

  // ---------------------------------------------------------------- W 读
  logic [127:0] w_rdata_r;
  logic         w_re_d;
  logic [23:0]  w_addr_d;
  always @(posedge clk) begin
    w_re_d   <= w_re;
    w_addr_d <= w_addr;
  end
  wire        w_re_e   = (W_LAT >= 2) ? w_re_d   : w_re;
  wire [23:0] w_addr_e = (W_LAT >= 2) ? w_addr_d : w_addr;
  always @(posedge clk) begin
    begin : w_rd
      logic [16:0] wa;
      wa = 17'(w_addr_e >> 2);   // 32-bit 字索引
      if (!w_re_e || (w_addr_e >= W_BYTES)) w_rdata_r <= 128'd0;
      else w_rdata_r <= {w_mem[wa + 17'd3], w_mem[wa + 17'd2],
                         w_mem[wa + 17'd1], w_mem[wa]};
    end
  end
  assign w_rdata = w_rdata_r;

  // ---------------------------------------------------------------- Q 读
  logic [63:0] q_rdata_r;
  always @(posedge clk) begin
    if (!q_re) q_rdata_r <= 64'd0;
    else q_rdata_r <= {q_mem[{q_addr, 1'b1}], q_mem[{q_addr, 1'b0}]};
  end
  assign q_rdata = q_rdata_r;

  // ---------------------------------------------------------------- A 读
  logic [127:0] a_rdata_r;
  always @(posedge clk) begin
    if (!a_re || !a_ok) a_rdata_r <= 128'd0;
    else                a_rdata_r <= act_mem[a_idx];
  end
  assign a_rdata = a_rdata_r;

  // ---------------------------------------------------------------- B 写 + 预装
  always @(posedge clk) begin
    if (b_we && b_ok) begin
      for (int i = 0; i < 16; i++) begin
        if (b_wstrb[i] && ((16'(b_boff) + 16'(i)) < 16))
          act_mem[b_idx][(b_boff + i[3:0])*8 +: 8] <= b_wdata[i*8 +: 8];
      end
    end
    if (cpu_we && cpu_ok) begin
      for (int i = 0; i < 4; i++) begin
        if (cpu_wstrb[i]) act_mem[cpu_w128][cpu_lane*8 + i*8 +: 8] <= cpu_wdata[i*8 +: 8];
      end
    end
    if (dbg_we) begin
      if (dbg_space) q_mem[dbg_addr[13:0]] <= dbg_wdata;
      else           w_mem[dbg_addr[16:0]] <= dbg_wdata;
    end
  end

  // ---------------------------------------------------------------- 初始化
  initial begin
    for (int i = 0; i < W_WORDS; i++)   w_mem[i]   = 32'd0;
    for (int i = 0; i < Q_WORDS; i++)   q_mem[i]   = 32'd0;
    for (int i = 0; i < ACT_WORDS; i++) act_mem[i] = 128'd0;
  end

endmodule
