`timescale 1ns/1ps

// ============================================================================
// dmem.sv — 数据存储器 (组合读 + 字节写使能)
// ----------------------------------------------------------------------------
// - 4 字节字阵列 + 每字节独立写使能, 支持 SB/SH/SW;
// - 组合读使 load 数据在 MEM 段当拍可用, 非对齐拆分的第二拍也能当拍合并;
// - 写入用非阻塞赋值到字节片, 综合推断 LUTRAM/BRAM 的字节写使能模式;
// - 深度必须是 4 字节的 2 的幂。
// ============================================================================

module dmem
  import rv32_pkg::*;
#(
  parameter logic [31:0] BASE  = DMEM_BASE,
  parameter int unsigned BYTES = DMEM_BYTES
)(
  input  logic          clk,
  input  logic [31:0]   addr,
  input  logic [31:0]   wdata,
  input  logic [3:0]    wstrb,
  input  logic          we,
  output logic [31:0]   rdata
);

  localparam int unsigned WORDS = BYTES / 4;
  localparam int unsigned AW    = $clog2(WORDS);

  logic [31:0] mem [WORDS];

  initial begin
    for (int i = 0; i < WORDS; i++) begin
      mem[i] = 32'h0;
    end
  end

  assign rdata = mem[addr[AW+1:2]];

  always_ff @(posedge clk) begin
    if (we) begin
      if (wstrb[0]) mem[addr[AW+1:2]][7:0]   <= wdata[7:0];
      if (wstrb[1]) mem[addr[AW+1:2]][15:8]  <= wdata[15:8];
      if (wstrb[2]) mem[addr[AW+1:2]][23:16] <= wdata[23:16];
      if (wstrb[3]) mem[addr[AW+1:2]][31:24] <= wdata[31:24];
    end
  end

endmodule
