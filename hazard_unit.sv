`timescale 1ns/1ps

// ============================================================================
// hazard_unit.sv — 冒险处理 (前递 + load-use 停顿 + 重定向冲刷)
// ----------------------------------------------------------------------------
// 停顿来源 (二选一, 可同时发生):
//   1) load-use 冒险: EX 段的 load 结果要到 MEM/WB 才可用, 紧随其后的
//      依赖指令在 ID 段停一拍 (经典 1 拍). 此时向 ID/EX 注入气泡(load
//      已经离开 EX), 冻结 PC 与 IF/ID.
//   2) 拆分访存 (lsu_stall): 非对齐跨字访问在 MEM 段占 2 拍, 期间整条
//      流水线冻结; 依赖它的指令若已在 EX, 会在冻结期间重算, 到 load
//      结果落入 MEM/WB 的那一拍拿到正确操作数 (组合前递每拍重估, 冻结
//      期间的计算结果不会被锁存). 此时 ID/EX 保持, 不能注气泡.
//
// 重定向 (分支/JAL/JALR 在 EX 判定) 会被停顿门控抑制: 冻结期间 EX 中的
// 指令可能因操作数未就绪而算出错误的判定, 下一拍重算后再生效; 重定向
// 只冲刷两条年轻指令 (IF/ID、ID/EX).
// ============================================================================

module hazard_unit
  import rv32_pkg::*;
(
  // ID/EX: 当前在 EX 的指令
  input  logic [4:0] id_ex_rs1,
  input  logic [4:0] id_ex_rs2,
  input  logic       id_ex_mem_read,
  input  logic [4:0] id_ex_rd,

  // EX/MEM: 当前在 MEM 的指令
  input  logic       ex_mem_reg_write,
  input  logic       ex_mem_mem_read,
  input  logic [4:0] ex_mem_rd,

  // MEM/WB: 当前在 WB 的指令
  input  logic       mem_wb_reg_write,
  input  logic [4:0] mem_wb_rd,

  // IF/ID: 当前在 ID 的指令
  input  logic [4:0] if_id_rs1,
  input  logic [4:0] if_id_rs2,

  // 拆分访存与重定向请求
  input  logic       lsu_stall,
  input  logic       redirect_raw,

  // 前递选择与流水线控制
  output fwd_sel_e   fwd_a,
  output fwd_sel_e   fwd_b,
  output logic       pipe_stall,      // 冻结 PC / IF-ID / ID-EX
  output logic       id_ex_bubble,    // 向 ID/EX 注入气泡
  output logic       hold_mem,        // 冻结 EX/MEM 与 MEM/WB
  output logic       redirect         // 生效的重定向
);

  // load-use 冒险: EX 的 load 与 ID 的指令存在寄存器依赖
  logic load_use;
  always_comb begin
    load_use = id_ex_mem_read && (id_ex_rd != 5'd0) &&
               ((id_ex_rd == if_id_rs1) || (id_ex_rd == if_id_rs2));
  end

  assign pipe_stall   = load_use || lsu_stall;
  assign id_ex_bubble = load_use && !lsu_stall;
  assign hold_mem     = lsu_stall;
  assign redirect     = redirect_raw && !pipe_stall;

  // 前递: EX/MEM 优先于 MEM/WB; load 在 EX/MEM 段只有地址没有数据,
  // 因此 EX/MEM 前递源排除 load (依赖它的指令由 load-use 停顿保证
  // 等到 MEM/WB 才取数)
  //
  // 注意: 这里刻意用显式组合逻辑而非 function + 连续赋值调用。
  // 函数体引用了模块级信号 (ex_mem_rd 等), 而部分仿真器 (实测 iverilog)
  // 对 "连续赋值调用函数" 只把函数实参计入敏感列表, 模块级信号变化不会
  // 触发重算, 前递结果会变成陈旧值 —— 表现为难以定位的偶发数据错误。
  // 显式写法行为确定, 且综合结果相同。
  logic hit_ex_mem_a, hit_ex_mem_b, hit_mem_wb_a, hit_mem_wb_b;

  assign hit_ex_mem_a = ex_mem_reg_write && !ex_mem_mem_read &&
                        (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs1);
  assign hit_ex_mem_b = ex_mem_reg_write && !ex_mem_mem_read &&
                        (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs2);
  assign hit_mem_wb_a = mem_wb_reg_write &&
                        (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs1);
  assign hit_mem_wb_b = mem_wb_reg_write &&
                        (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs2);

  always_comb begin
    if (hit_ex_mem_a)      fwd_a = FWD_EX_MEM;
    else if (hit_mem_wb_a) fwd_a = FWD_MEM_WB;
    else                   fwd_a = FWD_REG;

    if (hit_ex_mem_b)      fwd_b = FWD_EX_MEM;
    else if (hit_mem_wb_b) fwd_b = FWD_MEM_WB;
    else                   fwd_b = FWD_REG;
  end

endmodule
