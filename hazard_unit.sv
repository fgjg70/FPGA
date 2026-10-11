`timescale 1ns/1ps

// ============================================================================
// hazard_unit.sv — 冒险处理 (前递 + load-use 停顿 + 重定向冲刷)
// ----------------------------------------------------------------------------
// 停顿来源 (可同时发生):
//   1) **load-use 冒险 —— C-2 之后固定 2 拍气泡** (依据 RVCoreP-32IM 论文
//      arXiv 2010.16171 §III.A: "we did not include the load data into the
//      forwarding path from the write back stage" ⇒ "two cycles bubble")。
//      dmem 是寄存读 (地址第 N 拍、数据第 N+1 拍), 而 load 数据**故意不在
//      前递路径上** ⇒ 消费者在 EX 段永远拿不到"刚读回"的值, 只能等寄存器堆
//      在 WB 拍末尾写入, 由 regfile 的写优先旁路在同拍把新值送进 ID/EX。
//      两拍气泡:
//        · 第 1 拍: load 在 EX  (只有地址, 没有数据) -> load_use_ex
//        · 第 2 拍: load 在 MEM (dmem 正在锁存, 数据还没进 WB 段) -> load_use_mem
//      两拍都是"冻 PC / IF-ID + 向 ID/EX 注气泡"; load 自己照常前进 (hold_mem=0)。
//   2) 拆分访存 (lsu_stall) / 多周期除法 (ex_busy): 整条流水线硬冻结 (hold_mem),
//      期间**不能**注气泡 —— EX 里的指令还没算完, 注气泡会把它丢掉; 保持是安全
//      的, 因为 load_use 由冻结的 ID/EX + IF/ID 重新算出, 气泡只是被推迟、不会丢。
//
// 【pipe_stall 与 hold_mem 的分工 —— 一条必须记住的口径】
//   pipe_stall 是"两拍气泡停顿"与"硬冻结"的**并集**; 而 EX 段的**副作用**
//   (trap / CSR 写 / mret / BTB 更新) 只能被**硬冻结** (hold_mem) 门控:
//     · 硬冻结时 EX 里的指令会被重算, 副作用必须等它算完那一拍;
//     · 而 load_use_mem 那一拍 EX 里是**另一条真指令**, 它照常提交 ——
//       若副作用被并集 pipe_stall 门控, 会**静默丢掉**一次 CSR 写 / 一个精确
//       陷阱 ✗ (C-2 之前 pipe_stall=1 只可能出现在"EX 是 load"或"硬冻结"两种
//       情形, 所以全核都敢写 !pipe_stall; C-2 打破了这条隐含前提。)
//
// 重定向 (分支/JAL/JALR 在 EX 判定) 只被"硬冻结"与"EX 段是 load"抑制:
//   前者 EX 结果不可信 (下一拍重算), 后者 EX 根本不是控制流指令。
//   **load_use_mem 不抑制重定向** —— 那一拍 EX 可能是**与 load 无关**的分支,
//   它的判定是对的, 抑制它等于丢一次重定向 (流水线会一直跑在错路上)。
//
// 【C-10】前递选择 (哪一路) 改成 **ID 段预选 + 随 ID/EX 寄存**: EX 段只剩
//   select -> mux, 5 位相等比较/门控/优先级整条离开关键路径。逐位等价性证明
//   与"锁存使能必须与 id_ex_reg 一致"的约束见下面"前递"一节。
// ============================================================================

module hazard_unit
  import rv32_pkg::*;
(
  // ID/EX: 当前在 EX 的指令
  // 【C-10 清理】原先这里还有 id_ex_rs1/id_ex_rs2 两个端口 —— 它们是"EX 段现算
  // 前递"用的消费者 rs。C-10 把前递选择挪到 ID 段预选之后, 它们在模块内**再无
  // 使用者**, 综合会报 `Synth 8-3331 unconnected port` (各 5 条)。已删除 (端口 +
  // core 侧连接), 语义不变: 消费者 rs 由下面的 if_id_rs1/if_id_rs2 承担。
  input  logic       id_ex_mem_read,
  input  logic       id_ex_reg_write,  // C-10: 前递预选的"产生者侧"判据
  input  logic [4:0] id_ex_rd,

  // EX/MEM: 当前在 MEM 的指令
  input  logic       ex_mem_reg_write,
  input  logic       ex_mem_mem_read,
  input  logic [4:0] ex_mem_rd,

  // IF/ID: 当前在 ID 的指令 (C-10: 消费者侧 rs1/rs2)
  input  logic [4:0] if_id_rs1,
  input  logic [4:0] if_id_rs2,

  // 拆分访存 / 多周期执行单元忙 / 重定向请求
  input  logic       lsu_stall,
  input  logic       ex_busy,        // RV32M 除法器 busy: 冻结流水线直到出结果
  input  logic       redirect_raw,

  // 前递选择与流水线控制
  // 【C-10 语义】fwd_*_pre 是 **ID 段预选** (描述"下一拍 EX 段该选哪一路"),
  // 由 core.sv 随 ID/EX 打一拍 (id_ex_fwd_a/b) 后驱动 EX 前递 mux。
  // 旧的"EX 段现算"版本已删除 —— 它的比较链正是 C-2 之后的 top-1 关键路径。
  output fwd_sel_e   fwd_a_pre,
  output fwd_sel_e   fwd_b_pre,
  output logic       pipe_stall,      // 冻结 PC / IF-ID / ID-EX
  output logic       id_ex_bubble,    // 向 ID/EX 注入气泡
  output logic       hold_mem,        // 冻结 EX/MEM 与 MEM/WB (= 硬冻结)
  output logic       redirect         // 生效的重定向
);

  // --------------------------------------------------------------------------
  // load-use: 两拍气泡 (C-2)
  // --------------------------------------------------------------------------
  //   load_use_ex : 经典定义 —— EX 里的 load 与 ID 里的指令有寄存器依赖
  //   load_use_mem: C-2 新增 —— MEM 里的 load (数据还没到 WB) 与 ID 依赖
  // 名字 `load_use` 必须保留: sim/tb_sw.sv:317/322 直接层次化引用它做
  // "停顿构成"与"每条 load-use 恰好 2 拍气泡"的自证 (n_stall_lu == 2*events)。
  logic load_use_ex, load_use_mem, load_use;
  always_comb begin
    load_use_ex  = id_ex_mem_read && (id_ex_rd != 5'd0) &&
                   ((id_ex_rd == if_id_rs1) || (id_ex_rd == if_id_rs2));
    // reg_write 也一起判: 只对"真的写寄存器"的 load 拉停 (x0 与不写回的除外)
    load_use_mem = ex_mem_mem_read && ex_mem_reg_write && (ex_mem_rd != 5'd0) &&
                   ((ex_mem_rd == if_id_rs1) || (ex_mem_rd == if_id_rs2));
    load_use     = load_use_ex || load_use_mem;
  end

  // ex_busy (多周期除法) 与 lsu_stall 同类: 冻结 ID/EX 与 EX/MEM/MEM/WB,
  // *不能* 注气泡 (EX 里的指令还没算完, 注气泡会把它丢掉)。
  assign pipe_stall   = load_use || lsu_stall || ex_busy;
  assign id_ex_bubble = load_use && !(lsu_stall || ex_busy);
  assign hold_mem     = lsu_stall || ex_busy;
  // 见头注释: 只有硬冻结与"EX 是 load"抑制重定向; load_use_mem 不抑制。
  assign redirect     = redirect_raw && !(lsu_stall || ex_busy || load_use_ex);

  // --------------------------------------------------------------------------
  // 前递 (C-2: WB→EX 这一级**不再**送 load 数据; C-10: 选择**提前一拍**算好)
  // --------------------------------------------------------------------------
  // 【C-10 —— 为什么把选择挪到 ID 段】
  //   C-2 之后的关键路径 (实测 top-1, 50 条同源, route 76.1%) 是:
  //     u_ex_mem/rd_addr_reg[4]/C -> 前递比较/选择 -> 前递 mux -> 分支比较(CARRY4)
  //       -> ex_taken -> redirect_raw -> redirect -> any_redir -> pc mux -> imem 地址
  //     11.345ns (logic 2.707 / route 8.638, 14 级)
  //   比较用的三组信息在 **ID 那一拍就全部已知**:
  //     · 消费者 (ID) 的 rs1/rs2   = if_id_rs*
  //     · 下一拍 EX/MEM 段的产生者 = 本拍 ID/EX   (id_ex_rd/reg_write/mem_read)
  //     · 下一拍 MEM/WB 段的产生者 = 本拍 EX/MEM  (ex_mem_rd/reg_write/mem_read)
  //   (本拍 MEM/WB 段的产生者在下一拍已离开 WB; 它的值由 regfile 的写优先旁路在
  //    "消费者 ID 那一拍末尾"就吃进 id_ex_rs*_data —— 不需要任何 mux 选择。)
  //   于是"选哪一路"提前一拍算好, 由 core.sv 随 ID/EX 寄存 (id_ex_fwd_a/b),
  //   EX 段只剩 select -> mux; 5 位相等比较 + reg_write/mem_read 门控 + 优先级
  //   整条离开关键路径。
  //
  //   【逐位等价性】下一拍 EX 段的 ex_mem_rd/mem_wb_rd/reg_write/mem_read 恰好
  //   就是本拍的 id_ex_*/ex_mem_*; 下一拍消费者的 rs 就是本拍的 if_id_rs*。
  //   预选只在"消费者确实前进"时锁存 (与 id_ex_reg 同一组使能
  //   flush / bubble / stall, 见 core.sv 的 id_ex_fwd_* 时序块) ——
  //   三种情形下消费者都没进 EX, 用不到这个值。
  //
  // EX/MEM 优先于 MEM/WB; 两个源都排除"数据还没回来/不该走前递"的指令:
  //   · EX/MEM 段排除 load —— 此刻 ex_mem_alu_out 只是地址, 数据还没回来
  //     (依赖它的指令由 load_use_ex / load_use_mem 保证停在 ID);
  //   · MEM/WB 段也排除 load (C-2) —— "dmem RAMB36 输出寄存器 -> LSU 字节提取
  //     -> wb_data -> 前递 mux -> EX 操作数 -> 分支判定 -> 重定向 -> 取指地址脚"
  //     曾是实测 top-1 关键路径 (50 条同源)。摘掉后取指环起点不再是 BRAM 时钟脚。
  //     已证明这一支**不可达**: 若"WB 段是 load"命中前递, 则上一拍 ID 里必有
  //     依赖它的指令, load_use_mem 会把那条指令扣在 ID。
  //   · AMO/LR/SC 的 wb_src 也是 WB_MEM, 但 control_unit 不设 mem_read
  //     (见 OPC_AMO) ⇒ 它们**不**被排除, 旧值来自 LSU 锁存寄存器 amo_old。
  //     所以判据是 mem_read, 不是 wb_src。
  //
  // 【千万不要在这里排除 JAL/JALR】—— 曾经这么干过, 是个真 bug。
  //   JAL/JALR 在 EX/MEM 时 alu_out 是 *跳转目标*, 但它的链接值 (PC+4) 同样
  //   就在 EX/MEM 寄存器里 (ex_mem_pc_plus4)。正确做法是在 core.sv 里按
  //   wb_src 选择前递源 (WB_PC4 -> ex_mem_pc_plus4), 而不是把整条前递路径砍掉。
  //   砍掉的后果: 紧跟在 jal ra, f 之后的 mv t0, ra 这种 *距离 1* 消费者会读到
  //   陈旧的 ra。加分支预测之前它被 2 拍冲刷掩盖着, 预测生效后立刻暴露 ——
  //   实测把 libgcc 的 __umodsi3 打成了死循环。
  logic pre_ex_a, pre_wb_a, pre_ex_b, pre_wb_b;
  always_comb begin
    pre_ex_a = id_ex_reg_write && !id_ex_mem_read &&
               (id_ex_rd != 5'd0) && (id_ex_rd == if_id_rs1);
    pre_wb_a = ex_mem_reg_write && !ex_mem_mem_read &&
               (ex_mem_rd != 5'd0) && (ex_mem_rd == if_id_rs1);
    pre_ex_b = id_ex_reg_write && !id_ex_mem_read &&
               (id_ex_rd != 5'd0) && (id_ex_rd == if_id_rs2);
    pre_wb_b = ex_mem_reg_write && !ex_mem_mem_read &&
               (ex_mem_rd != 5'd0) && (ex_mem_rd == if_id_rs2);

    fwd_a_pre = pre_ex_a ? FWD_EX_MEM : pre_wb_a ? FWD_MEM_WB : FWD_REG;
    fwd_b_pre = pre_ex_b ? FWD_EX_MEM : pre_wb_b ? FWD_MEM_WB : FWD_REG;
  end

endmodule
