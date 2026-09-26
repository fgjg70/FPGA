`timescale 1ns/1ps

// ============================================================================
// load_store_unit.sv — 访存单元 (字节通道选择 + 非对齐硬件自动拆分)
// ----------------------------------------------------------------------------
// 【统一移位法】把"头字"(addr 对齐到 4 字节) 与"尾字"(head+4) 拼成 64 位,
// 按字节偏移整体移位, 一次覆盖所有对齐/非对齐情况:
//   load : raw = {tail_word, head_word} >> (8*addr[1:0])  再按 size/符号扩展
//   store: shifted = {32'b0, rs2} << (8*addr[1:0]), 字节使能为
//          ((1<<size_bytes)-1) << addr[1:0], 低 4 位写头字, 高 4 位写尾字
//
// 【何时需要两拍】仅当访问跨越 4 字节边界时 (off + size_bytes > 4):
//   - 字节访问: 永不跨字 (0 额外开销)
//   - 字内非对齐半字 (off=1): 不跨字, 只靠移位解决 (0 额外开销)
//   - 跨字访问 (如 LW off=1/2/3, LH off=3): 第 1 拍读/写头字并冻结流水线,
//     第 2 拍读/写尾字并当拍合并出结果 -> 总代价 1 个停顿周期
//
// 与 5 级流水的配合: 第 1 拍输出 lsu_stall 冻结前段 (EX/MEM、MEM/WB 保持,
// 保证地址/数据稳定), 第 2 拍不再冻结, 合并结果当拍进入 MEM/WB。
// 依赖该 load 的指令由 hazard_unit 的停顿/前递规则保证取到正确值。
//
// 注意: 全部用 assign 驱动 —— `logic x = expr;` 是声明式初始化, 只在 0 时刻
// 求值一次, 不是连续赋值 (本文件初版曾因此导致 lsu_stall 恒为 X)。
// ============================================================================

module load_store_unit
  import rv32_pkg::*;
(
  input  logic clk,
  input  logic rst,

  // MEM 段访存请求 (来自 EX/MEM 流水寄存器)
  input  logic            req_read,
  input  logic            req_write,
  input  mem_size_e       req_size,
  input  logic            req_unsigned,
  input  logic [31:0]     req_addr,
  input  logic [31:0]     req_wdata,

  // DMEM 接口 (组合读)
  output logic [31:0]     dmem_addr,
  output logic [31:0]     dmem_wdata,
  output logic [3:0]      dmem_wstrb,
  output logic            dmem_we,
  input  logic [31:0]     dmem_rdata,

  // 结果与流水线控制
  output logic [31:0]     load_data,
  output logic            lsu_stall
);

  // 状态: 0=IDLE, 1=TAIL (第 2 拍, 访问尾字)
  logic state;

  logic [1:0]  off;
  logic [31:0] size_bytes;
  logic        needs_split;
  logic [31:0] head_addr, tail_addr;
  logic [4:0]  shamt;
  logic [31:0] word_lo, word_hi;
  logic [63:0] load_shifted, store_shifted;
  logic [31:0] load_raw;
  logic [7:0]  size_mask, strobe8;
  logic [3:0]  head_strb, tail_strb;

  // 头字寄存器: 第 1 拍捕获, 第 2 拍与尾字合并
  logic [31:0] head_word_r;

  assign off        = req_addr[1:0];
  assign size_bytes = (req_size == MEM_BYTE) ? 32'd1 :
                      (req_size == MEM_HALF) ? 32'd2 : 32'd4;

  // 跨字判定: 起始偏移 + 访问字节数 超过 4
  assign needs_split = (req_read || req_write) &&
                       (({30'd0, off} + size_bytes) > 32'd4);

  assign head_addr = {req_addr[31:2], 2'b00};
  assign tail_addr = head_addr + 32'd4;
  assign shamt     = {off, 3'b000};               // 8 * off

  assign word_lo = state ? head_word_r : dmem_rdata;
  assign word_hi = state ? dmem_rdata : 32'd0;

  // ---------------- load 路径 ----------------
  assign load_shifted = {word_hi, word_lo} >> shamt;
  assign load_raw     = load_shifted[31:0];

  always_comb begin
    case (req_size)
      MEM_BYTE: load_data = req_unsigned ? {24'b0, load_raw[7:0]}
                                         : {{24{load_raw[7]}}, load_raw[7:0]};
      MEM_HALF: load_data = req_unsigned ? {16'b0, load_raw[15:0]}
                                         : {{16{load_raw[15]}}, load_raw[15:0]};
      default:  load_data = load_raw;                      // MEM_WORD
    endcase
  end

  // ---------------- store 路径 ----------------
  assign store_shifted = {32'b0, req_wdata} << shamt;
  assign size_mask     = (8'd1 << size_bytes[3:0]) - 8'd1;   // 1 / 3 / 15
  assign strobe8       = size_mask << off;
  assign head_strb     = strobe8[3:0];
  assign tail_strb     = strobe8[7:4];

  assign dmem_addr  = state ? tail_addr : head_addr;
  assign dmem_wdata = state ? store_shifted[63:32] : store_shifted[31:0];
  assign dmem_wstrb = req_write ? (state ? tail_strb : head_strb) : 4'b0000;
  assign dmem_we    = req_write;

  // 第 1 拍冻结流水线 (第 2 拍正常推进)
  assign lsu_stall  = !state && needs_split;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      state       <= 1'b0;
      head_word_r <= '0;
    end
    else if (!state) begin
      if (needs_split) begin
        state       <= 1'b1;
        head_word_r <= dmem_rdata;    // 捕获头字 (此时 dmem_addr = head_addr)
      end
    end
    else begin
      state <= 1'b0;                  // 尾拍完成
    end
  end

endmodule
