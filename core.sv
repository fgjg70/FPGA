`timescale 1ns/1ps

// ============================================================================
// core.sv — RV32I **五级**流水线处理器 (IF / ID / EX / MEM / WB)
// ----------------------------------------------------------------------------
// 【流水线级数的口径 —— 最容易差一的地方, 请先看这段】
//   本核**始终是 5 级**: IF / ID / EX / MEM / WB。
//   2026-10-08 只是去掉了一个**冗余寄存器**, 级数并没有变成 4 级。判据:
//
//     教科书 5 级在 pc 之后只有 **4 个**流水寄存器:
//         IF/ID, ID/EX, EX/MEM, MEM/WB              => 4 个寄存器 ⇒ **5 级**
//     (IF 级的工作发生在 IF/ID **之前**, 所以 级数 = 寄存器数 + 1。)
//
//     本核此前因为 imem 是 BRAM(同步读本身要占一拍), pc 之后有 **5 个**:
//         IMEM 输出寄存器 + if_id_reg + ID/EX + EX/MEM + MEM/WB  => 实际 **6 级**
//     其中 if_id_reg 前面**没有任何组合逻辑**, 只把 imem_rdata / pc 原样再打
//     一拍, 是纯搬运 —— 它给**每次重定向白加了一个气泡**。
//
//     现在去掉 if_id_reg, 让 IMEM 的输出寄存器**承担 IF/ID** 的角色:
//         IMEM 输出寄存器(=IF/ID) + ID/EX + EX/MEM + MEM/WB      => 4 个 ⇒ **5 级**
//     五个功能级(取指 / 译码 / 执行 / 访存 / 写回)一个不少。
//
//   收益的准确表述: **不是"少一级流水"**(少一级本身并不提高吞吐), 而是
//   **去掉一个纯搬运寄存器 ⇒ 每次重定向少穿一个气泡**(误判恢复快 1 拍)。
//   实测: 重定向 11535 次 ⇒ ticks 423527 → 413070 (−2.47%)。
//   完整记录(含实施中踩的两个坑)见 results/p8-ifid-elide.md §1/§4。
//
// 流水线结构:
//   IF  : PC -> imem (默认寄存读/BRAM; 其输出寄存器即 IF/ID)      => IF/ID
//   ID  : control_unit 译码, imm_gen, regfile 读 (组合读)          => ID/EX
//   EX  : 前递 mux -> ALU + branch_unit 判定; 控制流目标走专用加法器 => EX/MEM
//   MEM : load_store_unit (字节通道 + 非对齐拆分) + dmem            => MEM/WB
//   WB  : 写回 mux -> regfile
//
// 关键设计点 (详见各模块头注释与 rv32_pkg 顶部契约):
//   - 控制流目标用**专用 32 位加法器** (ex_ctrl_sum), **不兼职 ALU** —— 为把
//     ALU 的两级操作数 mux 移出关键路径而改; 代价约 32 LUT (results/p3-fmax.md 实验 A)
//   - 分支/跳转在 EX 判定, **带 BTB 分支预测**: 预测正确时绝不冲刷; 预测错误时
//     冲刷 **ID/EX 一级** (ID 中那条错误路径指令因 ID/EX 被 flush 而不会锁存),
//     **误判惩罚 1 拍**
//   - load-use 停顿 1 拍; 非对齐跨字访存在 MEM 占 2 拍 (冻结 1 拍)
//   - 寄存器堆组合读 + 写旁路 (write-first): 覆盖"距离 3"的 RAW 依赖
//     (WB 写与 ID 读同拍); 距离 1/2 由 hazard_unit 前递, load-use 停顿 1 拍
//   - 非法指令: 控制束已中性化为无副作用, 此处仅置粘滞调试标志
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
  // 【E2 扇出约束】实测关键路径上 `actual_taken` 的**扇出是 60**, 单是一跳布线
  // 就 0.947ns(占全路径 5.8%); 另有 `pc_src`/`redirect` 广播扇出 34, 一跳 1.055ns。
  // 两者合计约 2.0ns = 12% 的关键路径。给它们上限后, 综合器会自动**就近复制**
  // 驱动单元, 让关键负载走短线。纯约束, 不改功能。
  // (取 16: 再小会明显增面积, 再大不起作用; 这是 Vivado 常用的时序驱动档位。)
  (* max_fanout = 16 *) logic  pc_src;
  (* max_fanout = 16 *) logic  redirect, redirect_raw;
  logic        lsu_stall;
  // RV32A: LSU 的写相标志与读回的旧值 (供 MEM 段的 AMO 新值计算用)
  logic        amo_write_phase;
  logic [31:0] amo_old;
  // RV32A: LR/SC 算子标志 (LR/SC **都不写内存**; SC 恒失败 -> rd=1)。
  // 必须由下面 A_EN 段里**自己锁存**的 amo_op_r 译出, 不能用 ex_mem_ctrl.amo_op
  // (那份会被 hold_mem 挡住 —— 本项目在这一点上踩过坑)。
  logic        amo_is_lr, amo_is_sc;
  logic        id_ex_bubble;

  // 分支预测
  logic        pred_hit, pred_taken, btb_upd_en, is_ctrl_flow;
  logic [31:0] pred_target, actual_target;
  logic        pred_is_ret;          // 预测命中的 PC 是"函数返回" (RAS 用)
  logic        ex_is_call, ex_is_ret;// EX 解析出的 call / return (RAS 控制)
  logic        ex_is_cond;           // EX 段该指令是条件分支 (gshare 历史用)
  // 【E2 扇出约束】见上方 pc_src/redirect 处的说明。
  (* max_fanout = 16 *) logic  actual_taken, pred_ok;
  wire  [31:0] btb_pred_target;

  // IF/ID
  logic [31:0] if_pc, if_pc_plus4, if_instr;
  logic        if_pred_taken;
  logic [31:0] if_pred_target;

  // ID
  ctrl_s       id_ctrl;
  // 【issue #5】译码器的**原始**输出, 经 id_en 门控后才成为 id_ctrl。
  // 分开取名是为了让"门控挂在译码输出上"这件事在代码里显式可见 ——
  // 门控绝不能做成 32 位指令 mux (那会插进关键路径), 见 ID 段注释。
  ctrl_s       id_ctrl_raw;
  logic        id_en;       // ID 门控使能: 恒等于 boot_done (见 ID 段注释)
  logic [31:0] id_imm, id_rs1_data, id_rs2_data;
  logic [4:0]  id_rs1, id_rs2, id_rd;

  // ID/EX
  ctrl_s       id_ex_ctrl;
  logic        id_ex_valid;      // EX 段这条指令是否真实有效 (气泡/flush = 0)
  logic [31:0] id_ex_instr;      // EX 段这条指令的原始编码 (只给 mtval 用, 见 R-02)
  logic [31:0] id_ex_pc, id_ex_pc_plus4, id_ex_rs1_data, id_ex_rs2_data, id_ex_imm;
  logic [4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;
  logic        id_ex_pred_taken;
  logic [31:0] id_ex_pred_target;

  // EX
  // 【C-10】前递选择: ID 段预选 (fwd_a_pre/fwd_b_pre) -> 随 ID/EX 打一拍
  // (id_ex_fwd_a/id_ex_fwd_b) -> EX 段前递 mux。`id_ex_fwd_*` 表示
  // "当前在 EX 的这条指令该选哪一路" (与 id_ex_* 同生命周期)。
  fwd_sel_e    fwd_a_pre, fwd_b_pre, id_ex_fwd_a, id_ex_fwd_b;
  logic [31:0] ex_rs1, ex_rs2, ex_a, ex_b, ex_alu_out, ex_pc_target;
  logic [31:0] ex_amo_addr;      // RV32A: AMO 的访存地址 (rs1 + imm), 与算子解耦
  // RV32M
  logic [31:0] ex_result, md_result;
  logic        md_busy, is_muldiv;
  logic        ex_taken;

  // ---- Zicsr / 陷阱 (M-mode) ----
  logic [31:0] csr_rdata, csr_wdata, csr_src;
  logic        csr_we, is_csr;
  logic        exc_req, irq_take, trap_req, trap_enter, trap_redir;
  // 【X1 扇出约束 —— 按 fo 选目标, 不按信号名 (PITFALLS R36/R37)】
  // 2026-10-08 实测 (fpga/timing_paths.rpt, 基线 WNS 5.624 / fmax 69.6):
  //   **top-50 最差路径全部经过 any_redir**, 而它是关键路径上扇出最大的网:
  //     fo=122, 单这一跳布线 0.704~0.975ns。
  //   它同时喂两类负载: (a) 取指地址 mux -> u_imem/ADDRARDADDR (路径族 A),
  //                     (b) ID/EX 的 flush mux -> rs1/rs2_data_reg 的 D/CE (族 B)。
  //   旁证: 同一份报告里 pc_src / redirect / redirect_raw / actual_taken 已有
  //   max_fanout=16, 它们都不再出现在前 25 名的 fo 榜上 —— 只有 any_redir 漏了。
  // 纯约束, 不改功能 (组合网 -> 综合器复制的是驱动 LUT, 不是触发器)。
  (* max_fanout = 16 *) logic  any_redir;
  logic [4:0]  trap_cause, irq_cause;
  logic [3:0]  exc_cause;
  logic [31:0] trap_vector, mret_pc, trap_tval;
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
  // 【C-11】分支误判 redirect **寄存一拍** (切环): br_redir = 本拍检出;
  // br_redir_r = 上一拍检出 (这一拍才装 PC 与取指地址); br_redir_r2 = 再下一拍
  // (只用于"错路指令永不提交"的断言窗口)。trap/mret 仍走**组合**通路。
  logic        br_redir, br_redir_eff, br_redir_r, br_redir_r2;
  logic        redir_flush, pc_flush;
  logic [31:0] br_tgt_r, pc_flush_pc;

  // ==========================================================================
  // IF 段
  // ==========================================================================
  // --------------------------------------------------------------------------
  // 复位后冻结取指一拍 (寄存读 = 默认; 组合读回退时不需要)
  // --------------------------------------------------------------------------
  // 寄存读下 IMEM 要一拍才吐出数据, 而 pc 复位后**立即**前进 —— 于是
  // `pc_reset` 处的第一条指令从来没有任何一拍被送进 IMEM, 整条被跳过。
  // 这里在复位后先把 pc 冻一拍, 让 IMEM 有机会锁存 mem[PC_RESET]:
  //   cycle 0: imem_addr = pc = PC_RESET -> IMEM 锁存第一条指令; pc 冻结
  //   cycle 1: imem_rdata = 第一条指令, 且 pc 仍 = PC_RESET -> 配对正确 ✓
  // 组合读不需要它 (当拍递地址当拍出数据, 第一条指令本来就能取到)。
  logic fetch_hold;
  // 【boot_done 必须在 ifdef 之外声明】ID 段的 id_en 门控无条件引用它
  // (core.sv 的 `assign id_en = boot_done;`)。2026-10-08 审阅抓到过一次真 bug:
  // 当时它只在 `else`(寄存读) 分支里声明, 一旦定义 IMEM_COMB_READ 就变成
  // **未声明标识符 -> 隐式 1 位 net -> id_en 恒 0 -> 全核每拍译码成 NOP**。
  // 组合读下它恒为 1 (当拍递地址当拍出数据, 不需要 boot 冻结, 见上)。
  logic boot_done;
`ifdef IMEM_COMB_READ
  assign fetch_hold = pipe_stall;
  assign boot_done  = 1'b1;
