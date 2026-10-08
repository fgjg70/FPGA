`timescale 1ns/1ps

// ============================================================================
// ref5_core.sv — "教科书式" 普通五级流水线 RV32I (IF / ID / EX / MEM / WB)
// ----------------------------------------------------------------------------
// 这是一个**故意做笨**的参照核, 唯一目标是测出这颗器件上普通五级流水线的
// fmax 上限, 作为后续优化的标尺。功能上只要"能综合、时序口径干净"即可,
// **不需要跑程序、不需要可观测结果**。
//
// 相对主核 (core.sv) 刻意剥离的东西 —— 它们正是主核关键路径上的常客:
//   * **没有数据前递网络** (最贵的一项): RAW 靠"停顿 + 注气泡"解决。
//     ID 段拿 rs1/rs2 与 **EX / MEM / WB 三段**的 rd 比较, 命中就
//     pc 冻结、IF/ID 冻结 (靠 pc_next = pc 实现)、ID/EX 注气泡。
//     比到 WB 段是刻意的: 这样寄存器堆**不需要写旁路 (write-first)**,
//     读口就是一条干净的 LUTRAM 异步读 (RAM32M), 读路径上没有 wdata mux。
//   * **没有分支预测** (无 BTB / 无 RAS / 无 gshare): 分支与跳转在 EX 判定,
//     直接重定向冲刷 IF/ID + ID/EX (代价 2 拍, 我们不在乎)。
//   * **没有 M / A / CSR / trap / ecall / 中断**。
//   * **不 import rv32_pkg**: 自带局部 localparam, 与主核完全解耦。
//
// 唯一"不笨"的地方, 是为了让口径与主核一致而保留的两条:
//   1) imem/dmem 都是**同步读** (推断 BRAM), 与主核默认配置一致;
//   2) 取指地址 = **组合推出的下一拍 pc** (`pc_next`), 于是
//        不变式:  imem_rdata(N) == mem[pc(N)]
//      与主核 imem.sv:11-14 / core.sv:203-208 逐字同一条, IF/ID 不需要
//      额外的相位补偿, 重定向代价就是干净的 2 拍。
//      配套: 复位后冻结取指一拍 (boot_done), 否则第一条指令会被跳过。
//
// 流水结构 (pc 之后 4 个寄存器 ⇒ 5 级, 教科书口径):
//     [IF] pc -> IMEM(同步读, 其输出寄存器即 IF/ID)
//        -> [ID] 译码 + 立即数 + regfile 组合读 (LUTRAM)
//        -> ID/EX -> [EX] ALU + 分支比较 + 跳转目标 -> EX/MEM
//        -> [MEM] dmem 同步读 + 字节通道 -> MEM/WB -> [WB] 写回 mux -> regfile
// ============================================================================

module ref5_core #(
  parameter logic [31:0] PC_RESET = 32'h0000_0000
)(
  input  logic        clk,
  input  logic        rst,          // 异步, 高有效

  // ---- 指令存储器 (同步读, 1 拍延迟) ----
  output logic [31:0] imem_addr,
`ifdef REF5_ENARDEN
  output logic        imem_rd_en,   // 【E1 实验】停顿拍 = 0 -> 冻结 imem 输出寄存器
