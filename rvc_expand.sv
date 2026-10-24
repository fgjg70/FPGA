`timescale 1ns/1ps

// ============================================================================
// rvc_expand.sv — RV32C (RVC) 压缩指令 → 标准 32 位指令的"规范化展开"
// ----------------------------------------------------------------------------
// 【设计取舍: 为什么做"展开"而不是在 control_unit 里直接译 16 位】
//   RV32C 的每一条压缩指令都有唯一的 32 位等价形式 (规范 "C" 章的展开表,
//   RISC-V Unprivileged Spec, Volume I, Chapter "C")。把 16 位半字在 ID 段
//   展开成**规范 32 位编码**之后, control_unit / imm_gen / hazard_unit /
//   branch_unit **一行都不用改** —— 它们看到的仍是标准 32 位指令。
//   好处:
//     ① 译码"单一事实来源"仍然只有 control_unit 一处 (仓库的既有纪律);
//     ② 寄存器号 / 立即数全部回到标准字段位置, regfile 读口与 hazard 的
//        load-use 比较不需要知道 RVC 的 f/rs1'/rs2' 映射规则;
//     ③ 既有回归 (12 项) 的行为路径零扰动 —— 全 32 位程序展开后逐位不变。
//   代价: ID 段多一层纯组合译码 (约 200 LUT 量级; ID→ID/EX 的 D 端路径
//   会变长一点, 对本分支而言可接受 —— 本分支是"指令集拓展学习分支",
//   不承诺 150 MHz 档位的 fmax, 那是 main 分支的口径)。
//
// 【合法性与 HINT】
//   · 全零半字 (0x0000) 是规范**定义的非法指令** (D Netscape... 即 "defined
//     illegal"), 本模块判 valid=0。
//   · rd=x0 的 C.ADDI/C.LI/SLLI/MV/ADD 与 C.NOP 是规范允许的 **HINT**
//     (无架构副作用的合法指令) —— 展开成对应的 32 位形式 (addi x0,...)
//     自然无害, 不单独判非法。
//   · 保留编码 (如 C.ADDI4SPN 的 nzuimm=0、C.LUI 的 imm=0、RV32 下
//     shamt[5]=1、RV64 专属的 C.SUBW/C.ADDW、F 浮点槽位) 一律 valid=0,
//     由 control_unit 按"非法指令"处理 (mtval 记原始 16 位编码, 见 core.sv)。
//
// 【位序来源】全部立即数位映射逐位对照规范 Table "C" 的 CIW/CL/CS/CA/CB/CJ/
//   CSS 各格式图; 关键几处 (CJ 的位乱序、C.ADDI16SP 的 10 位拼接) 在行内注释
//   里标了 imm 位号, 方便对照规范复查。
// ============================================================================

module rvc_expand (
  input  logic [15:0] half,      // 取指到的 16 位半字 (按 pc[1] 选出的那一半)
  output logic        valid,     // 0 = 保留/非法编码 (control_unit 会判 illegal)
  output logic [31:0] instr32    // 规范化 32 位指令 (valid=0 时无意义)
);

  localparam logic [6:0] OP_IMM  = 7'b0010011;
  localparam logic [6:0] OP      = 7'b0110011;
  localparam logic [6:0] LOAD    = 7'b0000011;
  localparam logic [6:0] STORE   = 7'b0100011;
  localparam logic [6:0] BRANCH  = 7'b1100011;
  localparam logic [6:0] JAL     = 7'b1101111;
  localparam logic [6:0] JALR    = 7'b1100111;
  localparam logic [6:0] SYSTEM  = 7'b1110011;

  // ---- 寄存器字段 ----
  // 压缩字段 rd'/rs1' (3 位) 映射到 x8..x15: {2'b01, f}; CR/CI/CSS 用全 5 位。
  // 【注意两个 rd' 位置不同】CL/CS/CA/CB 的 rd' 在 [9:7] (rd_f),
  // 而 CIW (C.ADDI4SPN) 的 rd' 在 [4:2] (rd_ciw) —— 与 rs2' 同一位置。
  wire [4:0] rd_f   = {2'b01, half[9:7]};    // rs1'/rd' (CL/CS/CA/CB)
  wire [4:0] rd_ciw = {2'b01, half[4:2]};    // rd'     (CIW: C.ADDI4SPN)
  wire [4:0] rs2_f  = {2'b01, half[4:2]};    // rs2'    (CA/CS)
  wire [4:0] rd     = half[11:7];            // CI/CR 的全 5 位 rd
  wire [4:0] rs2    = half[6:2];             // CR/CSS 的全 5 位 rs2

  // ---- 立即数 (先拼好, 与 imm_gen 同一风格: assign 拼 + 末尾纯 mux) ----
  // CI: 6 位符号立即数 imm[5]=inst[12], imm[4:0]=inst[6:2]
  wire [31:0] imm_ci   = {{26{half[12]}}, half[12], half[6:2]};
  // CIW (C.ADDI4SPN): nzuimm[9:6]=inst[10:7] [5:4]=inst[12:11] [3]=inst[5] [2]=inst[6]
  wire [31:0] imm_ciw  = {8'b0, half[10:7], half[12:11], half[5], half[6], 2'b00};
  // CL/CS (C.LW/C.SW): offset[6]=inst[5] [5:3]=inst[12:10] [2]=inst[6]
  wire [31:0] imm_cl   = {25'b0, half[5], half[12:10], half[6], 2'b00};
  // CI-sp (C.LWSP): offset[7:6]=inst[3:2] [5]=inst[12] [4:2]=inst[6:4]
  wire [31:0] imm_lwsp = {24'b0, half[3:2], half[12], half[6:4], 2'b00};
  // CSS (C.SWSP): offset[7:6]=inst[8:7] [5:2]=inst[12:9]
  wire [31:0] imm_swsp = {24'b0, half[8:7], half[12:9], 2'b00};
  // C.ADDI16SP: nzimm[9]=inst[12] [8:7]=inst[4:3] [6]=inst[5] [5]=inst[2] [4]=inst[6]
  wire [31:0] imm_a16  = {{22{half[12]}}, half[12], half[4:3], half[5], half[2], half[6], 4'b0};
  // C.LUI: imm[17:12] = {inst[12], inst[6:2]}, 符号扩展到 32 位
  wire [31:0] imm_lui  = {{14{half[12]}}, half[12], half[6:2], 12'b0};
  // CB (C.BEQZ/C.BNEZ): 9 位符号偏移
  //   imm[8]=inst[12] [7:6]=inst[6:5] [5]=inst[2] [4:3]=inst[11:10] [2:1]=inst[4:3]
  wire [8:0]  imm_cb9  = {half[12], half[6:5], half[2], half[11:10], half[4:3], 1'b0};
  // CJ (C.J/C.JAL): 12 位符号偏移 (位序乱序, 逐位对照规范 CJ 格式图)
  //   imm[11]=inst[12] [10]=inst[8] [9:8]=inst[10:9] [7]=inst[6] [6]=inst[7]
  //   [5]=inst[2] [4]=inst[11] [3:1]=inst[5:3]
  wire [11:0] imm_cj12 = {half[12], half[8], half[10:9], half[6], half[7],
                          half[2], half[11], half[5:3], 1'b0};
  wire [20:0] imm_cj21 = {{9{imm_cj12[11]}}, imm_cj12};   // 21 位符号扩展 (J 型打包用)
  wire [12:0] imm_cb13 = {{4{imm_cb9[8]}}, imm_cb9};      // 13 位符号扩展 (B 型打包用)

  always_comb begin
    // 默认: 非法 (valid=0)。每个合法分支显式覆盖。
    valid   = 1'b0;
    instr32 = 32'h0;

    if (half == 16'h0000) begin
      // 全零半字: 规范定义的非法指令 (所有位为 0 的编码永远是 illegal)
      valid = 1'b0;
    end
    else case (half[1:0])
      // ====================================================================
      // Quadrant 0 (op=00): 按压缩 rd' 操作的取数/存数/加立即数
      // ====================================================================
      2'b00: begin
        case (half[15:13])
          3'b000: begin  // C.ADDI4SPN: addi rd', x2, nzuimm (nzuimm=0 保留)
            if (imm_ciw != 32'd0) begin
              valid   = 1'b1;
              instr32 = {imm_ciw[11:0], 5'd2, 3'b000, rd_ciw, OP_IMM};
            end
          end
          3'b010: begin  // C.LW: lw rd', uimm(rs1') —— I 型 LOAD
            // CL 格式: 基址 rs1' 在 [9:7] (=rd_f), 目的 rd' 在 [4:2] (=rs2_f)
            valid   = 1'b1;
            instr32 = {imm_cl[11:0], rd_f, 3'b010, rs2_f, LOAD};
          end
          3'b110: begin  // C.SW: sw rs2', uimm(rs1') —— S 型 STORE
            // S 型布局 (位宽 7+5+5+3+5+7): [31:25]=imm[11:5], [24:20]=数据 rs2'
            // ([4:2]), [19:15]=基址 rs1' ([9:7]), [14:12]=funct3, [11:7]=imm[4:0]
            valid   = 1'b1;
            instr32 = {imm_cl[11:5], rs2_f, rd_f, 3'b010, imm_cl[4:0], STORE};
          end
          default: ;     // C.FLD/C.FLW/C.FSD/C.FSW: F 扩展槽位, 本核无 F -> 非法
        endcase
      end

      // ====================================================================
      // Quadrant 1 (op=01)
      // ====================================================================
      2'b01: begin
        case (half[15:13])
          3'b000: begin  // C.ADDI (rd=x0 即 C.NOP/HINT): addi rd, rd, imm
            valid   = 1'b1;
            instr32 = {imm_ci[11:0], rd, 3'b000, rd, OP_IMM};
          end
          3'b001: begin  // C.JAL (RV32): jal x1, offset
            valid   = 1'b1;
            instr32 = {imm_cj21[20], imm_cj21[10:1], imm_cj21[11], imm_cj21[19:12],
                       5'd1, JAL};
          end
          3'b010: begin  // C.LI: addi rd, x0, imm
            valid   = 1'b1;
            instr32 = {imm_ci[11:0], 5'd0, 3'b000, rd, OP_IMM};
          end
          3'b011: begin
            if (rd == 5'd2) begin
              // C.ADDI16SP: addi x2, x2, nzimm (nzimm=0 保留)
              if (imm_a16[9:0] != 10'd0) begin
                valid   = 1'b1;
                instr32 = {imm_a16[11:0], 5'd2, 3'b000, 5'd2, OP_IMM};
              end
            end
            else if (rd == 5'd0) begin
              // C.LUI rd=x0: HINT (无架构副作用) -> lui x0, imm 照常展开
              valid   = 1'b1;
              instr32 = {imm_lui[31:12], 5'd0, 7'b0110111};
            end
            else begin
              // C.LUI: lui rd, nzimm[17:12] (nzimm=0 保留)
              if (half[6:2] != 5'd0 || half[12] != 1'b0) begin
                valid   = 1'b1;
                instr32 = {imm_lui[31:12], rd, 7'b0110111};
              end
            end
          end
          3'b100: begin
            case (half[11:10])
              2'b00: begin  // C.SRLI: srli rd', rd', shamt (bit12=1 为 RV128 -> 非法)
                if (half[12] == 1'b0) begin
                  valid   = 1'b1;
                  instr32 = {7'b0000000, half[6:2], rd_f, 3'b101, rd_f, OP_IMM};
                end
              end
              2'b01: begin  // C.SRAI: srai rd', rd', shamt
                if (half[12] == 1'b0) begin
                  valid   = 1'b1;
                  instr32 = {7'b0100000, half[6:2], rd_f, 3'b101, rd_f, OP_IMM};
                end
              end
              2'b10: begin  // C.ANDI: andi rd', rd', imm (符号扩展 6 位)
                valid   = 1'b1;
                instr32 = {imm_ci[11:0], rd_f, 3'b111, rd_f, OP_IMM};
              end
              2'b11: begin
                if (half[12] == 1'b0) begin
                  // C.SUB/C.XOR/C.OR/C.AND (CA 格式): op rd', rd', rs2'
                  valid = 1'b1;
                  case (half[6:5])
                    2'b00:   instr32 = {7'b0100000, rs2_f, rd_f, 3'b000, rd_f, OP};
                    2'b01:   instr32 = {7'b0000000, rs2_f, rd_f, 3'b100, rd_f, OP};
                    2'b10:   instr32 = {7'b0000000, rs2_f, rd_f, 3'b110, rd_f, OP};
                    default: instr32 = {7'b0000000, rs2_f, rd_f, 3'b111, rd_f, OP};
                  endcase
                end
                // half[12]=1: C.SUBW/C.ADDW 是 RV64 专属, RV32 下保留 -> 非法
              end
            endcase
          end
          3'b101: begin  // C.J: jal x0, offset
            valid   = 1'b1;
            instr32 = {imm_cj21[20], imm_cj21[10:1], imm_cj21[11], imm_cj21[19:12],
                       5'd0, JAL};
          end
          3'b110: begin  // C.BEQZ: beq rs1', x0, offset
            valid   = 1'b1;
            instr32 = {imm_cb13[12], imm_cb13[10:5], 5'd0, rd_f, 3'b000,
                       imm_cb13[4:1], imm_cb13[11], BRANCH};
          end
          3'b111: begin  // C.BNEZ: bne rs1', x0, offset
            valid   = 1'b1;
            instr32 = {imm_cb13[12], imm_cb13[10:5], 5'd0, rd_f, 3'b001,
                       imm_cb13[4:1], imm_cb13[11], BRANCH};
          end
        endcase
      end

      // ====================================================================
      // Quadrant 2 (op=10)
      // ====================================================================
      2'b10: begin
        case (half[15:13])
          3'b000: begin  // C.SLLI: slli rd, rd, shamt (rd=x0 为 HINT; shamt[5]=1 非法)
            if (half[12] == 1'b0) begin
              valid   = 1'b1;
              instr32 = {7'b0000000, half[6:2], rd, 3'b001, rd, OP_IMM};
            end
          end
          3'b010: begin  // C.LWSP: lw rd, offset(x2) (rd=x0 保留)
            if (rd != 5'd0) begin
              valid   = 1'b1;
              instr32 = {imm_lwsp[11:0], 5'd2, 3'b010, rd, LOAD};
            end
          end
          3'b100: begin
            if (half[12] == 1'b0) begin
              if (rs2 == 5'd0) begin
                // C.JR: jalr x0, 0(rd) (rd=x0 保留)
                if (rd != 5'd0) begin
                  valid   = 1'b1;
                  instr32 = {12'b0, rd, 3'b000, 5'd0, JALR};
                end
              end
              else begin
                // C.MV: add rd, x0, rs2 (rd=x0 为 HINT)
                valid   = 1'b1;
                instr32 = {7'b0000000, rs2, 5'd0, 3'b000, rd, OP};
              end
            end
            else begin
              if (rs2 == 5'd0) begin
                if (rd == 5'd0) begin
                  // C.EBREAK
                  valid   = 1'b1;
                  instr32 = 32'h00100073;
                end
                else begin
                  // C.JALR: jalr x1, 0(rd)
                  valid   = 1'b1;
                  instr32 = {12'b0, rd, 3'b000, 5'd1, JALR};
                end
              end
              else begin
                // C.ADD: add rd, rd, rs2 (rd=x0 为 HINT)
                valid   = 1'b1;
                instr32 = {7'b0000000, rs2, rd, 3'b000, rd, OP};
              end
            end
          end
          3'b110: begin  // C.SWSP: sw rs2, offset(x2)
            valid   = 1'b1;
            instr32 = {imm_swsp[11:5], rs2, 5'd2, 3'b010, imm_swsp[4:0], STORE};
          end
          default: ;     // C.FLDSP/C.FSDSP: F 扩展槽位 -> 非法
        endcase
      end

      // 2'b11: 32 位指令不应走到这里 (取指侧 pc[1]=0 且 word[1:0]=11 时
      // 已经按 32 位处理)。能进来的只有 pc[1]=1 的半字且其 [1:0]=11 ——
      // 那是 48/64 位指令编码空间 (RV32C 不含) -> 保持 valid=0。
      default: ;
    endcase
  end

endmodule