`else
  always_ff @(posedge clk or posedge rst) begin
    if (rst) boot_done <= 1'b0;
    else     boot_done <= 1'b1;
  end
  assign fetch_hold = pipe_stall || !boot_done;
`endif

  pc #(.XLEN(XLEN), .RESET_PC(PC_RESET)) u_pc (
    .clk       (clk),
    .rst       (rst),
    .stall     (fetch_hold),
    // 【C-2 + C-11】重定向 (trap/mret/分支误判纠正) 必须能**越过停顿**装 PC。
    //   · trap/mret: 检出当拍就装 (组合, 与历史语义一致);
    //   · 分支误判: C-11 把它寄存一拍 -> 下一拍才装 (见下面 pc_flush 的说明)。
    //   pc.sv 的优先级本来就是 flush > stall > pc_src, 所以接 flush 口。
    .flush     (pc_flush),
    .flush_pc  (pc_flush_pc),
    .pc_src    (pc_src),
    .pc_target (pc_target),
    .pc        (pc),
    .pc_plus4  (pc_plus4)
  );

  logic [31:0] imem_addr;         // 送给 imem 的取指地址
  // --------------------------------------------------------------------------
  // 寄存读的配对口径: **取指地址 = 下一拍的 pc** (组合推出)
  // --------------------------------------------------------------------------
  // 【这是整件事的关键, 前五轮都没看到它】
  //
  // 组合读: imem_rdata(N) = mem[addr(N)], addr 直接接 pc -> mem[pc(N)]。
  //   于是 IF/ID 用**当前** pc / pc_plus4 / pred_taken 就是对的。
  //
  // 寄存读: imem_rdata(N) = mem[addr(N-1)] (沿锁存, 晚一拍)。要让配对口径
  //   与组合读**完全一致**, 只需让 addr = pc_next:
  //
  //     不变式:  imem_rdata(N) = mem[pc_next(N-1)]
  //       未停顿:  pc_next(N-1) = pc(N)                    -> mem[pc(N)]  ✓
  //       停顿中:  pc_next(N-1) = pc(N-1) = pc(N) (冻结)   -> mem[pc(N)]  ✓
  //
  //   两种情况下都得到 imem_rdata(N) == mem[pc(N)] —— 与组合读逐位同口径!
  //   所以 **IF/ID 的接线一行都不用改**, 也不需要 pc_d1 之类的延迟副本。
  //
  // 【为什么这样重定向代价还是 2 拍】目标是 EX 在 cycle N 组合算出的,
  //   当拍就送进 IMEM -> N+1 数据出来 -> IF/ID 在 N+1 拿到 (pc(N+1)=T, mem(T))
  //   -> ID/EX 在 N+2 拿到。与组合读完全相同, **相位不平移**。
  //
  // 【为什么此前五次尝试全败】前四次在"延迟副本 + 补偿 mux"上打转;
  //   第五次(统一 FAR)把 addr 接成 pc_d1(寄存过的 pc_next), 又多错了一拍。
  //   真正的答案是 addr 直接接**组合的** pc_next —— 一次寄存器都不加。
  //
  // 【实测踩过的坑】曾把 addr 接成 `pc_src ? pc_target : pc_plus4` 却仍配
  //   pc_d1, 于是从第一条指令起就错开。那个写法本身没错, **错在配错了对象**:
  //   addr=pc_next 必须配当前 pc, 不是配 pc 的延迟副本。
  // --------------------------------------------------------------------------
  // --------------------------------------------------------------------------
  // 【C-11】取指地址 = 下一拍的 pc; 三类"改地址"事件的**相位**各不相同
  // --------------------------------------------------------------------------
  //   trap / mret      : 检出当拍生效 (pc_flush 的组合项) —— 语义与历史一致;
  //   分支误判纠正     : **寄存一拍**后生效 (pc_flush 的 br_redir_r 项) ——
  //                      这一项把 "分支比较 -> ex_taken -> redirect_raw ->
  //                      redirect -> any_redir -> pc mux -> imem 地址脚" 这条
  //                      组合环从中间切开 (C-10 之后它是 top-1, route 75.6%);
  //   顺序取指         : pc_plus4 或 BTB 预测目标 (pred_taken/pred_target)。
  // 检出那一拍 (br_redir=1) **不装 PC**: 让它照预测通路走一拍 (取回的错路指令
  // 由 redir_flush 冲掉), 下一拍 (br_redir_r=1) 才把 br_tgt_r 装进 PC/取指地址。
  // 配对不变式 imem_rdata(N) == mem[pc(N)] 仍然成立:
  //   N+1 拍 pc 取 pc_next(N)=错路值, 而 addr(N)=pc_next(N) ⇒ rdata(N+1) 与之配对
  //   (这条指令在 N+1 被 id_ex flush 冲掉); N+1 拍 addr=br_tgt_r 且 N+1 沿 pc 也
  //   装 br_tgt_r ⇒ N+2 拍 pc=T、rdata=T ✓ 配对恢复。
  // --------------------------------------------------------------------------
  wire [31:0] pc_next = pc_flush ? pc_flush_pc
                      : fetch_hold ? pc
                      : (pc_src ? pc_target : pc_plus4);
