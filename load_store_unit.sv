`timescale 1ns/1ps

// ============================================================================
// load_store_unit.sv — 访存单元 (字节通道 + 非对齐硬件自动拆分) 【寄存读版】
// ----------------------------------------------------------------------------
// 与组合读版的唯一区别: dmem 读数据晚一拍到。为了 **不增加流水线级数、也不增加
// load-use 停顿**, 把"字节提取 + 符号扩展"整体挪到 WB 段组合完成:
//
//   非对齐(不跨字)访问:
//     N   拍: 送地址 (指令在 MEM), 同时把本次访问的规格 (off/size/unsigned/split)
//             记进 WB 影子寄存器
//     N+1 拍: 数据到, 该指令已在 WB 段 -> 用影子寄存器提取 -> 直接进写回 mux
//
//   跨字访问 (off + size_bytes > 4): 多占 2 个停顿周期
//     IDLE: 送头字地址, lsu_stall=1
//     HEAD: 头字到, 捕获到 head_word_r, 改送尾字地址, lsu_stall=1
//     TAIL: 尾字到, lsu_stall=0 (本拍末尾请求离开 MEM 并进入 WB; 继续送尾字地址,
//           好让 WB 拍 dmem_rdata 仍是尾字)
//     WB  : {尾字, 头字} >> (8*off) 合并 -> 提取 -> 写回
//
// 写回 mux 直接用本模块的 load_data (组合), 不再经 MEM/WB 寄存器打第二拍。
//
// 【统一移位法】头字(对齐)与尾字(head+4)拼 64 位按字节偏移整体移位, 一套逻辑覆盖
// 全部对齐/非对齐情况; store 用 {32'b0, wdata} << shamt 配合掩码移位选通。
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

  // DMEM 接口 (寄存读: 地址第 N 拍, 数据第 N+1 拍)
  output logic [31:0]     dmem_addr,
  output logic [31:0]     dmem_wdata,
  output logic [3:0]      dmem_wstrb,
  output logic            dmem_we,
  input  logic [31:0]     dmem_rdata,

  // 结果 (WB 段组合有效, 直接进写回 mux) 与流水线控制
  output logic [31:0]     load_data,
  output logic            lsu_stall
);

  localparam logic [1:0] S_IDLE = 2'd0, S_HEAD = 2'd1, S_TAIL = 2'd2;

  logic [1:0]  state;

  logic [1:0]  off;
  logic [31:0] size_bytes;
  logic        needs_split;
  logic [31:0] head_addr, tail_addr;
  logic [63:0] store_shifted;
  logic [7:0]  size_mask, strobe8;
  logic [3:0]  head_strb, tail_strb;

  // 头字寄存器: HEAD 拍捕获, WB 拍与尾字合并
  logic [31:0] head_word_r;

  // WB 段影子: 访存指令进入 WB 时, 提取所需的规格
  logic [1:0]  off_wb;
  logic [1:0]  size_wb;
  logic        uns_wb;
  logic        split_wb;

  assign off        = req_addr[1:0];
  assign size_bytes = (req_size == MEM_BYTE) ? 32'd1 :
                      (req_size == MEM_HALF) ? 32'd2 : 32'd4;

  assign needs_split = (req_read || req_write) &&
                       (({30'd0, off} + size_bytes) > 32'd4);

  assign head_addr = {req_addr[31:2], 2'b00};
  assign tail_addr = head_addr + 32'd4;

  // 地址选择: IDLE 送头字, HEAD/TAIL 送尾字 (TAIL 继续送尾字, 让 WB 拍数据仍是尾字)
  assign dmem_addr  = (state == S_IDLE) ? head_addr : tail_addr;

  // ---------------- store 路径 ----------------
  // 注意: store 用 *当前请求* 的 off, 不是 WB 影子的 off_wb —— 影子属于上一条
  // 已进入 WB 的访存指令, 拿它移位会把数据挪错位置 (实测基础测试直接跑挂)。
  assign store_shifted = {32'b0, req_wdata} << {off, 3'b000};
  assign size_mask     = (8'd1 << size_bytes[3:0]) - 8'd1;
  assign strobe8       = size_mask << off;
  assign head_strb     = strobe8[3:0];
  assign tail_strb     = strobe8[7:4];

  assign dmem_wdata = (state == S_IDLE) ? store_shifted[31:0] : store_shifted[63:32];
  // TAIL 拍不再重复写 (跨字 store 在 IDLE 写头、HEAD 写尾即可)
  assign dmem_wstrb = (req_write && state != S_TAIL)
                      ? ((state == S_IDLE) ? head_strb : tail_strb) : 4'b0000;
  assign dmem_we    = req_write && (state != S_TAIL);

  // 停顿: HEAD 拍 + "IDLE 且需要拆分" 的那一拍
  assign lsu_stall  = (state == S_HEAD) || (state == S_IDLE && needs_split);

  // ---------------- load 路径 (WB 段组合) ----------------
  wire [4:0]  shamt_wb = {off_wb, 3'b000};
  wire [63:0] raw64    = split_wb ? {dmem_rdata, head_word_r}
                                  : {32'b0, dmem_rdata};
  // 注意: SystemVerilog 不允许对括号表达式做位选 ((a>>b)[31:0] 非法),
  // 必须先赋给中间 wire 再切片。
  wire [63:0] load_shifted = raw64 >> shamt_wb;
  wire [31:0] load_raw     = load_shifted[31:0];

  always_comb begin
    case (size_wb)
      MEM_BYTE: load_data = uns_wb ? {24'b0, load_raw[7:0]}
                                   : {{24{load_raw[7]}}, load_raw[7:0]};
      MEM_HALF: load_data = uns_wb ? {16'b0, load_raw[15:0]}
                                   : {{16{load_raw[15]}}, load_raw[15:0]};
      default:  load_data = load_raw;
    endcase
  end

  // ---------------- 时序 ----------------
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      state      <= S_IDLE;
      head_word_r<= 32'd0;
      off_wb     <= 2'd0;
      size_wb    <= MEM_WORD;
      uns_wb     <= 1'b0;
      split_wb   <= 1'b0;
    end
    else begin
      case (state)
        S_IDLE:  if (needs_split) state <= S_HEAD;
        S_HEAD:  state <= S_TAIL;
        default: state <= S_IDLE;
      endcase

      // 头字捕获: HEAD 拍末尾 dmem_rdata 就是头字
      if (state == S_HEAD) head_word_r <= dmem_rdata;

      // 请求离开 MEM 那一拍, 记下它的规格给 WB 段用
      if ((req_read || req_write) && !lsu_stall) begin
        off_wb   <= off;
        size_wb  <= req_size;
        uns_wb   <= req_unsigned;
        split_wb <= needs_split;
      end
    end
  end

endmodule
