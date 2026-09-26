`timescale 1ns/1ps

// ============================================================================
// branch_unit.sv — 条件分支判定单元
// ----------------------------------------------------------------------------
// - 独立于 ALU: 分支判定不串到 ALU 关键路径后面;
// - 利用 branch_type_e 的编码结构 (bit[0]=取反, bit[2]/bit[1]=有/无符号):
//     GE=~LT, GEU=~LTU, NE=~EQ  =>  只需 eq/lt/ltu 三个比较器;
// - 非法编码 (3'b010/3'b011, control_unit 不会产生) 落到 default 输出 0,
//   行为确定, 不产生 x。
// ============================================================================

module branch_unit
  import rv32_pkg::*;
#(
  parameter int unsigned XLEN = 32
)(
  input  logic [XLEN-1:0]  rs1,
  input  logic [XLEN-1:0]  rs2,
  input  branch_type_e     branch_type,

  output logic             taken
);

  logic eq, lt, ltu;

  assign eq  = (rs1 == rs2);
  assign lt  = ($signed(rs1) < $signed(rs2));
  assign ltu = (rs1 < rs2);

  always_comb begin
    case (branch_type)
      BR_EQ:  taken = eq;
      BR_NE:  taken = ~eq;
      BR_LT:  taken = lt;
      BR_GE:  taken = ~lt;
      BR_LTU: taken = ltu;
      BR_GEU: taken = ~ltu;
      default: taken = 1'b0;
    endcase
  end

endmodule