`ifdef IMEM_COMB_READ
  // 回退(组合读): 当拍递地址当拍出数据, 接当前 pc 才与 rdata 同拍
  assign imem_addr = pc;
`else
  // 默认(寄存读/BRAM): 这一拍把"下一拍要取的地址"递给 imem, 下一拍数据正好到
  assign imem_addr = pc_next;
`endif

  imem #(.BASE(IMEM_BASE), .BYTES(IMEM_BYTES)) u_imem (
    .clk   (clk),
    .addr  (imem_addr),
    .rdata (imem_rdata)
  );

  assign if_id_flush = any_redir;

  // --------------------------------------------------------------------------
  // 【历史记录】停顿释放气泡方案 —— 已被"取指地址 = pc_next"取代, 不再需要
  // --------------------------------------------------------------------------
  // 保留这段是因为它是这条 bug 最完整的现场记录, 并明确否掉了一条错路:
  //   "靠 pipe_stall 组合导出的释放脉冲去给 IF/ID 注气泡"。
  // 现象: 早期把 addr 接当前 pc、IF/ID 配延迟副本时, 停顿期间 IF/ID 反复重写
  //   同一条指令, 释放那拍 ID/EX 取走它的副本 -> 同一条执行两次、后一条被跳过
  //   (basic.S 测试 2, tohost=3)。
  // 为什么补不上: 需要拦住 IF/ID 的那一拍, pipe_stall 还是 1, 所以任何由
  //   pipe_stall 组合导出的释放信号都**天然晚一拍**; 而且无条件注入会把
  //   组合读路径也弄坏。
  // 正解: 根本不需要气泡 —— 把 addr 接 pc_next 后配对口径与组合读一致, 该问题
  //   不存在。见上面 pc_next 的注释。
  // --------------------------------------------------------------------------

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
    .upd_is_cond (ex_is_cond),
    .pred_is_ret (pred_is_ret)
  );

  // 条件分支 (pc_sel==PC_BR) —— gshare 的全局历史只记这类, 不记 JAL/JALR
  assign ex_is_cond = (id_ex_ctrl.pc_sel == PC_BR);

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

  // 控制流指令解析完成且结果有效时才更新。
  // 【C-2 口径修正】门控从 !pipe_stall 改为 !hold_mem (= !(lsu_stall||ex_busy)):
  //   硬冻结时 EX 里的指令会被重算, 副作用必须等它算完那一拍; 而 load_use_mem
  //   那一拍 EX 里是**另一条真指令**(可能是分支/JAL/JALR), 它照常提交, 它的
  //   预测更新必须照做 —— 用并集 pipe_stall 门控会静默丢掉这次更新。
  assign is_ctrl_flow = (id_ex_ctrl.pc_sel != PC_NEXT);
  assign btb_upd_en   = is_ctrl_flow && !hold_mem && !rst;

  // --------------------------------------------------------------------------
  // 【历史记录】寄存读 IMEM 的五轮失败史与最终解法
  // --------------------------------------------------------------------------
  // 收益很大 (LUT −1228 = 全核 31%)。前四轮都在"pc 的延迟副本 + 补偿 mux"上
  // 打转, 第五轮(统一 FAR)更差; 真正的解法是上面 IF 段的 **pc_next**:
  //
  //   组合读: cycle N 内 addr=pc(N) 且 rdata=instr(pc(N)), 同拍
  //   寄存读: rdata 晚一拍 -> 令 addr = **组合推出的下一拍 pc**(pc_next),
  //           则 imem_rdata(N) == mem[pc(N)], 与组合读**逐位同口径**
  //
  // 于是 IF/ID 一行都不用改, 重定向代价仍是 2 拍, 唯一配套是复位后冻结取指一拍。
  // 实测: LUT 4079 -> 2820 (−30.9%), CoreMark ticks 逐位不变, 已上板验证。
  // 完整五轮失败史(含三条已证伪的错路)见 results/p4-macro-failure.md 5.1 节。
  // --------------------------------------------------------------------------

  // ==========================================================================
  // 【issue #5 已实施】去掉冗余的 if_id_reg: IF/ID 落在 IMEM 的输出寄存器上
  // ==========================================================================
  // 【口径 —— 最容易差一的地方】本核**始终是 5 级流水线** (IF/ID/EX/MEM/WB)。
  //   教科书 5 级在 pc 之后只有 **4 个**寄存器 (IF/ID, ID/EX, EX/MEM, MEM/WB)
  //   —— **4 个寄存器 ⇒ 5 级**, 因为 IF 级的工作发生在 IF/ID 之前。
  //   改动前: imem 是 BRAM(同步读), 于是多插了一个 if_id_reg, 加上 ID/EX、
  //   EX/MEM、MEM/WB 共 **5 个**寄存器 ⇒ 实际是 **6 级**。
  //   这次去掉它, 才**真正**回到 5 级 (与 imem 组合读时的结构一致)。
  // 【收益的准确表述】不是"少一级流水"(少一级本身不提高吞吐), 而是:
  //   **去掉一个纯搬运寄存器 ⇒ 每次重定向少穿一个气泡** (误判恢复快 1 拍)。
  //   if_id_reg 前面**没有任何组合逻辑**, 只把 imem_rdata/pc 原样再打一拍。
  // ==========================================================================
  // 原来 IF 段有**两个寄存器装同一条指令**: imem 的输出寄存器 + if_id_reg。
  // 实测不变量 (见 imem.sv:11-14 与上面 pc_next 注释):
  //      imem_rdata(N) == mem[pc(N)]
  // 且 **BTB 用当前 pc 查询** (u_btb 的 .pred_pc(pc)) —— 所以第 N 拍的
  //      指令 (imem_rdata) / PC (pc) / 预测 (pred_taken,pred_target)
  // 三者**天然对应同一条指令**。if_id_reg 只是把同一份信息再打一拍,
  // 白多一级流水 —— 去掉它后 pc 之后只剩 4 个寄存器, 仍是 5 级 (教科书口径):
  //      [IF] pc -> IMEM -> IMEM 输出寄存器(=IF/ID) -> [ID] ID/EX -> [EX] EX/MEM -> [MEM] MEM/WB -> [WB]
  //
  // 【收益】误判恢复少穿一级: 重定向发生在 cycle T 时, 正确路径指令进 EX
  //   由 T+4 提前到 T+3, 每次误判省 1 拍。**实测**: 11535 次重定向 -> ticks
  //   423527 → 413070 (**−10457 = −2.47%**; 事前按 11501 次估的是 −2.72%, 略偏乐观)。
  // 【代价】id_ctrl 上一级 AND 门控 (见下), 净省 111 位 FF。赛题要求 >=3 级, 5 级合格。
  //
  // 【为什么用"组合别名"而不是把这些名字删掉】if_pc / if_instr 被
  //   tb_core 的逐拍 trace 与 tb_sw 的"取指对齐自检"**直接引用**;
  //   保留这几个名字当别名 => 两个 testbench 一行都不用改, 而且自检的
  //   不变量 (imem_rdata == mem[pc]) 完全不变、继续有效。
  assign if_pc          = pc;
  assign if_pc_plus4    = pc_plus4;
  assign if_instr       = imem_rdata;
  assign if_pred_taken  = pred_taken;
  assign if_pred_target = pred_target;

  // 【ID 门控只用 boot_done —— 绝不能用 if_id_flush】两条独立的实测理由:
  //   ① 组合环 (Vivado 综合报 [DRC LUTLP-1], 17 个 LUT):
  //        if_id_flush → id_valid → id_rs* → load_use → pipe_stall
  //          → redirect → any_redir → if_id_flush
  //      原设计没有它, 因为 if_id_rs* 来自 if_id_reg 的**输出寄存器**;
  //      去掉 IF/ID 后这条反馈路径暴露出来。
  //   ② 关键路径: if_id_flush 是全核最晚、扇出最大的信号之一 (实测 fo=125)。
  //      一旦让它串进 `id_ctrl -> imm_gen -> ID/EX` 的 D 端, fmax 立刻
  //      69.2 → 67.5 MHz (实测)。
  //   **冲刷期不需要在这里门控**: id_ex_reg 的 flush 接的就是 any_redir ——
  //   同一拍就把 ID/EX 清成气泡了, D 端是什么值都无所谓。
  //   **启动期 (boot_done=0) 必须门控**: 原来靠 if_id_reg 的 stall(fetch_hold)
  //   把 IF/ID 冻在复位值 (NOP), 去掉 IF/ID 后只能在这里补 ——
  //   否则第一条指令会在 boot 期间就流进 EX。
  assign id_en = boot_done;

  // ==========================================================================
  // ID 段
  // ==========================================================================
  // 【门控必须挂在译码输出上, 不能把 32 位 mux 插进指令路径】(issue #5 §4.3)
  //   ❌ 错误: id_instr = id_en ? imem_rdata : INSTR_NOP;  -> 32 位 mux 进关键路径
  //   ✅ 正确: 指令直连 imem_rdata, 只门控"译码结果"与三个寄存器号 ——
  //            id_ctrl 本来就是"译码 -> ID/EX"这条路径的终点, 加一级 AND 不影响。
  // 为什么必须有门控: 去掉 if_id_reg 后 imem 的输出寄存器**无条件每拍更新**,
  //   冲刷期它仍是一条真实指令。若不门控, id_rs1/id_rs2 会在冲刷期携带真实
  //   寄存器号 -> hazard_unit 可能误判 load-use -> 平白拉停 pipe_stall ->
  //   而 redirect 被 !pipe_stall 门控 -> **重定向被推迟一拍** (历史同类 bug:
  //   random "配错对象", 见 core.sv 早期停顿气泡的记录)。
  // 【⚠ 这三个寄存器号**绝不能**用 id_valid 门控 —— 会形成组合环!】
  //   实测 (Vivado 综合): [DRC LUTLP-1] Combinatorial Loop Alert, 17 个 LUT:
  //     if_id_flush → id_valid → id_rs* → hazard_unit.load_use
  //       → pipe_stall → redirect → any_redir → if_id_flush
  //   原设计没有这个环, 因为 `if_id_rs*` 来自 if_id_reg 的**输出寄存器**;
  //   改成组合别名 (去掉 if_id_reg) 后, 这条反馈路径就暴露出来了。
  //   所以这里直接用指令字段, **不加门控** —— 语义与原来"IF/ID 输出"一致:
  //   唯一差别是"冲刷期 IF/ID 原本是气泡 (rs=0)"。但重定向只可能由 EX 里的
  //   控制流指令产生 (pred_ok 只对 pc_sel!=PC_NEXT 才有意义), 而
  //   branch/jal/jalr 的 mem_read=0 ⇒ load_use 恒为 0 ⇒ 无影响。
  //   三个号的消费者 (regfile 读口 / ID-EX 入口) 在冲刷那拍都被 ID/EX 的
  //   flush 拦住, 真值流不进 EX。
  assign id_rs1 = if_instr[19:15];
  assign id_rs2 = if_instr[24:20];
  assign id_rd  = if_instr[11:7];

  control_unit u_ctrl (
    .instr (if_instr),
    .ctrl  (id_ctrl_raw)
  );

  always_comb begin
    id_ctrl = id_en ? id_ctrl_raw : ctrl_s'(0);
  end

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
    .valid_in    (id_en),
    .instr_in    (if_instr),
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
    .valid       (id_ex_valid),
    .instr       (id_ex_instr),
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

  // ---- WB→EX 前递源 (C-2: load 数据刻意不在这条路上) ----
  //   WB_MEM 且 mem_read (load) -> mem_wb_load_data —— MEM/WB 的**寄存器输出**
  //        ↑ C-2 之后这一支**不可达** (见 hazard_unit 的 load_use_mem 证明):
  //          "WB 段是 load 且命中前递"要求上一拍 ID 里有依赖它的指令, 而那一拍
  //          ex_mem 正是这条 load ⇒ load_use_mem 会把消费者扣在 ID。
  //          保留一个寄存器出口的意义在于: **它不再是 dmem 的组合输出** ——
  //          于是 top-1 关键路径 (dmem RAMB36 CLK→DO → LSU 字节提取 → 前递 mux
  //          → 分支判定 → 重定向 → 取指地址脚, 实测 12.466ns/route 67.8%)
  //          从时序图里整段消失, 这正是 C-2 提频的机理。
  //   WB_MEM 且 !mem_read (AMO/LR/SC, 仅 A_EN) -> amo_wb_value (见下, 也是寄存器)
  //   其余 (WB_PC4 / WB_ALU) -> mem_wb_pc_plus4 / mem_wb_alu_out (都是寄存器)
  // 【为什么 AMO 这一支必须自己拼, 不能用 wb_data】
  //   wb_data 的 WB_MEM 支路是 load_store_unit 的**组合输出** (rdata_eff mux,
  //   它把 dmem_rdata 当输入之一) —— 只要 wb_data 还挂在前递 mux 上, dmem 的
  //   RAMB36 输出就仍然**结构上**能走到取指地址脚, 综合器没有"mem_read 与 wb_src
  //   的组合约束"这条知识, 不会替你剪掉。所以这里用与 LSU 的 rdata_eff **逐位
  //   等价**的寄存器版本:
  //       AMO 那一拍 amo_mode_r=1 ⇒ rdata_eff = amo_sc ? 1 : amo_old
  //   (amo_old 是 LSU 里锁存旧值的寄存器; amo_is_sc 由 core 锁存的 amo_op_r 译出;
  //    AMO 的 off_wb/size_wb 恒为 0/WORD ⇒ 后面的字节提取是恒等操作。)
  //   默认宏 (A_EN 关) 下该支路不可达 → amo_old 恒 0、综合成常量, 前递 mux 上
  //   一个 dmem 负载都没有。
`ifdef A_EN
  wire [31:0] amo_wb_value = amo_is_sc ? 32'd1 : amo_old;
