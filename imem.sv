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

`ifdef SYNTHESIS
    // ---- 综合路径 ----
    // 综合工具不支持 string 变量与 $value$plusargs (Vivado 报 Synth 8-27),
    // 因此综合分支里不含这两者。需要把程序固化进 ROM 时, 由构建脚本额外
    // 定义 IMEM_INIT_FILE 宏指向 hex 文件。实测可用的写法:
    //   Vivado: synth_design -verilog_define {IMEM_INIT_FILE="prog/basic.hex"}
    //           (Vivado 综合会自动预定义 SYNTHESIS, 不必手动加;
    //            而 read_verilog -define 在非 compile-unit 模式下会被拒绝)
    //   PDS   : 在综合选项里加同名宏
    // 未定义该宏时指令存储器保持上面的 NOP 初值 —— 这是安全默认值, 正好
    // 配合"上电后由 UART 在线下载程序"的用法。
`ifdef IMEM_INIT_FILE
    $readmemh(`IMEM_INIT_FILE, mem);
`endif
`else
    // ---- 仿真路径: +imem=<file> 运行时覆盖, 换程序不必重编译 ----
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
`endif
  end

  assign rdata = mem[addr[AW+1:2]];

endmodule
