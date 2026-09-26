`timescale 1ns/1ps

// ============================================================================
// core.sv — RV32I 五级流水线处理器 (IF / ID / EX / MEM / WB)
// ----------------------------------------------------------------------------
// 流水线结构:
//   IF  : PC -> imem (组合读)                              => IF/ID
//   ID  : control_unit 译码, imm_gen, regfile 读 (组合读)   => ID/EX
//   EX  : 前递 mux -> ALU (兼职跳转目标加法器) + branch_unit 判定 => EX/MEM
//   MEM : load_store_unit (字节通道 + 非对齐拆分) + dmem      => MEM/WB
//   WB  : 写回 mux -> regfile
//
// 关键设计点 (详见各模块头注释与 rv32_pkg 顶部契约):
//   - 跳转目标复用 ALU: BR/JAL 用 a=PC, JALR 用 a=rs1, b=imm; JALR 目标清最低位
//   - 分支/跳转在 EX 判定, 重定向冲刷 IF/ID 与 ID/EX 两级 (2 周期惩罚)
//   - load-use 停顿 1 拍; 非对齐跨字访存在 MEM 占 2 拍 (冻结 1 拍)
//   - 寄存器堆组合读 + 写旁路 (write-first): 覆盖"距离 3"的 RAW 依赖
//     (WB 写与 ID 读同拍); 距离 1/2 由 hazard_unit 前递, load-use 停顿 1 拍
//   - 非法指令: 控制束已中性化为无副作用, 此处仅置粘滞调试标志 (trap 预留)
//   - 调试口: dbg_pc / dbg_instr / dbg_illegal / dbg_raddr -> dbg_rdata
// ============================================================================

module core
  import rv32_pkg::*;
(
  input  logic        clk,
  input  logic        rst,

  // 调试接口 (仿真 / ILA; 可悬空)
  output logic [31:0] dbg_pc,
  output logic [31:0] dbg_instr,
  output logic        dbg_illegal,
  input  logic [4:0]  dbg_raddr,
  output logic [31:0] dbg_rdata
);

  // ==========================================================================
  // 互连信号声明 (集中声明, 避免使用前隐式线网)
  // ==========================================================================
  // IF
  logic [31:0] pc, pc_plus4, pc_target, imem_rdata;
  logic        pc_src;
  logic        redirect, redirect_raw;
  logic        lsu_stall;
  logic        id_ex_bubble;

  // IF/ID
  logic [31:0] if_pc, if_pc_plus4, if_instr;

  // ID
  ctrl_s       id_ctrl;
  logic [31:0] id_imm, id_rs1_data, id_rs2_data;
  logic [4:0]  id_rs1, id_rs2, id_rd;

  // ID/EX
  ctrl_s       id_ex_ctrl;
  logic [31:0] id_ex_pc, id_ex_pc_plus4, id_ex_rs1_data, id_ex_rs2_data, id_ex_imm;
  logic [4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;

  // EX
  fwd_sel_e    fwd_a, fwd_b;
  logic [31:0] ex_rs1, ex_rs2, ex_a, ex_b, ex_alu_out, ex_pc_target;
  logic        ex_taken;

  // EX/MEM
  ctrl_s       ex_mem_ctrl;
  logic [31:0] ex_mem_alu_out, ex_mem_store_data, ex_mem_pc_plus4;
  logic [4:0]  ex_mem_rd;

  // MEM
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata, mem_load_data;
  logic [3:0]  dmem_wstrb;
  logic        dmem_we;

  // MEM/WB
  ctrl_s       mem_wb_ctrl;
  logic [31:0] mem_wb_alu_out, mem_wb_load_data, mem_wb_pc_plus4;
  logic [4:0]  mem_wb_rd;

  // WB
  logic [31:0] wb_data;
  logic [4:0]  wb_rd;
  logic        wb_reg_write;

  // 流水线控制
  logic        pipe_stall, if_id_flush, hold_mem;

  // ==========================================================================
  // IF 段
  // ==========================================================================
  pc #(.XLEN(XLEN), .RESET_PC(PC_RESET)) u_pc (
    .clk       (clk),
    .rst       (rst),
    .stall     (pipe_stall),
    .flush     (1'b0),          // 预留: trap 单元接管时改用 flush_pc
    .flush_pc  ('0),
    .pc_src    (pc_src),
    .pc_target (pc_target),
    .pc        (pc),
    .pc_plus4  (pc_plus4)
  );

  imem #(.BASE(IMEM_BASE), .BYTES(IMEM_BYTES)) u_imem (
    .addr  (pc),
    .rdata (imem_rdata)
  );

  assign if_id_flush = redirect;

  if_id_reg #(.RESET_PC(PC_RESET)) u_if_id (
    .clk         (clk),
    .rst         (rst),
    .flush       (if_id_flush),
    .stall       (pipe_stall),
    .pc_in       (pc),
    .pc_plus4_in (pc_plus4),
    .instr_in    (imem_rdata),
    .pc          (if_pc),
    .pc_plus4    (if_pc_plus4),
    .instr       (if_instr)
  );

  // ==========================================================================
  // ID 段
  // ==========================================================================
  assign id_rs1 = if_instr[19:15];
  assign id_rs2 = if_instr[24:20];
  assign id_rd  = if_instr[11:7];

  control_unit u_ctrl (
    .instr (if_instr),
    .ctrl  (id_ctrl)
  );

  imm_gen u_imm (
    .instr   (if_instr),
    .fmt     (id_ctrl.imm_fmt),
    .imm_out (id_imm)
  );

  regfile #(.XLEN(XLEN), .NUM_REGS(32)) u_regfile (
    .clk       (clk),
    .we        (wb_reg_write),
    .waddr     (wb_rd),
    .wdata     (wb_data),
    .raddr1    (id_rs1),
    .raddr2    (id_rs2),
    .rdata1    (id_rs1_data),
    .rdata2    (id_rs2_data),
    .dbg_raddr (dbg_raddr),
    .dbg_rdata (dbg_rdata)
  );

  id_ex_reg u_id_ex (
    .clk         (clk),
    .rst         (rst),
    .flush       (redirect),
    .stall       (pipe_stall),
    .bubble      (id_ex_bubble),
    .ctrl_in     (id_ctrl),
    .pc_in       (if_pc),
    .pc_plus4_in (if_pc_plus4),
    .rs1_data_in (id_rs1_data),
    .rs2_data_in (id_rs2_data),
    .imm_in      (id_imm),
    .rs1_addr_in (id_rs1),
    .rs2_addr_in (id_rs2),
    .rd_addr_in  (id_rd),
    .ctrl        (id_ex_ctrl),
    .pc          (id_ex_pc),
    .pc_plus4    (id_ex_pc_plus4),
    .rs1_data    (id_ex_rs1_data),
    .rs2_data    (id_ex_rs2_data),
    .imm         (id_ex_imm),
    .rs1_addr    (id_ex_rs1),
    .rs2_addr    (id_ex_rs2),
    .rd_addr     (id_ex_rd)
  );

  // ==========================================================================
  // EX 段
  // ==========================================================================
  always_comb begin
    // 前递 mux
    ex_rs1 = (fwd_a == FWD_EX_MEM) ? ex_mem_alu_out :
             (fwd_a == FWD_MEM_WB) ? wb_data : id_ex_rs1_data;
    ex_rs2 = (fwd_b == FWD_EX_MEM) ? ex_mem_alu_out :
             (fwd_b == FWD_MEM_WB) ? wb_data : id_ex_rs2_data;
    // ALU 操作数 mux (契约见 rv32_pkg 顶部)
    ex_a = (id_ex_ctrl.alu_a_src == ALU_A_PC)   ? id_ex_pc :
           (id_ex_ctrl.alu_a_src == ALU_A_ZERO) ? 32'd0 : ex_rs1;
    ex_b = (id_ex_ctrl.alu_b_src == ALU_B_IMM)  ? id_ex_imm : ex_rs2;
  end

  alu #(.XLEN(XLEN)) u_alu (
    .a   (ex_a),
    .b   (ex_b),
    .op  (id_ex_ctrl.alu_op),
    .out (ex_alu_out)
  );

  branch_unit #(.XLEN(XLEN)) u_branch (
    .rs1         (ex_rs1),        // 分支用前递后的寄存器值
    .rs2         (ex_rs2),
    .branch_type (id_ex_ctrl.branch_type),
    .taken       (ex_taken)
  );

  // 跳转目标: JALR 清最低位 (规范要求), 其余取 ALU 结果
  assign ex_pc_target = (id_ex_ctrl.pc_sel == PC_JR)
                        ? {ex_alu_out[31:1], 1'b0}
                        : ex_alu_out;

  assign redirect_raw = ((id_ex_ctrl.pc_sel == PC_BR) && ex_taken) ||
                        (id_ex_ctrl.pc_sel == PC_J) ||
                        (id_ex_ctrl.pc_sel == PC_JR);

  assign pc_src    = redirect;        // 由 hazard_unit 门控后的重定向
  assign pc_target = ex_pc_target;

  // ==========================================================================
  // 冒险单元
  // ==========================================================================
  hazard_unit u_hazard (
    .id_ex_rs1        (id_ex_rs1),
    .id_ex_rs2        (id_ex_rs2),
    .id_ex_mem_read   (id_ex_ctrl.mem_read),
    .id_ex_rd         (id_ex_rd),
    .ex_mem_reg_write (ex_mem_ctrl.reg_write),
    .ex_mem_mem_read  (ex_mem_ctrl.mem_read),
    .ex_mem_rd        (ex_mem_rd),
    .mem_wb_reg_write (mem_wb_ctrl.reg_write),
    .mem_wb_rd        (mem_wb_rd),
    .if_id_rs1        (id_rs1),
    .if_id_rs2        (id_rs2),
    .lsu_stall        (lsu_stall),
    .redirect_raw     (redirect_raw),
    .fwd_a            (fwd_a),
    .fwd_b            (fwd_b),
    .pipe_stall       (pipe_stall),
    .id_ex_bubble     (id_ex_bubble),
    .hold_mem         (hold_mem),
    .redirect         (redirect)
  );

  // ==========================================================================
  // EX/MEM
  // ==========================================================================
  ex_mem_reg u_ex_mem (
    .clk           (clk),
    .rst           (rst),
    .stall         (hold_mem),
    .ctrl_in       (id_ex_ctrl),
    .alu_out_in    (ex_alu_out),
    .store_data_in (ex_rs2),         // store 数据 (前递后)
    .pc_plus4_in   (id_ex_pc_plus4),
    .rd_addr_in    (id_ex_rd),
    .ctrl          (ex_mem_ctrl),
    .alu_out       (ex_mem_alu_out),
    .store_data    (ex_mem_store_data),
    .pc_plus4      (ex_mem_pc_plus4),
    .rd_addr       (ex_mem_rd)
  );

  // ==========================================================================
  // MEM 段
  // ==========================================================================
  load_store_unit u_lsu (
    .clk          (clk),
    .rst          (rst),
    .req_read     (ex_mem_ctrl.mem_read),
    .req_write    (ex_mem_ctrl.mem_write),
    .req_size     (ex_mem_ctrl.mem_size),
    .req_unsigned (ex_mem_ctrl.mem_unsigned),
    .req_addr     (ex_mem_alu_out),
    .req_wdata    (ex_mem_store_data),
    .dmem_addr    (dmem_addr),
    .dmem_wdata   (dmem_wdata),
    .dmem_wstrb   (dmem_wstrb),
    .dmem_we      (dmem_we),
    .dmem_rdata   (dmem_rdata),
    .load_data    (mem_load_data),
    .lsu_stall    (lsu_stall)
  );

  dmem #(.BASE(DMEM_BASE), .BYTES(DMEM_BYTES)) u_dmem (
    .clk   (clk),
    .addr  (dmem_addr),
    .wdata (dmem_wdata),
    .wstrb (dmem_wstrb),
    .we    (dmem_we),
    .rdata (dmem_rdata)
  );

  // ==========================================================================
  // MEM/WB 与 WB 段
  // ==========================================================================
  mem_wb_reg u_mem_wb (
    .clk          (clk),
    .rst          (rst),
    .stall        (hold_mem),
    .ctrl_in      (ex_mem_ctrl),
    .alu_out_in   (ex_mem_alu_out),
    .load_data_in (mem_load_data),
    .pc_plus4_in  (ex_mem_pc_plus4),
    .rd_addr_in   (ex_mem_rd),
    .ctrl         (mem_wb_ctrl),
    .alu_out      (mem_wb_alu_out),
    .load_data    (mem_wb_load_data),
    .pc_plus4     (mem_wb_pc_plus4),
    .rd_addr      (mem_wb_rd)
  );

  always_comb begin
    case (mem_wb_ctrl.wb_src)
      WB_MEM:  wb_data = mem_wb_load_data;
      WB_PC4:  wb_data = mem_wb_pc_plus4;
      default: wb_data = mem_wb_alu_out;      // WB_ALU
    endcase
  end

  assign wb_reg_write = mem_wb_ctrl.reg_write && (mem_wb_rd != 5'd0);
  assign wb_rd        = mem_wb_rd;

  // ==========================================================================
  // 调试与仿真专用
  // ==========================================================================
  assign dbg_pc    = pc;
  assign dbg_instr = if_instr;

  always_ff @(posedge clk or posedge rst) begin
    if (rst)                                  dbg_illegal <= 1'b0;
    else if (id_ctrl.illegal && !pipe_stall)  dbg_illegal <= 1'b1;
  end

  // 跳转目标必须 4 字节对齐 (未来 trap 单元接管时删除此断言)
  `ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && redirect && (pc_target[1:0] != 2'b00)) begin
      $error("instruction address misaligned: target=%h", pc_target);
    end
  end
  `endif

endmodule
