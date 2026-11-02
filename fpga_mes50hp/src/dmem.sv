`timescale 1ns/1ps

// ============================================================================
// dmem.sv — 数据存储器 (【寄存读】 + 字节写使能)
// ----------------------------------------------------------------------------
// 【为什么必须改成寄存读】
//   组合读无法映射到 BRAM, 只能落分布式 RAM —— 实测 16KB 吃掉 2131 个 LUT
//   (占全核 4494 的 47%), 而且 "分布式 RAM + 64 位移位器" 正是本核的关键路径
//   (13.2ns, 其中 route 占 80%)。寄存读之后这一大块变 BRAM: LUT 与 fmax 同时受益,
//   而且是为迁移紫光同创 PDS 保留的纯行为级推断 (不例化任何厂商 IP)。
//
// 【代价怎么被吸收】读数据晚一拍。由 load_store_unit 的状态机 + WB 段影子寄存器
//   把 "字节提取/符号扩展" 挪到 WB 拍完成 —— **不增加流水线级数, 也不增加
//   load-use 停顿**。MMIO 读数据在 core.sv 里同样寄存一拍, 两条路径保持同拍。
//
// 写仍用非阻塞赋值到字节片, 综合可推断 BRAM 的字节写使能 (byte-write enable)。
//
// 读优先 (read-first): 同拍读写同址读到旧值。本核 MEM 段每拍只发一个请求,
// 不存在同拍读写冲突, 读写优先都不影响正确性。
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
  output logic [31:0]   rdata        // 地址在第 N 拍, 数据在第 N+1 拍有效
);

  localparam int unsigned WORDS = BYTES / 4;
  localparam int unsigned AW    = $clog2(WORDS);

  logic [31:0] mem [WORDS];

  // 初值装载: 本核是哈佛结构, .data/.rodata 的初值无法靠 crt0 从 imem 搬运
  // (load 到不了 imem 空间), 所以 dmem 必须自己带一份初始化镜像。
  // 仿真: +dmem=<file>; 综合: 定义 DMEM_INIT_FILE 宏。
  initial begin
`ifndef SYNTHESIS
    for (int i = 0; i < WORDS; i++) begin
      mem[i] = 32'h0;
    end
`endif

`ifdef SYNTHESIS
`ifdef DMEM_INIT_FILE
    $readmemh(`DMEM_INIT_FILE, mem);
`endif
`else
    begin
      string dinit_file;
      if ($value$plusargs("dmem=%s", dinit_file)) begin
        $readmemh(dinit_file, mem);
        $display("[dmem] loaded image: %s", dinit_file);
      end
    end
`endif
  end

  // 用 always 而非 always_ff: initial 也写 mem, LRM 禁止 always_ff 驱动的变量
  // 再被其它进程驱动 (ModelSim vopt-7061 会直接报错)。
  always @(posedge clk) begin
    if (we) begin
      if (wstrb[0]) mem[addr[AW+1:2]][7:0]   <= wdata[7:0];
      if (wstrb[1]) mem[addr[AW+1:2]][15:8]  <= wdata[15:8];
      if (wstrb[2]) mem[addr[AW+1:2]][23:16] <= wdata[23:16];
      if (wstrb[3]) mem[addr[AW+1:2]][31:24] <= wdata[31:24];
    end
    rdata <= mem[addr[AW+1:2]];
  end

endmodule