`else
  wire [31:0] amo_wb_value = 32'd0;
`endif
  wire [31:0] fwd_wb_data =
        (mem_wb_ctrl.wb_src != WB_MEM) ? ((mem_wb_ctrl.wb_src == WB_PC4) ? mem_wb_pc_plus4
                                                                        : mem_wb_alu_out)
      : mem_wb_ctrl.mem_read           ? mem_wb_load_data
      :                                  amo_wb_value;

  always_comb begin
    // 前递 mux (C-10: 选择来自寄存器 id_ex_fwd_*, 不在本拍现算比较)
    ex_rs1 = (id_ex_fwd_a == FWD_EX_MEM) ? ex_mem_fwd_data :
             (id_ex_fwd_a == FWD_MEM_WB) ? fwd_wb_data : id_ex_rs1_data;
    ex_rs2 = (id_ex_fwd_b == FWD_EX_MEM) ? ex_mem_fwd_data :
             (id_ex_fwd_b == FWD_MEM_WB) ? fwd_wb_data : id_ex_rs2_data;
    // ALU 操作数 mux (契约见 rv32_pkg 顶部)
    ex_a = (id_ex_ctrl.alu_a_src == ALU_A_PC)   ? id_ex_pc :
           (id_ex_ctrl.alu_a_src == ALU_A_ZERO) ? 32'd0 : ex_rs1;
    ex_b = (id_ex_ctrl.alu_b_src == ALU_B_IMM)  ? id_ex_imm : ex_rs2;
    // ---- RV32A: AMO 的**访存地址**必须单独算 ----
    // 【为什么不能用 ex_alu_out】AMO 的 alu_op 是 ALU_AMO_* —— 那是用来算
    // "应写回内存的新值"(old op rs2) 的,**不是地址**。而 ex_result 在
    // `is_muldiv/is_csr` 之外直接取 ex_alu_out, 于是 LSU 拿到的"地址"
    // 其实是 AMO 的算子结果 (old + imm)。
    // 实测症状: 地址恒差一个 +4 (当时 imm=4 被当成加法项)。
    //
    // 正确语义: AMO 是 I 型, 访存地址 = rs1 + imm[11:0] (AMO 的 imm 恒为 0,
    // 所以结果就等于 rs1)。这里用一个**独立加法器**算地址, 与算子计算解耦 ——
    // 这正是本项目对跳转目标做过的事 (P3 的"独立加法器"), 有先例可循。
    // ---- RV32A: AMO 的访存地址 (rs1 + 0) ----
    // 【偏移必须写死为 0, 不能用 id_ex_imm】诊断打印 [ex-amo] 给出实测:
    //     rs1=90003000 imm=00000006 addr=90003006
    // 而 amoadd.w t2,t1,(t0) 的编码是 0x0062A3AF, 其 imm[11:0] **恒为 0**。
    // imm_gen 的 I 型提取用的是 instr[31:20], 而 AMO 的 instr[31:27] 是 funct5、
    // [24:20] 是 rs2 —— 于是它**把 rs2 当成了立即数**(本例 rs2=t1 的编号 6),
    // 这个 6 就污染了地址 (历史上的 +4 也是同一个成因, 只是当时 rs2 恰好是 4)。
    // 按规范 AMO 没有立即数字段, 所以这里**直接加 0**, 从根上避开 imm_gen。
    ex_amo_addr = ex_rs1;
  end

  alu #(.XLEN(XLEN)) u_alu (
    .a       (ex_a),
    .b       (ex_b),
    .op      (id_ex_ctrl.alu_op),
    .out     (ex_alu_out)
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
                   : id_ex_ctrl.amo_en ? ex_amo_addr   // AMO: 地址 = rs1+imm
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
  //
  // 【E1 关键路径优化, 逻辑等价】比较对象从 mux 后的 actual_target 改成
  // **直接比 ex_pc_target**:
  //   第二项本来就被 `!actual_taken ||` 门控 —— 即只在 actual_taken=1 时才有意义,
  //   而 actual_taken=1 时 `actual_target ≡ ex_pc_target` (上面那行 mux 的定义)。
  //   所以两种写法**逐位等价**, 但新写法把那个 32 位 2:1 mux **移出了比较路径** ——
  //   比较器的输入不再需要等 mux 选完, 少一级逻辑。
  //   实测证据: 该 mux 与后面的目标比较(CARRY4 x3)原本是串联的, 见
  //   results/p3-fmax.md 实验 C 的关键路径逐级清单。
  assign pred_ok = (actual_taken == id_ex_pred_taken) &&
                   (!actual_taken || (ex_pc_target == id_ex_pred_target));

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
    .trap_tval   (trap_tval),
    .trap_enter  (trap_enter),
    .trap_vector (trap_vector),
    // 【C-2 口径修正】!hold_mem: mret 的 rs1/rs2 字段恒为 0 ⇒ load_use_mem 永远
    // 不会在 MRET 那一拍为 1 (它要求 ID 指令依赖一个非 0 的 load rd), 所以改口径
    // **行为不变**, 只是把"哪种停顿能让 EX 的副作用重来"这件事写对 (见 hazard 头注释)。
    .mret_req    (is_mret && !hold_mem),
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
  // 【C-2 口径修正】用 !hold_mem (= !(lsu_stall||ex_busy)) 而不是 !pipe_stall:
  //   load_use_mem 那一拍 EX 里的 CSR 指令**照常提交**, 被并集 pipe_stall 门控
  //   会静默丢掉一次 CSR 写 (而 pipe_stall=1 时 csr_we=0 看起来"很合理")。
  assign csr_we    = is_csr && !hold_mem && !exc_req &&
                     (id_ex_ctrl.csr_cmd == 2'b01 || csr_src != 32'd0);

  // ---- 陷阱判定 (EX 段, 指令提交前) ----
  // 优先于分支重定向: 异常/中断一旦成立, 这条指令不能提交, 分支结果也不再重要。
  assign is_mret  = (id_ex_ctrl.sys_op == SYS_MRET);
  // 【C-2 口径修正】门控用 !hold_mem (= !(lsu_stall||ex_busy)) 而不是 !pipe_stall:
  //   只有**硬冻结**才让 EX 里的指令重算; 而 load_use_mem 那一拍 EX 里是另一条
  //   真指令, 它照常提交 ⇒ 异常必须当拍裁决, 否则会**静默丢掉**一个精确陷阱。
  //   等价性: C-2 之前 pipe_stall=1 只剩"EX 是 load"与硬冻结两种, 而 load 不可能
  //   是 illegal/ecall/ebreak ⇒ 原有行为逐位不变。
  assign exc_req  = !hold_mem && (id_ex_ctrl.illegal ||
                                  id_ex_ctrl.sys_op == SYS_ECALL ||
                                  id_ex_ctrl.sys_op == SYS_EBREAK);
  assign exc_cause = id_ex_ctrl.illegal            ? CAUSE_ILLEGAL
                   : id_ex_ctrl.sys_op == SYS_ECALL ? CAUSE_ECALL_M
                   :                                  CAUSE_BREAKPOINT;
  // 中断优先级低于异常 (规范要求), 且不在 MRET 那一拍取中断。
  //
  // 【R-01 修复 2026-10-11】必须再与 `id_ex_valid` 相与 —— "EX 段有真指令"。
  //   原判据只看了 pipe_stall: 而 load-use 停顿的**下一拍** pipe_stall 已落下、
  //   EX 里换成了 id_ex_reg 刚注入的气泡 (pc=0) —— 中断就在气泡上被接受,
  //   `trap_pc = id_ex_pc = 0` -> mepc=0, 且 ID 里那条真消费者被 any_redir
  //   一起冲掉、永不重执行 (MRET 后 PC=0, imem 只用 addr[13:2] -> 从头跑)。
  //   为什么用 valid 位而不是"irq_take & !id_ex_bubble": 气泡可以由三种原因
  //   产生 (load-use 注气泡、分支误判 flush、trap/mret flush), 只有显式 valid
  //   位同时覆盖三者; 而 pipe_stall 只覆盖第一种。
  //   为什么不会丢掉中断: irq_pending 是电平, 气泡期 veto 之后下一拍 (EX 是真
  //   指令) 就会被取走, 只是晚一拍 —— 对电平中断没有正确性影响。
  // 【C-2】irq_take 这里**故意保留** !pipe_stall: 中断是电平信号, 被气泡型停顿
  //   否决一拍不会丢, 下一拍 (EX 是真指令且管道前进) 照常取走 —— "只晚一拍"。
  //   (不能让它在 load_use_mem 那一拍被取走并顺带冲掉 ID 里的消费者: 那会改变
  //    中断相位, timer_irq.S 测试 7 的 DELTA 标定就是钉在相位上的。)
  assign irq_take  = irq_pending && !pipe_stall && !exc_req && !is_mret && id_ex_valid;
  assign trap_req  = exc_req || irq_take;
  assign trap_cause = exc_req ? {1'b0, exc_cause} : irq_cause;
  // ---- mtval (R-02 修复 2026-10-11) ----
  // 规范: 非法指令异常时 mtval = **触发指令的编码**; ecall/ebreak 与中断为 0。
  // csr_file.sv:14 的头注释早就这么承诺了, 但这里原来硬接 32'd0 ⇒ mtval 恒 0。
  // 【为什么必须把指令带过 ID/EX】trap 在 EX 段裁决, 而那一刻 IF/ID(=ID 段)里
  //   已经是**下一条**指令 —— `if_instr` 不是触发指令, 直接用它等于记错编码
  //   (本工程最忌讳的"看起来对、实际错位")。代价: ID/EX 多 32 位寄存器。
  // 【实测证据】修前 sim/prog 里一条 `0x0000007F` 的定向程序: mcause=2 ✓、
  //   mepc=0x80000024 ✓、mtval=0 ✗ ⇒ tohost=103 失败; 修后 mtval=0x0000007F ✓。
  assign trap_tval = id_ex_ctrl.illegal ? id_ex_instr : 32'd0;
  // 访存地址错异常 (CAUSE_LOAD/STORE_MISALIGN) 本核按"支持非对齐访存"处理,
  // 故不产生 —— tb_core 的 basic.hex 专门测了非对齐访存, 必须继续通过。

  // ==========================================================================
  // 【C-11】重定向: 分支误判**寄存一拍**, 陷阱/MRET 保持组合
  // --------------------------------------------------------------------------
  // 动机 (实测): C-10 之后 top-1 是
  //   u_ex_mem/ctrl_reg[wb_src][1]/C -> 前递 mux -> 分支比较(CARRY4) -> ex_taken
  //     -> pred_ok -> redirect_raw -> redirect -> any_redir -> pc mux
  //     -> u_imem/ADDRARDADDR      10.854ns (logic 2.653 / route 8.201 = 75.6%)
  // 50 条最差路径同源、Δ(top1,top2)=0.007ns ⇒ 按 R47 "逻辑重排无空间",
  // **必须把这条组合环从中间切断**。切点选在"分支误判"这一项上:
  //   检出拍 N : 只冲刷 (不装 PC), 把 {纠正请求, 目标} 寄存;
  //   下一拍 N+1: pc_flush 用**寄存器** br_redir_r/br_tgt_r 装 PC 与取指地址。
  // 于是从分支比较到取指地址脚的那一段被一个 FF 隔开。
  //
  // 【为什么只切分支误判】trap_enter/mret 走组合通路是 R-01/R48 那套不变量的
  // 前提 (ex_mem_reg.flush 只接 trap_enter、id_ex_valid 判据、trap 的精确性),
  // 一行都不动 —— 它们的路径本来也不在 top-N 上。
  //
  // 【错路指令永不提交 (R48 的反面) —— 逐条论证】
  //   记检出拍为 N (分支在 EX)。
  //   ① N 拍: ID 里的错路指令 X0 在**同拍**被 id_ex_reg.flush(any_redir) 冲掉,
  //      拍末 ID/EX 装气泡 ⇒ N+1 拍 EX 必是气泡;
  //   ② EX 里的分支自己照常提交 (ex_mem_reg.flush 只接 trap_enter=0), JAL/JALR
  //      的链接值照常写回 —— 它是真指令, 必须提交;
  //   ③ N+1 拍: ID 里是 N-1 拍取回的错路指令 X1 (imem 输出寄存器冲不掉), 但
  //      redir_flush 仍为 1 (br_redir_r) ⇒ 拍末 ID/EX 再装气泡 ⇒ N+2 拍 EX 仍是气泡;
  //   ④ N+1 拍 addr = br_tgt_r ⇒ N+2 拍 imem 输出 = 目标指令 T; N+2 拍无冲刷
  //      ⇒ 拍末 T 进 ID/EX ⇒ N+3 拍 T 在 EX。恢复窗口内 EX 全程是气泡。
  //   ⇒ 任何错路指令都到不了 EX, 更到不了 MEM/WB: 不写寄存器、不写存储器。
  //   (机器化判据: 文件末尾的 C-11 断言, 在整个回归的每一拍上检查 ③④。)
  // ==========================================================================
  assign br_redir = redirect;        // hazard 输出: 已被硬冻结 / load_use_ex 门控
  // 【trap/mret 同拍优先 —— 必须抑制登记】同一拍既有 trap/mret 又有分支误判时:
  //   当拍 PC 已经装 trap_vector/mret_pc; 若还把纠正登记到下一拍, 下一拍会把 PC
  //   拉回分支目标并冲掉陷阱处理程序的第一条指令 (灾难)。而 trap_enter 本来就会
  //   用 ex_mem_reg.flush 把 EX 里那条分支冲掉 ⇒ 分支不提交、mepc=它的 PC ⇒
  //   MRET 后重新执行、那时再纠正 —— 完全正确。
  assign br_redir_eff = br_redir && !trap_redir;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      br_redir_r  <= 1'b0;
      br_redir_r2 <= 1'b0;
      br_tgt_r    <= 32'd0;
    end
    else begin
      br_redir_r  <= br_redir_eff;
      br_redir_r2 <= br_redir_r;      // 只给断言用 (恢复窗口第 2 拍)
      if (br_redir_eff) br_tgt_r <= actual_target;
    end
  end

  // 冲刷窗口 (2 拍, 见上面的 ①②③): 检出拍 + 下一拍都冲 ID/EX 与 IF/ID
  assign redir_flush = br_redir_eff || br_redir_r;
  assign trap_redir  = trap_enter || mret_taken;
  assign any_redir   = redir_flush || trap_redir;

  // PC 装载相位: trap/mret 当拍; 分支误判纠正延后一拍 (这两项都优先于停顿)
  assign pc_flush    = trap_redir || br_redir_r;
  assign pc_flush_pc = trap_enter ? trap_vector
                     : mret_taken ? mret_pc
                     :              br_tgt_r;

  // 预测通路: **不含 redirect** —— 检出拍照预测走一拍 (取回的东西被 ①③ 冲掉)
  assign pc_src    = pred_taken;
  assign pc_target = pred_target;

  // ==========================================================================
  // 冒险单元
  // ==========================================================================
  hazard_unit u_hazard (
    .id_ex_rs1        (id_ex_rs1),
    .id_ex_rs2        (id_ex_rs2),
    .id_ex_mem_read   (id_ex_ctrl.mem_read),
    .id_ex_reg_write  (id_ex_ctrl.reg_write),   // C-10: 前递预选
    .id_ex_rd         (id_ex_rd),
    .ex_mem_reg_write (ex_mem_ctrl.reg_write),
    .ex_mem_mem_read  (ex_mem_ctrl.mem_read),
    .ex_mem_rd        (ex_mem_rd),
    .if_id_rs1        (id_rs1),
    .if_id_rs2        (id_rs2),
    .lsu_stall        (lsu_stall),
    .ex_busy          (md_busy),
    .redirect_raw     (redirect_raw),
    .fwd_a_pre        (fwd_a_pre),              // C-10: ID 段预选 (非 EX 现算)
    .fwd_b_pre        (fwd_b_pre),
    .pipe_stall       (pipe_stall),
    .id_ex_bubble     (id_ex_bubble),
    .hold_mem         (hold_mem),
    .redirect         (redirect)
  );

  // --------------------------------------------------------------------------
  // C-10: 前递预选的"随 ID/EX 打一拍"寄存器 (并行于 id_ex_reg, 4 位 FF)
  // --------------------------------------------------------------------------
  // 【为什么不能塞进 id_ex_reg.sv】那个文件不在本轮写入范围; 而且这里只需要
  // 4 位, 单独一组 FF 更省事 (FF +4 对 1254 可忽略)。
  // 【⚠ 必须与 id_ex_reg.sv 的控制优先级逐字一致: flush > bubble > stall】
  //   两者用同一组信号 (any_redir / id_ex_bubble / pipe_stall), 于是永远同步:
  //     · any_redir 或 id_ex_bubble -> 清成 FWD_REG (该拍进 EX 的是气泡)
  //     · pipe_stall                -> 保持 (消费者被扣在 ID, 预选值下次重算)
  //     · 其余                      -> 装入 fwd_*_pre (消费者这拍末进 EX)
  //   改 id_ex_reg 的控制逻辑时**必须同步改这里** (PITFALLS R1: 改了 A 忘 B)。
  // 【为什么组合上安全】预选描述的是"下一拍"的 ex_mem_*/mem_wb_* 位置关系:
  //   下一拍 EX/MEM 段的产生者 = 本拍 ID/EX; 下一拍 MEM/WB 段的产生者 = 本拍
  //   EX/MEM。只有在两者与本拍 ID 里的消费者**同拍前进**时才成立 —— 而
  //   "消费者前进" ⟺ (flush|bubble|stall 全 0) ⟹ hold_mem=0 ⟹ 两个产生者也
  //   同拍前进 (hold_mem=1 时 pipe_stall 也=1, 消费者不前进)。
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      id_ex_fwd_a <= FWD_REG;
      id_ex_fwd_b <= FWD_REG;
    end
    else if (any_redir || id_ex_bubble) begin
      id_ex_fwd_a <= FWD_REG;
      id_ex_fwd_b <= FWD_REG;
    end
    else if (!pipe_stall) begin
      id_ex_fwd_a <= fwd_a_pre;
      id_ex_fwd_b <= fwd_b_pre;
    end
  end

  // ==========================================================================
  // EX/MEM
  // ==========================================================================
  // 【.flush(trap_enter) —— 陷阱的精确性要求"触发指令被冲成气泡"】
  // 这里只冲 trap_enter (不含分支预测错误的 redirect, 也不含 mret):
  //   · redirect: EX 里是**分支自己**, 是真实指令, 必须提交;
  //   · mret: 只改 CSR, 无数据副作用。
  // 注意 **不要** 给下面的 u_mem_wb 也加 flush: 陷阱那一拍 MEM/WB 里是更老的
  // 指令, 必须提交 —— 两边都冲就变成丢指令 (这是刻意的**不对称**)。
  // 不变量: trap_enter=1 ⇒ hold_mem=0 (exc_req/mret_req 直接被 !hold_mem 门控;
  // irq_take 被 !pipe_stall 门控而 hold_mem ⊆ pipe_stall), 所以 flush 与 stall
  // 不会同拍冲突。C-2 之后 pipe_stall 多了"气泡型"停顿 (load_use_mem), 但
  // trap_enter 仍不可能与 hold_mem 同拍 —— 该不变量照旧成立。
  ex_mem_reg u_ex_mem (
    .clk           (clk),
    .rst           (rst),
    .stall         (hold_mem),
    .flush         (trap_enter),
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
  // 【必须在使用之前声明】曾经漏了这两行, 于是 ModelSim 把 `assign amo_newdata`
  // 当成**隐式 1 位网络**, 接到 32 位端口上只驱动了 1 位 -> 其余位是 Z ->
  // AMO 把 Z 写进内存 (vopt-2241 "connection width does not match" 是唯一提示)。
  // 与 PITFALLS R8 同类: 未声明的名字被隐式推断, 静默出错。
  logic [31:0] amo_newdata;    // 送给 LSU 的"应写回值" (A_EN 关时恒 0)
`ifdef A_EN
  logic [31:0] amo_new_comb;   // AMO 专用 ALU 的组合输出 (仅 A_EN 时有)
`endif

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
    .lsu_stall    (lsu_stall),
    // ---- RV32A 原子指令 ----
    // amo_en: 直接来自 EX/MEM 的控制束, 所以 A_EN 打开后译码出来的 amo_en
    //         能自然流到这里, LSU 的多周期序列即可启动。
    .amo_en            (ex_mem_ctrl.amo_en),
    .amo_newdata       (amo_newdata),
    .amo_lr            (amo_is_lr),
    .amo_sc            (amo_is_sc),
    .amo_write_phase   (amo_write_phase),
    .amo_old_out       (amo_old)
  );

  // ------------------------------------------------------------------------
  // RV32A: AMO 的"应写回内存的新值"计算
  // ------------------------------------------------------------------------
  // 【为什么必须在 MEM 段算, 不能在 EX 段】ALU 的 ALU_AMO_* 约定
  //   a = **从内存读回的旧值**, b = rs2
  // 而 dmem 是**寄存读**(地址第 N 拍、数据第 N+1 拍) —— EX 段根本拿不到旧值,
  // 旧值要到 MEM 段第二拍 (LSU 的 S_AMO 写相) 才出现在 amo_old 里。
  //
  // 所以这里**再例化一个 alu 实例**专做这件事: 输入 {amo_old, rs2}, 输出新值。
  // 复用 ALU_AMO_* 的语义, 不重复实现一遍 min/max 的符号判断 ——
  // 那份逻辑已经有 14 条单元检查覆盖 (含 0x80000000 这类符号边界)。
  //
  // rs2 需要随流水送到 MEM 段: 用 ex_mem_reg 之外的一个简单寄存器锁存
  // (id_ex_rs2 在 ID/EX 有效, 到 MEM 段就是上一条了, 所以必须寄存)。
  // ------------------------------------------------------------------------
`ifdef A_EN
  logic [31:0] amo_rs2;
  logic [31:0] ex_rs2_d;      // 打一拍的 ex_rs2, 用来对齐 amo_rs2 的采样窗口
  logic        amo_en_d;      // 上一位的 amo_en (AMO 在 EX 那一拍为 1)
  logic [4:0]  amo_op_r;      // 自己锁存的 amo_op (ex_mem_ctrl 里那份会被 hold_mem 挡住)

  // 【为什么需要 ex_rs2_d】诊断打印 [ex] 给出实测:
  //     t=175000 amo_en=1 rs2=00000017   <- AMO 在 EX, rs2 正确 (t1=23)
  //     t=215000 amo_en=0 rs2=00000000   <- AMO 已在 MEM
  // 而 amo_rs2 若直接锁存 ex_rs2, 取到的是**下一拍**的值 —— 那时 EX 里已经是
  // 后续指令 (rs2=0), 于是 AMO 的算子变成 old+0, 写回旧值, 校验失败。
  // 加一级延迟后, 采样窗口正好落在"AMO 在 EX 那一拍"。
  always_ff @(posedge clk or posedge rst) begin
    if (rst) ex_rs2_d <= 32'd0;
    else     ex_rs2_d <= ex_rs2;
  end

  always_ff @(posedge clk or posedge rst) begin
    if (rst) amo_en_d <= 1'b0;
    else     amo_en_d <= id_ex_ctrl.amo_en;
  end

  always_ff @(posedge clk or posedge rst) begin
    if (rst) amo_rs2 <= 32'd0;
    // 只在 AMO 位于 EX 那一拍捕获 (用上一拍的 amo_en 对齐), 之后保持不变,
    // 正好跨过整个多周期序列。
    else if (amo_en_d) amo_rs2 <= ex_rs2_d;
  end

  // 【为什么需要自己锁存 amo_op, 不用 ex_mem_ctrl.amo_op】
  // 诊断打印给出实测: `ex_op=00001` (EX 段正确) 但 `mem_op=00000`。
  // 根因在 ex_mem_reg.sv 第 35 行: `else if (!stall) ctrl <= ctrl_in;`
  // 而 stall 接的是 hold_mem —— **AMO 在 EX 段停留期间 hold_mem 有效,
  // 于是 ctrl_in 根本没被锁存**, MEM 段看到的还是上一条指令的 amo_op (0),
  // 结果把 amoswap 当成 amoadd 算 (0x1111+0x2222=0x3333)。
  //
  // 而 AMO 停在 EX 期间 `id_ex_ctrl.amo_op` 是**稳定且正确**的 —— 但实测
  // 它只在 `amo_en` 有效的那一拍为真值, 再往后就被后续指令冲掉了
  // (打印 [d] 实测: amo_en_d=1 那一拍 idex_op 已经是 00000)。
  // 所以锁存条件必须用 **id_ex_ctrl.amo_en 本身**, 而不是它的延迟 amo_en_d。
  always_ff @(posedge clk or posedge rst) begin
    if (rst) amo_op_r <= 5'd0;
    else if (id_ex_ctrl.amo_en) amo_op_r <= id_ex_ctrl.amo_op;
  end

  // LR.W / SC.W 标志: 从**锁存下来的** amo_op_r 译出, 整个多周期序列内稳定。
  // 用途 (见 load_store_unit): ① S_AMO 相关闭写使能 (LR 只读、SC 不写);
  //                          ② SC 的 rd 恒返回 1 (失败)。规范允许 SC 永远失败。
  assign amo_is_lr = (amo_op_r == AMO_LR);
  assign amo_is_sc = (amo_op_r == AMO_SC);

  alu #(.XLEN(XLEN)) u_amo_alu (
    .a       (amo_old),            // 从内存读回的旧值
    .b       (amo_rs2),            // rs2
    .op      (amo_op_r == AMO_SWAP ? ALU_AMO_SWAP :
              amo_op_r == AMO_ADD  ? ALU_AMO_ADD  :
              amo_op_r == AMO_XOR  ? ALU_AMO_XOR  :
              amo_op_r == AMO_AND  ? ALU_AMO_AND  :
              amo_op_r == AMO_OR   ? ALU_AMO_OR   :
              amo_op_r == AMO_MIN  ? ALU_AMO_MIN  :
              amo_op_r == AMO_MAX  ? ALU_AMO_MAX  :
              amo_op_r == AMO_MINU ? ALU_AMO_MINU :
              amo_op_r == AMO_MAXU ? ALU_AMO_MAXU :
                                     ALU_AMO_ADD),
    .out     (amo_new_comb)
  );

  // 只在该用的时候选它: LR/SC 不写内存 (由 amo_op 决定), 且必须处于写相。
  // 其余时候给 0, 避免把无关数据当写值 (LSU 也只在写相才用 amo_newdata)。
  assign amo_newdata = (amo_write_phase &&
                        amo_op_r != AMO_LR &&
                        amo_op_r != AMO_SC) ? amo_new_comb : 32'd0;

  // (诊断打印已移除 —— 结论写进 results/p6-a-extension.md 第 5.8 节)
`else
  // 【A_EN 关闭时: 整个 AMO 新值计算单元不综合】
  // 实测: 它虽然休眠却仍占面积与路径 (fmax 61.2 -> 59.1 MHz, LUT +14)。
  // 既然默认不开 A 扩展, 就没有理由为它付这个代价 —— 用 `ifdef 让综合器
  // 把它整体裁掉 (与 GEMM_EN/RAS_EN/BTB_GSHARE 同样的做法)。
  assign amo_newdata = 32'd0;
  // RV32A 关掉时把 LR/SC 标志钉成常量: LSU 里那两处门控/回读 mux 会被综合裁掉,
  // 默认配置的面积与时序与加 A 扩展之前**逐位相同**。
  assign amo_is_lr   = 1'b0;
  assign amo_is_sc   = 1'b0;
`endif


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

  // ---- 临时诊断: 把读数据这条链一次打印完 (排查完删掉) ----
  // 上一次只打到 LSU 侧, 看到 rdata 恒 0 却分不清是"译码丢了"还是"dmem 没输出"。
  // 这一次把 u_dmem 的输出、译码选择、外部通路一次全打出来, 直接对半砍。
  // (诊断打印已移除 —— 结论写进 results/p6-a-extension.md 第 5.2 节)
  // 注: 想直接探 `u_dmem.mem[]` 是**不行**的 —— SystemVerilog 不允许跨模块
  // 层次引用数组元素 (vlog 编译直接失败)。要探阵列得在 tb 里或用 dmem 的读口。

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
  // 【刻意不对称: 这里**没有** flush】陷阱只冲 EX/MEM (ex_mem_reg.flush) ——
  // 陷阱那一拍 MEM/WB 里是"更老的指令", 它必须提交; 给 mem_wb_reg 加 flush
  // 会把已经进入 WB 的正确指令丢掉 (丢指令比双执行更难查)。
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
  // dbg_pc 必须与 dbg_instr 取自 *同一级*: if_pc 是 ID 里那条指令的地址,
  // if_instr 就是那条指令本身。原先这里接的是 IF 段正在取的 pc, 与 if_instr
  // 永远差一拍 —— 超时/非法指令的失败诊断会指向错误的指令。
  // 【为什么两个 PC 都要引出】
  //   dbg_pc    = IF 段正在取的地址 —— 回答"现在跑到哪了", 超时诊断用它;
  //   dbg_id_pc = ID 中那条指令的地址, 与 dbg_instr 严格配对 —— 回答
  //               "出问题的是哪条指令"。
  // 只引出一个都有坑: 单用 pc 则与 if_instr 差一拍 (指错指令)。
  // 【2026-10-08 更新】原注还说"单用 if_pc 则 if_id_reg 在 flush 那拍会把它
  // 清成 0" —— 那条**已随 if_id_reg 删除而失效**: 现在 if_pc 只是 pc 的组合别名
  // (见 ID 段注释), flush 期间也不再被清 0, 诊断信息反而更完整。
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
    // C-11: 用 redir_flush (2 拍窗口) 而不是 redirect —— 恢复窗口那两拍 ID 里
    // 还留着错路指令, 它译码出的 illegal 是假失败 (EX 里已经是气泡)。
    else if (id_ex_ctrl.illegal && !pipe_stall && !redir_flush && !trap_enter) dbg_illegal <= 1'b1;
  end

  // 跳转目标必须 4 字节对齐。陷阱接管后这条断言覆盖 trap/mret 与分支误判纠正
  // 两条路径: trap_vector 在 csr_file 里已按 {mtvec[31:2],2'b00} 对齐, mepc 写入
  // 时同样对齐, br_tgt_r 来自 actual_target (ex_pc_target 对 JALR 清最低位、
  // 否则是 pc+4) —— 本来就恒定对齐, 保留断言等于免费多一道保险。
  // 【C-11 口径】判据从 `any_redir && pc_target` 改为 `pc_flush && pc_flush_pc`:
  //   pc_target 现在是"预测目标"(不装 PC), 真正装进 PC 的是 pc_flush_pc。
  `ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && pc_flush && (pc_flush_pc[1:0] != 2'b00)) begin
      $error("instruction address misaligned: target=%h", pc_flush_pc);
    end
  end
  `endif

  // 【R-01 的机器化判据】trap 被接受那一拍, EX 段必须是一条**真指令**。
  //   这条不变量正是 R-01 的根因: 中断曾在 load-use 停顿注入的气泡上被接受
  //   (气泡的 id_ex_pc=0) -> mepc=0 + ID 里那条真指令被 any_redir 永久丢弃。
  //   为什么必须有它: sim/prog/timer_irq.S 的测试 7 要靠 DELTA 标定值才能撞上
  //   那个相位; 以后任何人改流水线相位, DELTA 会失配而"测试仍然绿"(静默失效)。
  //   这条断言与相位无关 —— 只要 trap_enter 时 EX 不是真指令就直接报错。
  //   (exc_req 的三个来源都带 id_ex_ctrl 判据、irq_take 已与 id_ex_valid 相与,
  //    所以正常情况下它恒真。)
  `ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && trap_enter && !id_ex_valid) begin
      $error("trap_enter on an invalid EX instruction (R-01 regression): pc=0x%08x cause=0x%02x",
             id_ex_pc, trap_cause);
    end
  end
  `endif

  // 【C-11 的机器化判据 —— "错路指令永不提交" (R48 的反面)】
  //   分支误判检出后, 恢复窗口的两拍 (br_redir_r = N+1, br_redir_r2 = N+2)
  //   内 EX 段**必须一直是气泡**; 目标指令要到 N+3 才进 EX。
  //   为什么必须有它: 寄存 redirect 唯一的致命风险就是"被冲刷的错路指令晚一拍
  //   才被冲, 于是有一条错路指令提交了"(寄存器写/存储器写)。这条断言与相位或
  //   DELTA 无关, 覆盖整个回归的每一拍 —— 任何那样的事故都会立刻 $error。
  //   (EX 里的分支自己不算: 它在 N 拍, 而窗口从 N+1 才开始。)
  `ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && id_ex_valid && (br_redir_r || br_redir_r2)) begin
      $error("C-11: wrong-path instruction entered EX during redirect recovery (pc=0x%08x instr=0x%08x)",
             id_ex_pc, id_ex_instr);
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
