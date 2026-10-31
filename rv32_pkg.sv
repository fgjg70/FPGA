`timescale 1ns/1ps

// ============================================================================
// rv32_pkg.sv — RV32I 核心编码包 / 控制束定义（单一事实来源）
// ----------------------------------------------------------------------------
// 所有指令编码、ALU/分支/访存/写回编码只在此处定义一次, 各模块 import 使用,
// 消灭"同一编码两处维护"的幽灵 bug。
//
// 【数据通路接线契约】(供你自己编写 datapath 时对照)
//   ⚠ 本契约描述的是**单周期基线**。当前 5 级流水实现以 `core.sv` 为准 ——
//     下面第 2、3 条随 P3(fmax) 与分支预测的演进**已与 RTL 不一致**, 见各条末尾的更正。
//   1. ALU 操作数选择:
//        a_op = (alu_a_src==ALU_A_RS1) ? rs1_data
//             : (alu_a_src==ALU_A_PC ) ? pc        // AUIPC / BR/JAL 目标计算
//             :                          '0        // LUI
//        b_op = (alu_b_src==ALU_B_IMM) ? imm : rs2_data
//   2. 跳转目标 —— **【已改, 不要照抄】不再让 ALU 兼职目标加法器**:
//      原契约: BR/JAL: alu_a=PC, alu_b=IMM, ADD => alu_out = pc+imm
//              JALR  : alu_a=RS1, alu_b=IMM, ADD => alu_out = rs1+imm
//              pc_target = (pc_sel==PC_JR) ? {alu_out[31:1],1'b0} : alu_out
//      现实现(core.sv:517-536): 为把 ALU 的两级操作数 mux 移出关键路径, 控制流目标
//      改走**专用 32 位加法器**:
//              ex_ctrl_sum = (pc_sel==PC_JR ? ex_rs1 : id_ex_pc) + id_ex_imm
//              pc_target   = (pc_sel==PC_JR) ? {ex_ctrl_sum[31:1],1'b0} : ex_ctrl_sum
//      代价约 32 LUT (0.8%), 无周期代价; 数据见 results/p3-fmax.md 实验 A。
//      连带: `alu.sum_out` 端口因此失去消费者, 已于 2026-10-08 (issue #1) 删除。
//   3. PC 选择 —— **【已改, 不要照抄】**:
//      原契约: pc_src = (pc_sel==PC_BR && branch_taken) || PC_J || PC_JR
//      加入分支预测后 `redirect` 的语义从"分支 taken"变成"**预测错了**"(core.sv:566-571),
//      于是现实现是 (core.sv:636):
//              pc_src = any_redir || pred_taken
//              any_redir = redirect(预测错误) || trap_enter || mret_taken
//      真实判定仍来自 branch_unit(rs1_data, rs2_data, branch_type) -> ex_taken,
//      但要先与 BTB 预测比对 (pred_ok) 才决定是否冲刷 —— 预测正确时**绝不冲刷**。
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
    OPC_SYSTEM = 7'b1110011,   // ECALL / EBREAK / MRET / Zicsr
    OPC_AMO    = 7'b0101111    // RV32A: LR.W / SC.W / AMO*.W
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
    ALU_REMU   = 5'd17,
    // ---- RV32A 原子指令的"新值"计算 (5'd18..25) ----
    // 语义: alu_out = rs2 与"从内存读回的旧值"按 amo 类型运算后的**待写回值**。
    // 有符号/无符号的 min/max 必须分开 (这是 A 扩展最易写错的地方):
    //   amomin.w / amomax.w    用**有符号**比较
    //   amominu.w / amomaxu.w  用**无符号**比较
    ALU_AMO_SWAP  = 5'd18,   // 新值 = rs2
    ALU_AMO_ADD   = 5'd19,   // 新值 = 旧值 + rs2
    ALU_AMO_XOR   = 5'd20,
    ALU_AMO_AND   = 5'd21,
    ALU_AMO_OR    = 5'd22,
    ALU_AMO_MIN   = 5'd23,   // 有符号
    ALU_AMO_MAX   = 5'd24,   // 有符号
    ALU_AMO_MINU  = 5'd25,   // 无符号
    ALU_AMO_MAXU  = 5'd26    // 无符号
    // 5'd27..5'd31 保留
  } alu_op_e;

  // --------------------------------------------------------------------------
  // 原子操作码 (AMO) —— instr[31:27], 即 funct5。仅在 opcode = OPC_AMO 时有效。
  // 编码已用 riscv-none-elf-gcc -march=rv32ia 实测确认 (见 results/p6-a-extension.md):
  //   amoadd.w 0x0062a3af(funct5=00000)  lr.w 0x1002ae2f(00010)  sc.w 0x1862aeaf(00011)
  //   amoswap.w 0x0862af2f(00001)        amoor.w 0x4062afaf(01000)
  // --------------------------------------------------------------------------
  localparam logic [4:0] AMO_LR      = 5'b00010;
  localparam logic [4:0] AMO_SC      = 5'b00011;
  localparam logic [4:0] AMO_SWAP    = 5'b00001;
  localparam logic [4:0] AMO_ADD     = 5'b00000;
  localparam logic [4:0] AMO_XOR     = 5'b00100;
  localparam logic [4:0] AMO_AND     = 5'b01100;
  localparam logic [4:0] AMO_OR      = 5'b01000;
  localparam logic [4:0] AMO_MIN     = 5'b10000;
  localparam logic [4:0] AMO_MAX     = 5'b10100;
  localparam logic [4:0] AMO_MINU    = 5'b11000;
  localparam logic [4:0] AMO_MAXU    = 5'b11100;

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
  //
  // 【位宽构成与各级消费量 —— 实测, issue #4】当前 ctrl_s = **56 位**:
  //   alu_op 5 | alu_a_src 2 | alu_b_src 1 | branch_type 3 | pc_sel 2
  //   mem_read 1 | mem_write 1 | mem_size 2 | mem_unsigned 1
  //   reg_write 1 | wb_src 2 | imm_fmt 3 | illegal 1 | sys_op 3
  //   csr_addr 12 | csr_cmd 2 | csr_src_imm 1 | csr_uimm 5
  //   amo_en 1 | amo_op 5 | amo_aq 1 | amo_rl 1        => 合计 56
  //
  //   各流水级**实际消费量**:  ID 3/56 (译码当场用, 不进流水)   EX 44/56
  //                            MEM 16/56                        WB 3/56 (reg_write + wb_src)
  //   ⇒ **EX/MEM 之后理论上只剩约 3 位需要布线** —— 综合器对未消费字段做常量
  //     传播, 会自动把 MEM/WB 段里那 53 位优化掉。全宽走完三级的就是 EX 那 44 位,
  //     而它是真实需要的。
  //
  // 【结论: 不要为"省布线"去拆 ctrl_s】位宽不是本核的瓶颈, **扇出与走线长度才是**:
  //   实测 actual_taken 扇出 60(单跳 0.947ns)、pc_src/redirect 扇出 34(1.055ns),
  //   合计约 2.0ns = 12% 关键路径; 且 results/p3-fmax.md 的结论是本核瓶颈已转为
  //   布线 (零 IPC 代价上限 69.2 MHz)。
  //   更要紧的教训来自 results/p3-imem.md: **"不要凭'用了多少'推断'能省多少'"**
  //   (缩容 16KB→12KB 想省 LUT, 实测反而多 883 个 LUT)。
  //   真要压布线: 先出 report_route_status / 拥塞报告, 再决定动不动控制束。
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
    // ---- RV32A 原子指令 (EX/MEM 段消费) ----
    // 【为什么需要 amo_en 而不是复用 mem_read/mem_write】
    // AMO 是"读-改-写"三合一: 单拍只读或只写的 LSU 做不了, 必须让 MEM 段
    // 进入多周期序列。amo_en 就是告诉流水线控制"这条指令要走原子序列"。
    logic        amo_en;         // 1 = 本条是 LR/SC/AMO (opcode=0x2F)
    logic [4:0]  amo_op;         // funct5 (见 AMO_* 常量)
    logic        amo_aq;         // acquire 语义位
    logic        amo_rl;         // release 语义位
    // 【这两个字段"只写不读"是**有意**的, 不要当死代码删掉 (issue #3 更正)】
    //   设计上单核无 cache, aq/rl 译码后**无副作用**, 全工程确实没有消费者 ——
    //   这一半 issue #3 说对了。但 issue #3 的另一半 ("没有任何测试引用") **与
    //   实际不符**: `sim/tb_units.sv:471-472` 有 2 条定向检查专门验证它们的译码:
    //       chk({31'd0, cu_ctrl.amo_aq}, 32'd1, "AMO aq 位译码");
    //       chk({31'd0, cu_ctrl.amo_rl}, 32'd1, "AMO rl 位译码");
    //   删字段就必须连这 2 条检查一起删 —— 那是拿"回归覆盖"换 6 个 FF 的可读性,
    //   不划算 (本仓库明确把 tb_units 定位为"含**全部历史 bug** 的定向回归", 见
    //   PITFALLS)。所以这里的处理是**只补文档、不动字段**。
    // 【注意: 这里**不放** amo_newdata】
    // AMO 的"待写回值"是在 **MEM 段**算出来的 (因为要等 dmem 寄存读回的旧值),
    // 它不随流水走, 而是 core.sv 里一个专用组合单元的直接产物 -> 直接接给 LSU。
    // 曾经在这里放过一个同名字段, 结果 core.sv 里的 `assign amo_newdata = ...`
    // 撞名 (vlog-2388), 且容易让人误以为它是流水传下来的。已删除。
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

  // --------------------------------------------------------------------------
  // NPU 大容量存储窗口 (AI 加速专用; 仅 `NN_EN` 构建里参与逻辑)
  // --------------------------------------------------------------------------
  // 【为什么单独开窗口, 而不是把 DMEM 扩成 512KB】
  //   交付档 (150 MHz) 的每一步时序都是逐位锁定过的。把 dmem 扩到 512KB 会改变
  //   BRAM 的深度级联与输出 mux, 直接动到"dmem 输出 -> WB -> 前递 -> PC"那条
  //   已经压线的关键路径。这里另开一个 256KB 对齐的窗口, core 里只多一级地址
  //   比较和一个读数据 mux, 而且**全部包在 `ifdef NN_EN` 里** —— 交付档零改动。
  //   窗口的读口径与 dmem 完全一致 (地址在 MEM 拍给出、数据在 WB 拍有效), 所以
  //   不会出现"BRAM 同步读 vs MMIO 组合读差一拍"的相位错误 (PITFALLS R32 族)。
  //   布局/契约见 results/ai-accel/CONTRACT.md。
  parameter logic [31:0] NN_BASE  = 32'h9004_0000;    // 256KB 对齐, 避开 DMEM 窗口
  parameter int unsigned NN_BYTES = 512*1024;         // 512 KB

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
  // NPU 控制寄存器 (AI 加速引擎, 见 results/ai-accel/CONTRACT.md §4)
  //   仅 `NN_EN` 构建里由 nn_subsys 响应; 交付档 (无 NN_EN) 这些地址读 0。
  // --------------------------------------------------------------------------
  localparam logic [31:0] MMIO_NN_CTRL   = 32'hA000_0100;  // W: bit0=start bit1=irq_en
  localparam logic [31:0] MMIO_NN_STATUS = 32'hA000_0104;  // R: bit0=busy bit1=done(读清) bit2=err(读清) bit3=irq
  localparam logic [31:0] MMIO_NN_CYCLES = 32'hA000_0108;  // R: 上一次 op 的忙周期数
  localparam logic [31:0] MMIO_NN_OP     = 32'hA000_010C;  // W: bit[1:0] 0=conv 1=pool 2=copy/up 3=add
  localparam logic [31:0] MMIO_NN_SRC    = 32'hA000_0110;  // W: 源激活缓冲字节偏移
  localparam logic [31:0] MMIO_NN_DST    = 32'hA000_0114;  // W: 目的激活缓冲字节偏移
  localparam logic [31:0] MMIO_NN_WOFF   = 32'hA000_0118;  // W: 权重区字节偏移
  localparam logic [31:0] MMIO_NN_QOFF   = 32'hA000_011C;  // W: 量化参数区字节偏移
  localparam logic [31:0] MMIO_NN_IH     = 32'hA000_0120;  // W: 输入高
  localparam logic [31:0] MMIO_NN_IW     = 32'hA000_0124;  // W: 输入宽
  localparam logic [31:0] MMIO_NN_IC     = 32'hA000_0128;  // W: 输入通道
  localparam logic [31:0] MMIO_NN_OC     = 32'hA000_012C;  // W: 输出通道
  localparam logic [31:0] MMIO_NN_KS     = 32'hA000_0130;  // W: 卷积核 1/3/5 (pool: 2/3/5/9)
  localparam logic [31:0] MMIO_NN_ST     = 32'hA000_0134;  // W: 步长 1/2
  localparam logic [31:0] MMIO_NN_PAD    = 32'hA000_0138;  // W: 真实 padding 像素数
  localparam logic [31:0] MMIO_NN_FLAGS  = 32'hA000_013C;  // W: bit0=depthwise bit1=leaky bit2=add bit3=upsample bit4=pool_max
  localparam logic [31:0] MMIO_NN_DBG0   = 32'hA000_0140;  // R: 引擎状态
  localparam logic [31:0] MMIO_NN_DBG1   = 32'hA000_0144;  // R: {cur_ic, cur_oc}
  localparam logic [31:0] MMIO_NN_DBG2   = 32'hA000_0148;  // R: {cycles, err_code}

  // --------------------------------------------------------------------------
  // 陷阱原因码
  // --------------------------------------------------------------------------
  // 【为什么分成两组命名 (issue #2)】RISC-V 规范把"异常"与"中断"放在**不同的
  // 取值空间**里: mcause 的 bit31 = 是否中断, 低 4 位才是原因码。而机器定时器
  // (7) 与机器外部 (11) 这两个**中断编号**, 恰好与 LOAD_MISALIGN(4) / ECALL_M(11)
  // 这两个**异常编号**数值重复 —— 于是放在同一组 `CAUSE_*` 常量里会让人误读
  // (issue 作者自己在核对时就被绊了一次)。
  //
  // 注意: **行为本来就是对的**, 不是 bug —— `csr_file.sv:138` 生成 irq_cause 时
  // 是 `{1'b1, 编号}` 显式补上最高位的, 所以 mcause 得到 0x8000_0007 / 0x8000_000B,
  // 两个值都符合规范。这里只是**改名分组**以消除误读 (issue #2 已从 fix 降为 style)。
  //
  // ⚠ 这个文件已经因为 `mcause` 位布局吃过一次真 bug: `csr_file.sv:169-175` 记录
  //   过"bit4 写成 bit31 之外的位 -> mcause 读回 0x00000017 而不是 0x80000007 ->
  //   中断处理程序全部走错分支"。所以同一处的"异常码/中断码混读"值得防复发。
  // --------------------------------------------------------------------------

  // ---- 异常原因码 (同步, mcause[31] = 0) ----
  localparam logic [3:0] CAUSE_INSN_MISALIGN  = 4'd0;
  localparam logic [3:0] CAUSE_ILLEGAL        = 4'd2;
  localparam logic [3:0] CAUSE_BREAKPOINT     = 4'd3;
  localparam logic [3:0] CAUSE_LOAD_MISALIGN  = 4'd4;
  localparam logic [3:0] CAUSE_STORE_MISALIGN = 4'd6;
  localparam logic [3:0] CAUSE_ECALL_M        = 4'd11;

  // ---- 中断编号 (异步, mcause[31] = 1) ----
  // 这两项与上面的异常码**数值表面重复** (7 / 11), 但它们属于规范定义的中断编号,
  // 与异常码不是一个取值空间; 使用时一律由 `{1'b1, code}` 补上最高位。
  localparam logic [3:0] IRQ_TIMER            = 4'd7;    // machine timer    -> mcause 0x8000_0007
  localparam logic [3:0] IRQ_EXT              = 4'd11;   // machine external -> mcause 0x8000_000B

  // --------------------------------------------------------------------------
  // EX 段操作数前递来源
  // --------------------------------------------------------------------------
  typedef enum logic [1:0] {
    FWD_REG    = 2'd0,   // 用 ID/EX 内部的寄存器值
    FWD_EX_MEM = 2'd1,   // 来自 EX/MEM (ALU 结果)
    FWD_MEM_WB = 2'd2    // 来自 MEM/WB (ALU 结果 / load 数据 / PC+4)
  } fwd_sel_e;

endpackage
