`timescale 1ns/1ps

// ============================================================================
// control_unit.sv — 主译码器 (RV32I 全指令 + 非法指令检测)
// ----------------------------------------------------------------------------
// 输出一个 ctrl_s 控制束 (定义于 rv32_pkg), 数据通路接线契约见
// rv32_pkg.sv 顶部注释。相对旧版控制单元的修复:
//   [P0] LOAD 的 imm_fmt 由未定义的 IMM_L 改为 IMM_I
//   [P1] 以 ctrl = '0 全默认起步, wb_src/mem_unsigned 不再有锁存器
//   [P1] JAL 不再置位 jalr —— 旧版会把 JAL 目标算成 rs1+imm
//   [P1] JALR 补 wb_src = WB_PC4 (链接值 PC+4 写回 rd)
//   [P1] AUIPC 补 alu_a_src = ALU_A_PC (旧版 alu_src_pc 从未置位)
//   [P1] LUI 用 alu_a_src = ALU_A_ZERO 取 a=0 (旧版 rs1 是垃圾值)
//   [P2] mem_to_reg 并入 wb_src; branch/jump/jalr 三位合并为 pc_sel;
//        alu_src/alu_src_pc 合并为对称的 alu_a_src/alu_b_src
// 鲁棒性: opcode/funct3/funct7 三级合法性检查, 非法指令置 illegal
// 并在末尾统一中性化使能信号 (reg_write/mem_read/mem_write 清零, PC_NEXT),
// 保证非法指令严格"无架构副作用"。
// ============================================================================

module control_unit
  import rv32_pkg::*;
#(
  parameter int unsigned XLEN = 32
)(
  input  logic [XLEN-1:0] instr,

  output ctrl_s           ctrl
);

  // 指令字段
  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;

  assign opcode = instr[6:0];
  assign funct3 = instr[14:12];
  assign funct7 = instr[31:25];

  // 非法指令标志用局部信号累计, 末尾再整束输出到 ctrl.illegal。
  // 这样 always_comb 内不出现结构体成员读 (iverilog 对 always_* 内
  // 常量位选的敏感列表分析不完善, 会给出 "sorry" 告警)。
  logic illegal;

  always_comb begin
    // 全零默认 —— 所有枚举 0 值恰好构成安全 NOP (见 rv32_pkg ctrl_s 注释),
    // 先整束赋默认再按指令覆盖, 从写法上杜绝锁存器推断
    ctrl = '0;
    illegal = 1'b0;

    case (opcode)
      // ----------------------------------------------------------------
      // R 型: ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND
      // ----------------------------------------------------------------
      OPC_OP: begin
        ctrl.reg_write = 1'b1;
        ctrl.alu_b_src = ALU_B_RS2;
        ctrl.wb_src    = WB_ALU;
        case (funct3)
          3'b000: begin  // ADD / SUB
            case (funct7)
              F7_ZERO: ctrl.alu_op = ALU_ADD;
              F7_ALT:  ctrl.alu_op = ALU_SUB;
              default: illegal = 1'b1;  // 含 F7_MULDIV -> MUL (RV32M 预留)
            endcase
          end
          3'b001: begin  // SLL
            ctrl.alu_op   = ALU_SLL;
            illegal  = (funct7 != F7_ZERO);
          end
          3'b010: begin  // SLT
            ctrl.alu_op   = ALU_SLT;
            illegal  = (funct7 != F7_ZERO);
          end
          3'b011: begin  // SLTU
            ctrl.alu_op   = ALU_SLTU;
            illegal  = (funct7 != F7_ZERO);
          end
          3'b100: begin  // XOR
            ctrl.alu_op   = ALU_XOR;
            illegal  = (funct7 != F7_ZERO);
          end
          3'b101: begin  // SRL / SRA
            case (funct7)
              F7_ZERO: ctrl.alu_op = ALU_SRL;
              F7_ALT:  ctrl.alu_op = ALU_SRA;
              default: illegal = 1'b1;  // 含 F7_MULDIV -> DIVU (RV32M 预留)
            endcase
          end
          3'b110: begin  // OR
            ctrl.alu_op   = ALU_OR;
            illegal  = (funct7 != F7_ZERO);
          end
          3'b111: begin  // AND
            ctrl.alu_op   = ALU_AND;
            illegal  = (funct7 != F7_ZERO);
          end
        endcase
      end

      // ----------------------------------------------------------------
      // I 型算术: ADDI/SLTI/SLTIU/XORI/ORI/ANDI/SLLI/SRLI/SRAI
      // ----------------------------------------------------------------
      OPC_OPIMM: begin
        ctrl.reg_write = 1'b1;
        ctrl.alu_b_src = ALU_B_IMM;
        ctrl.imm_fmt   = IMM_I;
        ctrl.wb_src    = WB_ALU;
        case (funct3)
          3'b000: ctrl.alu_op = ALU_ADD;   // ADDI
          3'b010: ctrl.alu_op = ALU_SLT;   // SLTI
          3'b011: ctrl.alu_op = ALU_SLTU;  // SLTIU
          3'b100: ctrl.alu_op = ALU_XOR;   // XORI
          3'b110: ctrl.alu_op = ALU_OR;    // ORI
          3'b111: ctrl.alu_op = ALU_AND;   // ANDI
          3'b001: begin  // SLLI —— RV32 下 imm[11:5] 必须为 0 (imm[4:0] 是 shamt)
            ctrl.alu_op   = ALU_SLL;
            illegal  = (funct7 != F7_ZERO);
          end
          3'b101: begin  // SRLI / SRAI
            case (funct7)
              F7_ZERO: ctrl.alu_op = ALU_SRL;
              F7_ALT:  ctrl.alu_op = ALU_SRA;
              default: illegal = 1'b1;
            endcase
          end
        endcase
      end

      // ----------------------------------------------------------------
      // LOAD: LB/LH/LW/LBU/LHU
      // ----------------------------------------------------------------
      OPC_LOAD: begin
        ctrl.reg_write    = 1'b1;
        ctrl.mem_read     = 1'b1;
        ctrl.alu_b_src    = ALU_B_IMM;
        ctrl.imm_fmt      = IMM_I;
        ctrl.wb_src       = WB_MEM;
        ctrl.mem_unsigned = 1'b0;
        case (funct3)
          3'b000: ctrl.mem_size = MEM_BYTE;   // LB
          3'b001: ctrl.mem_size = MEM_HALF;   // LH
          3'b010: ctrl.mem_size = MEM_WORD;   // LW
          3'b100: begin ctrl.mem_size = MEM_BYTE; ctrl.mem_unsigned = 1'b1; end  // LBU
          3'b101: begin ctrl.mem_size = MEM_HALF; ctrl.mem_unsigned = 1'b1; end  // LHU
          default: illegal = 1'b1;       // 3'b011/110/111 非法
        endcase
      end

      // ----------------------------------------------------------------
      // STORE: SB/SH/SW
      // ----------------------------------------------------------------
      OPC_STORE: begin
        ctrl.mem_write  = 1'b1;
        ctrl.alu_b_src  = ALU_B_IMM;
        ctrl.imm_fmt    = IMM_S;
        ctrl.mem_size   = MEM_BYTE;
        case (funct3)
          3'b000: ctrl.mem_size = MEM_BYTE;   // SB
          3'b001: ctrl.mem_size = MEM_HALF;   // SH
          3'b010: ctrl.mem_size = MEM_WORD;   // SW
          default: illegal = 1'b1;       // 其余非法
        endcase
      end

      // ----------------------------------------------------------------
      // 条件分支: BEQ/BNE/BLT/BGE/BLTU/BGEU
      // ALU 兼职目标加法器: a=PC, b=imm -> alu_out = pc+imm
      // ----------------------------------------------------------------
      OPC_BRANCH: begin
        ctrl.pc_sel     = PC_BR;
        ctrl.alu_a_src  = ALU_A_PC;
        ctrl.alu_b_src  = ALU_B_IMM;
        ctrl.imm_fmt    = IMM_B;
        ctrl.branch_type = BR_EQ;
        case (funct3)
          3'b000: ctrl.branch_type = BR_EQ;
          3'b001: ctrl.branch_type = BR_NE;
          3'b100: ctrl.branch_type = BR_LT;
          3'b101: ctrl.branch_type = BR_GE;
          3'b110: ctrl.branch_type = BR_LTU;
          3'b111: ctrl.branch_type = BR_GEU;
          default: illegal = 1'b1;       // 3'b010/011 非法
        endcase
      end

      // ----------------------------------------------------------------
      // LUI: rd = 0 + imm  (A 操作数强制为零, 替代旧版读垃圾 rs1 的做法)
      // ----------------------------------------------------------------
      OPC_LUI: begin
        ctrl.reg_write = 1'b1;
        ctrl.alu_a_src = ALU_A_ZERO;
        ctrl.alu_b_src = ALU_B_IMM;
        ctrl.imm_fmt   = IMM_U;
        ctrl.alu_op    = ALU_ADD;
        ctrl.wb_src    = WB_ALU;
      end

      // ----------------------------------------------------------------
      // AUIPC: rd = PC + imm
      // ----------------------------------------------------------------
      OPC_AUIPC: begin
        ctrl.reg_write = 1'b1;
        ctrl.alu_a_src = ALU_A_PC;
        ctrl.alu_b_src = ALU_B_IMM;
        ctrl.imm_fmt   = IMM_U;
        ctrl.alu_op    = ALU_ADD;
        ctrl.wb_src    = WB_ALU;
      end

      // ----------------------------------------------------------------
      // JAL: rd = PC+4, PC = PC+imm  (目标由 ALU 计算: a=PC, b=imm)
      // ----------------------------------------------------------------
      OPC_JAL: begin
        ctrl.reg_write = 1'b1;
        ctrl.pc_sel    = PC_J;
        ctrl.alu_a_src = ALU_A_PC;
        ctrl.alu_b_src = ALU_B_IMM;
        ctrl.imm_fmt   = IMM_J;
        ctrl.alu_op    = ALU_ADD;
        ctrl.wb_src    = WB_PC4;
      end

      // ----------------------------------------------------------------
      // JALR: rd = PC+4, PC = (rs1+imm)&~1  (目标由 ALU 计算: a=rs1, b=imm,
      //                                     最低位清零由数据通路完成)
      // ----------------------------------------------------------------
      OPC_JALR: begin
        ctrl.reg_write = 1'b1;
        ctrl.pc_sel    = PC_JR;
        ctrl.alu_a_src = ALU_A_RS1;
        ctrl.alu_b_src = ALU_B_IMM;
        ctrl.imm_fmt   = IMM_I;
        ctrl.alu_op    = ALU_ADD;
        ctrl.wb_src    = WB_PC4;
        if (funct3 != 3'b000) begin
          illegal = 1'b1;
        end
      end

      default: begin
        illegal = 1'b1;   // 未知 opcode: 其余信号保持 NOP 安全默认
      end
    endcase

    ctrl.illegal = illegal;

    // 非法指令按"什么都不做"处理 (见 rv32_pkg 顶部契约第 6 条):
    // 各分支在检测到非法编码前可能已置位使能 (如 R 型先置 reg_write=1,
    // 再在 funct7 检查里置 illegal, 分支型先置 pc_sel=PC_BR 再发现 funct3 非法),
    // 此处统一中性化, 防止垃圾值写回 rd、产生访存副作用、或让非法指令跳转。
    // illegal 标志保留, 将来接 trap 单元直接使用。
    if (illegal) begin
      ctrl.reg_write = 1'b0;
      ctrl.mem_read  = 1'b0;
      ctrl.mem_write = 1'b0;
      ctrl.pc_sel    = PC_NEXT;
    end
  end

endmodule
