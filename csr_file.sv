`timescale 1ns/1ps

// ============================================================================
// csr_file.sv — Zicsr 控制状态寄存器堆 + 机器模式陷阱状态机
// ----------------------------------------------------------------------------
// 对应赛题高阶任务的"完整异常/中断"。本核是 RV32I(M), 只实现 **机器模式 (M-mode)**:
//   mstatus / mie / mtvec / mscratch / mepc / mcause / mtval / mip
//   + 只读的 mvendorid/marchid/mimpid/mhartid (返回 0)
//
// 【陷阱语义 (RISC-V 特权规范)】
//   进入陷阱:
//     mepc    <- 触发指令的 PC
//     mcause  <- 原因 (最高位 = 是否中断)
//     mtval   <- 附加信息 (非法指令时放指令编码, 地址错时放地址)
//     mstatus.MPIE <- mstatus.MIE ; mstatus.MIE <- 0 ; mstatus.MPP <- 3 (M-mode)
//     PC      <- mtvec (mode=0 直接, mode=1 向量化 -> 本实现按直接处理)
//   MRET:
//     PC      <- mepc ; mstatus.MIE <- mstatus.MPIE ; mstatus.MPIE <- 1
//     mstatus.MPP <- 0 (本核无 U 模式, 恒回到 M)
//
// 【中断判定时机】在 EX 段、指令边界上判定 (与分支重定向同一套冲刷机制),
//   所以陷阱是精确的: 触发指令不写寄存器、不写存储器, 其前的指令全部已提交。
//
// 【为什么单独一个模块】CSR 是纯状态机, 与数据通路正交; 独立出来便于单独验证,
//   也让 core 保持"数据通路"的单一职责。全部行为级 RTL, 不含任何厂商原语。
// ============================================================================

module csr_file
  import rv32_pkg::*;
#(
  parameter logic [31:0] MTVEC_RESET = 32'h8000_0100,   // 复位后陷阱入口 (imem 内)
  parameter logic [31:0] MISA_VALUE  = 32'h4000_1100    // MXL=1(RV32) + I + M
)(
  input  logic        clk,
  input  logic        rst,

  // ---------------- CSR 读口 (EX 段组合读) ----------------
  input  logic [11:0] raddr,
  output logic [31:0] rdata,

  // ---------------- CSR 写口 (EX 段) ----------------
  // 只写 waddr 指定的那一个寄存器; 未实现地址读 0、写忽略。
  input  logic        we,
  input  logic [11:0] waddr,
  input  logic [31:0] wdata,

  // ---------------- 陷阱入口 ----------------
  // 【优先级由 core 裁决】只有 core 知道流水线状态 (是否停顿、EX 里是不是气泡),
  // 所以 core 把"异常"和"已使能的中断"合成一个 trap_req 送进来, 本模块只管状态转移。
  input  logic        trap_req,      // 本拍确实要陷入 (已含优先级裁决)
  input  logic [4:0]  trap_cause,    // {is_interrupt, code[3:0]} —— 这不是 mcause 的位布局
  input  logic [31:0] trap_pc,       // 要记录的 PC (异常=触发指令本身; 中断=被抢占的指令)
  input  logic [31:0] trap_tval,
  output logic        trap_enter,    // = trap_req, 供 core 拿来重定向 PC
  output logic [31:0] trap_vector,

  input  logic        mret_req,      // 执行 MRET
  output logic        mret_taken,    // = mret_req, 供 core 重定向到 mepc
  output logic [31:0] mret_pc,

  // ---------------- 中断请求 (来自外设, 电平) ----------------
  input  logic        irq_timer,     // -> mip.MTIP (bit7)
  input  logic        irq_ext,       // -> mip.MEIP (bit11)
  output logic        irq_pending,   // 有"全局使能且未屏蔽"的中断待处理
  output logic [4:0]  irq_cause      // 中断原因码 {1, code[3:0]}
);

  // ------------------------------------------------------------------------
  // CSR 地址 (M-mode 标准地址)
  // ------------------------------------------------------------------------
  localparam logic [11:0] CSR_MSTATUS  = 12'h300;
  localparam logic [11:0] CSR_MISA     = 12'h301;
  localparam logic [11:0] CSR_MIE      = 12'h304;
  localparam logic [11:0] CSR_MTVEC    = 12'h305;
  localparam logic [11:0] CSR_MSCRATCH = 12'h340;
  localparam logic [11:0] CSR_MEPC     = 12'h341;
  localparam logic [11:0] CSR_MCAUSE   = 12'h342;
  localparam logic [11:0] CSR_MTVAL    = 12'h343;
  localparam logic [11:0] CSR_MIP      = 12'h344;
  localparam logic [11:0] CSR_MVENDORID= 12'hF11;
  localparam logic [11:0] CSR_MARCHID  = 12'hF12;
  localparam logic [11:0] CSR_MIMPID   = 12'hF13;
  localparam logic [11:0] CSR_MHARTID  = 12'hF14;

  // mstatus 位
  localparam int MSTATUS_MIE  = 3;
  localparam int MSTATUS_MPIE = 7;
  localparam int MSTATUS_MPP  = 11;    // 2 位
  // mie/mip 位
  localparam int IRQ_MTIP = 7;
  localparam int IRQ_MEIP = 11;

  // ------------------------------------------------------------------------
  // 状态寄存器
  // ------------------------------------------------------------------------
  logic        st_mie;        // mstatus.MIE
  logic        st_mpie;       // mstatus.MPIE
  logic [1:0]  st_mpp;        // mstatus.MPP
  logic [31:0] mtvec;
  logic [31:0] mscratch;
  logic [31:0] mepc;
  logic [31:0] mcause;
  logic [31:0] mtval;
  logic        ie_mtie, ie_meie;   // mie

  // 【位布局修正 2026-10-08 (审阅发现)】
  // 原写法 `{20'b0, irq_ext, 19'b0, irq_timer, 7'b0}` 拼出来是 **48 位**, 赋给 32 位
  // 只保留低 32 位 —— 于是 `irq_ext` 落到 **bit27** 而不是 bit11。定时器那两位
  // 恰好仍在 bit7, 所以定时器测试没暴露; 但软件 `csrrs mie, 0x800` 后读回恒 0,
  // mip 的 MEIP 也读不到。写路径(见下 wdata[11]/wdata[7])本来就是对的, 读必须对齐:
  //   bit31:12 = 0 | bit11 = MEIP/MEIE | bit10:8 = 0 | bit7 = MTIP/MTIE | bit6:0 = 0
  wire [31:0] mip_val = {20'b0, irq_ext, 3'b0, irq_timer, 7'b0};

  // ------------------------------------------------------------------------
  // 组合读
  // ------------------------------------------------------------------------
  always_comb begin
    case (raddr)
      CSR_MSTATUS : rdata = {19'b0, st_mpp, 3'b0, st_mpie, 3'b0, st_mie, 3'b0};
      CSR_MISA    : rdata = MISA_VALUE;
      CSR_MIE     : rdata = {20'b0, ie_meie, 3'b0, ie_mtie, 7'b0};   // 同上: 48->32 位截断修正
      CSR_MTVEC   : rdata = mtvec;
      CSR_MSCRATCH: rdata = mscratch;
      CSR_MEPC    : rdata = mepc;
      CSR_MCAUSE  : rdata = mcause;
      CSR_MTVAL   : rdata = mtval;
      CSR_MIP     : rdata = mip_val;
      CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID: rdata = 32'd0;
      default     : rdata = 32'd0;         // 未实现地址读 0 (规范允许)
    endcase
  end

  // ------------------------------------------------------------------------
  // 中断判定
  //   全局使能 MIE && 对应位置位 && 对应请求挂起。mtimer 优先级高于外部。
  // ------------------------------------------------------------------------
  wire mtip = irq_timer;
  wire meip = irq_ext;
  wire timer_irq_req = st_mie && ie_mtie && mtip;
  wire ext_irq_req   = st_mie && ie_meie && meip;

  // 定时器优先级高于外部 (mtimecmp 是唯一的内核定时源)
  assign irq_pending = timer_irq_req || ext_irq_req;
  assign irq_cause   = timer_irq_req ? {1'b1, IRQ_TIMER} : {1'b1, IRQ_EXT};

  // 【mepc 取 trap_pc 本身, 不 +4】
  //   因为异常与中断都在 EX 段、指令提交之前裁决, 被抢占的那条指令还没产生任何
  //   架构副作用, MRET 后必须 *重新执行* 它。异常时它是触发指令, 中断时它是
  //   "本来要执行的下一条" —— 两种情况都指向同一条指令, 语义统一。
  assign trap_enter  = trap_req;
  assign trap_vector = {mtvec[31:2], 2'b00};   // mode=0 直接; mode=1 本实现同样按直接处理
  assign mret_taken  = mret_req;
  assign mret_pc     = mepc;

  // ------------------------------------------------------------------------
  // 时序
  // ------------------------------------------------------------------------
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      st_mie   <= 1'b0;
      st_mpie  <= 1'b0;
      st_mpp   <= 2'b11;
      mtvec    <= MTVEC_RESET;
      mscratch <= 32'd0;
      mepc     <= 32'd0;
      mcause   <= 32'd0;
      mtval    <= 32'd0;
      ie_mtie  <= 1'b0;
      ie_meie  <= 1'b0;
    end
    else begin
      // ---- 进入陷阱: 优先级最高, 覆盖同拍的 CSR 写入 ----
      if (trap_req) begin
        mepc        <= trap_pc;
        // 【mcause 的位布局是规范定死的】bit31 = 是否中断, bit[30:0] = 原因码。
        // 而 trap_cause 是紧凑的 {is_interrupt, code[3:0]} (5 位), 两者布局不同,
        // **必须显式重排**, 不能直接 {27'b0, trap_cause} —— 那样会把中断位放到
        // bit4 ! 实测后果: mcause 读回 0x00000017 而不是 0x80000007, 于是
        // "检查 mcause[31] 判断是中断" 的中断处理程序全部走错分支。
        // (之前只测同步异常所以没暴露: 异常的 bit31 本来就是 0。)
        mcause      <= {trap_cause[4], 27'b0, trap_cause[3:0]};
        mtval       <= trap_tval;
        st_mpie     <= st_mie;
        st_mie      <= 1'b0;
        st_mpp      <= 2'b11;
      end
      // ---- MRET ----
      else if (mret_req) begin
        st_mie  <= st_mpie;
        st_mpie <= 1'b1;
        st_mpp  <= 2'b00;      // 无 U 模式, 回到 M
      end
      // ---- 普通 CSR 写 ----
      else if (we) begin
        case (waddr)
          CSR_MSTATUS : begin st_mie <= wdata[MSTATUS_MIE]; st_mpie <= wdata[MSTATUS_MPIE]; st_mpp <= wdata[MSTATUS_MPP +: 2]; end
          CSR_MIE     : begin ie_mtie <= wdata[IRQ_MTIP]; ie_meie <= wdata[IRQ_MEIP]; end
          CSR_MTVEC   : mtvec    <= {wdata[31:2], 2'b00};
          CSR_MSCRATCH: mscratch <= wdata;
          CSR_MEPC    : mepc     <= {wdata[31:2], 2'b00};
          CSR_MCAUSE  : mcause   <= wdata;
          CSR_MTVAL   : mtval    <= wdata;
          // mip 的 MTIP/MEIP 由外设电平决定, 软件写无效 (只读观测);
          // 只读 ID 寄存器写忽略; 其余地址忽略。
          default     : ;
        endcase
      end
    end
  end

endmodule
