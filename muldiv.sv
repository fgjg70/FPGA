`timescale 1ns/1ps

// ============================================================================
// muldiv.sv — RV32M 乘除法单元
// ----------------------------------------------------------------------------
// 乘法: 组合, 单周期。三个 64 位积并行算 (signed×signed / signed×unsigned /
//       unsigned×unsigned), 综合映射到 DSP48。
// 除法: 多周期, 32 步恢复余数法。busy 期间 EX 保持 (core 拉 pipe_stall)。
//
// RISC-V 对除法的边界定义 (必须精确, 否则 riscv-tests 不过):
//   - 除零: 商 = 全 1 (-1), 余数 = 被除数
//   - 溢出: INT_MIN / -1 -> 商 = INT_MIN, 余数 = 0
//   - REM 的符号跟被除数 (不是除数)
//
// 【两个容易写错的地方, 都是真踩过的】
// 1) 余数必须是 33 位。恢复余数法里 rem 要左移一位再补进被除数的最高位, 若只用
//    32 位, 当除数 > 2^31 时 rem 会达到 2^31 量级, 左移就丢位 -> 结果错。
// 2) 迭代做完那一拍不能马上放行流水线。若 busy 与末次迭代同拍清零,
//    EX/MEM 会在同一个时钟沿捕获到 *上一次* 的 div_result。
//    正确做法: 最后一步只寄存结果, 下一拍 (cnt==0) 才拉低 busy。
// ============================================================================

module muldiv
  import rv32_pkg::*;
#(
  parameter int unsigned XLEN = 32
)(
  input  logic clk,
  input  logic rst,

  input  alu_op_e         op,        // 仅 ALU_MUL..ALU_REMU 被使用
  input  logic [XLEN-1:0] a,
  input  logic [XLEN-1:0] b,

  output logic [XLEN-1:0] result,
  output logic            busy       // 除法进行中 -> core 停顿流水线
);

  // ------------------------------------------------------------------------
  // 乘法 (组合)
  // ------------------------------------------------------------------------
  // 只需要两个乘法器 (省一组 DSP 和面积):
  //   MULHSU 的乘积 signed(a) x unsigned(b) 可以用恒等式表示 ——
  //     signed(a)*unsigned(b) = signed(a)*signed(b) + signed(a)*(b[31] ? 2^32 : 0)
  //   而 (a<<32) 的低 32 位是 0, 不会向高位进位, 于是
  //     high32(MULHSU) = high32(prod_ss) + (b[31] ? a : 0)
  //   一个 32 位加法即可, 不必再实例化第三个乘法器。
  // 【乘积必须寄存进 DSP 内部寄存器】
  //   若让乘法组合直达写回, 关键路径会变成
  //     hazard/前递 -> DSP48E1 x2 -> 13 级 CARRY4 (64 位加法) -> EX/MEM
  //   实测 15.5ns (logic 占 55%), fmax 从 74 掉到 65MHz。
  //   写成 always @(posedge clk) <= a*b 是 DSP 推断的经典模式, Vivado 会把
  //   它塞进 DSP48 的 MREG/PREG —— 乘法那一段就完全不出寄存器了。
  //   代价: 每次乘法多占 1 拍 (见下面的 busy 逻辑)。
  logic signed [63:0] prod_ss;
  logic        [63:0] prod_uu;

  always @(posedge clk) begin
    prod_ss <= $signed(a) * $signed(b);
    prod_uu <= a * b;
  end

  wire [31:0] mulhsu_hi = prod_ss[63:32] + (b[31] ? a : 32'd0);

  // ------------------------------------------------------------------------
  // 操作分类
  // ------------------------------------------------------------------------
  wire is_div_op    = (op == ALU_DIV) || (op == ALU_DIVU) ||
                      (op == ALU_REM) || (op == ALU_REMU);
  wire is_signed_op = (op == ALU_DIV) || (op == ALU_REM);
  wire want_rem     = (op == ALU_REM) || (op == ALU_REMU);

  // ------------------------------------------------------------------------
  // 除法: 32 步无符号恢复余数 + 外层符号修正
  // ------------------------------------------------------------------------
  logic [5:0]  cnt;              // 0 = 空闲
  logic [31:0] dvnd, dvsr;
  logic [32:0] rem;              // 【33 位】
  logic [31:0] quo;
  logic        q_sign, r_sign;
  logic        busy_r;           // 正在迭代
  logic        done_r;           // 单拍脉冲: 本次除法刚出结果
  logic [31:0] div_result;

  wire [31:0] a_abs = (is_signed_op && a[31]) ? (~a + 32'd1) : a;
  wire [31:0] b_abs = (is_signed_op && b[31]) ? (~b + 32'd1) : b;
  wire        a_neg = is_signed_op && a[31];
  wire        b_neg = is_signed_op && b[31];

  wire div_zero = (b == 32'd0);
  wire div_ovf  = is_signed_op && (a == 32'h8000_0000) && (b == 32'hFFFF_FFFF);

  // ---------------------------------------------------------------------------
  // 【待办 #1 已完成 · 插桩已移除】muldiv 那 3.1% 的构成 —— 实测结论
  // ---------------------------------------------------------------------------
  // 问题: `profile` 报 `stall_muldiv` = 14,415 拍 = 3.1% 总周期。
  //       但这 3.1% 里"32 步迭代"(radix-4 能砍半)与"启动/收尾固定开销"
  //       (radix-4 砍不掉) 各占多少? —— 这决定待办 #8 的上限。
  //
  // 实测 (CoreMark, 计数器插在 muldiv 内, 每次除法收尾打印累计值):
  //   除法总条数          84 条
  //   累计 busy           2,897 拍  (其中纯迭代 2,687 拍 -> **迭代占 92.7%**)
  //   平均每次除法        总 ~34.5 拍, 迭代 ~32 拍 (与 32 步恢复余数法一致)
  //
  // 【结论: 待办 #8 (radix-4) 判定不做】
  //   radix-4 (32->16 步) 每次省 ~16 拍, 84 条共省 ~1,344 拍
  //   = 468,659 的 **0.29%** -> 对 CoreMark/MHz 几乎无影响。
  //
  //   更关键: `stall_muldiv` 那 14,415 拍里**绝大部分不是除法**(84 条除法
  //   最多只占 ~2,900 拍), 而是**乘法的启动拍** —— radix-4 对乘法毫无帮助。
  //   而加深 muldiv 的组合(其输出正对 EX/MEM, 路径含 DSP48E1x2 -> 13 级
  //   CARRY4)有掉 fmax 的风险, 收益却只有 0.29% -> **明确的净亏**。
  // ---------------------------------------------------------------------------

  // 一次迭代的组合结果
  wire [32:0] rem_shift = {rem[31:0], dvnd[31]};
  wire [32:0] rem_sub   = rem_shift - {1'b0, dvsr};
  wire        rem_ge    = (rem_shift >= {1'b0, dvsr});
  wire [32:0] rem_n     = rem_ge ? rem_sub : rem_shift;
  wire [31:0] quo_n     = {quo[30:0], rem_ge};

  wire [31:0] rem_final = r_sign ? (~rem_n[31:0] + 32'd1) : rem_n[31:0];
  wire [31:0] quo_final = q_sign ? (~quo_n + 32'd1) : quo_n;

  // 【busy 必须覆盖"启动那一拍"】
  //   若 busy 只在 busy_r 有效, 启动拍流水线不被冻结, DIV 会在结果出来前
  //   就离开 EX (实测: m_ext 的第 6 组一上来就失败)。
  // 【收尾必须让 busy 在结果被捕获的那一拍之前落下】
  //   EX/MEM 与 MEM/WB 由 hold_mem (= ex_busy) 冻结: busy 若多停一拍,
  //   捕获窗口就错过, DIV 的结果永远进不了 EX/MEM。
  //   所以末次迭代 (cnt==1) 就拉低 busy_r 并给出一拍 done_r 脉冲。
  // 统一判据: 只要"结果还没寄存进 div_result"就必须冻结流水线。
  //   - 多周期: 启动拍 (busy_r 还是 0) 与迭代期间
  //   - 单周期: 除零 / 溢出 —— 它们同样要占一拍, 否则结果和指令在同一个
  //     时钟沿离开 EX, EX/MEM 捕获到的是上一次的 div_result。
  //     (实测: m_ext 第 8 组除零就是栽在这里)
  wire is_mul_op = (op == ALU_MUL) || (op == ALU_MULH) ||
                   (op == ALU_MULHSU) || (op == ALU_MULHU);

  wire special = div_zero || div_ovf;
  assign busy = busy_r                                                     // 除法迭代中
              || (is_mul_op && !done_r)                                    // 乘法: 启动拍 (乘积正在寄存)
              || (is_div_op && !done_r && (special || !busy_r));           // 除法: 启动拍 / 单周期特例

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      busy_r     <= 1'b0;
      done_r     <= 1'b0;
      cnt        <= 6'd0;
      dvnd       <= 32'd0;
      dvsr       <= 32'd0;
      rem        <= 33'd0;
      quo        <= 32'd0;
      q_sign     <= 1'b0;
      r_sign     <= 1'b0;
      div_result <= 32'd0;
    end
    else begin
      done_r <= 1'b0;                       // 默认清零 (单拍脉冲)
      if (busy_r) begin
        dvnd <= {dvnd[30:0], 1'b0};
        rem  <= rem_n;
        quo  <= quo_n;
        cnt  <= cnt - 6'd1;
        if (cnt == 6'd1) begin              // 末次迭代
          div_result <= want_rem ? rem_final : quo_final;
          busy_r     <= 1'b0;
          done_r     <= 1'b1;
        end
      end
      else if (is_mul_op) begin
        // 乘积已在本拍的时钟沿寄存进 DSP 输出寄存器; 下一拍 done_r=1,
        // busy 落下, EX/MEM 才捕获结果。
        if (!done_r) done_r <= 1'b1;
      end
      else if (is_div_op) begin
        if (div_zero) begin
          div_result <= want_rem ? a : 32'hFFFF_FFFF;        // 除零
          done_r     <= 1'b1;                                // 下一拍才放行
        end
        else if (div_ovf) begin
          div_result <= want_rem ? 32'd0 : 32'h8000_0000;    // 溢出
          done_r     <= 1'b1;
        end
        else if (!done_r) begin
          busy_r <= 1'b1;                   // 启动
          cnt    <= 6'd32;
          dvnd   <= a_abs;
          dvsr   <= b_abs;
          rem    <= 33'd0;
          quo    <= 32'd0;
          q_sign <= a_neg ^ b_neg;
          r_sign <= a_neg;
        end
      end
    end
  end

  // ------------------------------------------------------------------------
  // 结果选择
  // ------------------------------------------------------------------------
  always_comb begin
    if (!is_div_op) begin
      case (op)
        ALU_MUL:    result = prod_ss[31:0];
        ALU_MULH:   result = prod_ss[63:32];
        ALU_MULHSU: result = mulhsu_hi;
        ALU_MULHU:  result = prod_uu[63:32];
        default:    result = 32'd0;
      endcase
    end
    else result = div_result;
  end

endmodule
