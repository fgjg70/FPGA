`timescale 1ns/1ps

// ============================================================================
// rv32_pkg.sv — RV32I 核心编码包 / 控制束定义（单一事实来源）
// ----------------------------------------------------------------------------
// 所有指令编码、ALU/分支/访存/写回编码只在此处定义一次, 各模块 import 使用,
// 消灭"同一编码两处维护"的幽灵 bug。
//
// 【数据通路接线契约】(供你自己编写 datapath 时对照)
//   1. ALU 操作数选择:
//        a_op = (alu_a_src==ALU_A_RS1) ? rs1_data
//             : (alu_a_src==ALU_A_PC ) ? pc        // AUIPC / BR/JAL 目标计算
//             :                          '0        // LUI
//        b_op = (alu_b_src==ALU_B_IMM) ? imm : rs2_data
//   2. 跳转目标契约 —— ALU 兼职目标加法器, 不需要独立的 32 位加法器:
//        BR/JAL: alu_a=PC, alu_b=IMM, alu_op=ADD  => alu_out = pc+imm
//        JALR  : alu_a=RS1, alu_b=IMM, alu_op=ADD => alu_out = rs1+imm
//        pc_target = (pc_sel==PC_JR) ? {alu_out[XLEN-1:1],1'b0}  // JALR 最低位清零
//                                   :  alu_out
//   3. PC 选择:
//        pc_src = (pc_sel==PC_BR && branch_taken) || pc_sel==PC_J || pc_sel==PC_JR
//        其中 branch_taken 来自 branch_unit(rs1_data, rs2_data, branch_type)
//   4. 写回选择: WB_ALU->alu_out | WB_MEM->load_unit 输出 | WB_PC4->pc_plus4
//   5. 访存: mem_size/mem_unsigned 送 load/store 处理单元;
//        地址用 alu_out (字节地址), 字节通道选择用 alu_out[1:0]
//   6. illegal=1 的指令按"什么都不做"处理 (reg_write/mem_write 均为 0),
//        未来接 trap 单元时改为跳转异常入口。
//
// 【流水线化路径】(3 级/5 级)
//   - ctrl_s 整束在 ID 产生, ID/EX 流水寄存器一行整体打拍下传;
//   - 各字段按消费阶段分组标注 (EX/MEM/WB), 拆流水线时照注释切片即可;
//   - pc 模块已备 stall/flush 端口, 由未来的 hazard/redirect 逻辑驱动。
//
// 【M 扩展启用路径】
//   - ALU 操作码已扩到 5 位, MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU 编码
//     已预留在 alu_op_e (5'd10..5'd17), 当前 control_unit 将其译码为 illegal;
//   - 启用时: control_unit 增加 funct7==F7_MULDIV 分支译出对应 alu_op,
//     ALU 增加实现(乘法走 DSP; 除法建议做成多周期状态机 + stall)。
// ============================================================================

package rv32_pkg;

  // --------------------------------------------------------------------------
  // 全局参数
  // --------------------------------------------------------------------------
  parameter int unsigned XLEN = 32;   // RV32; 若做 RV64 需全面评审移位/立即数位宽

  // --------------------------------------------------------------------------
  // opcode
  // --------------------------------------------------------------------------
  typedef enum logic [6:0] {
    OPC_LUI    = 7'b0110111,
    OPC_AUIPC  = 7'b0010111,
    OPC_JAL    = 7'b1101111,
    OPC_JALR   = 7'b1100111,
    OPC_BRANCH = 7'b1100011,
    OPC_LOAD   = 7'b0000011,
    OPC_STORE  = 7'b0100011,
    OPC_OPIMM  = 7'b0010011,
    OPC_OP     = 7'b0110011,
    OPC_FENCE  = 7'b0001111,   // FENCE / FENCE.I: 本核顺序执行无 cache, 退化为 NOP
    OPC_SYSTEM = 7'b1110011    // ECALL / EBREAK / MRET / Zicsr
  } opcode_e;

  // --------------------------------------------------------------------------
  // funct7 常量
  // --------------------------------------------------------------------------
  localparam logic [6:0] F7_ZERO   = 7'b0000000;
  localparam logic [6:0] F7_ALT    = 7'b0100000;  // SUB / SRA(-I)
  localparam logic [6:0] F7_MULDIV = 7'b0000001;  // RV32M (预留, 当前译码为 illegal)

  // --------------------------------------------------------------------------
  // ALU 操作 — 5 位编码, 低 10 位为 RV32I 基础操作, 10~17 为 RV32M 预留
  // --------------------------------------------------------------------------
  typedef enum logic [4:0] {
    ALU_ADD  = 5'd0,
    ALU_SUB  = 5'd1,
    ALU_AND  = 5'd2,
    ALU_OR   = 5'd3,
    ALU_XOR  = 5'd4,
    ALU_SLL  = 5'd5,
    ALU_SRL  = 5'd6,
    ALU_SRA  = 5'd7,
    ALU_SLT  = 5'd8,
    ALU_SLTU = 5'd9,
    // ---- RV32M 预留: 启用前 control_unit 译码为 illegal, ALU 输出 x ----
    ALU_MUL    = 5'd10,
    ALU_MULH   = 5'd11,
    ALU_MULHSU = 5'd12,
    ALU_MULHU  = 5'd13,
    ALU_DIV    = 5'd14,
    ALU_DIVU   = 5'd15,
    ALU_REM    = 5'd16,
    ALU_REMU   = 5'd17
    // 5'd18..5'd31 保留
  } alu_op_e;

  // --------------------------------------------------------------------------
  // ALU 操作数来源 —— 取代旧设计中的 alu_src / alu_src_pc 两个不对称信号,
  // 同时一并解决 LUI (需要 a=0) 与 AUIPC (需要 a=PC) 的操作数选择问题
  // --------------------------------------------------------------------------
  typedef enum logic [1:0] {
    ALU_A_RS1  = 2'd0,
    ALU_A_PC   = 2'd1,   // AUIPC; BR/JAL 目标计算
    ALU_A_ZERO = 2'd2    // LUI
    // 2'd3 保留
  } alu_a_src_e;

  typedef enum logic {
    ALU_B_RS2 = 1'b0,
    ALU_B_IMM = 1'b1
  } alu_b_src_e;

  // --------------------------------------------------------------------------
  // 立即数格式
  // --------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IMM_I = 3'd0,
    IMM_S = 3'd1,
    IMM_B = 3'd2,
    IMM_U = 3'd3,
    IMM_J = 3'd4
    // 3'd5..3'd7 保留
  } imm_fmt_e;

  // --------------------------------------------------------------------------
  // 分支类型 — 编码有结构: bit[2]=有符号比较, bit[1]=无符号比较, bit[0]=取反
  // (GE=~LT, GEU=~LTU, NE=~EQ), branch_unit 由此只需 2 个比较器
  // --------------------------------------------------------------------------
  typedef enum logic [2:0] {
    BR_EQ  = 3'b000,
    BR_NE  = 3'b001,
    BR_LT  = 3'b100,
    BR_GE  = 3'b101,
    BR_LTU = 3'b110,
    BR_GEU = 3'b111
    // 3'b010/3'b011 非法, control_unit 译码为 illegal
  } branch_type_e;

  // --------------------------------------------------------------------------
  // 访存宽度 (load/store 共用)
  // --------------------------------------------------------------------------
  typedef enum logic [1:0] {
    MEM_BYTE = 2'd0,
    MEM_HALF = 2'd1,
    MEM_WORD = 2'd2
    // 2'd3 保留
  } mem_size_e;

  // --------------------------------------------------------------------------
  // 写回来源
  // --------------------------------------------------------------------------
  typedef enum logic [1:0] {
    WB_ALU = 2'd0,
    WB_MEM = 2'd1,   // load 数据 (经 load 扩展单元)
    WB_PC4 = 2'd2,   // JAL/JALR 链接值
    WB_CSR = 2'd3    // CSR 旧值 (CSRRW/S/C 写回 rd 的是 *读到的旧值*)
  } wb_src_e;

  // --------------------------------------------------------------------------
  // SYSTEM 指令子类型 (opcode = 1110011)
  // --------------------------------------------------------------------------
  typedef enum logic [2:0] {
    SYS_NONE   = 3'd0,   // 非 SYSTEM 指令
    SYS_CSR    = 3'd1,   // Zicsr: CSRRW/S/C + 立即数形式
    SYS_ECALL  = 3'd2,   // 环境调用 -> 异常 11
    SYS_EBREAK = 3'd3,   // 断点    -> 异常 3
    SYS_MRET   = 3'd4    // 从 M 模式陷阱返回
  } sys_op_e;

  // --------------------------------------------------------------------------
  // 下一 PC 来源 —— 取代旧设计中 branch/jump/jalr 三个独立位,
  // 流水线化时直接映射为重定向类型
  // --------------------------------------------------------------------------
  typedef enum logic [1:0] {
    PC_NEXT = 2'd0,   // pc + 4
    PC_BR   = 2'd1,   // 条件分支, 目标=alu_out, 是否跳转由 branch_unit 决定
    PC_J    = 2'd2,   // JAL,   目标=alu_out (pc+imm)
    PC_JR   = 2'd3    // JALR,  目标=(rs1+imm)&~1 = alu_out&~1
  } pc_sel_e;

  // --------------------------------------------------------------------------
  // 控制束 — 单周期下整束组合产生并全周期有效;
  // 流水线化时在 ID/EX 整体打拍, 按注释的消费阶段向 EX/MEM/WB 切片。
  // 注意: 全零值 ('0) 恰好是安全的"NOP"默认 (所有枚举 0 值均合法且无害),
  // control_unit 以 ctrl = '0 起步再覆盖, 不存在锁存器问题。
  // --------------------------------------------------------------------------
  typedef struct packed {
    // ---- EX 段消费 ----
    alu_op_e      alu_op;        // ALU 操作
    alu_a_src_e   alu_a_src;     // ALU A 操作数来源 (RS1/PC/ZERO)
    alu_b_src_e   alu_b_src;     // ALU B 操作数来源 (RS2/IMM)
    branch_type_e branch_type;   // 条件分支比较类型 (PC_BR 时有效)
    pc_sel_e      pc_sel;        // 下一 PC 来源
    // ---- MEM 段消费 ----
    logic       mem_read;        // load 使能
    logic       mem_write;       // store 使能
    mem_size_e  mem_size;        // 访存宽度
    logic       mem_unsigned;    // load 无符号扩展 (LB/LBU, LH/LHU)
    // ---- WB 段消费 ----
    logic       reg_write;       // 写回使能
    wb_src_e    wb_src;          // 写回数据来源
    // ---- ID 段消费 ----
    imm_fmt_e   imm_fmt;         // 立即数格式 (imm_gen 用)
    // ---- 状态/异常 ----
    logic       illegal;         // 非法指令标志 (core 据此发起异常 2)
    // ---- SYSTEM / Zicsr (EX 段消费) ----
    sys_op_e    sys_op;          // SYSTEM 子类型
    logic [11:0] csr_addr;       // CSR 地址 (instr[31:20])
    logic [1:0]  csr_cmd;        // 01=W (直接写) 10=S (置位) 11=C (清位)
    logic        csr_src_imm;    // 1 = 源操作数取 5 位零扩展的 uimm, 0 = 取 rs1
    logic [4:0]  csr_uimm;       // 立即数形式的源 (instr[19:15])
  } ctrl_s;

  // --------------------------------------------------------------------------
  // 地址映射 (Harvard; 参数化, 改这里即可搬迁)
  //   PC_RESET 与 IMEM_BASE 采用 riscv-tests 约定 0x8000_0000;
  //   数据段用独立基址, 与指令段分离 (汇编器/链接脚本按此约定放置 .text/.data);
  //   两个存储器深度都必须是 4 字节的 2 的幂 (索引用地址位切片)
  // --------------------------------------------------------------------------
  parameter logic [31:0] PC_RESET   = 32'h8000_0000;
  parameter logic [31:0] IMEM_BASE  = 32'h8000_0000;
  parameter int unsigned IMEM_BYTES = 16384;          // 16 KB = 4096 条指令
  parameter logic [31:0] DMEM_BASE  = 32'h9000_0000;
  parameter int unsigned DMEM_BYTES = 16384;          // 16 KB 数据

  parameter logic [31:0] INSTR_NOP  = 32'h0000_0013;  // addi x0,x0,0: 流水线气泡

  // --------------------------------------------------------------------------
  // MMIO 映射 —— 落在 DMEM 窗口之外的访问由 core 的 ext_* 总线送出, 由顶层外设响应。
  // 地址译码在 core 内完成: DMEM 窗口 -> 内部 dmem; 其它 -> ext_* 总线。
  // 外设一律 32 位对齐访问; 本核 LSU 是组合读, 要求外设同拍组合给出读数据。
  // --------------------------------------------------------------------------
  parameter logic [31:0] MMIO_BASE = 32'hA000_0000;

  localparam logic [31:0] MMIO_GPIO_OUT   = 32'hA000_0000;  // W: GPIO/LED 输出
  localparam logic [31:0] MMIO_GPIO_IN    = 32'hA000_0004;  // R: 按键/拨码输入
  localparam logic [31:0] MMIO_CYCLE_LO   = 32'hA000_0008;  // R: 自由运行周期计数器 [31:0]
  localparam logic [31:0] MMIO_CYCLE_HI   = 32'hA000_000C;  // R: 周期计数器 [63:32]
  localparam logic [31:0] MMIO_UART_TX    = 32'hA000_0010;  // W: 发送一个字节 (bit[7:0])
  localparam logic [31:0] MMIO_UART_STAT  = 32'hA000_0014;  // R: bit0 = TX 忙
  localparam logic [31:0] MMIO_UART_RX    = 32'hA000_0018;  // R: 收到的字节
  localparam logic [31:0] MMIO_UART_RSTAT = 32'hA000_001C;  // R: bit0 = RX 有数据
  // 上板跑分观测用 (软件 -> 硬件单向报告, 供顶层 LED 与 ILA 抓取)
  localparam logic [31:0] MMIO_MARK        = 32'hA000_0020;  // W: 写任意值 -> 单拍 mark 脉冲 (ILA 触发点)
  localparam logic [31:0] MMIO_RESULT      = 32'hA000_0024;  // W/R: 写锁存结果并置 done; 读回该值
  // 机器定时器 (对应 RISC-V 的 mtime/mtimecmp, 产生 MTIP 中断)
  localparam logic [31:0] MMIO_MTIMECMP_LO = 32'hA000_0028;  // W/R: mtimecmp[31:0]
  localparam logic [31:0] MMIO_MTIMECMP_HI = 32'hA000_002C;  // W/R: mtimecmp[63:32]
  localparam logic [31:0] MMIO_MTIME_LO    = 32'hA000_0030;  // R:   mtime[31:0]  (= 周期计数器)
  localparam logic [31:0] MMIO_MTIME_HI    = 32'hA000_0034;  // R:   mtime[63:32]

  // --------------------------------------------------------------------------
  // GEMM 加速单元 (AI 应用场景) —— 见 gemm_accel.sv 与 results/p5-ai-accelerator.md
  // --------------------------------------------------------------------------
  // 设计要点: 本核 dmem 是**单读口且被 LSU 独占**, 加速单元若直接访存就会争用,
  // 而且单口限制使每拍只能取一个操作数、并行度上不去。所以采用"**本地缓冲**"
  // 方案: 加速单元自带片上缓冲, CPU 用 MMIO 把数据推入、算完再读出来。
  // 零访存冲突, 且不动已经上板验证过的 CPU/存储子系统。
  //
  // 缓冲布局 (一个 1KB 的 arena, 按字编址):
  //   +0x000 .. +0x0FF  A[256]  int8   (16x16, 行主序)  —— 64 个字
  //   +0x100 .. +0x1FF  B[256]  int8                    —— 64 个字
  //   +0x200 .. +0x5FF  C[256]  int32                   —— 256 个字
  localparam logic [31:0] MMIO_GEMM_CTRL   = 32'hA000_0040;  // W: bit0=start(自清) bit1=irq_en
  localparam logic [31:0] MMIO_GEMM_STATUS = 32'hA000_0044;  // R: bit0=busy bit1=done(读清)
  localparam logic [31:0] MMIO_GEMM_M      = 32'hA000_0048;  // W/R: A 的行数
  localparam logic [31:0] MMIO_GEMM_K      = 32'hA000_004C;  // W/R: A 的列数 = B 的行数
  localparam logic [31:0] MMIO_GEMM_N      = 32'hA000_0050;  // W/R: B 的列数
  localparam logic [31:0] MMIO_GEMM_CYCLES = 32'hA000_0054;  // R:  本次运算周期数 (软件算加速比)
  localparam logic [31:0] MMIO_GEMM_ARENA  = 32'hA000_0400;  // W/R: 缓冲窗口基址 (1KB, 按字访问)
  // 诊断寄存器 (可综合): 最近一拍状态机算出的 A 字节下标与 A/B 操作数。
  // 留着是因为"加速单元读不到操作数"这类问题只能靠看内部下标来定位。
  localparam logic [31:0] MMIO_GEMM_DBGA   = 32'hA000_0058;  // R: 最近用的 A 字节下标
  localparam logic [31:0] MMIO_GEMM_DBGV   = 32'hA000_005C;  // R: {b_val, a_val} (各含符号扩展)
  localparam logic [31:0] MMIO_GEMM_DBGW   = 32'hA000_0060;  // R: {写回次数[15:0], 写回下标[15:0]}
  localparam logic [31:0] MMIO_GEMM_DBGK   = 32'hA000_0064;  // R: {r_n, r_k} 运算期间的值

  // --------------------------------------------------------------------------
  // 陷阱原因码 (mcause 的低 4 位; 最高位由 csr_file 补 = 是否中断)
  // --------------------------------------------------------------------------
  localparam logic [3:0] CAUSE_INSN_MISALIGN  = 4'd0;
  localparam logic [3:0] CAUSE_ILLEGAL        = 4'd2;
  localparam logic [3:0] CAUSE_BREAKPOINT     = 4'd3;
  localparam logic [3:0] CAUSE_LOAD_MISALIGN  = 4'd4;
  localparam logic [3:0] CAUSE_STORE_MISALIGN = 4'd6;
  localparam logic [3:0] CAUSE_ECALL_M        = 4'd11;
  localparam logic [3:0] CAUSE_IRQ_TIMER      = 4'd7;    // 机器定时器中断
  localparam logic [3:0] CAUSE_IRQ_EXT        = 4'd11;   // 机器外部中断

  // --------------------------------------------------------------------------
  // EX 段操作数前递来源
  // --------------------------------------------------------------------------
  typedef enum logic [1:0] {
    FWD_REG    = 2'd0,   // 用 ID/EX 内部的寄存器值
    FWD_EX_MEM = 2'd1,   // 来自 EX/MEM (ALU 结果)
    FWD_MEM_WB = 2'd2    // 来自 MEM/WB (ALU 结果 / load 数据 / PC+4)
  } fwd_sel_e;

endpackage
