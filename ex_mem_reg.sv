`timescale 1ns/1ps

// ============================================================================
// ex_mem_reg.sv — EX/MEM 流水寄存器
// ----------------------------------------------------------------------------
// 携带: 控制束 (MEM/WB 段消费)、ALU 结果 (访存地址)、store 数据、rd 地址、
//       PC+4 (JAL/JALR 链接值)。
// 停顿: 拆分访存 (lsu_stall) 时保持, 与 MEM/WB 同步冻结。
// ============================================================================

module ex_mem_reg
  import rv32_pkg::*;
(
  input  logic        clk,
  input  logic        rst,
  input  logic        stall,

  input  ctrl_s       ctrl_in,
  input  logic [31:0] alu_out_in,
  input  logic [31:0] store_data_in,
  input  logic [31:0] pc_plus4_in,
  input  logic [4:0]  rd_addr_in,

  output ctrl_s       ctrl,
  output logic [31:0] alu_out,
  output logic [31:0] store_data,
  output logic [31:0] pc_plus4,
  output logic [4:0]  rd_addr
);

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      ctrl       <= '0;
      alu_out    <= '0;
      store_data <= '0;
      pc_plus4   <= '0;
      rd_addr    <= '0;
    end
    else if (!stall) begin
      ctrl       <= ctrl_in;
      alu_out    <= alu_out_in;
      store_data <= store_data_in;
      pc_plus4   <= pc_plus4_in;
      rd_addr    <= rd_addr_in;
    end
  end

endmodule
