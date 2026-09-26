`timescale 1ns/1ps

// ============================================================================
// imem.sv — 指令存储器 (组合读, LUTRAM 风格)
// ----------------------------------------------------------------------------
// - 组合读: IF 段当拍给出 PC 即得指令, IF/ID 在时钟沿锁存;
// - 深度必须是 4 字节的 2 的幂, 索引用地址位切片 (高位地址被忽略,
//   因为我们用参数化的独立地址空间);
// - 程序加载: 用运行时 plusarg 指定 hex 文件 (换程序无需重新编译):
//       vvp tb_core.vvp +imem=prog/basic.hex
//   文件格式为每行一个 32 位字 (工具 tools/asm.py 产出);
// - 综合时: Vivado 可把本模块推断为 ROM, 用 INIT_FILE 属性或 IP 核替换
//   initial 块 (综合工具忽略 $readmemh);
// - 升级到 BRAM (更大容量) 时: 把 rdata 改为寄存输出, 接口不变,
//   流水线无需改动。
// ============================================================================

module imem
  import rv32_pkg::*;
#(
  parameter logic [31:0] BASE  = IMEM_BASE,
  parameter int unsigned BYTES = IMEM_BYTES
)(
  input  logic [31:0] addr,
  output logic [31:0] rdata
);

  localparam int unsigned WORDS = BYTES / 4;
  localparam int unsigned AW    = $clog2(WORDS);

  logic [31:0] mem [WORDS];

  // 未初始化区域填 NOP: 程序跑飞时不会产生非法指令噪声干扰调试
  initial begin
    for (int i = 0; i < WORDS; i++) begin
      mem[i] = INSTR_NOP;
    end
    begin
      string init_file;
      if ($value$plusargs("imem=%s", init_file)) begin
        $readmemh(init_file, mem);
        $display("[imem] loaded program: %s", init_file);
      end
      else begin
        $display("[imem] no +imem=<file> given, instruction memory stays all-NOP");
      end
    end
  end

  assign rdata = mem[addr[AW+1:2]];

endmodule