`endif
  input  logic [31:0] imem_rdata,

  // ---- 数据存储器 (同步读 + 字节写使能) ----
  output logic [31:0] dmem_addr,
  output logic [31:0] dmem_wdata,
  output logic [3:0]  dmem_wstrb,
  output logic        dmem_we,
  input  logic [31:0] dmem_rdata,

  // ---- 观测口 (只为让综合器保住这条反馈链; 不参与功能) ----
  output logic [31:0] dbg_pc
);

  // ==========================================================================
  // 局部常量 (不依赖 rv32_pkg)
  // ==========================================================================
  // opcode
  localparam [6:0] OP_LUI   = 7'b0110111;
  localparam [6:0] OP_AUIPC = 7'b0010111;
  localparam [6:0] OP_JAL   = 7'b1101111;
  localparam [6:0] OP_JALR  = 7'b1100111;
  localparam [6:0] OP_BR    = 7'b1100011;
  localparam [6:0] OP_LOAD  = 7'b0000011;
  localparam [6:0] OP_STORE = 7'b0100011;
  localparam [6:0] OP_IMM   = 7'b0010011;
  localparam [6:0] OP_REG   = 7'b0110011;

  // ALU 操作
  localparam [3:0] A_ADD  = 4'd0,  A_SUB  = 4'd1,  A_SLL  = 4'd2,  A_SLT  = 4'd3,
                   A_SLTU = 4'd4,  A_XOR  = 4'd5,  A_SRL  = 4'd6,  A_SRA  = 4'd7,
                   A_OR   = 4'd8,  A_AND  = 4'd9;

  // ALU 操作数 A 选择
  localparam [1:0] AS_RS1 = 2'd0, AS_PC = 2'd1, AS_ZERO = 2'd2;
  // ALU 操作数 B 选择
  localparam       BS_RS2 = 1'b0, BS_IMM = 1'b1;
  // 下一拍 PC 选择
  localparam [1:0] P_NEXT = 2'd0, P_BR = 2'd1, P_JAL = 2'd2, P_JALR = 2'd3;
  // 立即数格式
  localparam [2:0] F_I = 3'd0, F_S = 3'd1, F_B = 3'd2, F_U = 3'd3, F_J = 3'd4;
  // 写回来源
  localparam [1:0] W_ALU = 2'd0, W_MEM = 2'd1, W_PC4 = 2'd2;
  // 分支比较类型
  localparam [2:0] B_EQ = 3'd0, B_NE = 3'd1, B_LT = 3'd2,
                   B_GE = 3'd3, B_LTU = 3'd4, B_GEU = 3'd5;

  // ==========================================================================
  // 互连信号集中声明 (避免使用前隐式线网 —— 这是本项目反复踩过的坑)
  // ==========================================================================
  // IF
  logic [31:0] pc, pc_plus4, pc_next;
  logic        boot_done;

  // ID
  logic [31:0] if_instr, id_imm, id_rs1_data, id_rs2_data, id_a_sel, id_b_sel;
  logic [4:0]  id_rs1, id_rs2, id_rd;
  logic [3:0]  id_alu_op, id_f3_alu;
  logic [1:0]  id_alu_a, id_alu_b_sel, id_pc_sel, id_wb_sel, id_mem_size;
  logic [2:0]  id_br_type, id_imm_fmt;
  logic        id_reg_write, id_mem_write, id_mem_uns, id_is_reg;

  // 冒险
  logic        ex_wr, mem_wr, wb_wr, raw_ex, raw_mem, raw_wb;
  logic [5:0]  hit;
  // 【V4 扇出约束】主核实测这类广播线扇出可达 60, 单跳就要 1~2ns。
  (* max_fanout = 16 *) logic pipe_stall, redirect;
  logic        fetch_hold, id_ex_en;

  // ID/EX
  logic [31:0] id_ex_pc, id_ex_pc_plus4, id_ex_rs1_data, id_ex_rs2_data, id_ex_imm;
`ifdef REF5_ALU_MFOUT
  // 【E5 实验: ALU 操作数广播网的扇出上限】
  // E1 实验把关键路径暴露到 ALU 之后实测: 这条路 83% 是布线, 其中最贵的一跳是
  // `u_core/ex_b[3]` **单根网驱动 115 个负载 = 3.0ns** (整个 6.857ns 的 44%)。
  // max_fanout 让综合器把该寄存器位复制成若干副本, 每份副本就近驱动一部分负载。
  // 值由 build_ref5.tcl 的 REF5_ALU_MF 给 (默认 16): 值越小副本越多,
  // ALU 侧越松但 D 侧(选择逻辑)负载越重, 是个要实测的折中。
  (* max_fanout = `REF5_ALU_MF *) logic [31:0] id_ex_a, id_ex_b;
`else
  logic [31:0] id_ex_a, id_ex_b;
`endif
  logic [4:0]  id_ex_rd;
  logic [3:0]  id_ex_alu_op;
  logic [1:0]  id_ex_pc_sel, id_ex_wb_sel, id_ex_mem_size;
  logic [2:0]  id_ex_br_type;
  logic        id_ex_reg_write, id_ex_mem_write, id_ex_mem_uns, id_ex_bubble;
  logic        ex_reg_write_eff, ex_mem_write_eff;

  // EX
  logic [31:0] ex_rs1, ex_rs2, ex_a, ex_b, ex_alu_out, ex_ctrl_sum, ex_target;
  logic        ex_eq, ex_lt, ex_ltu, ex_taken, ex_is_ctrl;

  // EX/MEM
  logic [31:0] ex_mem_alu_out, ex_mem_store_data, ex_mem_pc_plus4;
  logic [4:0]  ex_mem_rd;
  logic [1:0]  ex_mem_wb_sel, ex_mem_mem_size, mem_off;
  logic        ex_mem_reg_write, ex_mem_mem_write, ex_mem_mem_uns;

  // MEM/WB
  logic [31:0] mem_wb_alu_out, mem_wb_pc_plus4;
  logic [4:0]  mem_wb_rd;
  logic [1:0]  mem_wb_wb_sel, mem_wb_mem_size, mem_wb_off;
  logic        mem_wb_reg_write, mem_wb_mem_uns;

  // WB
  logic [31:0] wb_load_data, wb_data;
  logic [7:0]  wb_byte;
  logic [15:0] wb_half;
  logic [4:0]  wb_rd;
  logic        wb_reg_write;

  // ==========================================================================
  // IF 段 —— PC
  // ==========================================================================
  // 复位后冻结取指一拍: 让 IMEM 有机会把 PC_RESET 处的指令锁存出来
  // (同步读要一拍; pc 若立即前进, 第一条指令就永远没被取过)。
  always_ff @(posedge clk or posedge rst) begin
    if (rst) boot_done <= 1'b0;
    else     boot_done <= 1'b1;
  end

  // PC: 停顿/重定向都已经体现在 pc_next 里 (fetch_hold 时 pc_next = pc)
  always_ff @(posedge clk or posedge rst) begin
    if (rst) pc <= PC_RESET;
    else     pc <= pc_next;
  end

  assign pc_plus4 = pc + 32'd4;
  assign dbg_pc   = pc;

  // ==========================================================================
  // ID 段 (组合) —— 指令 = imem_rdata = mem[pc]
  // ==========================================================================
  assign if_instr  = imem_rdata;
  assign id_rs1    = if_instr[19:15];
  assign id_rs2    = if_instr[24:20];
  assign id_rd     = if_instr[11:7];
  assign id_is_reg = (if_instr[6:0] == OP_REG);

  // ---- OP / OP-IMM 共用的 funct3 -> ALU 映射 ----
  // SUB 只可能出现在 OP (寄存器型), 否则 ADDI 的 imm[10] 会被当成 bit30 误判
  // 成减法; SRA/SRAI 两者都用 bit30。
  always_comb begin
    case (if_instr[14:12])
      3'b000:  id_f3_alu = (id_is_reg && if_instr[30]) ? A_SUB : A_ADD;
      3'b001:  id_f3_alu = A_SLL;
      3'b010:  id_f3_alu = A_SLT;
      3'b011:  id_f3_alu = A_SLTU;
      3'b100:  id_f3_alu = A_XOR;
      3'b101:  id_f3_alu = if_instr[30] ? A_SRA : A_SRL;
      3'b110:  id_f3_alu = A_OR;
      default: id_f3_alu = A_AND;
    endcase
  end

  // ---- 译码 (窄编码控制束) ----
  always_comb begin
    // 默认: 中性 (非法/未实现指令 = NOP, 零副作用)
    id_alu_op    = A_ADD;
    id_alu_a     = AS_RS1;
    id_alu_b_sel = BS_RS2;
    id_pc_sel    = P_NEXT;
    id_br_type   = if_instr[14:12];
    id_imm_fmt   = F_I;
    id_wb_sel    = W_ALU;
    id_mem_size  = if_instr[13:12];
    id_mem_uns   = if_instr[14];
    id_reg_write = 1'b0;
    id_mem_write = 1'b0;

    case (if_instr[6:0])
      OP_LUI:   begin id_alu_a = AS_ZERO; id_alu_b_sel = BS_IMM;
                      id_imm_fmt = F_U; id_reg_write = 1'b1; end
      OP_AUIPC: begin id_alu_a = AS_PC;   id_alu_b_sel = BS_IMM;
                      id_imm_fmt = F_U; id_reg_write = 1'b1; end
      OP_JAL:   begin id_pc_sel = P_JAL; id_imm_fmt = F_J;
                      id_wb_sel = W_PC4; id_reg_write = 1'b1; end
      OP_JALR:  begin id_pc_sel = P_JALR; id_imm_fmt = F_I;
                      id_wb_sel = W_PC4; id_reg_write = 1'b1; end
      OP_BR:    begin id_pc_sel = P_BR; id_imm_fmt = F_B; end
      OP_LOAD:  begin id_alu_op = A_ADD; id_alu_b_sel = BS_IMM; id_imm_fmt = F_I;
                      id_wb_sel = W_MEM; id_reg_write = 1'b1; end
      OP_STORE: begin id_alu_op = A_ADD; id_alu_b_sel = BS_IMM; id_imm_fmt = F_S;
                      id_mem_write = 1'b1; end
      OP_IMM:   begin id_alu_op = id_f3_alu; id_alu_b_sel = BS_IMM;
                      id_imm_fmt = F_I; id_reg_write = 1'b1; end
      OP_REG:   begin id_alu_op = id_f3_alu; id_reg_write = 1'b1; end
      default:  ;   // NOP
    endcase
  end

  // ---- 立即数生成 (纯连线/小 mux) ----
  always_comb begin
    case (id_imm_fmt)
      F_I:     id_imm = {{20{if_instr[31]}}, if_instr[31:20]};
      F_S:     id_imm = {{20{if_instr[31]}}, if_instr[31:25], if_instr[11:7]};
      F_B:     id_imm = {{19{if_instr[31]}}, if_instr[31], if_instr[7],
                         if_instr[30:25], if_instr[11:8], 1'b0};
      F_U:     id_imm = {if_instr[31:12], 12'b0};
      default: id_imm = {{11{if_instr[31]}}, if_instr[31], if_instr[19:12],
                         if_instr[20], if_instr[30:21], 1'b0};   // F_J
    endcase
  end

  // ==========================================================================
  // 寄存器堆 —— 组合读, 推断 LUTRAM (RAM32M), 零 BRAM
  // --------------------------------------------------------------------------
  // 无写旁路: 写 x0 被忽略 ⇒ mem[0] 恒 0 ⇒ 读 x0 天然得 0, 读路径上没有
  // 任何 x0 mux、也没有 wdata mux (RAW 由"比到 WB 段"的停顿覆盖)。
  // ==========================================================================
  logic [31:0] rf [32];
  integer      rf_i;

  initial begin
    for (rf_i = 0; rf_i < 32; rf_i = rf_i + 1) rf[rf_i] = 32'd0;
  end

  always @(posedge clk) begin
    if (wb_reg_write && (wb_rd != 5'd0)) rf[wb_rd] <= wb_data;
  end

  assign id_rs1_data = rf[id_rs1];
  assign id_rs2_data = rf[id_rs2];

  // ---- ALU 操作数在 ID 段就选好 (V4) ----
  // ex_a 原本是 3:1 (PC/ZERO/rs1)、ex_b 是 2:1 (imm/rs2), 两级 mux 直接压在
  // ID/EX -> ALU 这条路径上。挪到 ID 段后, 这些 mux 的终点变成一个普通 FF,
  // EX 段从 FF 出发直接进加法器。
  // 注意: 原来的 id_ex_rs1_data / rs2_data 仍然保留 —— 分支比较、存数数据、
  // JALR 目标要用**原始** rs 值 (STORE 的 alu_b 是 imm, 不能用选好的 b)。
  assign id_a_sel = (id_alu_a == AS_PC)   ? pc :
                    (id_alu_a == AS_ZERO) ? 32'd0 : id_rs1_data;
  assign id_b_sel = (id_alu_b_sel == BS_IMM) ? id_imm : id_rs2_data;

  // ==========================================================================
  // 冒险判定 —— 最笨的"停顿 + 气泡", 不打前递
  // --------------------------------------------------------------------------
  // 与 **EX / MEM / WB** 三段的 rd 比。比到 WB 段是刻意的: 省掉写旁路。
  // 代价: 距离 1 的 RAW 停 3 拍 —— 我们不在乎吞吐, 只在乎关键路径。
  // 只比较字段、不看"这条指令是否真的用该源": 多停是安全的 (生产者最多在
  // 三段内一定离开流水线, 不会死锁)。
  //
  // 【V4 扁平化, 保留】写成 6 个并行 term + 一次 6 输入 OR:
  //   5 位相等比较 + 1 个使能 = 正好一个 LUT6  => 第 1 级;
  //   6 个 term 的 OR 也是一个 LUT6            => 第 2 级。
  // (V4 当时还额外把 `!redirect` 折进使能里, 那一步在 V6 被**撤回**, 见下。)
  // ==========================================================================
  // 【V6 关键改动 —— 把 redirect 从冒险路径上摘掉】
  //   V4 曾把 `!redirect` 折进三个使能里, 结果形成
  //       id_ex 寄存器 -> 32 位比较 -> redirect -> hit -> pipe_stall
  //         -> fetch_hold -> 取指地址 mux -> imem 地址脚
  //   一条又长又绕的路 (实测 7.376ns, 10 级)。
  //   现在**不折**了: 重定向那拍就算 pipe_stall=1 也无害 —— pc_next 里
  //   `redirect` 的优先级高于 `fetch_hold`, 而 ID/EX 那拍本来就该注气泡,
  //   错路指令被丢掉。于是 redirect 只驱动 mux 选择和 id_ex_en,
  //   冒险路径与它彻底解耦。
  assign ex_wr  = ex_reg_write_eff && (id_ex_rd != 5'd0);
  assign mem_wr = ex_mem_reg_write && (ex_mem_rd != 5'd0);
  assign wb_wr  = mem_wb_reg_write && (mem_wb_rd != 5'd0);

  assign hit[0] = (id_rs1 == id_ex_rd)  && ex_wr;
  assign hit[1] = (id_rs2 == id_ex_rd)  && ex_wr;
  assign hit[2] = (id_rs1 == ex_mem_rd) && mem_wr;
  assign hit[3] = (id_rs2 == ex_mem_rd) && mem_wr;
  assign hit[4] = (id_rs1 == mem_wb_rd) && wb_wr;
  assign hit[5] = (id_rs2 == mem_wb_rd) && wb_wr;

  assign raw_ex     = hit[0] | hit[1];
  assign raw_mem    = hit[2] | hit[3];
  assign raw_wb     = hit[4] | hit[5];
  assign pipe_stall = |hit;

  assign fetch_hold = pipe_stall || !boot_done;
  assign id_ex_en   = !(pipe_stall || redirect);   // ID/EX 装载使能 (否则注气泡)

  // 取指地址 = 组合推出的下一拍 pc (与主核同一条不变式)
  // 【V6 优先级】redirect 优先于 fetch_hold: 重定向是"必须立刻改地址"的事件,
  //   停顿那拍可能同时成立, 但此时 ID 里是错路指令, 停不停都无所谓。
`ifdef REF5_ENARDEN
  // ==========================================================================
  // 【E1 实验: 取指环去地址 mux】见 REPORT_E1.md
  // --------------------------------------------------------------------------
  // V7: imem_addr = pc_next, 于是 `pipe_stall -> fetch_hold -> 地址 mux ->
  //     imem 地址脚` 是同一拍里的组合环 (实测 6.760ns / 4 级, 最坏路径)。
  // E1: 停顿不再改地址, 而是把 imem 的**读使能**拉低 -> 输出寄存器冻结。
  //     * imem_addr 只由**已寄存的 pc**(+EX 的 redirect)决定,
  //       pipe_stall 彻底离开地址脚;
  //     * pc 仍然在停顿拍冻结 (pc_next 里的 fetch_hold) —— 这是配对正确性
  //       的必要条件, 只是它的终点变成 pc 这个普通 FF, 不再是 BRAM 的地址脚。
  //
  // 配对不变式 imem_rdata(N) == mem[pc(N)] 的推理 (N 为周期号):
  //   addr(N-1) = redirect(N-1) ? T : (boot_done ? pc(N-1)+4 : pc(N-1))
  //   pc(N)     = redirect(N-1) ? T : (fetch_hold ? pc(N-1) : pc(N-1)+4)
  //   rd_en(N-1)= !pipe_stall | redirect | !boot_done
  //   ① redirect(N-1)=1: addr=T=pc(N), 且 rd_en=1 -> rdata(N)=mem[T]=mem[pc(N)] ✓
  //   ② 无 redirect、boot_done=1、!pipe_stall: addr=pc(N-1)+4=pc(N), rd_en=1 ✓
  //   ③ 无 redirect、boot_done=1、pipe_stall: pc(N)=pc(N-1) 且 rd_en=0
  //      -> rdata(N)=rdata(N-1)=mem[pc(N-1)]=mem[pc(N)] (归纳) ✓
  //   ④ boot_done=0: addr=pc(N-1)=pc(N) (pc 冻结), rd_en=1 -> rdata(N)=mem[pc(N)] ✓
  //   即: 停顿拍地址可以随便跑, 因为输出被冻结; 而"冻结输出"与"冻结 pc"
  //   同时成立, 所以解冻那一刻 addr 正好又等于 pc(N)+4 = 下一拍 pc。位序/配对不变。
  // ==========================================================================
  assign pc_next    = redirect ? ex_target : (fetch_hold ? pc : pc_plus4);
  assign imem_addr  = redirect ? ex_target : (boot_done ? pc_plus4 : pc);
  assign imem_rd_en = !pipe_stall || redirect || !boot_done;
`else
  assign pc_next   = redirect ? ex_target
                              : (fetch_hold ? pc : pc_plus4);
  assign imem_addr = pc_next;
`endif

  // ==========================================================================
  // ID/EX
  // --------------------------------------------------------------------------
  // 数据字段**无条件**锁存: 停顿期间 pc 冻结 ⇒ imem_rdata 稳定 ⇒ ID 的值
  // 本来就不变。控制字段也**不再做 id_ex_en 的 2:1 mux** (V7) ——
  //   V6 的关键路径是 `imem 输出 -> 冒险比较 -> pipe_stall -> id_ex_en ->
  //   控制位 D 端` (5 级), 那条 mux 把 30 多个控制位全都挂在冒险逻辑上。
  //   现在只寄存 **1 位气泡标志** `id_ex_bubble`, 效果信号在 EX 段门控
  //   (需要门控的只有 3 个: 跳转/寄存器写/存储器写 —— wb_sel/mem_size/rd
  //    等只在有写使能时才有意义, 不必门控)。
  //   于是控制位的 D 端变成**纯译码输出**, 完全脱离冒险路径。
  // ==========================================================================
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      id_ex_alu_op    <= A_ADD;
      id_ex_pc_sel    <= P_NEXT;
      id_ex_br_type   <= B_EQ;
      id_ex_wb_sel    <= W_ALU;
      id_ex_mem_size  <= 2'b10;
      id_ex_mem_uns   <= 1'b0;
      id_ex_reg_write <= 1'b0;
      id_ex_mem_write <= 1'b0;
      id_ex_bubble    <= 1'b1;
      id_ex_pc        <= PC_RESET;
      id_ex_pc_plus4  <= PC_RESET + 32'd4;
      id_ex_rs1_data  <= 32'd0;
      id_ex_rs2_data  <= 32'd0;
      id_ex_imm       <= 32'd0;
      id_ex_a         <= 32'd0;
      id_ex_b         <= 32'd0;
      id_ex_rd        <= 5'd0;
    end
    else begin
      id_ex_alu_op    <= id_alu_op;
      id_ex_pc_sel    <= id_pc_sel;
      id_ex_br_type   <= id_br_type;
      id_ex_wb_sel    <= id_wb_sel;
      id_ex_mem_size  <= id_mem_size;
      id_ex_mem_uns   <= id_mem_uns;
      id_ex_reg_write <= id_reg_write;
      id_ex_mem_write <= id_mem_write;
      id_ex_bubble    <= !id_ex_en;
      id_ex_rd        <= id_rd;
      // ---- 数据 (无条件) ----
      id_ex_pc        <= pc;
      id_ex_pc_plus4  <= pc_plus4;
      id_ex_rs1_data  <= id_rs1_data;
      id_ex_rs2_data  <= id_rs2_data;
      id_ex_imm       <= id_imm;
      id_ex_a         <= id_a_sel;
      id_ex_b         <= id_b_sel;
    end
  end

  // ==========================================================================
  // EX 段
  // ==========================================================================
  // 操作数: 无前递, 且**操作数选择已经在 ID 段做完**(V4) —— 这里直接进 ALU。
  assign ex_rs1 = id_ex_rs1_data;      // 原始 rs1 (分支比较 / JALR 目标用)
  assign ex_rs2 = id_ex_rs2_data;      // 原始 rs2 (分支比较 / 存数用)
  assign ex_a   = id_ex_a;             // 已选好的 ALU 操作数 A
  assign ex_b   = id_ex_b;             // 已选好的 ALU 操作数 B

  // ---- ALU ----
  always_comb begin
    case (id_ex_alu_op)
      A_ADD:   ex_alu_out = ex_a + ex_b;
      A_SUB:   ex_alu_out = ex_a - ex_b;
      A_SLL:   ex_alu_out = ex_a << ex_b[4:0];
      A_SLT:   ex_alu_out = {31'b0, ($signed(ex_a) < $signed(ex_b))};
      A_SLTU:  ex_alu_out = {31'b0, (ex_a < ex_b)};
      A_XOR:   ex_alu_out = ex_a ^ ex_b;
      A_SRL:   ex_alu_out = ex_a >> ex_b[4:0];
      A_SRA:   ex_alu_out = $signed(ex_a) >>> ex_b[4:0];
      A_OR:    ex_alu_out = ex_a | ex_b;
      default: ex_alu_out = ex_a & ex_b;      // A_AND
    endcase
  end

  // ---- 分支比较 (直接用 ID/EX 的 rs 值, 不穿 ALU 的操作数 mux) ----
  assign ex_eq  = (ex_rs1 == ex_rs2);
  assign ex_lt  = ($signed(ex_rs1) < $signed(ex_rs2));
  assign ex_ltu = (ex_rs1 < ex_rs2);

  always_comb begin
    case (id_ex_br_type)
      B_EQ:    ex_taken =  ex_eq;
      B_NE:    ex_taken = !ex_eq;
      B_LT:    ex_taken =  ex_lt;
      B_GE:    ex_taken = !ex_lt;
      B_LTU:   ex_taken =  ex_ltu;
      default: ex_taken = !ex_ltu;           // B_GEU
    endcase
  end

  // ---- 控制流目标 (独立加法器, 不兼职 ALU, 只有 1 级操作数 mux) ----
  assign ex_ctrl_sum = ((id_ex_pc_sel == P_JALR) ? ex_rs1 : id_ex_pc) + id_ex_imm;
  assign ex_target   = (id_ex_pc_sel == P_JALR) ? {ex_ctrl_sum[31:1], 1'b0}
                                                : ex_ctrl_sum;

  // ---- 重定向 (无预测: 分支 taken 或任何跳转即冲刷) ----
  // V7: 气泡门控挪到这里 (原来的 id_ex_en 只留 1 位 id_ex_bubble)
  assign ex_reg_write_eff = id_ex_reg_write && !id_ex_bubble;
  assign ex_mem_write_eff = id_ex_mem_write && !id_ex_bubble;
  assign ex_is_ctrl = (id_ex_pc_sel != P_NEXT) && !id_ex_bubble;
  assign redirect   = ex_is_ctrl && ((id_ex_pc_sel == P_BR) ? ex_taken : 1'b1);

  // ==========================================================================
  // EX/MEM
  // ==========================================================================
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      ex_mem_alu_out   <= 32'd0;
      ex_mem_store_data<= 32'd0;
      ex_mem_pc_plus4  <= 32'd0;
      ex_mem_rd        <= 5'd0;
      ex_mem_wb_sel    <= W_ALU;
      ex_mem_mem_size  <= 2'b10;
      ex_mem_reg_write <= 1'b0;
      ex_mem_mem_write <= 1'b0;
      ex_mem_mem_uns   <= 1'b0;
    end
    else begin
      ex_mem_alu_out   <= ex_alu_out;
      ex_mem_store_data<= ex_rs2;
      ex_mem_pc_plus4  <= id_ex_pc_plus4;
      ex_mem_rd        <= id_ex_rd;
      ex_mem_wb_sel    <= id_ex_wb_sel;
      ex_mem_mem_size  <= id_ex_mem_size;
      ex_mem_reg_write <= ex_reg_write_eff;
      ex_mem_mem_write <= ex_mem_write_eff;
      ex_mem_mem_uns   <= id_ex_mem_uns;
    end
  end

  // ==========================================================================
  // MEM 段
  // ==========================================================================
  assign dmem_addr = ex_mem_alu_out;
  assign dmem_we   = ex_mem_mem_write;
  assign mem_off   = ex_mem_alu_out[1:0];

  always_comb begin
    case (ex_mem_mem_size)
      2'b00: begin   // SB
        dmem_wstrb = 4'b0001 << mem_off;
        dmem_wdata = {4{ex_mem_store_data[7:0]}} << (8 * mem_off);
      end
      2'b01: begin   // SH
        dmem_wstrb = 4'b0011 << mem_off;
        dmem_wdata = {2{ex_mem_store_data[15:0]}} << (8 * mem_off);
      end
      default: begin // SW
        dmem_wstrb = 4'b1111;
        dmem_wdata = ex_mem_store_data;
      end
    endcase
  end

  // ==========================================================================
  // MEM/WB
  // --------------------------------------------------------------------------
  // load 数据**不进**这个寄存器: dmem 自己的输出寄存器就是那一拍
  // (地址在 MEM 拍给出, 数据正好在 WB 拍有效), 与主核默认口径一致。
  // ==========================================================================
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      mem_wb_alu_out   <= 32'd0;
      mem_wb_pc_plus4  <= 32'd0;
      mem_wb_rd        <= 5'd0;
      mem_wb_wb_sel    <= W_ALU;
      mem_wb_mem_size  <= 2'b10;
      mem_wb_mem_uns   <= 1'b0;
      mem_wb_off       <= 2'd0;
      mem_wb_reg_write <= 1'b0;
    end
    else begin
      mem_wb_alu_out   <= ex_mem_alu_out;
      mem_wb_pc_plus4  <= ex_mem_pc_plus4;
      mem_wb_rd        <= ex_mem_rd;
      mem_wb_wb_sel    <= ex_mem_wb_sel;
      mem_wb_mem_size  <= ex_mem_mem_size;
      mem_wb_mem_uns   <= ex_mem_mem_uns;
      mem_wb_off       <= mem_off;
      mem_wb_reg_write <= ex_mem_reg_write;
    end
  end

  // ==========================================================================
  // WB 段
  // ==========================================================================
  assign wb_byte = dmem_rdata[8*mem_wb_off +: 8];
  assign wb_half = dmem_rdata[8*mem_wb_off +: 16];
  assign wb_rd        = mem_wb_rd;
  assign wb_reg_write = mem_wb_reg_write;

  always_comb begin
    case (mem_wb_mem_size)
      2'b00:   wb_load_data = mem_wb_mem_uns ? {24'b0, wb_byte}
                                             : {{24{wb_byte[7]}}, wb_byte};
      2'b01:   wb_load_data = mem_wb_mem_uns ? {16'b0, wb_half}
                                             : {{16{wb_half[15]}}, wb_half};
      default: wb_load_data = dmem_rdata;
    endcase
  end

  always_comb begin
    case (mem_wb_wb_sel)
      W_MEM:   wb_data = wb_load_data;
      W_PC4:   wb_data = mem_wb_pc_plus4;
      default: wb_data = mem_wb_alu_out;
    endcase
  end

endmodule
