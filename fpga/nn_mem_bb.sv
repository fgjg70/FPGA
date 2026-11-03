// nn_mem 黑盒 stub (自动生成, 勿手改; 由 tools/gen_nn_mem_bb.py 从 nn_mem.sv 提取)
// 整机综合时替换 nn_mem.sv, 综合后用 read_checkpoint -cell u_nn/u_mem <dcp> 链接 OOC 结果。
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
  // 空 body -> Vivado black box
endmodule
