`timescale 1ns/1ps

// ============================================================================
// core.sv — RV32I 五级流水线处理器 (IF / ID / EX / MEM / WB)
// ----------------------------------------------------------------------------
// 流水线结构:
//   IF  : PC -> imem (组合读)                              => IF/ID
//   ID  : control_unit 译码, imm_gen, regfile 读 (组合读)   => ID/EX
//   EX  : 前递 mux -> ALU (兼职跳转目标加法器) + branch_unit 判定 => EX/MEM
//   MEM : load_store_unit (字节通道 + 非对齐拆分) + dmem      => MEM/WB
//   WB  : 写回 mux -> regfile
//
// 关键设计点 (详见各模块头注释与 rv32_pkg 顶部契约):
//   - 跳转目标复用 ALU: BR/JAL 用 a=PC, JALR 用 a=rs1, b=imm; JALR 目标清最低位
//   - 分支/跳转在 EX 判定, 重定向冲刷 IF/ID 与 ID/EX 两级 (2 周期惩罚)
//   - load-use 停顿 1 拍; 非对齐跨字访存在 MEM 占 2 拍 (冻结 1 拍)
//   - 寄存器堆组合读 + 写旁路 (write-first): 覆盖"距离 3"的 RAW 依赖
//     (WB 写与 ID 读同拍); 距离 1/2 由 hazard_unit 前递, load-use 停顿 1 拍
//   - 非法指令: 控制束已中性化为无副作用, 此处仅置粘滞调试标志 (trap 预留)
//   - 调试口: dbg_pc / dbg_instr / dbg_illegal / dbg_raddr -> dbg_rdata
// ============================================================================

module core
  import rv32_pkg::*;
(
  input  logic        clk,
  input  logic        rst,

  // 调试接口 (仿真 / ILA; 可悬空)
  output logic [31:0] dbg_pc,      // IF 段正在取的地址 ("现在跑到哪了")
  output logic [31:0] dbg_id_pc,   // IF/ID 中那条指令的地址 (与 dbg_instr 配对)
  output logic [31:0] dbg_instr,
  output logic        dbg_illegal,
  input  logic [4:0]  dbg_raddr,
  output logic [31:0] dbg_rdata,

  // 存储器写观测口 (上板闭环 / ILA 用; 可悬空)
  // 直接旁路自 dmem 端口, 让顶层能在真实硬件上判定自校验程序的 PASS/FAIL,
  // 而不必深入 core 内部做跨模块引用 (那样会妨碍综合优化)。
  output logic        dbg_mem_we,
  output logic [31:0] dbg_mem_addr,
  output logic [31:0] dbg_mem_wdata,

  // 流水线效率观测 (分析报告里的 ILA 波形用; 可悬空)
  output logic        dbg_stall,     // 流水线停顿 (load-use / 拆分访存 / 多周期乘除)
  output logic        dbg_redirect,  // 分支预测错误引发的冲刷

  // 外部 MMIO 总线 (DMEM 窗口之外的访问; 接 GPIO/UART/定时器等外设)
  // 组合读: 外设必须在同拍给出 ext_rdata, 与本核组合读的 LSU 匹配。
  output logic        ext_we,
  output logic        ext_re,      // 读选通 (1 拍脉冲) —— 外设靠它清"数据就绪"标志
  output logic [31:0] ext_addr,
  output logic [31:0] ext_wdata,
  output logic [3:0]  ext_wstrb,
  input  logic [31:0] ext_rdata,

  // 定时器中断请求 (电平, 来自 mmio_subsys 的 mtime>=mtimecmp; -> mip.MTIP)
  input  logic        irq_timer
);

  // ==========================================================================
  // 互连信号声明 (集中声明, 避免使用前隐式线网)
  // ==========================================================================
  // IF
  logic [31:0] pc, pc_plus4, pc_target, imem_rdata;
  logic        pc_src;
  logic        redirect, redirect_raw;
  logic        lsu_stall;
  logic        id_ex_bubble;

  // 分支预测
  logic        pred_hit, pred_taken, btb_upd_en, is_ctrl_flow;
  logic [31:0] pred_target, actual_target;
  logic        pred_is_ret;          // 预测命中的 PC 是"函数返回" (RAS 用)
  logic        ex_is_call, ex_is_ret;// EX 解析出的 call / return (RAS 控制)
  logic        actual_taken, pred_ok;
  wire  [31:0] btb_pred_target;

  // IF/ID
  logic [31:0] if_pc, if_pc_plus4, if_instr;
  logic        if_pred_taken;
  logic [31:0] if_pred_target;

  // ID
  ctrl_s       id_ctrl;
  logic [31:0] id_imm, id_rs1_data, id_rs2_data;
  logic [4:0]  id_rs1, id_rs2, id_rd;

  // ID/EX
  ctrl_s       id_ex_ctrl;
  logic [31:0] id_ex_pc, id_ex_pc_plus4, id_ex_rs1_data, id_ex_rs2_data, id_ex_imm;
  logic [4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;
  logic        id_ex_pred_taken;
  logic [31:0] id_ex_pred_target;

  // EX
  fwd_sel_e    fwd_a, fwd_b;
  logic [31:0] ex_rs1, ex_rs2, ex_a, ex_b, ex_alu_out, ex_pc_target, ex_sum;
  // RV32M
  logic [31:0] ex_result, md_result;
  logic        md_busy, is_muldiv;
  logic        ex_taken;

  // ---- Zicsr / 陷阱 (M-mode) ----
  logic [31:0] csr_rdata, csr_wdata, csr_src;
  logic        csr_we, is_csr;
  logic        exc_req, irq_take, trap_req, trap_enter, trap_redir, any_redir;
  logic [4:0]  trap_cause, irq_cause;
  logic [3:0]  exc_cause;
  logic [31:0] trap_vector, mret_pc;
  logic        irq_pending, mret_taken, is_mret;

  // EX/MEM
  ctrl_s       ex_mem_ctrl;
  logic [31:0] ex_mem_alu_out, ex_mem_store_data, ex_mem_pc_plus4;
  logic [4:0]  ex_mem_rd;

  // MEM
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata, mem_load_data;
  logic [3:0]  dmem_wstrb;
  logic        dmem_we;
  // 地址译码: 内部 dmem vs 外部 MMIO
  logic        sel_dmem;
  logic        dmem_we_g;
  logic [31:0] dmem_rdata_g;
  // dmem 改成寄存读之后, MMIO 读数据也必须寄存一拍, 否则两条路径差一拍、
  // 写回 mux 会取到错的数据。
  logic        sel_dmem_r;
  logic [31:0] ext_rdata_r;

  // MEM/WB
  ctrl_s       mem_wb_ctrl;
  logic [31:0] mem_wb_alu_out, mem_wb_load_data, mem_wb_pc_plus4;
  logic [4:0]  mem_wb_rd;

  // WB
  logic [31:0] wb_data;
  logic [4:0]  wb_rd;
  logic        wb_reg_write;

  // 流水线控制
  logic        pipe_stall, if_id_flush, hold_mem;

  // ==========================================================================
  // IF 段
  // ==========================================================================
  pc #(.XLEN(XLEN), .RESET_PC(PC_RESET)) u_pc (
    .clk       (clk),
    .rst       (rst),
    .stall     (pipe_stall),
    .flush     (1'b0),          // 预留: trap 单元接管时改用 flush_pc
    .flush_pc  ('0),
    .pc_src    (pc_src),
    .pc_target (pc_target),
    .pc        (pc),
    .pc_plus4  (pc_plus4)
  );

  imem #(.BASE(IMEM_BASE), .BYTES(IMEM_BYTES)) u_imem (
    .clk   (clk),
    .addr  (pc),
    .rdata (imem_rdata)
  );

  assign if_id_flush = any_redir;

  // ==========================================================================
  // 分支预测 (IF 预测 / EX 校验)
  // --------------------------------------------------------------------------
  // 每周期用 pc 组合查 BTB: 命中且方向计数器说 taken -> 直接用表里的目标取指,
  // 分支惩罚归零。预测结果随 IF/ID -> ID/EX 传下去, EX 段再和真实结果比对,
  // 只有不一致时才冲刷 (redirect_raw = 预测错误)。
  // ==========================================================================
  // IDX_BITS=6 -> 64 项。曾试 128 项: 条件分支误判只从 6041 降到 5694 (省 347 次),
  // 但 LUT +258、pc 路径多一级 LUTRAM 输出 mux 使 fmax 掉 4.6%, 净亏。
  // 配合目标位宽压缩(14 位), 64 项每项只有 24 位, 比原来未压缩的 41 位还小。
  btb #(.IDX_BITS(6), .PC_TOP(14), .PC_BASE(IMEM_BASE)) u_btb (
    .clk         (clk),
    .rst         (rst),
    .pred_pc     (pc),
    .pred_hit    (pred_hit),
    .pred_taken  (pred_taken),
    .pred_target (btb_pred_target),
    .upd_en      (btb_upd_en),
    .upd_pc      (id_ex_pc),
    .upd_taken   (actual_taken),
    .upd_target  (ex_pc_target),
    .upd_is_ret  (ex_is_ret),
    .pred_is_ret (pred_is_ret)
  );

  // ==========================================================================
  // 返回地址栈 (RAS) —— 由 RAS_EN 宏控制, **默认关闭**
  // --------------------------------------------------------------------------
  // 【为什么加】把预测错误按类型拆开后实测: JALR 占全部误判的 **37%** (4378 次),
  // 且其中绝大多数是函数返回 —— BTB 只记得住"上一次"的返回地址。
  //
  // 【实测结果: 有效, 但综合指标净亏 —— 故默认关闭】
  //   CoreMark/MHz  2.3611 -> 2.3701  (+0.38%)   JALR 误判 4378 -> 3558
  //   fmax          61.3   -> 59.6    (-2.8%)
  //   LUT           4015   -> 4142
  //   绝对吞吐       144.7  -> 141.4   (-2.3%)   <-- 输
  // 原因: 栈顶是 `stk[sp-1]` 的 8:1 mux, 而它落在**已经最紧的 pc_target 路径**上
  // (预测目标 -> 下一拍 PC)。为 0.38% 的周期收益换 2.8% 的 fmax 不划算。
  // 要救它得让栈顶**提前一拍**准备好 (寄存 RAS top, 但那样返回目标就晚一拍),
  // 或与取指流水一起重排 —— 都是结构性改动, 收益太小。
  // 完整数据见 results/p4-ras.md。
  // ==========================================================================
`ifdef RAS_EN
  logic [31:0] ras_top;
  logic        ras_empty;
  // call = 带链接的跳转 (JAL/JALR 且 rd 是链接寄存器 x1/x5)
  wire ex_is_call_w = btb_upd_en
                 && ((id_ex_ctrl.pc_sel == PC_J) || (id_ex_ctrl.pc_sel == PC_JR))
                 && (id_ex_rd == 5'd1 || id_ex_rd == 5'd5);
  // return = JALR 且 rs1 是链接寄存器 且 rd=x0 (标准 ret 不长新链接)
  wire ex_is_ret_w  = btb_upd_en
                 && (id_ex_ctrl.pc_sel == PC_JR)
                 && (id_ex_rs1 == 5'd1 || id_ex_rs1 == 5'd5)
                 && (id_ex_rd == 5'd0);
  assign ex_is_call = ex_is_call_w;
  assign ex_is_ret  = ex_is_ret_w;

  ras #(.DEPTH(8)) u_ras (
    .clk     (clk),
    .rst     (rst),
    .push_en (ex_is_call),
    .push_pc (id_ex_pc_plus4),   // 返回地址 = 链接值 (JAL/JALR 写的就是 pc+4)
    .pop_en  (ex_is_ret),
    .top     (ras_top),
    .empty   (ras_empty)
  );

  // 预测目标: 若这条 PC 是"返回"(BTB 记着 is_ret) 且栈非空, 用 RAS 栈顶
  assign pred_target = (pred_is_ret && !ras_empty) ? ras_top : btb_pred_target;
