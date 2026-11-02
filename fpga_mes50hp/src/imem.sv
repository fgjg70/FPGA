`timescale 1ns/1ps

// ============================================================================
// imem.sv — 指令存储器
// ----------------------------------------------------------------------------
// 【默认 = 寄存读 (BRAM)；组合读只作回退/对照】
//   综合结果实测: 组合读把 ROM 摊成 1228 个纯 LUT 的组合逻辑 (占全核 31%);
//   寄存读则可推断为 RAMB36 ×4, 把那 1228 个 LUT 全部释放。
//   DMEM 同样是寄存读 (dmemi 见 dmem.sv) —— 本核的 imem/dmem **都落 BRAM**。
//
//   【口径更正 2026-10-08】原文写"读延迟 1 拍不产生气泡、也不增加流水线级数" ——
//   **只说对了一半**。配对口径确实没变 (把取指地址接成**组合推出的下一拍 pc**
//   (pc_next), 于是 imem_rdata(N) == mem[pc(N)], 与组合读逐位同口径),
//   但同步读**确实多插了一个寄存器**: 当时还留着的 if_id_reg 前面没有任何组合
//   逻辑、只做纯搬运, 使 pc 之后共有 5 个指令寄存器 ⇒ 实际是 6 级流水、
//   每次重定向多一个气泡。去掉它之后才真正是 5 级 (见 results/p8-ifid-elide.md)。
//   唯一配套是复位后冻结取指一拍, 让 IMEM 有机会锁存 PC_RESET 处的第一条指令。
//
//   宏: 定义 IMEM_COMB_READ -> 组合读 (LUT ROM, 回退/做 A-B 对照用)
//       不定义 (默认)      -> 寄存读 (可推断 BRAM)
//   选择依据与实测见 results/p4-macro-failure.md 5.1 与 results/p3-imem.md。
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
`ifndef SYNTHESIS
    for (int i = 0; i < WORDS; i++) begin
      mem[i] = INSTR_NOP;
    end
`endif

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

`ifdef IMEM_COMB_READ
  // ---- 回退: 组合读 -> 落成 LUT ROM (实测 1228 LUT, 占全核 31%) ----
  // 注意"未初始化区域填 NOP"让 Vivado 能把大片 NOP 当常量折叠掉 ——
  // 实测 16KB 只用 1228 LUT, 反而比缩到 12KB (2111 LUT) 更省。
  assign rdata = mem[addr[AW+1:2]];
`else
  // ---- 默认: 寄存读 -> 可推断 RAMB36 (同步读是 BRAM 的硬性要求) ----
  always @(posedge clk) begin
    rdata <= mem[addr[AW+1:2]];
  end
`endif

endmodule
