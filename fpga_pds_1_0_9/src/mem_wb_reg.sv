`timescale 1ns/1ps

// ============================================================================
// mem_wb_reg.sv — MEM/WB 流水寄存器
// ----------------------------------------------------------------------------
// 携带: 控制束 (WB 段消费)、load 数据 (经 load_store_unit 扩展后)、
//       ALU 结果、PC+4 (链接值)、rd 地址。
// 停顿: 拆分访存 (lsu_stall) 时保持 —— 保证拆分 load 的合并结果在
//       最后一个访存拍才被锁存。
// ============================================================================

module mem_wb_reg
  import rv32_pkg::*;
(
  input  logic        clk,
  input  logic        rst,
  input  logic        stall,

  input  ctrl_s       ctrl_in,
  input  logic [31:0] alu_out_in,
  input  logic [31:0] load_data_in,
  input  logic [31:0] pc_plus4_in,
  input  logic [4:0]  rd_addr_in,

  output ctrl_s       ctrl,
  output logic [31:0] alu_out,
  output logic [31:0] load_data,
  output logic [31:0] pc_plus4,
  output logic [4:0]  rd_addr
);

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      ctrl      <= '0;
      alu_out   <= '0;
      load_data <= '0;
      pc_plus4  <= '0;
      rd_addr   <= '0;
    end
    else if (!stall) begin
      ctrl      <= ctrl_in;
      alu_out   <= alu_out_in;
      load_data <= load_data_in;
      pc_plus4  <= pc_plus4_in;
      rd_addr   <= rd_addr_in;
    end
  end

endmodule
