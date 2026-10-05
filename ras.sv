`timescale 1ns/1ps

// ============================================================================
// ras.sv — 返回地址栈 (Return Address Stack)
// ----------------------------------------------------------------------------
// 【为什么需要它】实测把预测错误按类型拆开 (tb_sw 的统计):
//     条件分支 = 6055 (52%)   JAL = 1102 (9%)   JALR = 4378 (37%)
//   JALR 里绝大多数是**函数返回**, 而返回目标由调用点决定, BTB 里只记得住
//   "上一次"的返回地址 —— 同一个函数被不同地方调用时就会被踢来踢去。
//   RAS 专门记调用点, 天然解决这个问题, 且它很便宜 (8 项 × 32 位 + 一个指针)。
//
// 【与 BTB 的分工】这是本设计的关键点:
//   前端在 IF 段**无法识别返回指令**(要译码才知道), 所以做法是:
//     1) EX 段解析出控制流后, 除了写 BTB 目标, 还写一个 **is_ret 标记**;
//     2) 下次取到同一条 PC, BTB 命中且 is_ret=1 -> 说明"这条是返回",
//        于是改用 RAS 栈顶作为预测目标, 忽略表里存的旧目标。
//   即: BTB 负责"记住这条 PC 是返回", RAS 负责"现在该返回到哪"。
//
// 【为什么只在 EX 更新, 不做投机】陷阱/预测错误会冲刷流水, 若在取指阶段就
//   投机地 push/pop, 冲刷后栈就脏了, 而且没有廉价的回滚手段。EX 段是解析点,
//   此时该指令即将提交 (被冲刷时 upd_en 不会有效), 所以栈始终是精确的。
//
// 【压栈的时机细节】push 的值是**返回地址 = 链接寄存器的值**。对 JAL/JALR 且
//   rd=x1/x5 而言, 这个值就是 pc+4, 由 core 送进来 (ras_push_pc)。
//   注意 push 必须与"call 指令在 EX"同拍完成, 这样等被调用函数的 ret 到达 IF 时,
//   栈顶已经是正确的返回地址 (中间至少隔了若干拍取指)。
//
// 【深度】8 项。CoreMark 调用深度很浅 (3~4 层), 8 项足够; 溢出时**不回绕**,
//   而是停在满/空状态 (饱和), 因为回绕会让栈顶指向错误的返回地址, 比"不预测"
//   更糟。溢出后该次返回预测错误, 由 EX 重定向兜底, 不影响正确性。
// ============================================================================

module ras
  import rv32_pkg::*;
#(
  parameter int unsigned DEPTH = 8
)(
  input  logic        clk,
  input  logic        rst,

  // 压栈 (EX 段: 该指令是 call —— 带链接的跳转)
  input  logic        push_en,
  input  logic [31:0] push_pc,       // 返回地址 (= 链接值)

  // 弹栈 (EX 段: 该指令是 return —— JALR rd=x0, rs1=x1/x5)
  input  logic        pop_en,

  // 查询 (IF 段组合读): 栈顶 = 下一个返回地址
  output logic [31:0] top,
  output logic        empty
);

  localparam int unsigned PW = $clog2(DEPTH + 1);

  logic [31:0]   stk [DEPTH];
  logic [PW-1:0] sp;                 // 栈内项数 (0 = 空)
  wire  [PW-1:0] full_sp = PW'(DEPTH);

  assign empty = (sp == '0);
  // 组合读栈顶。DEPTH 很小, 综合成一级 mux, 不落 BRAM, 也不会引入长路径。
  assign top   = stk[sp - 1'b1];

  integer i;
  initial begin
    for (i = 0; i < DEPTH; i++) stk[i] = '0;
    sp = '0;
  end

  always @(posedge clk) begin
    if (rst) begin
      sp <= '0;
    end
    else begin
      // push 与 pop 同拍 (例如 call 到一条 ret 上, 实际上不会同拍, 但保守处理):
      // 以 pop 优先 —— 先把旧项弹掉再压新的, 保持栈的语义正确。
      if (pop_en && sp != '0) begin
        sp <= sp - 1'b1;
        if (push_en) stk[sp - 1'b1] <= push_pc;   // 覆盖被弹出的槽位
      end
      else if (push_en && sp != full_sp) begin
        stk[sp] <= push_pc;
        sp <= sp + 1'b1;
      end
    end
  end

endmodule
