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
          3'b000: begin  // ADD / SUB / MUL
            case (funct7)
              F7_ZERO:   ctrl.alu_op = ALU_ADD;
              F7_ALT:    ctrl.alu_op = ALU_SUB;
              F7_MULDIV: ctrl.alu_op = ALU_MUL;     // RV32M
              default:   illegal = 1'b1;
            endcase
          end
          3'b001: begin  // SLL / MULH
            if (funct7 == F7_MULDIV) ctrl.alu_op = ALU_MULH;      // RV32M
            else begin ctrl.alu_op = ALU_SLL; illegal = (funct7 != F7_ZERO); end
          end
          3'b010: begin  // SLT / MULHSU
            if (funct7 == F7_MULDIV) ctrl.alu_op = ALU_MULHSU;    // RV32M
            else begin ctrl.alu_op = ALU_SLT; illegal = (funct7 != F7_ZERO); end
          end
          3'b011: begin  // SLTU / MULHU
            if (funct7 == F7_MULDIV) ctrl.alu_op = ALU_MULHU;     // RV32M
            else begin ctrl.alu_op = ALU_SLTU; illegal = (funct7 != F7_ZERO); end
          end
          3'b100: begin  // XOR / DIV
            if (funct7 == F7_MULDIV) ctrl.alu_op = ALU_DIV;       // RV32M
            else begin ctrl.alu_op = ALU_XOR; illegal = (funct7 != F7_ZERO); end
          end
          3'b101: begin  // SRL / SRA / DIVU
            case (funct7)
              F7_ZERO:   ctrl.alu_op = ALU_SRL;
              F7_ALT:    ctrl.alu_op = ALU_SRA;
              F7_MULDIV: ctrl.alu_op = ALU_DIVU;    // RV32M
              default:   illegal = 1'b1;
            endcase
          end
          3'b110: begin  // OR / REM
            if (funct7 == F7_MULDIV) ctrl.alu_op = ALU_REM;       // RV32M
            else begin ctrl.alu_op = ALU_OR; illegal = (funct7 != F7_ZERO); end
          end
          3'b111: begin  // AND / REMU
            if (funct7 == F7_MULDIV) ctrl.alu_op = ALU_REMU;      // RV32M
            else begin ctrl.alu_op = ALU_AND; illegal = (funct7 != F7_ZERO); end
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

      // ----------------------------------------------------------------
      // RV32A: LR.W / SC.W / AMO*.W  (opcode 7'b0101111) —— 由 A_EN 宏门控
      // ----------------------------------------------------------------
      // 【为什么默认关闭 —— 实测数据】这段译码会给评分三项带来**纯代价**:
      //     fmax  61.7 -> 58.8 MHz   (-4.7%)
      //     LUT   4078 -> 4104       (+26)
      //     绝对吞吐 145.6 -> 138.9   (-4.6%)
      //   而收益为**零**: CoreMark 不含任何原子指令 (ticks 一位都不变),
      //   而且多周期"读-改-写"还没实现, 所以当前 A 指令**还执行不了**。
      //   funct5 的比较 + ALU 算符 mux 落在了访存地址那条已经很紧的路径上。
      //   要启用: set A_EN=1, 并先完成多周期控制 (见 results/p6-a-extension.md 第 5 节)。
      //
      // 字段布局与 R 型一致, 只是 funct5 = instr[31:27] 选算子:
      //   [31:27] funct5  [26] aq  [25] rl  [24:20] rs2  [19:15] rs1  [11:7] rd
      // 编码已用 riscv-none-elf-gcc -march=rv32ia 逐条实测确认
      // (results/p6-a-extension.md 第 2 节)。
      //
      // 【写回来源】所有 A 指令的 rd 都是"从内存读回的**旧值**"(LR 是读到的值,
      // AMO 是操作前的值, SC 是 0/1 成功标志) —— 所以 wb_src 必须是 WB_MEM。
      // 【执行方式】AMO 是"读-改-写", 单拍 LSU 做不了; amo_en 告诉流水线控制
      // 本条要走多周期原子序列 (由 core.sv 的 amo 状态机处理, 见那里的注释)。
