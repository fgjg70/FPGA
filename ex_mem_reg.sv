`timescale 1ns/1ps

// ============================================================================
// ex_mem_reg.sv — EX/MEM 流水寄存器
// ----------------------------------------------------------------------------
// 携带: 控制束 (MEM/WB 段消费)、ALU 结果 (访存地址)、store 数据、rd 地址、
//       PC+4 (JAL/JALR 链接值)。
// 停顿: 拆分访存 (lsu_stall) 时保持, 与 MEM/WB 同步冻结。
//
// 【flush —— 陷阱必须把 EX 里那条指令冲成气泡】2026-10-11 新增 (P0 架构缺陷)
//   症状 (实测): 中断被接受的那一拍 EX 里是真实指令, 它**照样提交**, 而
//     csr_file 又把 mepc 记成这条指令的 PC ⇒ MRET 之后它**再执行一次**:
//       c=2506 trap_enter=1 (EX = add s5,s5,t3, mepc=80000100)
//       c=2509 s5=12345678          <- 提交了 (WB 写回)
//       c=2546 mret 回到 80000100   <- 同一条 add 重新执行
//       c=2550 s5=2468acf0          <- 正好 2× = 双重执行
//     ecall/ebreak/非法指令看不出来 (control_unit 早已把它们中性化成无副作用),
//     但**中断**抢占的是任意指令: 被抢占的 add 执行两次、被抢占的 sw 写两次
//     (MMIO 上就是 UART 发两次)。旧 timer_irq.S 的等待循环是 `li+bne`(幂等),
//     所以这条缺陷静默潜伏至今 (与 PITFALLS R1/R17 同族: 静默失效)。
//   修法来源: core.sv 顶部注释本来就承诺"触发指令被冲成气泡 -> 不写寄存器、
//     不写存储器", 但 any_redir 只冲了 id_ex_reg 与 IF/ID —— 这里补上冲刷口。
//
// 【为什么只冲 trap_enter, 不是 any_redir】
//   any_redir = redirect(分支预测错误) || trap_enter || mret_taken。后两者之外
//   的 redirect 里, EX 中的指令是**分支自己** —— 它是真实指令, 必须提交
//   (冲掉它就等于丢指令); MRET 本身也只改 CSR、无数据副作用, 不必冲。
//   所以 flush 由 core 接 `trap_enter`, **不要顺手改成 any_redir**。
//
// 【为什么 flush 在 !stall 之前 —— 一条不变量】
//   trap_enter = trap_req = exc_req || irq_take, 而 exc_req 与 irq_take 都被
//   `!pipe_stall` 门控; 又有 hold_mem = lsu_stall || ex_busy,
//   pipe_stall = load_use || lsu_stall || ex_busy ⇒ **trap_enter=1 ⇒ hold_mem=0**。
//   两者不可能同拍, 但优先级仍按 id_ex_reg 的惯例写成 flush > stall。
//
// 【对称性警告】mem_wb_reg **故意不加 flush**: 陷阱那一拍 MEM/WB 里是"更老的
//   指令", 它必须提交 (陷阱的精确性只要求冲掉触发指令本身)。给 mem_wb_reg
//   加 flush 会丢指令 —— 见 core.sv 里 u_mem_wb 处的注释。
//
// ============================================================================
// 【候选 D′ · 2026-10-13 · **已判负并回退**】flush 只冲 ctrl, 数据字段只受 stall
// ============================================================================
// 【试过什么】把 `flush` 从 5 个字段的 CE/D 上收窄到只有 `ctrl`, 数据字段只保留
//   `CE = !stall`。**动机** (150 档 top-1 = `u_ex_mem/alu_out_reg[2]/CE`):
//   Source = imem 的指令字寄存器, 7.081ns / 5 级 / logic 仅 5×0.105 = 0.525ns,
//   两跳高扇出布线 = **2.147ns (30%)**。逐跳解出的真实锥是
//     `if_id_rs1/rs2 → 相等比较(网名 rd_addr_reg[*], fo≈121/122) → load_use
//      → pipe_stall → !pipe_stall → irq_take → trap_req → trap_enter → flush → CE`
//   (`core.sv` 的 `irq_take` 里有 `!pipe_stall`; `pipe_stall` 的 `load_use` 项正是
//    `if_id_rs*` 与 `id_ex_rd/ex_mem_rd` 的比较), 而原来 `flush` 把 5 个字段一起清零
//   ⇒ 这条锥被接到 **122 个** CE 引脚上。
// 【结果 (Lead 实测, 150 档, 基线 = A+C+C-12c 的 −0.852)】
//     + `--no-lc`            → **−0.490**  (目前最好; 工具侧单选项)
//     + D′ 单独              → **−1.021**  (**更差 0.169** ⇒ 回退)
//     + D′ + `--no-lc`       → **−0.582**  (比 `-no-lc` 单独更差 0.092)
//   D′ 的族分布: 19 条 `ex_mem/alu_out_reg/D`(−0.503) —— **`alu_out/CE` 那一族确实被治掉了** ✓,
//     但**墙转移到新族**: 8 条 `id_ex/rs1_data_reg/CE`(−0.411) + 2 条 `id_ex/rs2_data_reg/CE`(−0.357),
//     另有 7+7 条 `csr/mepc|mtval_reg/CE`(D′ 够不到, 它们在 csr_file 里由 `trap_enter` 直接写)。
// 【结论 —— "墙转移"的第三个实例】本设计在 150 档对单点结构改动的响应是**墙转移**:
//   摘掉一条 CE 锥, 别的 CE 锥接班。⇒ 优先用**工具侧单选项**(`--no-lc` 零 ticks 代价 +0.362ns),
//   而不是付 IPC 代价买断某一条链。(另两个实例: C-12c 断 DSP 链、C-18a 单片 DSP 见各自文件。)
//
// 【仍然有效的文档: `flush` 那一拍各字段的消费者审计】`ctrl='0` ⇒ 该指令是气泡
//   ⇒ 其余字段全是 don't-care (下表是本文件"改 flush 语义时怎么证明没坏"的依据):
//   | 字段 | 消费者 (core.sv) | 门控依据 |
//   |---|---|---|
//   | `alu_out`    | LSU `req_addr`(:1336) / `ex_mem_fwd_data`(:715) / mem_wb(:1510) | LSU 的 `dmem_we/re` 由 `ctrl.mem_write/mem_read` 给; 前递由 `id_ex_fwd_*` 选, 而它由 `ex_mem_ctrl.reg_write=0` ⇒ FWD_REG; mem_wb 写由 `ctrl.reg_write=0` 给 |
//   | `store_data` | LSU `req_wdata`(:1337) | `ctrl.mem_write=0` |
//   | `pc_plus4`   | `ex_mem_fwd_data` 的 WB_PC4 分支 / mem_wb | `ctrl.wb_src` + `ctrl.reg_write=0` |
//   | `rd_addr`    | mem_wb `rd_addr_in`(:1528) / hazard `ex_mem_rd`(:1207) | regfile 写由 `ctrl.reg_write=0`; 前递/冒险比较由 `ex_mem_ctrl.reg_write/mem_read=0` |
//   两条间接消费者: hazard 的 `load_use_mem` = `ex_mem_mem_read && rd!=0 && match(...)`
//   ⇒ `mem_read=0` 时不可能误判 ✓; regfile 的同拍写优先旁路由 `wb_reg_write` 给 ✓。
//   观测面: `sim/tb_sw.sv:402` 只读 `ex_mem_ctrl.mem_read` ✓, 全仓无断言看数据字段 ✓。
// ============================================================================

