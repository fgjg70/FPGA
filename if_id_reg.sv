`timescale 1ns/1ps

// ============================================================================
// if_id_reg.sv — IF/ID 流水寄存器
// ----------------------------------------------------------------------------
// flush (重定向/冲刷) 优先级高于 stall (停顿): 但两者由 hazard_unit 保证
// 互斥 (重定向信号被停顿门控), 此处顺序仅为防御性写法。
// 气泡用真实 NOP 指令编码表示 (写 x0, 无副作用), 不需要 valid 位。
// ============================================================================

module if_id_reg
  import rv32_pkg::*;
#(
  parameter logic [31:0] RESET_PC = PC_RESET
)(
  input  logic        clk,
  input  logic        rst,
  input  logic        flush,
  input  logic        stall,

  input  logic [31:0] pc_in,
  input  logic [31:0] pc_plus4_in,
  input  logic [31:0] instr_in,

  output logic [31:0] pc,
  output logic [31:0] pc_plus4,
  output logic [31:0] instr
);

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      pc       <= RESET_PC;
      pc_plus4 <= RESET_PC;
      instr    <= INSTR_NOP;
    end
    else if (flush) begin
      pc       <= '0;
      pc_plus4 <= '0;
      instr    <= INSTR_NOP;
    end
    else if (!stall) begin
      pc       <= pc_in;
      pc_plus4 <= pc_plus4_in;
      instr    <= instr_in;
    end
  end

endmodule