`ifdef A_EN
      OPC_AMO: begin
        ctrl.amo_en    = 1'b1;
        ctrl.amo_op    = instr[31:27];   // funct5
        ctrl.amo_aq    = instr[26];
        ctrl.amo_rl    = instr[25];
        ctrl.reg_write = 1'b1;
        ctrl.wb_src    = WB_MEM;         // rd <- 旧值 / SC 的成功标志
        // ----------------------------------------------------------------
        // 【必须显式设这三个字段 —— 否则地址算错, AMO 会读到一个从没写过的字】
        // AMO 是 I 型: 访存地址 = rs1 + imm[11:0] (AMO 的 imm 恒为 0)。
        // 而 `ctrl = '0` 的默认值恰好是:
        //     alu_a_src = ALU_A_RS1 (0)   -> 正确, a 取 rs1
        //     alu_b_src = ALU_B_RS2 (0)   -> **错! b 取 rs2 而不是立即数**
        //     imm_fmt   = IMM_I     (0)   -> 值对, 但只有 b 选 IMM 时才用得上
        // 于是地址变成 `rs1 + rs2` 而不是 `rs1 + 0`。
        //
        // 实测症状: `sw` 写 0x90003100, 而同一个 t0 上的 AMO 去访问 0x90003114
        // —— 差的正是当时 t1 的值 0x14。于是 AMO 读一个从没写过的字, 恒为 0。
        // **这个 bug 极具欺骗性**: 状态机、相位、写使能、写数据全对, 只有地址错,
        // 而"读回 0"看起来像读通路坏了 —— 我为此绕了三轮。
        ctrl.alu_a_src = ALU_A_RS1;      // a = rs1 (基址)
        ctrl.alu_b_src = ALU_B_IMM;      // b = imm  (AMO 恒为 0)  <- 关键修复
        ctrl.imm_fmt   = IMM_I;          // I 型立即数
        if (funct3 != 3'b010) begin
          // 本核只实现 .W 变体 (RV32); funct3=010。其余 (如 .D/.B) 判非法。
          illegal = 1'b1;
        end
        else begin
          unique case (ctrl.amo_op)
            // ---- LR / SC: 不给 ALU 算符 (不走 ALU 的"新值"路径) ----
            AMO_LR, AMO_SC: ctrl.alu_op = ALU_ADD;   // 占位, 实际不使用
            // ---- AMO*: ALU 算"应写回内存的新值" (a=旧值, b=rs2) ----
            AMO_SWAP: ctrl.alu_op = ALU_AMO_SWAP;
            AMO_ADD:  ctrl.alu_op = ALU_AMO_ADD;
            AMO_XOR:  ctrl.alu_op = ALU_AMO_XOR;
            AMO_AND:  ctrl.alu_op = ALU_AMO_AND;
            AMO_OR:   ctrl.alu_op = ALU_AMO_OR;
            AMO_MIN:  ctrl.alu_op = ALU_AMO_MIN;
            AMO_MAX:  ctrl.alu_op = ALU_AMO_MAX;
            AMO_MINU: ctrl.alu_op = ALU_AMO_MINU;
            AMO_MAXU: ctrl.alu_op = ALU_AMO_MAXU;
            default:  illegal = 1'b1;                // 未实现的 funct5
          endcase
        end
      end
`else
      // A_EN 未定义: 0x2F 保持非法 (与加 A 扩展之前的行为一致)
      OPC_AMO: illegal = 1'b1;
`endif

      // ----------------------------------------------------------------
      // FENCE / FENCE.I: 本核顺序执行且无 cache, 架构上无副作用 -> 合法 NOP。
      // **不能译成 illegal**: 编译器/运行库会在切换栈、初始化之后插 fence,
      // 误判为非法会让正常程序一上来就掉进陷阱。
      // ----------------------------------------------------------------
      OPC_FENCE: begin
        // 有意留空: 安全默认就是 NOP
      end

      // ----------------------------------------------------------------
      // SYSTEM: ECALL / EBREAK / MRET / Zicsr
      // ----------------------------------------------------------------
      OPC_SYSTEM: begin
        case (funct3)
          3'b000: begin
            // 特权指令靠 instr[31:20] 区分 (规范里这三个编码固定)
            case (instr[31:20])
              12'h000: ctrl.sys_op = SYS_ECALL;    // -> 异常 11 (M 模式环境调用)
              12'h001: ctrl.sys_op = SYS_EBREAK;   // -> 异常 3  (断点)
              12'h302: ctrl.sys_op = SYS_MRET;     // -> PC <- mepc 并恢复 MIE
              default: illegal = 1'b1;
            endcase
          end
          3'b100: illegal = 1'b1;                  // 规范保留, 非法
          default: begin
            // CSRRW/S/C 与立即数形式 (funct3 = 001/010/011/101/110/111)
            ctrl.sys_op      = SYS_CSR;
            ctrl.csr_addr    = instr[31:20];
            ctrl.csr_cmd     = funct3[1:0];        // 01=W 10=S 11=C
            ctrl.csr_src_imm = funct3[2];
            ctrl.csr_uimm    = instr[19:15];
            ctrl.reg_write   = 1'b1;               // 写回的是 *读到的旧值*
            ctrl.wb_src      = WB_CSR;
          end
        endcase
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
