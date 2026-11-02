`timescale 1ns/1ps

// ============================================================================
// imm_gen.sv — 立即数生成器 (I/S/B/U/J 五种格式)
// ----------------------------------------------------------------------------
// - fmt 由 control_unit 的 ctrl_s.imm_fmt 驱动, 枚举定义于 rv32_pkg;
// - 五种格式的位拼接均已逐位对照 RISC-V 规范 (B/J 型立即数位序乱序,
//   这是规范为保持 major opcode 对齐的历史选择);
// - 非法 fmt (control_unit 不会产生) 输出 x, 仿真中快速暴露集成 bug。
// ============================================================================

module imm_gen
  import rv32_pkg::*;
#(
  parameter int unsigned XLEN = 32
)(
  input  logic [XLEN-1:0] instr,
  input  imm_fmt_e        fmt,

  output logic [XLEN-1:0] imm_out
);

  // 各格式先在 assign 里拼好, always_comb 只做纯 mux
  // (拼接注释为立即数位到指令位的映射, B/J 型位序乱序是规范为保持
  //  major opcode 对齐的历史选择)
  logic [XLEN-1:0] imm_i, imm_s, imm_b, imm_u, imm_j;

  assign imm_i = {{(XLEN-12){instr[31]}}, instr[31:20]};                      // imm[11:0]  = instr[31:20]
  assign imm_s = {{(XLEN-12){instr[31]}}, instr[31:25], instr[11:7]};         // imm[11:5]=instr[31:25], imm[4:0]=instr[11:7]
  assign imm_b = {{(XLEN-13){instr[31]}}, instr[31], instr[7],
                  instr[30:25], instr[11:8], 1'b0};                           // imm[12]=instr[31], imm[11]=instr[7],
                                                                              // imm[10:5]=instr[30:25], imm[4:1]=instr[11:8]
  assign imm_u = {instr[31:12], {(XLEN-20){1'b0}}};                           // imm[31:12] = instr[31:12]
  assign imm_j = {{(XLEN-21){instr[31]}}, instr[31], instr[19:12],
                  instr[20], instr[30:21], 1'b0};                             // imm[20]=instr[31], imm[19:12]=instr[19:12],
                                                                              // imm[11]=instr[20], imm[10:1]=instr[30:21]

  always_comb begin
    case (fmt)
      IMM_I:    imm_out = imm_i;
      IMM_S:    imm_out = imm_s;
      IMM_B:    imm_out = imm_b;
      IMM_U:    imm_out = imm_u;
      IMM_J:    imm_out = imm_j;
      default:  imm_out = 'x;   // 非法 fmt (control_unit 不会产生), 仿真中快速暴露集成 bug
    endcase
  end

endmodule
