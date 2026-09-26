`timescale 1ns/1ps

// ============================================================================
// id_ex_reg.sv — ID/EX 流水寄存器 (控制束 + 操作数 + 地址 + 立即数)
// ----------------------------------------------------------------------------
// 气泡 = ctrl = '0, 所有枚举 0 值构成安全 NOP (见 rv32_pkg ctrl_s 注释)。
// stall 与 bubble 由 hazard_unit 保证互斥 (bubble 会被 lsu 停顿门控),
// 此处顺序仅为防御性写法。
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

  output ctrl_s       ctrl,
  output logic [31:0] pc,
  output logic [31:0] pc_plus4,
  output logic [31:0] rs1_data,
  output logic [31:0] rs2_data,
  output logic [31:0] imm,
  output logic [4:0]  rs1_addr,
  output logic [4:0]  rs2_addr,
  output logic [4:0]  rd_addr
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
    end
  end

endmodule