`else
  assign ex_is_call  = 1'b0;      // 关掉时给恒 0, 让综合把 RAS 相关逻辑全裁掉
  assign ex_is_ret   = 1'b0;
  assign pred_target = btb_pred_target;
`endif

  // 控制流指令解析完成且结果有效时才更新 (停顿期间操作数可能未就绪)
  assign is_ctrl_flow = (id_ex_ctrl.pc_sel != PC_NEXT);
  assign btb_upd_en   = is_ctrl_flow && !pipe_stall && !rst;

  // --------------------------------------------------------------------------
  // 【寄存读取指存储器: 需要重排取指流水, 当前**不做**】
  // --------------------------------------------------------------------------
  // 结论 (2026-10-05, 实测): 把 imem 改成寄存读**不是**"给 PC 加一级寄存器"
  // 就能对齐的, 它要求重排取指流水。原因:
  //
  //   组合读: cycle N 内 addr=pc_N, rdata=instr(pc_N) —— pc 寄存器与"当前取回的
  //           指令"是同一拍, 于是 pc / pc_plus4 可以直接喂给 IF/ID 与重定向逻辑。
  //   寄存读: rdata 晚一拍, 于是 **pc 寄存器本身就成了"取指流水的一部分"**:
  //           pc(N) = instr 的地址 + 1 拍。所有"用 pc 算出来的东西"
  //           (pc_plus4 -> if_pc_plus4 -> id_ex_pc_plus4 -> 跳转链接值 /
  //            分支不跳时的后继 / actual_target) 全部跟着早了一拍。
  //
  // 实测过程: 先错位 timeout -> 给 pc_if 加一级寄存器后, 取指对齐自检
  // (tb_sw 的 [ALIGN]) 变成 0 次错位, 但 **tb_core_basic 第 2 组仍挂**;
  // 查 trace 发现跳转目标是错的 (0x80000048 的 `j .` 被解析成跳去 0x80000050),
  // 即 pc_plus4 那一串全部偏移。所以这是**取指级重排**, 不是局部补丁。
  //
  // 正确做法是引入标准的"取指地址寄存器 + 取指数据寄存器"两级结构, 并让
  // 重定向在这一级上闭环 —— 那等于**改流水线级数/结构**, 与"不动流水线"的
  // 约束冲突, 收益 (LUT −1228) 与风险不成比例, 故暂缓。
  // 详见 results/p4-macro-failure.md 第 5.1 节。
  //
  // 当前 pc_if / pred_if_* 一律直通, 与组合读行为完全一致。
  // --------------------------------------------------------------------------
  wire [31:0] pc_if          = pc;
  wire        pred_if_taken  = pred_taken;
  wire [31:0] pred_if_target = pred_target;
  wire [31:0] pc_if_plus4    = pc_plus4;

  if_id_reg #(.RESET_PC(PC_RESET)) u_if_id (
    .clk         (clk),
    .rst         (rst),
    .flush       (if_id_flush),
    .stall       (pipe_stall),
    .pc_in       (pc_if),
    .pc_plus4_in (pc_if_plus4),
    .instr_in    (imem_rdata),
    .pred_taken_in  (pred_if_taken),
    .pred_target_in (pred_if_target),
    .pc          (if_pc),
    .pc_plus4    (if_pc_plus4),
    .instr       (if_instr),
    .pred_taken  (if_pred_taken),
    .pred_target (if_pred_target)
  );

  // ==========================================================================
  // ID 段
  // ==========================================================================
  assign id_rs1 = if_instr[19:15];
  assign id_rs2 = if_instr[24:20];
  assign id_rd  = if_instr[11:7];

  control_unit u_ctrl (
    .instr (if_instr),
    .ctrl  (id_ctrl)
  );

  imm_gen u_imm (
    .instr   (if_instr),
    .fmt     (id_ctrl.imm_fmt),
    .imm_out (id_imm)
  );

  regfile #(.XLEN(XLEN), .NUM_REGS(32)) u_regfile (
    .clk       (clk),
    .we        (wb_reg_write),
    .waddr     (wb_rd),
    .wdata     (wb_data),
    .raddr1    (id_rs1),
    .raddr2    (id_rs2),
    .rdata1    (id_rs1_data),
    .rdata2    (id_rs2_data),
    .dbg_raddr (dbg_raddr),
    .dbg_rdata (dbg_rdata)
  );

  id_ex_reg u_id_ex (
    .clk         (clk),
    .rst         (rst),
    // 陷阱也必须冲掉 ID/EX —— 否则触发指令会继续走到 MEM/WB 产生副作用,
    // 陷阱就不再是"精确"的了 (见本文件顶部陷阱注释)。
    .flush       (any_redir),
    .stall       (pipe_stall),
    .bubble      (id_ex_bubble),
    .ctrl_in     (id_ctrl),
    .pc_in       (if_pc),
    .pc_plus4_in (if_pc_plus4),
    .rs1_data_in (id_rs1_data),
    .rs2_data_in (id_rs2_data),
    .imm_in      (id_imm),
    .rs1_addr_in (id_rs1),
    .rs2_addr_in (id_rs2),
    .rd_addr_in  (id_rd),
    .pred_taken_in  (if_pred_taken),
    .pred_target_in (if_pred_target),
    .ctrl        (id_ex_ctrl),
    .pc          (id_ex_pc),
    .pc_plus4    (id_ex_pc_plus4),
    .rs1_data    (id_ex_rs1_data),
    .rs2_data    (id_ex_rs2_data),
    .imm         (id_ex_imm),
    .rs1_addr    (id_ex_rs1),
    .rs2_addr    (id_ex_rs2),
    .rd_addr     (id_ex_rd),
    .pred_taken  (id_ex_pred_taken),
    .pred_target (id_ex_pred_target)
  );

  // ==========================================================================
  // EX 段
  // ==========================================================================
  // EX/MEM 段的前递数据必须按写回来源选:
  //   WB_PC4 (JAL/JALR 的链接值) -> ex_mem_pc_plus4
  //   其余                       -> ex_mem_alu_out
  // 少了这一层选择, 紧跟 jal 的消费者会从"跳转目标"里取链接值 (真踩过)。
  wire [31:0] ex_mem_fwd_data = (ex_mem_ctrl.wb_src == WB_PC4) ? ex_mem_pc_plus4
                                                               : ex_mem_alu_out;

  always_comb begin
    // 前递 mux
    ex_rs1 = (fwd_a == FWD_EX_MEM) ? ex_mem_fwd_data :
             (fwd_a == FWD_MEM_WB) ? wb_data : id_ex_rs1_data;
    ex_rs2 = (fwd_b == FWD_EX_MEM) ? ex_mem_fwd_data :
             (fwd_b == FWD_MEM_WB) ? wb_data : id_ex_rs2_data;
    // ALU 操作数 mux (契约见 rv32_pkg 顶部)
    ex_a = (id_ex_ctrl.alu_a_src == ALU_A_PC)   ? id_ex_pc :
           (id_ex_ctrl.alu_a_src == ALU_A_ZERO) ? 32'd0 : ex_rs1;
    ex_b = (id_ex_ctrl.alu_b_src == ALU_B_IMM)  ? id_ex_imm : ex_rs2;
  end

  alu #(.XLEN(XLEN)) u_alu (
    .a       (ex_a),
    .b       (ex_b),
    .op      (id_ex_ctrl.alu_op),
    .out     (ex_alu_out),
    .sum_out (ex_sum)
  );

  // ---- RV32M 乘除法单元 ----
  always_comb begin
    case (id_ex_ctrl.alu_op)
      ALU_MUL, ALU_MULH, ALU_MULHSU, ALU_MULHU,
      ALU_DIV, ALU_DIVU, ALU_REM,   ALU_REMU: is_muldiv = 1'b1;
      default:                                 is_muldiv = 1'b0;
    endcase
  end

  muldiv #(.XLEN(XLEN)) u_muldiv (
    .clk    (clk),
    .rst    (rst),
    .op     (id_ex_ctrl.alu_op),
    .a      (ex_a),
    .b      (ex_b),
    .result (md_result),
    .busy   (md_busy)
  );

  // 写回结果: M 指令取 muldiv, CSR 指令取读到的旧值, 其余取 ALU。
  // WB_CSR 走写回 mux 的 default 分支 (mem_wb_alu_out), 而 EX/MEM 存的就是
  // ex_result —— 所以只要在这里加一路, CSR 读值就自然到了 WB 段。
  assign ex_result = is_muldiv ? md_result
                   : is_csr    ? csr_rdata
                   :             ex_alu_out;

  branch_unit #(.XLEN(XLEN)) u_branch (
    .rs1         (ex_rs1),        // 分支用前递后的寄存器值
    .rs2         (ex_rs2),
    .branch_type (id_ex_ctrl.branch_type),
    .taken       (ex_taken)
  );

  // ---- 跳转/分支目标: 独立加法器 (P3 fmax 还债) ----
  //
  // 【为什么不让跳转目标穿 ALU】原写法取 alu 的 ex_sum, 虽然已绕过 ALU 的
  // 结果 mux, 但**操作数 mux 仍在路径上**: ex_a 是 3:1 (PC/ZERO/rs1)、
  // ex_b 是 2:1 (imm/rs2)。而 BR/JAL/JALR 的 alu_op 恒为 ADD, 操作数是确定的:
  //   BR/JAL -> pc + imm      JALR -> rs1 + imm
  // 所以这里给它们一条**只有 1 级 mux** 的专用加法器, 把 ALU 那两级操作数 mux
  // 整个移出关键路径。
  //
  // 关键路径实测 (P1 后): u_dmem/mem_reg_3/CLKBWRCLK -> u_pc/pc_reg[2]/D
  //   16.125ns (logic 5.268 = 32.7%, route 10.857 = 67.3%), 19 级
  // 布线占 2/3 -> 少一级逻辑往往同时减少扇出与布线长度, 收益可能超过逻辑本身。
  // 代价: 一个 32 位加法器 (约 32 LUT, 相对 3923 是 ~0.8%), 无任何周期代价。
  wire [31:0] ex_ctrl_operand_a = id_ex_ctrl.pc_sel == PC_JR ? ex_rs1 : id_ex_pc;
  wire [31:0] ex_ctrl_sum       = ex_ctrl_operand_a + id_ex_imm;

  // 跳转目标: JALR 清最低位 (规范要求), 其余直接取专用加法器输出。
  assign ex_pc_target = (id_ex_ctrl.pc_sel == PC_JR)
                        ? {ex_ctrl_sum[31:1], 1'b0}
                        : ex_ctrl_sum;

  // ---- 控制流真实结果 ----
  assign actual_taken = ((id_ex_ctrl.pc_sel == PC_BR) && ex_taken) ||
                        (id_ex_ctrl.pc_sel == PC_J) ||
                        (id_ex_ctrl.pc_sel == PC_JR);

  // 【重定向目标必须是"正确的后继 PC"】
  //   实际 taken   -> 控制流目标 ex_pc_target
  //   实际不 taken -> pc+4
  // 不能在"非 PC_NEXT"时一律用 ex_pc_target —— 条件分支 *不 taken* 时
  // ex_pc_target 是分支目标而不是后继, 用它会把 PC 送进错误路径。
  // (第一版就是这么写错的: 一旦 BTB 预测 taken 而分支实际不跳, 就会跳到
  //  分支目标, 程序直接跑飞。tb_core 与 CoreMark 同时失败暴露了它。)
  // 直接用流水寄存器里现成的 pc+4, *不要* 在这里再算一次 id_ex_pc + 4 ——
  // 那会在关键路径 (rs1/rs2 -> 前递 -> ALU -> 目标选择 -> pc) 上串进一个
  // 额外的 32 位加法器。实测它让 WNS 从 +7.25ns 掉到 +4.64ns (fmax 78->65MHz)。
  assign actual_target = actual_taken ? ex_pc_target : id_ex_pc_plus4;

  // ---- 预测正确性判定 ----
  // 方向一致; 若实际 taken, 目标也必须一致。
  assign pred_ok = (actual_taken == id_ex_pred_taken) &&
                   (!actual_taken || (actual_target == id_ex_pred_target));

  // 【关键】redirect 不再是"分支 taken", 而是"预测错误"。
  // 预测正确时绝不能冲刷, 否则两条正确路径被白白丢掉, 预测收益归零。
  assign redirect_raw = !pred_ok;

  // ==========================================================================
  // Zicsr 与陷阱 (M-mode) —— 赛题高阶任务"完整异常/中断"
  // --------------------------------------------------------------------------
  // 陷阱在 EX 段、指令 *提交之前* 裁决, 与分支预测错误共用同一套冲刷机制。
  // 这样陷阱是精确的: 触发指令被冲成气泡 -> 不写寄存器、不写存储器, 而它之前
  // 的指令全部已经提交。mepc 记 trap_pc 本身(不 +4), 因为被抢占的指令必须
  // 重新执行 —— 异常时它是触发指令, 中断时它是本来要执行的下一条。
  // ==========================================================================
  csr_file u_csr (
    .clk         (clk),
    .rst         (rst),
    .raddr       (id_ex_ctrl.csr_addr),
    .rdata       (csr_rdata),
    .we          (csr_we),
    .waddr       (id_ex_ctrl.csr_addr),
    .wdata       (csr_wdata),
    .trap_req    (trap_req),
    .trap_cause  (trap_cause),
    .trap_pc     (id_ex_pc),
    .trap_tval   (32'd0),
    .trap_enter  (trap_enter),
    .trap_vector (trap_vector),
    .mret_req    (is_mret && !pipe_stall),
    .mret_taken  (mret_taken),
    .mret_pc     (mret_pc),
    // P2 已接通: mtimecmp 定时器中断 (mmio_subsys 产生, 电平)
    .irq_timer   (irq_timer),
    .irq_ext     (1'b0),        // 外部中断: 暂无外设, 预留
    .irq_pending (irq_pending),
    .irq_cause   (irq_cause)
  );

  // ---- EX 段 CSR 读改写 ----
  assign is_csr    = (id_ex_ctrl.sys_op == SYS_CSR);
  assign csr_src   = id_ex_ctrl.csr_src_imm ? {27'b0, id_ex_ctrl.csr_uimm} : ex_rs1;
  assign csr_wdata = (id_ex_ctrl.csr_cmd == 2'b01) ? csr_src
                   : (id_ex_ctrl.csr_cmd == 2'b10) ? (csr_rdata |  csr_src)
                   :                                (csr_rdata & ~csr_src);
  // 规范: CSRRS/CSRRC 且源为 0 时不写 —— 读只读寄存器不得触发异常。
  // exc_req 也参与否决: 陷阱与 CSR 写不能同拍 (异常指令本身就不该有副作用)。
  assign csr_we    = is_csr && !pipe_stall && !exc_req &&
                     (id_ex_ctrl.csr_cmd == 2'b01 || csr_src != 32'd0);

  // ---- 陷阱判定 (EX 段, 指令提交前) ----
  // 优先于分支重定向: 异常/中断一旦成立, 这条指令不能提交, 分支结果也不再重要。
  assign is_mret  = (id_ex_ctrl.sys_op == SYS_MRET);
  assign exc_req  = !pipe_stall && (id_ex_ctrl.illegal ||
                                    id_ex_ctrl.sys_op == SYS_ECALL ||
                                    id_ex_ctrl.sys_op == SYS_EBREAK);
  assign exc_cause = id_ex_ctrl.illegal            ? CAUSE_ILLEGAL
                   : id_ex_ctrl.sys_op == SYS_ECALL ? CAUSE_ECALL_M
                   :                                  CAUSE_BREAKPOINT;
  // 中断优先级低于异常 (规范要求), 且不在 MRET 那一拍取中断。
  assign irq_take  = irq_pending && !pipe_stall && !exc_req && !is_mret;
  assign trap_req  = exc_req || irq_take;
  assign trap_cause = exc_req ? {1'b0, exc_cause} : irq_cause;
  // 访存地址错异常 (CAUSE_LOAD/STORE_MISALIGN) 本核按"支持非对齐访存"处理,
  // 故不产生 —— tb_core 的 basic.hex 专门测了非对齐访存, 必须继续通过。

  // ---- 重定向: 分支预测错误 与 陷阱 共用 ----
  assign trap_redir = trap_enter || mret_taken;
  assign any_redir  = redirect || trap_redir;

  assign pc_src    = any_redir || pred_taken;
  // 目标优先级: 陷阱入口 > MRET 返回 > 预测错误纠正 > 预测目标
  assign pc_target = trap_enter ? trap_vector
                   : mret_taken ? mret_pc
                   : redirect   ? actual_target
                   :              pred_target;

  // ==========================================================================
  // 冒险单元
  // ==========================================================================
  hazard_unit u_hazard (
    .id_ex_rs1        (id_ex_rs1),
    .id_ex_rs2        (id_ex_rs2),
    .id_ex_mem_read   (id_ex_ctrl.mem_read),
    .id_ex_rd         (id_ex_rd),
    .ex_mem_reg_write (ex_mem_ctrl.reg_write),
    .ex_mem_mem_read  (ex_mem_ctrl.mem_read),
    .ex_mem_rd        (ex_mem_rd),
    .mem_wb_reg_write (mem_wb_ctrl.reg_write),
    .mem_wb_rd        (mem_wb_rd),
    .if_id_rs1        (id_rs1),
    .if_id_rs2        (id_rs2),
    .lsu_stall        (lsu_stall),
    .ex_busy          (md_busy),
    .redirect_raw     (redirect_raw),
    .fwd_a            (fwd_a),
    .fwd_b            (fwd_b),
    .pipe_stall       (pipe_stall),
    .id_ex_bubble     (id_ex_bubble),
    .hold_mem         (hold_mem),
    .redirect         (redirect)
  );

  // ==========================================================================
  // EX/MEM
  // ==========================================================================
  ex_mem_reg u_ex_mem (
    .clk           (clk),
    .rst           (rst),
    .stall         (hold_mem),
    .ctrl_in       (id_ex_ctrl),
    .alu_out_in    (ex_result),
    .store_data_in (ex_rs2),         // store 数据 (前递后)
    .pc_plus4_in   (id_ex_pc_plus4),
    .rd_addr_in    (id_ex_rd),
    .ctrl          (ex_mem_ctrl),
    .alu_out       (ex_mem_alu_out),
    .store_data    (ex_mem_store_data),
    .pc_plus4      (ex_mem_pc_plus4),
    .rd_addr       (ex_mem_rd)
  );

  // ==========================================================================
  // MEM 段
  // ==========================================================================
  load_store_unit u_lsu (
    .clk          (clk),
    .rst          (rst),
    .req_read     (ex_mem_ctrl.mem_read),
    .req_write    (ex_mem_ctrl.mem_write),
    .req_size     (ex_mem_ctrl.mem_size),
    .req_unsigned (ex_mem_ctrl.mem_unsigned),
    .req_addr     (ex_mem_alu_out),
    .req_wdata    (ex_mem_store_data),
    .dmem_addr    (dmem_addr),
    .dmem_wdata   (dmem_wdata),
    .dmem_wstrb   (dmem_wstrb),
    .dmem_we      (dmem_we),
    .dmem_rdata   (dmem_rdata_g),   // 译码后: 窗口内取 dmem, 窗口外取 ext_rdata
    .load_data    (mem_load_data),
    .lsu_stall    (lsu_stall)
  );

  // ------------------------------------------------------------------------
  // 地址译码: DMEM 窗口内 -> 内部 dmem; 窗口外 -> 外部 MMIO 总线
  // 原设计里 imem/dmem 的 BASE 参数声明了却从不使用, 任何地址都会别名进
  // 16KB 窗口 —— 那样既无法加 MMIO, 也无法产生访问错误异常。这里让 BASE
  // 真正参与译码。
  // ------------------------------------------------------------------------
  assign sel_dmem     = (dmem_addr >= DMEM_BASE) && (dmem_addr < (DMEM_BASE + DMEM_BYTES));
  assign dmem_we_g    = dmem_we && sel_dmem;                                  // 窗口外不写内部 RAM
  // 读数据回选: 内部 dmem 与外部 MMIO 都已寄存一拍, 用寄存后的选择信号对齐
  always @(posedge clk) begin
    ext_rdata_r <= ext_rdata;
    sel_dmem_r  <= sel_dmem;
  end
  assign dmem_rdata_g = sel_dmem_r ? dmem_rdata : ext_rdata_r;

  // 读选通同样必须送出: 外设的"数据就绪"标志需要软件读一次来清除, 若只给写
  // 选通, 粘滞标志永远清不掉 —— 表现为"第一次轮询正常, 之后每次都立即通过并
  // 读到上一次的数据"(UART RX 实测踩过)。mem_read 只在 load 的 MEM 段有效,
  // 所以它天然是每访问一拍的脉冲, 不像地址会在总线上多停几拍。
  assign ext_we    = dmem_we && !sel_dmem && (dmem_wstrb != 4'b0000);
  assign ext_re    = ex_mem_ctrl.mem_read && !sel_dmem;
  assign ext_addr  = dmem_addr;
  assign ext_wdata = dmem_wdata;
  assign ext_wstrb = dmem_wstrb;

  dmem #(.BASE(DMEM_BASE), .BYTES(DMEM_BYTES)) u_dmem (
    .clk   (clk),
    .addr  (dmem_addr),
    .wdata (dmem_wdata),
    .wstrb (dmem_wstrb),
    .we    (dmem_we_g),
    .rdata (dmem_rdata)
  );

  // ==========================================================================
  // MEM/WB 与 WB 段
  // ==========================================================================
  mem_wb_reg u_mem_wb (
    .clk          (clk),
    .rst          (rst),
    .stall        (hold_mem),
    .ctrl_in      (ex_mem_ctrl),
    .alu_out_in   (ex_mem_alu_out),
`ifdef LOAD_RESULT_REG
    // 【P3 实验C】让 MEM/WB 真正寄存 load 结果。
    // 关键路径原来长这样 (15.2ns, route 占 64%):
    //   u_dmem 输出寄存器 -> LSU 字节提取 -> wb_data mux -> 前递 mux -> ID/EX
    // 即"组合读出的数据"在**同一个时钟沿**既要被 MEM/WB 锁存、又要穿过
    // wb_data mux 去前递/写回 —— 两跳合一跳。
    // 寄存后: MEM/WB 锁存提取结果, wb_data 从前递寄存器出发 -> 砍掉一段长走线。
    // **不新增任何寄存器** (用的就是这个本来就存在的 MEM/WB 寄存器)。
    // 实测 load-use 停顿与 ticks 均**不变** —— 因为 dmem 的寄存读已经提供了
    // 那一拍, MEM/WB 只是把同一个值再接一次, 没有额外延迟。
    .load_data_in (mem_load_data),
`else
    // 【寄存读版】load_data 不再经 MEM/WB 打第二拍: 它在 WB 拍由 LSU 组合给出
    // (dmem 的输出寄存器就是"第一拍"), 写回 mux 直接用它。这里恒 0 让它被优化掉。
    .load_data_in (32'h0),
`endif
    .pc_plus4_in  (ex_mem_pc_plus4),
    .rd_addr_in   (ex_mem_rd),
    .ctrl         (mem_wb_ctrl),
    .alu_out      (mem_wb_alu_out),
    .load_data    (mem_wb_load_data),
    .pc_plus4     (mem_wb_pc_plus4),
    .rd_addr      (mem_wb_rd)
  );

  always_comb begin
    case (mem_wb_ctrl.wb_src)
`ifdef LOAD_RESULT_REG
      // 【P3 实验C】从前递寄存器取, 而不是从"刚组合读出的数据"取 —— 这是砍掉
      // 关键路径的关键一步 (见 u_mem_wb 处注释)。
      WB_MEM:  wb_data = mem_wb_load_data;
`else
      // 直接用 LSU 的 WB 拍组合输出 (dmem 寄存读的数据此刻正好有效)
      WB_MEM:  wb_data = mem_load_data;
`endif
      WB_PC4:  wb_data = mem_wb_pc_plus4;
      default: wb_data = mem_wb_alu_out;      // WB_ALU
    endcase
  end

  assign wb_reg_write = mem_wb_ctrl.reg_write && (mem_wb_rd != 5'd0);
  assign wb_rd        = mem_wb_rd;

  // ==========================================================================
  // 调试与仿真专用
  // ==========================================================================
  // dbg_pc 必须与 dbg_instr 取自 *同一级*: if_pc 是 IF/ID 中那条指令的地址,
  // if_instr 就是那条指令本身。原先这里接的是 IF 段正在取的 pc, 与 if_instr
  // 永远差一拍 —— 超时/非法指令的失败诊断会指向错误的指令。
  // 【为什么两个 PC 都要引出】
  //   dbg_pc    = IF 段正在取的地址 —— 回答"现在跑到哪了", 超时诊断用它;
  //   dbg_id_pc = IF/ID 中那条指令的地址, 与 dbg_instr 严格配对 —— 回答
  //               "出问题的是哪条指令"。
  // 只引出一个都有坑: 单用 pc 则与 if_instr 差一拍 (指错指令); 单用 if_pc
  // 则 if_id_reg 在 flush 那一拍会把它清成 0, 诊断信息会变成 PC=0 (实测踩过)。
  assign dbg_pc    = pc;
  assign dbg_id_pc = if_pc;
  assign dbg_instr = if_instr;

  // 存储器写观测: wstrb 全零的"空写"不算 (LSU 在非写周期也拉高 dmem_we)
  assign dbg_mem_we    = dmem_we && (dmem_wstrb != 4'b0000);
  assign dbg_mem_addr  = dmem_addr;
  assign dbg_mem_wdata = dmem_wdata;

  // 非法指令粘滞标志 (调试用: 表示"发生了一次**没被处理**的非法指令")。
  // 两个必须排除的情况, 都会造成假失败:
  //   1) redirect=1 的这一拍, ID 段里装的是分支/跳转的 *错误路径* 后继指令, 它马上
  //      就会被冲掉; 若它恰好译码非法, 标志会被误置 1。
  //   2) trap_enter=1 的这一拍, 非法指令正在被陷阱机制**正常接管** —— 它不再是
  //      "错误", 而是 trap.S 专门要测的行为。此时若仍置位, tb_core 会立刻 $fatal,
  //      测试程序根本没机会跑它的 handler。
  // 【必须用 id_ex_ctrl.illegal (EX 段), 不能用 id_ctrl.illegal (ID 段)】
  //   陷阱是在 EX 段裁决的, trap_enter 由 id_ex_ctrl.illegal 驱动。ID 段的 illegal
  //   比它早整整一拍 —— 用 ID 段会在"非法指令还在 ID、trap 尚未触发"那一拍就置位,
  //   与 trap_enter 对不上, 于是假失败依旧发生 (实测: cyc50 id_illegal=1 而
  //   exc_req=0; cyc51 才 ex_illegal=1/trap_enter=1)。
  // 反方向不会漏报: 真正无法处理的非法指令 (trap 未接线) 不会进 trap_enter, 标志照常置位。
  always_ff @(posedge clk or posedge rst) begin
    if (rst)                                                               dbg_illegal <= 1'b0;
    else if (id_ex_ctrl.illegal && !pipe_stall && !redirect && !trap_enter) dbg_illegal <= 1'b1;
  end

  // 跳转目标必须 4 字节对齐。陷阱接管后这条断言覆盖 redirect 与 trap_redir 两条路径:
  // trap_vector 在 csr_file 里已按 {mtvec[31:2],2'b00} 对齐, mepc 写入时同样对齐,
  // 所以两者本来就恒定对齐 —— 保留断言等于免费多一道保险。
  `ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && any_redir && (pc_target[1:0] != 2'b00)) begin
      $error("instruction address misaligned: target=%h", pc_target);
    end
  end
  `endif

  // ==========================================================================
  // 流水线效率观测 (纯观测, 不参与逻辑; 未连接时会被综合优化掉)
  // 必须放在所有信号声明之后
  // ==========================================================================
  assign dbg_stall    = pipe_stall;
  assign dbg_redirect = redirect;

endmodule
