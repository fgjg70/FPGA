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
