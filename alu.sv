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

  output logic [XLEN-1:0] out
);

  localparam int unsigned SHAMT_W = $clog2(XLEN);

  logic [XLEN-1:0] sum, diff, and_out, or_out, xor_out, sll_out, srl_out, sra_out;
  logic            slt, sltu;

  assign sum     = a + b;
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
      // ALU_MUL..ALU_REMU (RV32M 预留) 与其它未用编码落到这里
      default:  out = 'x;
    endcase
  end

endmodule