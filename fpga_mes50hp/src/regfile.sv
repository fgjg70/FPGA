`timescale 1ns/1ps

// ============================================================================
// regfile.sv — 整数寄存器堆 (2 读 1 写, x0 恒零)
// ----------------------------------------------------------------------------
// - 读端口为组合 (异步) 读: 单周期数据通路的正确选择, 且综合到
//   Xilinx FPGA 时自动推断 LUTRAM (distributed RAM), 零 BRAM 开销;
// - 【流水线化时的改造点】3/5 级流水线通常把读寄存器放 ID 段并打一拍,
//   届时把本模块改为同步读 (BRAM), 对外接口不变, 只有数据晚一拍;
//   写写同周期冲突由前递/写优先旁路解决, 不在寄存器堆内处理;
// - x0 读出恒 0; 对 x0 的写被忽略 (写使能与地址同判, 不多花逻辑);
// - 上电全零初始化: RISC-V 只保证 x0=0, 其余寄存器架构上无定义,
//   全零化使仿真行为确定, 避免未写先读的 x 传播干扰调试。
// ============================================================================

module regfile
  import rv32_pkg::*;
#(
  parameter int unsigned XLEN     = 32,
  parameter int unsigned NUM_REGS = 32
)(
  input  logic clk,

  input  logic                   we,
  input  logic [$clog2(NUM_REGS)-1:0] waddr,
  input  logic [XLEN-1:0]        wdata,

  input  logic [$clog2(NUM_REGS)-1:0] raddr1,
  input  logic [$clog2(NUM_REGS)-1:0] raddr2,
  output logic [XLEN-1:0]        rdata1,
  output logic [XLEN-1:0]        rdata2,

  // 调试读口 (testbench / ILA 用; 不参与数据通路, 可悬空)
  input  logic [$clog2(NUM_REGS)-1:0] dbg_raddr,
  output logic [XLEN-1:0]             dbg_rdata
);

  logic [XLEN-1:0] mem [NUM_REGS];

  initial begin
`ifdef SYNTHESIS
    $readmemh("firmware/regfile_zero.hex", mem);
`else
    for (int i = 0; i < NUM_REGS; i++) begin
      mem[i] = '0;
    end
`endif
  end

  // 这里用 always 而不是 always_ff: mem 同时被上面的 initial 块初始化, 而
  // SystemVerilog LRM 禁止 always_ff 驱动的变量再被其它进程驱动 —— ModelSim
  // 会直接报 vopt-7061 并拒绝优化 (iverilog 不报, 所以这个坑只有换工具才暴露)。
  // always 没有该限制, 综合结果与 always_ff 完全相同。
  always @(posedge clk) begin
    if (we && (waddr != '0)) begin
      mem[waddr] <= wdata;
    end
  end

  // 读端口带写旁路 (write-first / internal forwarding):
  // 同一周期内 WB 正在写的寄存器, ID 组合读必须立刻看到新值。这是 5 级
  // 流水线处理"距离 3"RAW 依赖的标准手段 (距离 1/2 由 hazard_unit 前递)。
  // 注意: 仅靠 mem[] 的 NBA 更新是不够的 —— 读数据在时钟沿前就被
  // ID/EX 锁存了, 等不到 mem 更新。
  assign rdata1 = (raddr1 == '0) ? '0 :
                  ((we && (waddr == raddr1)) ? wdata : mem[raddr1]);
  assign rdata2 = (raddr2 == '0) ? '0 :
                  ((we && (waddr == raddr2)) ? wdata : mem[raddr2]);
  assign dbg_rdata = mem[dbg_raddr];

endmodule
