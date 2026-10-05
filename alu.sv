`timescale 1ns/1ps

// ============================================================================
// alu.sv — RV32I 算术逻辑单元
// ----------------------------------------------------------------------------
// - 操作码 alu_op_e 定义于 rv32_pkg (5 位, 含 RV32M 预留编码);
// - 旧设计的 zero 输出已删除: 分支比较由独立的 branch_unit 完成,
//   不应把分支判定串到 ALU 关键路径后面 (MIPS 遗留思路);
// - 未实现的编码 (含 M 预留) 输出 x: 仿真中一旦出现 x 即说明
//   译码或数据通路把不该送进来的编码送进来了 —— 快速暴露集成 bug;
// - 移位量取低 log2(XLEN) 位, 与 RISC-V 规范一致 (移位量来自寄存器时
//   高位被忽略; imm_gen 产生的 shamt 本身就在 imm[4:0])。
// ============================================================================

module alu
  import rv32_pkg::*;
#(
  parameter int unsigned XLEN = 32
)(
  input  logic [XLEN-1:0] a,
  input  logic [XLEN-1:0] b,
  input  alu_op_e         op,

  output logic [XLEN-1:0] out,

  // 原始加法器输出 (未经操作码 mux)。
  // 【为什么单独引出】BR/JAL/JALR 的 alu_op 恒为 ALU_ADD, 跳转目标就等于 sum;
  // 直接从加法器出口取, 可以少走 ALU 的结果 mux (约 2 级 LUT) —— 那几级正好
  // 在 pc 的关键路径上 (实测逻辑 3.7ns / 布线 11ns)。零面积代价。
  output logic [XLEN-1:0] sum_out
);

  localparam int unsigned SHAMT_W = $clog2(XLEN);

  logic [XLEN-1:0] sum, diff, and_out, or_out, xor_out, sll_out, srl_out, sra_out;
  logic            slt, sltu;

  assign sum     = a + b;
  assign sum_out = sum;
  assign diff    = a - b;
  assign and_out = a & b;
  assign or_out  = a | b;
  assign xor_out = a ^ b;
  assign sll_out = a << b[SHAMT_W-1:0];
  assign srl_out = a >> b[SHAMT_W-1:0];
  assign sra_out = $signed(a) >>> b[SHAMT_W-1:0];
  assign slt     = $signed(a) < $signed(b);
  assign sltu    = a < b;

  always_comb begin
    case (op)
      ALU_ADD:  out = sum;
      ALU_SUB:  out = diff;
      ALU_AND:  out = and_out;
      ALU_OR:   out = or_out;
      ALU_XOR:  out = xor_out;
      ALU_SLL:  out = sll_out;
      ALU_SRL:  out = srl_out;
      ALU_SRA:  out = sra_out;
      ALU_SLT:  out = {{(XLEN-1){1'b0}}, slt};
      ALU_SLTU: out = {{(XLEN-1){1'b0}}, sltu};
      // RV32M 的算符由 core 里的 muldiv 单元负责, 本模块对它们输出 0 而不是 'x:
      // 这些编码现在是 *合法输入*, 若输出 'x 会沿 ex_mem_alu_out 传播,
      // 污染前递与调试观测。真正非法的编码由 control_unit 拦截。
      ALU_MUL, ALU_MULH, ALU_MULHSU, ALU_MULHU,
      ALU_DIV, ALU_DIVU, ALU_REM,   ALU_REMU: out = '0;
      default:  out = 'x;
    endcase
  end

endmodule