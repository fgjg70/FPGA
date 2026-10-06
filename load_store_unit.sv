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

  // ---- RV32A 原子指令 (读-改-写) ----
  // 【为什么接在 LSU 而不是另起一套】LSU 本来就有多周期 FSM (为"非对齐跨字
  // 访存 2 拍拆分"建的): 它能按相选地址、按相控写使能、并且用 lsu_stall 冻结
  // 流水线 —— 这正是 AMO 需要的全部要素。所以 AMO 接成**新增相**即可,
  // 不必去动 core.sv 的内存路径接线或 ex_mem 流水寄存器的语义
  // (本项目在"改流水寄存器语义"上吃过四轮亏, 见 IMEM_REG_READ)。
  //
  // amo_newdata: 由 EX 段 ALU 算好的"应写回内存的新值"随流水传下来。
  //              (ALU 的 ALU_AMO_* 就是算这个; a=旧值要等读回来, 所以这里
  //               传的是**已算好的结果**, 逻辑上等价于"新值"。)
  input  logic            amo_en,
  input  logic [31:0]     amo_newdata,

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

  // AMO 用两个新相接在拆分访存状态机后面 (编码 2'd3 做 AMO_READ,
  // 再用一个独立的标志区分 WAIT, 避免把 state 加宽 -> 少动现有逻辑)
  localparam logic [1:0] S_IDLE = 2'd0, S_HEAD = 2'd1, S_TAIL = 2'd2;
  localparam logic [1:0] S_AMO  = 2'd3;      // AMO 读相 / 写相 (由 amo_wr 区分)
  logic                  amo_wr;             // 0 = AMO 读旧值, 1 = AMO 写新值
  logic [31:0]           amo_old;            // 读回的旧值 (也是 rd 的值)
  logic                  amo_mode_r;         // AMO 已启动 (保持到 WB 拍, 供 load_data 选择)

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
  //           AMO 两相都送同一个字地址 (AMO 只做字访问, 不拆分)
  assign dmem_addr  = (state == S_AMO) ? head_addr
                    : (state == S_IDLE) ? head_addr : tail_addr;

  // ---------------- store 路径 ----------------
  // 注意: store 用 *当前请求* 的 off, 不是 WB 影子的 off_wb —— 影子属于上一条
  // 已进入 WB 的访存指令, 拿它移位会把数据挪错位置 (实测基础测试直接跑挂)。
  assign store_shifted = {32'b0, req_wdata} << {off, 3'b000};
  assign size_mask     = (8'd1 << size_bytes[3:0]) - 8'd1;
  assign strobe8       = size_mask << off;
  assign head_strb     = strobe8[3:0];
  assign tail_strb     = strobe8[7:4];

  assign dmem_wdata = (state == S_AMO)  ? amo_newdata          // AMO 写相写"新值"
                    : (state == S_IDLE) ? store_shifted[31:0]
                                        : store_shifted[63:32];
  // ---- 写使能 ----
  // 原逻辑: TAIL 拍不再重复写 (跨字 store 在 IDLE 写头、HEAD 写尾即可)
  // AMO: 读相不写, 写相才写整个字 (4'b1111)
  assign dmem_wstrb = (state == S_AMO)  ? (amo_wr ? 4'b1111 : 4'b0000)
                    : (req_write && state != S_TAIL)
                      ? ((state == S_IDLE) ? head_strb : tail_strb) : 4'b0000;
  assign dmem_we    = (state == S_AMO)  ? amo_wr
                    : (req_write && (state != S_TAIL));

  // 停顿: HEAD 拍 + "IDLE 且需要拆分" 的那一拍 + AMO 的两相都要停
  assign lsu_stall  = (state == S_HEAD) || (state == S_IDLE && needs_split)
                   || (state == S_AMO && !amo_wr);   // 读相停, 写相放行

  // ---------------- load 路径 (WB 段组合) ----------------
  wire [4:0]  shamt_wb = {off_wb, 3'b000};
  // AMO 的"读回值"走同一条路: 旧值在 amo_old 里, 且 off/size 已按字对齐设好,
  // 所以下面的移位与符号扩展对它是恒等操作。
  wire [31:0] rdata_eff = amo_mode_r ? amo_old : dmem_rdata;
  wire [63:0] raw64    = split_wb ? {rdata_eff, head_word_r}
                                  : {32'b0, rdata_eff};
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
        S_IDLE:  if (amo_en)         state <= S_AMO;
                 else if (needs_split) state <= S_HEAD;
        S_HEAD:  state <= S_TAIL;
        S_AMO:   state <= amo_wr ? S_IDLE : S_AMO;   // 写相做完就放行
        default: state <= S_IDLE;
      endcase

      if (state == S_AMO) amo_wr <= ~amo_wr;

      // 头字捕获: HEAD 拍末尾 dmem_rdata 就是头字
      if (state == S_HEAD) head_word_r <= dmem_rdata;
      // 【AMO 旧值捕获】在读相那拍末尾 dmem_rdata 就是内存旧值。
      // 它就是 rd 要读到的值 (规范: AMO 的 rd = 操作前的值)。
      if (state == S_AMO && !amo_wr) amo_old <= dmem_rdata;

      // 请求离开 MEM 那一拍, 记下它的规格给 WB 段用。
      // 【AMO 必须在启动那拍就记】因为放行发生在 S_AMO 的写相, 而那时
      // req_* 已经不是 AMO 的请求了 (amo_en 只在启动拍有效)。
      if (amo_en) begin
        off_wb     <= 2'd0;            // AMO 一律字对齐字访问
        size_wb    <= MEM_WORD;
        uns_wb     <= 1'b0;
        split_wb   <= 1'b0;
        amo_mode_r <= 1'b1;            // 让 WB 拍 load_data 选 amo_old
      end
      else begin
        amo_mode_r <= 1'b0;
        if ((req_read || req_write) && !lsu_stall) begin
          off_wb   <= off;
          size_wb  <= req_size;
          uns_wb   <= req_unsigned;
          split_wb <= needs_split;
        end
      end
    end
  end

endmodule