module ex_mem_reg
  import rv32_pkg::*;
(
  input  logic        clk,
  input  logic        rst,
  input  logic        stall,
  input  logic        flush,      // 陷阱: 把 EX 里那条被抢占的指令冲成气泡
                                  // (只能接 trap_enter, 不能接 any_redir, 见头注释)

  input  ctrl_s       ctrl_in,
  input  logic [31:0] alu_out_in,
  input  logic [31:0] store_data_in,
  input  logic [31:0] pc_plus4_in,
  input  logic [4:0]  rd_addr_in,

  output ctrl_s       ctrl,
  output logic [31:0] alu_out,
  output logic [31:0] store_data,
  output logic [31:0] pc_plus4,
  output logic [4:0]  rd_addr
);

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      ctrl       <= '0;
      alu_out    <= '0;
      store_data <= '0;
      pc_plus4   <= '0;
      rd_addr    <= '0;
    end
    else if (flush) begin
      // 注入气泡: 被抢占的指令不写寄存器、不写存储器, MRET 后重新执行它
      // 【候选 D′ 已回退 (2026-10-13)】曾改成"flush 只冲 ctrl、数据字段只受 stall 门控"
      //   (理论依据: ctrl='0 ⇒ 其余字段 don't-care, 审计见文件头)。机制上确实治好了
      //   `u_ex_mem/alu_out_reg/CE` 那一族, 但 150 档实测**更差**: −0.490 → −1.021
      //   (单独) / −0.490 → −0.582 (叠加 --no-lc) —— 墙转移到了 `id_ex/rs1_data_reg/CE`
      //   (8 条) 与 `rs2_data_reg/CE` (2 条)。⇒ 按预登记条件回退, 恢复"全字段清零"。
      //   (审计表保留在文件头: 它是"flush 这一拍哪些字段真的被消费"的完整记录。)
      ctrl       <= '0;
      alu_out    <= '0;
      store_data <= '0;
      pc_plus4   <= '0;
      rd_addr    <= '0;
    end
    else if (!stall) begin
      ctrl       <= ctrl_in;
      alu_out    <= alu_out_in;
      store_data <= store_data_in;
      pc_plus4   <= pc_plus4_in;
      rd_addr    <= rd_addr_in;
    end
  end

endmodule
