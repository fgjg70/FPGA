// ============================================================================
// tb_units.sv — 6 个 RTL 模块的单元回归测试 (自校验)
// ----------------------------------------------------------------------------
// 覆盖: alu / imm_gen / branch_unit / control_unit / regfile / pc
// 重点回归 (对应 control_unit.sv 头部注释列出的修复项):
//   - LOAD 后译码 STORE, wb_src/mem_unsigned 必须回到默认 (锁存器检查)
//   - JAL 的 pc_sel 必须是 PC_J 而不是 PC_JR
//   - JALR 的 wb_src 必须是 WB_PC4
//   - AUIPC 的 alu_a_src 必须是 ALU_A_PC
//   - LUI 的 alu_a_src 必须是 ALU_A_ZERO
//   - LOAD 的 imm_fmt 必须是 IMM_I
// imm_gen 用 5 条独立手推的黄金向量做基准, 不依赖字段拼接函数,
// 防止"测试与被测代码犯同一个错"。
// 运行: sim/run.bat (Windows) 或 sim/run.sh (Linux/WSL)
// ============================================================================

`timescale 1ns/1ps

module tb_units;
  import rv32_pkg::*;

  localparam time TCLK_HALF = 5ns;   // 100 MHz 等效时钟

  logic clk = 1'b0;
  always #(TCLK_HALF) clk = ~clk;

  int errors = 0;
  int checks = 0;

  // --------------------------------------------------------------------------
  // 检查任务
  // --------------------------------------------------------------------------
  task automatic chk(input logic [31:0] got, input logic [31:0] exp,
                     input string what);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("  [FAIL] %s: got=%h exp=%h", what, got, exp);
    end
  endtask

  // --------------------------------------------------------------------------
  // 指令编码辅助函数 (仅按规范字段布局拼接, 与 RTL 无共享代码)
  // --------------------------------------------------------------------------
  function automatic logic [31:0] enc_r(input logic [6:0]  f7,
                                        input logic [4:0]  rs2,
                                        input logic [4:0]  rs1,
                                        input logic [2:0]  f3,
                                        input logic [4:0]  rd);
    return {f7, rs2, rs1, f3, rd, 7'b0110011};
  endfunction

  function automatic logic [31:0] enc_i(input logic [11:0] imm,
                                        input logic [4:0]  rs1,
                                        input logic [2:0]  f3,
                                        input logic [4:0]  rd,
                                        input logic [6:0]  opc);
    return {imm, rs1, f3, rd, opc};
  endfunction

  function automatic logic [31:0] enc_s(input logic [11:0] imm,
                                        input logic [4:0]  rs2,
                                        input logic [4:0]  rs1,
                                        input logic [2:0]  f3);
    return {imm[11:5], rs2, rs1, f3, imm[4:0], 7'b0100011};
  endfunction

  function automatic logic [31:0] enc_b(input logic [12:0] imm,
                                        input logic [4:0]  rs2,
                                        input logic [4:0]  rs1,
                                        input logic [2:0]  f3);
    return {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], 7'b1100011};
  endfunction

  function automatic logic [31:0] enc_u(input logic [19:0] imm20,
                                        input logic [4:0]  rd,
                                        input logic [6:0]  opc);
    return {imm20, rd, opc};
  endfunction

  function automatic logic [31:0] enc_j(input logic [20:0] imm,
                                        input logic [4:0]  rd);
    return {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'b1101111};
  endfunction

  // --------------------------------------------------------------------------
  // DUT: ALU
  // --------------------------------------------------------------------------
  logic [31:0] alu_a, alu_b, alu_out;
  alu_op_e     alu_op;

  alu u_alu (.a(alu_a), .b(alu_b), .op(alu_op), .out(alu_out));

  // --------------------------------------------------------------------------
  // DUT: imm_gen
  // --------------------------------------------------------------------------
  logic [31:0] ig_instr, ig_imm;
  imm_fmt_e    ig_fmt;

  imm_gen u_ig (.instr(ig_instr), .fmt(ig_fmt), .imm_out(ig_imm));

  // --------------------------------------------------------------------------
  // DUT: branch_unit
  // --------------------------------------------------------------------------
  logic [31:0] bu_rs1, bu_rs2;
  branch_type_e bu_type;
  logic        bu_taken;

  branch_unit u_bu (.rs1(bu_rs1), .rs2(bu_rs2),
                     .branch_type(bu_type), .taken(bu_taken));

  // --------------------------------------------------------------------------
  // DUT: control_unit
  // --------------------------------------------------------------------------
  logic [31:0] cu_instr;
  ctrl_s       cu_ctrl;

  control_unit u_cu (.instr(cu_instr), .ctrl(cu_ctrl));

  // --------------------------------------------------------------------------
  // DUT: regfile
  // --------------------------------------------------------------------------
  logic        rf_we;
  logic [4:0]  rf_waddr, rf_raddr1, rf_raddr2;
  logic [31:0] rf_wdata, rf_rdata1, rf_rdata2;

  regfile u_rf (.clk(clk),
                .we(rf_we), .waddr(rf_waddr), .wdata(rf_wdata),
                .raddr1(rf_raddr1), .raddr2(rf_raddr2),
                .rdata1(rf_rdata1), .rdata2(rf_rdata2),
                .dbg_raddr(5'd0), .dbg_rdata());

  // --------------------------------------------------------------------------
  // DUT: pc
  // --------------------------------------------------------------------------
  localparam logic [31:0] RESET_PC = 32'h0000_0100;   // 故意用非零复位值, 抓接线错误

  logic        pc_rst, pc_stall, pc_flush, pc_src;
  logic [31:0] pc_flush_pc, pc_target, pc_pc, pc_plus4;

  pc #(.RESET_PC(RESET_PC)) u_pc (
    .clk(clk), .rst(pc_rst),
    .stall(pc_stall), .flush(pc_flush), .flush_pc(pc_flush_pc),
    .pc_src(pc_src), .pc_target(pc_target),
    .pc(pc_pc), .pc_plus4(pc_plus4));

  // ==========================================================================
  // 测试主体
  // ==========================================================================
  initial begin
    // ------------------------------------------------------------------
    $display("[1/6] ALU ...");
    // 加减法 (含边界)
    alu_op = ALU_ADD; alu_a = 32'd1;          alu_b = 32'd2;          #1; chk(alu_out, 32'd3,          "ADD 1+2");
    alu_a = 32'hFFFFFFFF;                     alu_b = 32'd1;          #1; chk(alu_out, 32'd0,          "ADD -1+1");
    alu_a = 32'h7FFFFFFF;                     alu_b = 32'd1;          #1; chk(alu_out, 32'h80000000,   "ADD max+1");
    alu_op = ALU_SUB; alu_a = 32'd5;          alu_b = 32'd3;          #1; chk(alu_out, 32'd2,          "SUB 5-3");
    alu_a = 32'd3;                            alu_b = 32'd5;          #1; chk(alu_out, 32'hFFFFFFFE,   "SUB 3-5");
    // 逻辑
    alu_op = ALU_AND; alu_a = 32'hF0F0F0F0;   alu_b = 32'h0FF00FF0;   #1; chk(alu_out, 32'h00F000F0,   "AND");
    alu_op = ALU_OR;  alu_a = 32'hF0F0F0F0;   alu_b = 32'h0F0F0F0F;   #1; chk(alu_out, 32'hFFFFFFFF,   "OR");
    alu_op = ALU_XOR; alu_a = 32'hAAAA5555;   alu_b = 32'hAAAA55AA;   #1; chk(alu_out, 32'h000000FF,   "XOR");
    // 移位 (含 0/31/超宽移位量)
    alu_op = ALU_SLL; alu_a = 32'd1;          alu_b = 32'd31;         #1; chk(alu_out, 32'h80000000,   "SLL 1<<31");
                     alu_a = 32'hDEADBEEF;    alu_b = 32'd4;          #1; chk(alu_out, 32'hEADBEEF0,   "SLL <<4");
                     alu_a = 32'h12345678;    alu_b = 32'd0;          #1; chk(alu_out, 32'h12345678,   "SLL <<0");
                     alu_a = 32'd1;           alu_b = 32'd32;         #1; chk(alu_out, 32'd1,          "SLL <<32(高位忽略)");
    alu_op = ALU_SRL; alu_a = 32'h80000000;   alu_b = 32'd31;         #1; chk(alu_out, 32'd1,          "SRL >>31");
                     alu_a = 32'hFFFFFFFF;    alu_b = 32'd4;          #1; chk(alu_out, 32'h0FFFFFFF,   "SRL -1>>4");
    alu_op = ALU_SRA; alu_a = 32'h80000000;   alu_b = 32'd31;         #1; chk(alu_out, 32'hFFFFFFFF,   "SRA min>>31");
                     alu_a = 32'hFFFFFFFF;    alu_b = 32'd4;          #1; chk(alu_out, 32'hFFFFFFFF,   "SRA -1>>4");
                     alu_a = 32'h7FFFFFFF;    alu_b = 32'd4;          #1; chk(alu_out, 32'h07FFFFFF,   "SRA max>>4");
                     alu_a = 32'h80000000;    alu_b = 32'd1;          #1; chk(alu_out, 32'hC0000000,   "SRA min>>1");
    // 比较 (有符号/无符号边界)
    alu_op = ALU_SLT;  alu_a = 32'hFFFFFFFF;  alu_b = 32'd0;          #1; chk(alu_out, 32'd1,          "SLT -1<0");
                       alu_a = 32'd0;         alu_b = 32'hFFFFFFFF;  #1; chk(alu_out, 32'd0,          "SLT 0<-1");
                       alu_a = 32'h80000000;  alu_b = 32'h7FFFFFFF;   #1; chk(alu_out, 32'd1,          "SLT min<max");
    alu_op = ALU_SLTU; alu_a = 32'hFFFFFFFF;  alu_b = 32'd0;          #1; chk(alu_out, 32'd0,          "SLTU max<u 0");
                       alu_a = 32'd0;         alu_b = 32'hFFFFFFFF;  #1; chk(alu_out, 32'd1,          "SLTU 0<u max");
                       alu_a = 32'h80000000;  alu_b = 32'h7FFFFFFF;   #1; chk(alu_out, 32'd0,          "SLTU 0x8.. <u 0x7..");
    // M 预留编码必须输出 x (仿真中暴露误用)
    alu_op = ALU_MUL;  alu_a = 32'd7;         alu_b = 32'd6;          #1; chk(alu_out, 32'bx,          "MUL reserved -> x");
    alu_op = ALU_DIV;                                                 #1; chk(alu_out, 32'bx,          "DIV reserved -> x");

    // ------------------------------------------------------------------
    $display("[2/6] imm_gen ...");
    // 黄金向量 (独立手推, 不经过 enc_* 函数)
    ig_instr = 32'h00000013; ig_fmt = IMM_I; #1; chk(ig_imm, 32'h00000000,   "golden NOP imm");
    ig_instr = 32'hFFF00093; ig_fmt = IMM_I; #1; chk(ig_imm, 32'hFFFFFFFF,   "golden addi x1,x0,-1");
    ig_instr = 32'hDEADB2B7; ig_fmt = IMM_U; #1; chk(ig_imm, 32'hDEADB000,   "golden lui x5,0xDEADB");
    ig_instr = 32'h008000EF; ig_fmt = IMM_J; #1; chk(ig_imm, 32'h00000008,   "golden jal x1,+8");
    ig_instr = 32'hFE208EE3; ig_fmt = IMM_B; #1; chk(ig_imm, 32'hFFFFFFFC,   "golden beq x1,x2,-4");
    // 字段构造向量
    ig_instr = enc_i(12'h7FF, 5'd3, 3'b000, 5'd1, OPC_OPIMM); ig_fmt = IMM_I; #1; chk(ig_imm, 32'h000007FF, "I max pos");
    ig_instr = enc_s(12'hFFC, 5'd5, 5'd2, 3'b010);            ig_fmt = IMM_S; #1; chk(ig_imm, 32'hFFFFFFFC, "S -4");
    ig_instr = enc_s(12'h800, 5'd5, 5'd2, 3'b000);            ig_fmt = IMM_S; #1; chk(ig_imm, 32'hFFFFF800, "S min neg");
    ig_instr = enc_b(13'd16,  5'd1, 5'd2, 3'b000);            ig_fmt = IMM_B; #1; chk(ig_imm, 32'h00000010, "B +16");
    ig_instr = enc_b(13'h1FF0, 5'd1, 5'd2, 3'b001);           ig_fmt = IMM_B; #1; chk(ig_imm, 32'hFFFFFFF0, "B -16");
    ig_instr = enc_j(21'd1024, 5'd1);                         ig_fmt = IMM_J; #1; chk(ig_imm, 32'h00000400, "J +1024");
    ig_instr = enc_j(21'h100000, 5'd1);                       ig_fmt = IMM_J; #1; chk(ig_imm, 32'hFFF00000, "J neg");
    ig_instr = enc_u(20'h12345, 5'd5, OPC_LUI);               ig_fmt = IMM_U; #1; chk(ig_imm, 32'h12345000, "U");

    // ------------------------------------------------------------------
    $display("[3/6] branch_unit ...");
    bu_rs1 = 32'd5; bu_rs2 = 32'd5;
    bu_type = BR_EQ;  #1; chk({31'd0, bu_taken}, 32'd1, "EQ  5,5");
    bu_type = BR_NE;  #1; chk({31'd0, bu_taken}, 32'd0, "NE  5,5");
    bu_rs1 = 32'd5; bu_rs2 = 32'd6;
    bu_type = BR_EQ;  #1; chk({31'd0, bu_taken}, 32'd0, "EQ  5,6");
    bu_type = BR_NE;  #1; chk({31'd0, bu_taken}, 32'd1, "NE  5,6");
    bu_rs1 = 32'hFFFFFFFF; bu_rs2 = 32'd1;   // -1 vs 1
    bu_type = BR_LT;  #1; chk({31'd0, bu_taken}, 32'd1, "LT  -1,1");
    bu_type = BR_GE;  #1; chk({31'd0, bu_taken}, 32'd0, "GE  -1,1");
    bu_type = BR_LTU; #1; chk({31'd0, bu_taken}, 32'd0, "LTU max,1");
    bu_type = BR_GEU; #1; chk({31'd0, bu_taken}, 32'd1, "GEU max,1");
    bu_rs1 = 32'h80000000; bu_rs2 = 32'h7FFFFFFF;   // 有符号 min/max, 无符号反之
    bu_type = BR_LT;  #1; chk({31'd0, bu_taken}, 32'd1, "LT  min,max");
    bu_type = BR_LTU; #1; chk({31'd0, bu_taken}, 32'd0, "LTU 0x8..,0x7..");

    // ------------------------------------------------------------------
    $display("[4/6] control_unit ...");
    // NOP: addi x0,x0,0 —— 注意 reg_write=1 (写 x0 被寄存器堆忽略)
    cu_instr = 32'h00000013; #1;
    chk({31'd0, cu_ctrl.reg_write}, 32'd1, "NOP reg_write");
    chk(cu_ctrl.alu_op,   ALU_ADD,  "NOP alu_op");
    chk(cu_ctrl.alu_b_src, ALU_B_IMM, "NOP alu_b_src");
    chk(cu_ctrl.pc_sel,   PC_NEXT, "NOP pc_sel");
    chk(cu_ctrl.wb_src,   WB_ALU,  "NOP wb_src");
    // R 型
    cu_instr = enc_r(F7_ZERO, 5'd3, 5'd2, 3'b000, 5'd1); #1;   // add
    chk(cu_ctrl.alu_op, ALU_ADD, "ADD alu_op");
    chk(cu_ctrl.alu_b_src, ALU_B_RS2, "ADD alu_b_src");
    chk({31'd0, cu_ctrl.reg_write}, 32'd1, "ADD reg_write");
    cu_instr = enc_r(F7_ALT, 5'd3, 5'd2, 3'b000, 5'd1); #1;    // sub
    chk(cu_ctrl.alu_op, ALU_SUB, "SUB alu_op");
    cu_instr = enc_r(F7_ALT, 5'd3, 5'd2, 3'b101, 5'd1); #1;    // sra
    chk(cu_ctrl.alu_op, ALU_SRA, "SRA alu_op");
    cu_instr = enc_r(7'b0000010, 5'd3, 5'd2, 3'b000, 5'd1); #1; // 非法 funct7
    chk({31'd0, cu_ctrl.illegal}, 32'd1, "R bad funct7 illegal");
    chk({31'd0, cu_ctrl.reg_write}, 32'd0, "illegal R 不写寄存器");
    cu_instr = enc_r(F7_MULDIV, 5'd3, 5'd2, 3'b000, 5'd1); #1; // mul (M 预留)
    chk({31'd0, cu_ctrl.illegal}, 32'd1, "MUL reserved illegal");
    chk({31'd0, cu_ctrl.reg_write}, 32'd0, "MUL 预留不写寄存器");
    // I 型
    cu_instr = enc_i(12'hFF4, 5'd2, 3'b000, 5'd1, OPC_OPIMM); #1;  // addi -12
    chk(cu_ctrl.alu_op, ALU_ADD, "ADDI alu_op");
    chk(cu_ctrl.alu_b_src, ALU_B_IMM, "ADDI alu_b_src");
    cu_instr = enc_i(12'h401, 5'd2, 3'b101, 5'd1, OPC_OPIMM); #1;  // srai 1 (funct7=0100000)
    chk(cu_ctrl.alu_op, ALU_SRA, "SRAI alu_op");
    cu_instr = enc_i(12'h401, 5'd2, 3'b001, 5'd1, OPC_OPIMM); #1;  // slli 非法 funct7
    chk({31'd0, cu_ctrl.illegal}, 32'd1, "SLLI bad funct7 illegal");
    chk({31'd0, cu_ctrl.reg_write}, 32'd0, "illegal I 不写寄存器");
    // LOAD: 重点回归 imm_fmt=IMM_I (旧版 IMM_L 未定义 bug)
    cu_instr = enc_i(12'hFF4, 5'd2, 3'b000, 5'd3, OPC_LOAD); #1;   // lb -12(x2)
    chk(cu_ctrl.imm_fmt, IMM_I, "LB imm_fmt");
    chk(cu_ctrl.mem_size, MEM_BYTE, "LB mem_size");
    chk({31'd0, cu_ctrl.mem_read},  32'd1, "LB mem_read");
    chk({31'd0, cu_ctrl.mem_unsigned}, 32'd0, "LB mem_unsigned");
    chk(cu_ctrl.wb_src, WB_MEM, "LB wb_src");
    cu_instr = enc_i(12'd4, 5'd2, 3'b101, 5'd3, OPC_LOAD); #1;     // lhu
    chk(cu_ctrl.mem_size, MEM_HALF, "LHU mem_size");
    chk({31'd0, cu_ctrl.mem_unsigned}, 32'd1, "LHU mem_unsigned");
    cu_instr = enc_i(12'd4, 5'd2, 3'b010, 5'd3, OPC_LOAD); #1;     // lw
    chk(cu_ctrl.mem_size, MEM_WORD, "LW mem_size");
    cu_instr = enc_i(12'd4, 5'd2, 3'b011, 5'd3, OPC_LOAD); #1;     // 非法 funct3
    chk({31'd0, cu_ctrl.illegal}, 32'd1, "LW f3=011 illegal");
    chk({31'd0, cu_ctrl.reg_write}, 32'd0, "illegal load 不写寄存器");
    chk({31'd0, cu_ctrl.mem_read},  32'd0, "illegal load 不读存储器");
    // 锁存器回归: LHU(mem_unsigned=1) 之后译码 ADDI, mem_unsigned 必须回 0
    cu_instr = enc_i(12'hFFC, 5'd2, 3'b101, 5'd3, OPC_LOAD); #1;    // lhu
    cu_instr = enc_i(12'd1, 5'd2, 3'b000, 5'd1, OPC_OPIMM); #1;    // addi
    chk({31'd0, cu_ctrl.mem_unsigned}, 32'd0, "ADDI mem_unsigned 回默认 (锁存器检查)");
    chk(cu_ctrl.wb_src, WB_ALU, "ADDI wb_src");
    // STORE: 重点回归 wb_src 回默认 (旧版锁存器 bug 会保持 WB_MEM)
    cu_instr = enc_i(12'd4, 5'd2, 3'b010, 5'd3, OPC_LOAD); #1;     // lw (wb_src=WB_MEM)
    cu_instr = enc_s(12'd8, 5'd4, 5'd2, 3'b000); #1;               // sb
    chk(cu_ctrl.wb_src, WB_ALU, "SB wb_src 回默认 (锁存器检查)");
    chk({31'd0, cu_ctrl.mem_write}, 32'd1, "SB mem_write");
    chk({31'd0, cu_ctrl.reg_write}, 32'd0, "SB reg_write");
    chk(cu_ctrl.mem_size, MEM_BYTE, "SB mem_size");
    chk(cu_ctrl.imm_fmt, IMM_S, "SB imm_fmt");
    cu_instr = enc_s(12'd8, 5'd4, 5'd2, 3'b010); #1;               // sw
    chk(cu_ctrl.mem_size, MEM_WORD, "SW mem_size");
    cu_instr = enc_s(12'd8, 5'd4, 5'd2, 3'b100); #1;               // 非法 funct3
    chk({31'd0, cu_ctrl.illegal}, 32'd1, "SB f3=100 illegal");
    chk({31'd0, cu_ctrl.mem_write}, 32'd0, "illegal store 不写存储器");
    // 分支
    cu_instr = enc_b(13'd8, 5'd2, 5'd1, 3'b000); #1;               // beq
    chk(cu_ctrl.pc_sel, PC_BR, "BEQ pc_sel");
    chk(cu_ctrl.branch_type, BR_EQ, "BEQ branch_type");
    chk(cu_ctrl.alu_a_src, ALU_A_PC, "BEQ alu_a_src (目标加法器)");
    chk(cu_ctrl.alu_b_src, ALU_B_IMM, "BEQ alu_b_src");
    chk(cu_ctrl.alu_op, ALU_ADD, "BEQ alu_op");
    chk(cu_ctrl.imm_fmt, IMM_B, "BEQ imm_fmt");
    cu_instr = enc_b(13'd8, 5'd2, 5'd1, 3'b111); #1;               // bgeu
    chk(cu_ctrl.branch_type, BR_GEU, "BGEU branch_type");
    cu_instr = enc_b(13'd8, 5'd2, 5'd1, 3'b010); #1;               // 非法 funct3
    chk({31'd0, cu_ctrl.illegal}, 32'd1, "BR f3=010 illegal");
    chk(cu_ctrl.pc_sel, PC_NEXT, "illegal branch 不跳转");
    // LUI: a=0 修复回归 (旧版 rs1 为垃圾值)
    cu_instr = enc_u(20'hDEADB, 5'd5, OPC_LUI); #1;
    chk(cu_ctrl.alu_a_src, ALU_A_ZERO, "LUI alu_a_src (a=0 修复)");
    chk(cu_ctrl.alu_b_src, ALU_B_IMM, "LUI alu_b_src");
    chk(cu_ctrl.imm_fmt, IMM_U, "LUI imm_fmt");
    chk({31'd0, cu_ctrl.reg_write}, 32'd1, "LUI reg_write");
    // AUIPC: a=PC 修复回归 (旧版 alu_src_pc 从未置位)
    cu_instr = enc_u(20'h00001, 5'd6, OPC_AUIPC); #1;
    chk(cu_ctrl.alu_a_src, ALU_A_PC, "AUIPC alu_a_src (a=PC 修复)");
    chk(cu_ctrl.alu_op, ALU_ADD, "AUIPC alu_op");
    // JAL: pc_sel 必须是 PC_J (旧版误置 jalr 的修复回归)
    cu_instr = enc_j(21'd16, 5'd1); #1;
    chk(cu_ctrl.pc_sel, PC_J, "JAL pc_sel (非 PC_JR 修复)");
    chk(cu_ctrl.wb_src, WB_PC4, "JAL wb_src");
    chk(cu_ctrl.alu_a_src, ALU_A_PC, "JAL alu_a_src");
    chk(cu_ctrl.imm_fmt, IMM_J, "JAL imm_fmt");
    // JALR: wb_src=WB_PC4 修复回归 (旧版漏赋值)
    cu_instr = enc_i(12'd4, 5'd3, 3'b000, 5'd1, OPC_JALR); #1;
    chk(cu_ctrl.pc_sel, PC_JR, "JALR pc_sel");
    chk(cu_ctrl.wb_src, WB_PC4, "JALR wb_src (修复)");
    chk(cu_ctrl.alu_a_src, ALU_A_RS1, "JALR alu_a_src");
    chk(cu_ctrl.alu_b_src, ALU_B_IMM, "JALR alu_b_src");
    chk(cu_ctrl.imm_fmt, IMM_I, "JALR imm_fmt");
    cu_instr = enc_i(12'd4, 5'd3, 3'b001, 5'd1, OPC_JALR); #1;     // 非法 funct3
    chk({31'd0, cu_ctrl.illegal}, 32'd1, "JALR f3=001 illegal");
    chk({31'd0, cu_ctrl.reg_write}, 32'd0, "illegal jalr 不写寄存器");
    chk(cu_ctrl.pc_sel, PC_NEXT, "illegal jalr 不跳转");
    // 未实现/未知 opcode 一律 illegal
    cu_instr = {25'd0, 7'b1110011}; #1;                            // SYSTEM (未实现)
    chk({31'd0, cu_ctrl.illegal}, 32'd1, "SYSTEM illegal");
    chk({31'd0, cu_ctrl.reg_write}, 32'd0, "SYSTEM NOP 安全");
    cu_instr = {25'd0, 7'b0001111}; #1;                            // FENCE (未实现)
    chk({31'd0, cu_ctrl.illegal}, 32'd1, "FENCE illegal");

    // ------------------------------------------------------------------
    $display("[5/6] regfile ...");
    rf_we = 1'b0;
    // 对 x0 的写必须被忽略
    @(negedge clk);
    rf_we = 1'b1; rf_waddr = 5'd0; rf_wdata = 32'hDEADBEEF;
    @(negedge clk);
    rf_we = 1'b0; rf_raddr1 = 5'd0; rf_raddr2 = 5'd0; #1;
    chk(rf_rdata1, 32'd0, "x0 读恒零");
    chk(rf_rdata2, 32'd0, "x0 写被忽略");
    // 全寄存器读写 (x1..x31)
    for (int i = 1; i < 32; i++) begin
      @(negedge clk);
      rf_we = 1'b1; rf_waddr = i[4:0]; rf_wdata = i * 32'h01010101;
    end
    @(negedge clk);          // 最后一笔写 (x31) 需要见到它的 posedge
    rf_we = 1'b0;
    for (int i = 1; i < 32; i++) begin
      rf_raddr1 = i[4:0]; rf_raddr2 = 32 - i[4:0]; #1;
      chk(rf_rdata1, i * 32'h01010101, "写读回端口1");
      chk(rf_rdata2, (32 - i) * 32'h01010101, "写读回端口2");
    end
    // 覆盖写
    @(negedge clk);
    rf_we = 1'b1; rf_waddr = 5'd5; rf_wdata = 32'hCAFEBABE;
    @(negedge clk);
    rf_we = 1'b0; rf_raddr1 = 5'd5; #1;
    chk(rf_rdata1, 32'hCAFEBABE, "覆盖写生效");
    // 异步读的写穿透: 写沿之后同周期读出新值 (未来流水线旁路依赖此语义)
    rf_raddr1 = 5'd7;
    @(negedge clk);
    rf_we = 1'b1; rf_waddr = 5'd7; rf_wdata = 32'h77777777;
    @(posedge clk);
    #1;
    rf_we = 1'b0;
    chk(rf_rdata1, 32'h77777777, "写穿透 (async read)");

    // ------------------------------------------------------------------
    $display("[6/6] pc ...");
    pc_stall = 1'b0; pc_flush = 1'b0; pc_src = 1'b0;
    pc_target = 32'd0; pc_flush_pc = 32'd0;
    // 异步复位到 RESET_PC (非零)
    pc_rst = 1'b1; #1;
    chk(pc_pc, RESET_PC, "复位到 RESET_PC");
    chk(pc_plus4, RESET_PC + 32'd4, "pc_plus4");
    pc_rst = 1'b0;
    // 顺序执行 +4
    @(posedge clk); #1; chk(pc_pc, RESET_PC + 32'd4,  "顺序 +4 (1)");
    @(posedge clk); #1; chk(pc_pc, RESET_PC + 32'd8,  "顺序 +4 (2)");
    // 跳转
    pc_src = 1'b1; pc_target = 32'h0000_0200;
    @(posedge clk); #1; chk(pc_pc, 32'h0000_0200, "跳转到 target");
    // stall: 保持不动
    pc_src = 1'b0; pc_stall = 1'b1;
    @(posedge clk); #1; chk(pc_pc, 32'h0000_0200, "stall 保持");
    @(posedge clk); #1; chk(pc_pc, 32'h0000_0200, "stall 保持 (2)");
    // flush 优先于 stall
    pc_flush = 1'b1; pc_flush_pc = 32'h0000_0300;
    @(posedge clk); #1; chk(pc_pc, 32'h0000_0300, "flush 优先于 stall");
    pc_flush = 1'b0; pc_stall = 1'b0;
    @(posedge clk); #1; chk(pc_pc, 32'h0000_0304, "恢复顺序执行");

    // ------------------------------------------------------------------
    $display("=================================================");
    $display("  检查点: %0d", checks);
    $display("  错误数: %0d", errors);
    if (errors == 0) begin
      $display("  RESULT : PASS");
      $finish;
    end
    else begin
      $display("  RESULT : FAIL");
      $fatal(1);
    end
  end

endmodule
