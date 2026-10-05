`timescale 1ns/1ps

// ============================================================================
// id_ex_reg.sv — ID/EX 流水寄存器 (控制束 + 操作数 + 地址 + 立即数)
// ----------------------------------------------------------------------------
// 气泡 = ctrl = '0, 所有枚举 0 值构成安全 NOP (见 rv32_pkg ctrl_s 注释)。
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
