`timescale 1ns/1ps

// ============================================================================
// ref5_top.sv — ref5 参照核的顶层 (含 imem / dmem)
// ----------------------------------------------------------------------------
// 只有 clk / rst 两个输入, 加两个纯观测输出 (让综合器没有理由把这条
// pc -> imem -> 译码 -> ... -> pc 的反馈链修剪掉; 它们不参与功能)。
//
// 两个存储器都是**同步读** (与主核默认口径一致, 推断为 BRAM):
//   imem: `always_ff rdata <= mem[addr[...]]`      -> RAMB36
//   dmem: 同步读 + 4 位字节写使能                  -> RAMB36 (带 byte-write)
// 内容用**地址相关的常量模式**初始化: 既避免"全同内容 ROM 被常量折叠"
// (那样 BRAM 会从关键路径上消失, 测出来的 fmax 就是假的), 也让取指出来的
// 是随机指令流 —— 停顿/重定向逻辑都会被真实激励到, 但不需要任何程序镜像。
// ============================================================================

module ref5_imem #(
  parameter int unsigned BYTES = 16384
)(
  input  logic        clk,
  input  logic [31:0] addr,
`ifdef REF5_ENARDEN
  input  logic        rd_en,      // 【E1 实验】读使能: 0 = 输出寄存器冻结 (BRAM ENARDEN)
`endif
  output logic [31:0] rdata
);
  localparam int unsigned WORDS = BYTES / 4;
  localparam int unsigned AW    = $clog2(WORDS);

  logic [31:0] mem [WORDS];
  integer      i;

  initial begin
    for (i = 0; i < WORDS; i = i + 1) begin
      // 与地址相关 -> 不可能被常量折叠
      mem[i] = {i[15:0], i[15:0]} ^ 32'h0000_0013;
    end
  end

`ifdef REF5_ENARDEN
  // 【E1 实验: 停顿改用"读使能冻结输出"代替"摁住地址"】
  // 停顿拍 rd_en=0 -> 推断成 RAMB36 的 ENARDEN(读端口使能), 输出寄存器 DOADO
  // 保持上一拍的值。于是 imem_addr 上不再需要 pipe_stall 的 mux, 取指地址
  // 只由**已寄存的 pc** 决定 (见 ref5_core.sv 的 E1 分支)。
  always_ff @(posedge clk) begin
    if (rd_en) rdata <= mem[addr[AW+1:2]];
  end
`else
  always_ff @(posedge clk) begin
    rdata <= mem[addr[AW+1:2]];
  end
`endif
endmodule


module ref5_dmem #(
  parameter int unsigned BYTES = 16384
)(
  input  logic        clk,
  input  logic [31:0] addr,
  input  logic [31:0] wdata,
  input  logic [3:0]  wstrb,
  input  logic        we,
  output logic [31:0] rdata
);
  localparam int unsigned WORDS = BYTES / 4;
  localparam int unsigned AW    = $clog2(WORDS);

  logic [31:0] mem [WORDS];
  integer      i;

  initial begin
    for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'd0;
  end

  // 同步读 + 字节写使能 -> BRAM (READ_FIRST 行为: 同拍读写同地址读到旧值)
  always_ff @(posedge clk) begin
    if (we) begin
      if (wstrb[0]) mem[addr[AW+1:2]][7:0]   <= wdata[7:0];
      if (wstrb[1]) mem[addr[AW+1:2]][15:8]  <= wdata[15:8];
      if (wstrb[2]) mem[addr[AW+1:2]][23:16] <= wdata[23:16];
      if (wstrb[3]) mem[addr[AW+1:2]][31:24] <= wdata[31:24];
    end
    rdata <= mem[addr[AW+1:2]];
  end
endmodule


module ref5_top (
  input  logic        clk,
  input  logic        rst,
  output logic [31:0] dbg_pc,
  output logic        dbg_live      // pc 的奇偶校验: 只为制造一个可观测终点
);

// 【默认 = 4KB/4KB (各 1 块 RAMB36)】这是**实测最快**的几何 (V3 起):
//   imem 从 4 块 RAMB36 减到 1 块后, 取指地址那根网只驱动 1 个 BRAM 的地址脚,
//   fmax 102.5 -> 117.3 MHz (同 RTL)。定义 REF5_BIG_MEM 可回到 16KB/16KB
//   (与主核同口径的存储器规模) 做对照 —— 那会慢约 7%。
`ifdef REF5_BIG_MEM
  localparam int unsigned IMEM_BYTES = 16384;   // RAMB36 x4 (与主核同档)
  localparam int unsigned DMEM_BYTES = 16384;   // RAMB36 x4
`else
  localparam int unsigned IMEM_BYTES = 4096;    // RAMB36 x1
  localparam int unsigned DMEM_BYTES = 4096;    // RAMB36 x1
`endif

  logic [31:0] imem_addr, imem_rdata;
`ifdef REF5_ENARDEN
  logic        imem_rd_en;      // 【E1 实验】imem 读使能 (0 = 冻结输出寄存器)
`endif
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_wstrb;
  logic        dmem_we;

  ref5_core u_core (
    .clk        (clk),
    .rst        (rst),
    .imem_addr  (imem_addr),
`ifdef REF5_ENARDEN
    .imem_rd_en (imem_rd_en),
`endif
    .imem_rdata (imem_rdata),
    .dmem_addr  (dmem_addr),
    .dmem_wdata (dmem_wdata),
    .dmem_wstrb (dmem_wstrb),
    .dmem_we    (dmem_we),
    .dmem_rdata (dmem_rdata),
    .dbg_pc     (dbg_pc)
  );

  ref5_imem #(.BYTES(IMEM_BYTES)) u_imem (
    .clk   (clk),
    .addr  (imem_addr),
`ifdef REF5_ENARDEN
    .rd_en (imem_rd_en),
`endif
    .rdata (imem_rdata)
  );

  ref5_dmem #(.BYTES(DMEM_BYTES)) u_dmem (
    .clk   (clk),
    .addr  (dmem_addr),
    .wdata (dmem_wdata),
    .wstrb (dmem_wstrb),
    .we    (dmem_we),
    .rdata (dmem_rdata)
  );

  assign dbg_live = ^dbg_pc;

endmodule
