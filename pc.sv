`timescale 1ns/1ps

// ============================================================================
// pc.sv — 程序计数器
// ----------------------------------------------------------------------------
// - 异步高有效复位 rst (与全核统一, 请保持极性一致);
// - stall: 流水线钩子 —— 单周期数据通路下恒接 0; 流水线化后由
//   hazard unit 驱动 (load-use 冒险 / 多周期除法器忙 等);
// - flush/flush_pc: 流水线重定向钩子 —— 分支在 EX 才判定时,
//   错误路径指令已进入流水线, 由 redirect 逻辑发 flush 冲刷并
//   指定恢复地址。优先级高于 stall: 重定向不应被停顿吞掉。
// - pc_src/pc_target: 当周期组合重定向 (单周期分支/跳转), 见
//   rv32_pkg.sv 顶部【数据通路接线契约】。
// ============================================================================

module pc
  import rv32_pkg::*;
#(
  parameter int unsigned   XLEN     = 32,
  parameter logic [XLEN-1:0] RESET_PC = 32'h0000_0000
)(
  input  logic          clk,
  input  logic          rst,

  input  logic          stall,
  input  logic          flush,
  input  logic [XLEN-1:0] flush_pc,

  input  logic          pc_src,      // 0: 顺序下一地址, 1: pc_target
  input  logic [XLEN-1:0] pc_target,

  // 【RVC】顺序下一地址 = pc + 当前指令长度 (16 位指令 +2 / 32 位 +4)。
  // 由上层 (core.sv) 按"当前 pc 配对的那条取指字"算好送进来; C 扩展关闭
  // (C_DIS) 时它恒等于 pc_plus4, 行为与加 C 之前逐位一致。
  // 链接值/分支不跳落点也用同一个"下一条顺序指令地址"(见 core.sv IF 段注释),
  // 所以这里只需要这一个信号, 不再需要单独的 +4 常量。
  input  logic [XLEN-1:0] pc_nxi,

  output logic [XLEN-1:0] pc,
  output logic [XLEN-1:0] pc_plus4
);

  assign pc_plus4 = pc + XLEN'(4);

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      pc <= RESET_PC;
    end
    else if (flush) begin
      pc <= flush_pc;
    end
    else if (!stall) begin
      pc <= pc_src ? pc_target : pc_nxi;
    end
  end

endmodule
