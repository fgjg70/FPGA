`timescale 1ns/1ps

// ============================================================================
// imem.sv — 指令存储器
// ----------------------------------------------------------------------------
// 【为什么是寄存读 (P3 fmax/LUT 实验)】
//   原来这里是**组合读**, 综合结果是把 ROM 实现成 1228 个纯 LUT 的组合逻辑
//   (占全核 3945 LUT 的 31%) —— 既不是 BRAM 也不是 LUTRAM。BRAM 做不了组合读,
//   所以 Vivado 只能摊成 LUT 树。改成寄存读后可以落进 RAMB36, 释放那 1228 个 LUT。
//
//   代价: 读延迟 1 拍。**这会在取指路径上引入一个气泡**, 除非重排 PC 流水寄存器
//   (那就是改流水线级数, 本轮明确不做)。所以本模块现在由 IMEM_REG_READ 宏控制:
//     定义   -> 寄存读 (可推断 BRAM, 省 LUT, 但每拍多一个取指气泡)
//     不定义 -> 组合读 (现状, LUT 多但取指无延迟)
//   实测数据见 results/p3-imem.md, 由构建方按四项指标裁决用哪个。
//
// - 深度必须是 4 字节的 2 的幂, 索引用地址位切片 (高位地址被忽略);
// - 程序加载: 运行时 plusarg 指定 hex 文件 (换程序无需重新编译);
// - 未初始化区域填 NOP: 程序跑飞时不会产生非法指令噪声干扰调试
// ============================================================================

module imem
  import rv32_pkg::*;
#(
  parameter logic [31:0] BASE  = IMEM_BASE,
  parameter int unsigned BYTES = IMEM_BYTES
)(
  input  logic        clk,
  input  logic [31:0] addr,
  output logic [31:0] rdata
);

  localparam int unsigned WORDS = BYTES / 4;
  localparam int unsigned AW    = $clog2(WORDS);

  logic [31:0] mem [WORDS];

  initial begin
    for (int i = 0; i < WORDS; i++) begin
      mem[i] = INSTR_NOP;
    end

`ifdef SYNTHESIS
    // ---- 综合路径 ----
    // 综合工具不支持 string 变量与 $value$plusargs (Vivado 报 Synth 8-27),
    // 因此综合分支里不含这两者。程序由构建脚本定义 IMEM_INIT_FILE 宏指向 hex。
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

`ifdef IMEM_REG_READ
  // 寄存读: 可推断为 RAMB36 (同步读是 BRAM 的硬性要求)
  always @(posedge clk) begin
    rdata <= mem[addr[AW+1:2]];
  end
`else
  // 组合读: 落成 LUT ROM。注意"未初始化区域填 NOP"让 Vivado 能把大片 NOP
  // 当常量折叠掉 —— 实测 16KB 只用 1228 LUT, 反而比缩到 12KB (2111 LUT) 更省。
  assign rdata = mem[addr[AW+1:2]];
`endif

endmodule
