`timescale 1ns/1ps

// ============================================================================
// id_ex_reg.sv — ID/EX 流水寄存器 (控制束 + 操作数 + 地址 + 立即数)
// ----------------------------------------------------------------------------
// 气泡 = ctrl = '0, 所有枚举 0 值构成安全 NOP (见 rv32_pkg ctrl_s 注释)。
//
// 【valid —— "EX 段这条指令是否真实有效"】2026-10-11 新增 (R-01 修复的一部分)
//   气泡/flush 时 pc 被清 0, 于是 `id_ex_pc` 本身**无法区分**"真指令在 0x0"
//   与"这里是气泡" —— 而 trap 单元用 `trap_pc = id_ex_pc` 写 mepc。
//   后果 (实测复现): 中断在 load-use 停顿注入的气泡上被接受 -> mepc = 0,
//   同时 ID 里那条真指令被 any_redir 冲掉、永不重执行。
//   所以必须有一个**显式**的有效位:
//     valid_in = id_en (boot_done): 只有真正译码出来的指令才算有效
//     气泡/flush/rst -> 0;  停顿 (!stall=0) 保持原值。
//   core 侧用它否决中断 (irq_take &= id_ex_valid): 电平中断晚一拍取不影响正确性。
// ============================================================================
//
// 【重要】stall 与 bubble 并 *不* 互斥: load_use=1 且 lsu_stall=0 时,
// pipe_stall 与 id_ex_bubble 会同时为 1 (见 hazard_unit)。下面的优先级
// (flush > bubble > stall) 是 *必需* 的, 不是防御性写法:
//   - load_use 表示 EX 里是 load、ID 里是它的消费者; 此时必须向 ID/EX
//     注气泡 (load 已经离开 EX), 同时冻结 PC 与 IF/ID;
//   - 若反过来让 stall 优先, load 会被扣在 EX、消费者被扣在 ID,
//     load_use 永不清零 -> 死锁。
// 原注释声称"互斥", 与代码不符; 照原注释调整分支顺序会引入死锁。
// ============================================================================

module id_ex_reg
  import rv32_pkg::*;
(
  input  logic        clk,
  input  logic        rst,
  input  logic        flush,
  input  logic        stall,
  input  logic        bubble,
  input  logic        valid_in,
  input  logic [31:0] instr_in,

  input  ctrl_s       ctrl_in,
  input  logic [31:0] pc_in,
  input  logic [31:0] pc_plus4_in,
  input  logic [31:0] rs1_data_in,
  input  logic [31:0] rs2_data_in,
  input  logic [31:0] imm_in,
  input  logic [4:0]  rs1_addr_in,
  input  logic [4:0]  rs2_addr_in,
  input  logic [4:0]  rd_addr_in,
  input  logic        pred_taken_in,
  input  logic [31:0] pred_target_in,

  output ctrl_s       ctrl,
  output logic        valid,          // EX 段这条指令是否**真实有效** (气泡/flush 为 0)
  output logic [31:0] instr,          // 本条指令的**原始编码** (只为 mtval 携带, 见头注释)
  output logic [31:0] pc,
  output logic [31:0] pc_plus4,
  output logic [31:0] rs1_data,
  output logic [31:0] rs2_data,
  output logic [31:0] imm,
  output logic [4:0]  rs1_addr,
  output logic [4:0]  rs2_addr,
  output logic [4:0]  rd_addr,
  output logic        pred_taken,
  output logic [31:0] pred_target
);

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      ctrl      <= '0;
      valid     <= 1'b0;
      instr     <= '0;
      pc        <= '0;
      pc_plus4  <= '0;
      rs1_data  <= '0;
      rs2_data  <= '0;
      imm       <= '0;
      rs1_addr  <= '0;
      rs2_addr  <= '0;
      rd_addr   <= '0;
      pred_taken  <= 1'b0;
      pred_target <= '0;
    end
    else if (flush || bubble) begin
      ctrl      <= '0;
      valid     <= 1'b0;
      instr     <= '0;
      pc        <= '0;
      pc_plus4  <= '0;
      rs1_data  <= '0;
      rs2_data  <= '0;
      imm       <= '0;
      rs1_addr  <= '0;
      rs2_addr  <= '0;
      rd_addr   <= '0;
      pred_taken  <= 1'b0;   // 气泡按"不跳"处理, 避免假预测错误
      pred_target <= '0;
    end
    else if (!stall) begin
      ctrl      <= ctrl_in;
      valid     <= valid_in;
      instr     <= instr_in;
      pc        <= pc_in;
      pc_plus4  <= pc_plus4_in;
      rs1_data  <= rs1_data_in;
      rs2_data  <= rs2_data_in;
      imm       <= imm_in;
      rs1_addr  <= rs1_addr_in;
      rs2_addr  <= rs2_addr_in;
      rd_addr   <= rd_addr_in;
      pred_taken  <= pred_taken_in;
      pred_target <= pred_target_in;
    end
  end

endmodule
