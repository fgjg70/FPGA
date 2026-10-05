`timescale 1ns/1ps

// ============================================================================
// tb_sw.sv — 通用裸机程序测试台 (core + mmio_subsys)
// ----------------------------------------------------------------------------
// 用途: 跑任意 C/汇编程序, 程序结束(写 tohost=1)后把 dmem 里的日志缓冲区
//       当字符串 dump 出来。这样即使没有串口也能拿到程序输出。
//
// 约定 (见 sw/link.ld):
//   tohost    = 0x90002000  写 1 = 正常结束
//   log 缓冲区 = 0x90003000 .. 0x90003FFF  NUL 结尾
//
// plusarg:
//   +imem=<file>        程序 hex
//   +max_cycles=<N>     超时周期数 (默认 2_000_000; CoreMark 需要调大)
//   +dump=<file>        VCD 波形 (可选)
// ============================================================================

module tb_sw;
  import rv32_pkg::*;

  localparam time TCLK_HALF = 10ns;      // 50 MHz

  // tohost 约定地址 = DMEM_BASE + 0x2000 (见 sw/link.ld)
  localparam logic [31:0] TOHOST_ADDR = DMEM_BASE + 32'h2000;
  localparam int unsigned TOHOST_IDX  = (TOHOST_ADDR - DMEM_BASE) / 4;
  localparam logic [31:0] LOG_ADDR    = 32'h90003000;
  localparam int unsigned LOG_IDX     = (LOG_ADDR - DMEM_BASE) / 4;
  localparam int unsigned LOG_MAX     = 4096;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #(TCLK_HALF) clk = ~clk;

  int unsigned cycles = 0;
  int unsigned max_cycles = 2000000;
  bit finished = 1'b0;
  bit pass_seen = 1'b0;

  logic [31:0] dbg_pc, dbg_id_pc, dbg_instr, dbg_rdata, dbg_mem_addr, dbg_mem_wdata;
  logic        dbg_illegal, dbg_mem_we;
  logic        ext_we, ext_re, uart_txd, uart_rxd;
  logic [31:0] ext_addr, ext_wdata, ext_rdata;
  logic [3:0]  ext_wstrb;
  logic [31:0] gpio_out, tx_bytes, rx_bytes;

  core u_dut (
    .clk (clk), .rst (rst),
    .dbg_pc (dbg_pc), .dbg_id_pc (dbg_id_pc), .dbg_instr (dbg_instr),
    .dbg_illegal (dbg_illegal),
    .dbg_raddr (5'd0), .dbg_rdata (dbg_rdata),
    .dbg_mem_we (dbg_mem_we), .dbg_mem_addr (dbg_mem_addr), .dbg_mem_wdata (dbg_mem_wdata),
    .ext_we (ext_we), .ext_re (ext_re), .ext_addr (ext_addr), .ext_wdata (ext_wdata),
    .ext_wstrb (ext_wstrb), .ext_rdata (ext_rdata)
  );

  mmio_subsys #(.CLK_HZ(50_000_000), .BAUD_HZ(115_200)) u_mmio (
    .clk (clk), .rst (rst),
    .we (ext_we), .re (ext_re), .addr (ext_addr), .wdata (ext_wdata), .wstrb (ext_wstrb),
    .rdata (ext_rdata),
    .gpio_out (gpio_out), .gpio_in (32'h0),
    .uart_txd (uart_txd), .uart_rxd (uart_rxd),
    .tx_byte_count (tx_bytes), .rx_byte_count (rx_bytes)
  );

  wire [31:0] tohost_word = u_dut.u_dmem.mem[TOHOST_IDX];

  // ---- 上板跑分上报路径监视 ----
  // 软件在测量区间起点写 MMIO_MARK, 结束时把最终 tick 数写进 MMIO_RESULT。
  // 上板时这两个信号喂给 ILA (串口不通, 只能走 JTAG 读回), 这里先在仿真里
  // 确认软件确实写了、值也对 —— 免得白跑一次 10 秒的上板实验。
  localparam logic [31:0] MMIO_MARK_A   = 32'hA000_0020;
  localparam logic [31:0] MMIO_RESULT_A = 32'hA000_0024;
  logic        saw_mark, saw_result;
  logic [31:0] hw_result;
  always @(posedge clk) begin
    if (rst) begin
      saw_mark   <= 1'b0;
      saw_result <= 1'b0;
      hw_result  <= 32'd0;
    end
    else begin
      if (ext_we && (ext_addr == MMIO_MARK_A))   saw_mark   <= 1'b1;
      if (ext_we && (ext_addr == MMIO_RESULT_A)) begin
        saw_result <= 1'b1;
        hw_result  <= ext_wdata;
      end
    end
  end

  // ---- 启动 ----
  initial begin : boot
    begin
      string f;
      if ($value$plusargs("dump=%s", f)) begin $dumpfile(f); $dumpvars(0, tb_sw); end
    end
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 2000000;
    repeat (4) @(posedge clk);
    rst = 1'b0;
    $display("[tb_sw] reset released, max_cycles=%0d", max_cycles);
  end

  // ---- 主循环 ----
  always_ff @(posedge clk) begin
    if (!rst && !finished) begin
      cycles <= cycles + 1;

      if (cycles > max_cycles) begin
        finished = 1'b1;
        $display("[tb_sw] FAIL: timeout (%0d cycles), id_pc=0x%08x instr=0x%08x",
                 max_cycles, dbg_id_pc, dbg_instr);
        $fatal(1);
      end

      if (dbg_illegal) begin
        finished = 1'b1;
        $display("[tb_sw] FAIL: illegal instruction id_pc=0x%08x instr=0x%08x",
                 dbg_id_pc, dbg_instr);
        $fatal(1);
      end

      if (tohost_word == 32'd1) begin
        finished  = 1'b1;
        pass_seen = 1'b1;
      end
      else if (tohost_word != 32'd0) begin
        finished = 1'b1;
        $display("[tb_sw] FAIL: tohost=0x%08x (not 1), id_pc=0x%08x",
                 tohost_word, dbg_id_pc);
        $fatal(1);
      end
    end
  end

  // ---- 性能剖析 (层次化引用 core 内部信号; 纯仿真手段, 不改 RTL) ----
  // 目的: 在优化之前先量清楚周期花在哪 —— 分支惩罚、load-use 停顿、拆分访存。
  int unsigned n_fetch = 0;      // IF/ID 前进的周期数 ≈ 取回指令数
  int unsigned n_redirect = 0;   // 重定向次数 (taken 分支 / JAL / JALR)
  int unsigned n_stall = 0;      // pipe_stall 周期数
  int unsigned n_stall_lsu = 0;  // 其中拆分访存造成的
  int unsigned n_wb = 0;         // MEM/WB 非气泡周期数 ≈ 退休指令数(不含 NOP)
  // 重定向分类: 决定分支预测该怎么做
  int unsigned n_bcond = 0;      // 条件分支 *总数* (不论跳不跳)
  int unsigned n_br_taken = 0;   // 条件分支 taken (BEQ/BNE/BLT/...)
  int unsigned n_jal = 0;        // JAL
  int unsigned n_jalr = 0;       // JALR (函数返回/间接跳转 —— 有 BTB 也难预测)
  // 停顿构成 (决定下一步该优化什么)
  int unsigned n_stall_lu = 0;   // load-use 停顿
  int unsigned n_stall_ls = 0;   // 拆分访存停顿
  int unsigned n_stall_ex = 0;   // 多周期执行单元忙 (乘除法)
  // 预测器精度
  int unsigned n_ctrl = 0;       // 控制流指令数 (每条做一次预测)
  int unsigned n_mis  = 0;       // 预测错误数

  always @(posedge clk) begin
    if (!rst) begin
      if (!u_dut.if_id_flush && !u_dut.pipe_stall) n_fetch++;
      if (u_dut.redirect)    n_redirect++;
      if (u_dut.pipe_stall)  n_stall++;
      if (u_dut.lsu_stall)   n_stall_lsu++;
      if (u_dut.mem_wb_ctrl != '0) n_wb++;

      // 停顿构成 (pipe_stall = load_use || lsu_stall || ex_busy)
      if (u_dut.u_hazard.load_use) n_stall_lu++;   // load_use 在 hazard_unit 内部
      if (u_dut.lsu_stall) n_stall_ls++;
      if (u_dut.md_busy)   n_stall_ex++;

      // 预测器精度: 每条控制流指令做一次预测 (停顿期间不重复计)
      if (u_dut.id_ex_ctrl.pc_sel != 2'd0) begin
        if (!u_dut.pipe_stall) n_ctrl++;
        if (u_dut.redirect_raw) n_mis++;
      end

      // pc_sel_e: PC_NEXT=0 PC_BR=1 PC_J=2 PC_JR=3
      if (u_dut.id_ex_ctrl.pc_sel == 2'd1) begin
        n_bcond++;
        if (u_dut.redirect) n_br_taken++;
      end
      if (u_dut.redirect) begin
        if (u_dut.id_ex_ctrl.pc_sel == 2'd2) n_jal++;
        if (u_dut.id_ex_ctrl.pc_sel == 2'd3) n_jalr++;
      end
    end
  end

  // ---- PC 轨迹 (调试用, +trace 开启; 每 2000 周期采一次) ----
  bit trace_on = 1'b0;
  initial if ($test$plusargs("trace")) trace_on = 1'b1;

  // 逐拍窗口: +trace 从第 20000 拍起打印 60 拍, 带关键内部信号
  always @(posedge clk) begin
    if (!rst && trace_on && cycles >= 2140 && cycles < 2200)
      $display("[trace] c=%0d pc=%08x pT=%b pTgt=%08x mis=%b stall=%b idpc=%08x sel=%0d aT=%b aTgt=%08x exT=%b",
               cycles, dbg_pc, u_dut.pred_taken, u_dut.pred_target,
               u_dut.redirect_raw, u_dut.pipe_stall,
               u_dut.id_ex_pc, u_dut.id_ex_ctrl.pc_sel,
               u_dut.actual_taken, u_dut.actual_target, u_dut.ex_taken);
  end

  // ---- x5 (t0) 写入追踪: 只在值落在 __umodsi3 区域时打印 ----
  always @(posedge clk) begin
    if (!rst && trace_on && u_dut.wb_reg_write && (u_dut.wb_rd == 5'd5)
        && (u_dut.wb_data >= 32'h8000_03a0) && (u_dut.wb_data <= 32'h8000_03d0))
      $display("[x5] c=%0d  at_pc=0x%08x   x5 <- 0x%08x",
               cycles, u_dut.mem_wb_pc_plus4 - 32'd4, u_dut.wb_data);
  end

  // ---- 日志 dump ----
  initial begin : dump_log
    wait (pass_seen);
    #(TCLK_HALF * 4);
    $display("=================================================");
    $display("  cycles = %0d", cycles);
    $write("  --- program output ---\n");
    for (int i = 0; i < LOG_MAX; i++) begin
      logic [7:0] b;
      b = u_dut.u_dmem.mem[LOG_IDX + i/4] >> (8 * (i % 4));
      if (b == 8'h00) break;
      $write("%c", b);
    end
    $display("  --- end of output ---");
    $display("  --- profile ---");
    $display("  cycles     = %0d", cycles);
    $display("  fetch      = %0d", n_fetch);
    $display("  retire(wb) = %0d", n_wb);
    $display("  redirects  = %0d   (每刺损失 2 拍 -> 约 %0d 周期 = %0d%%)",
             n_redirect, n_redirect * 2, (n_redirect * 200) / (cycles == 0 ? 1 : cycles));
    $display("  stalls     = %0d   (拆分访存 %0d) = %0d%%",
             n_stall, n_stall_lsu, (n_stall * 100) / (cycles == 0 ? 1 : cycles));
    $display("  --- hardware score reporting ---");
    $display("  MMIO_MARK written   = %0d", saw_mark);
    $display("  MMIO_RESULT written = %0d   value (ticks) = %0d", saw_result, hw_result);
    $display("  --- stall breakdown ---");
    $display("  load-use   = %0d  (%0d%%)", n_stall_lu, (n_stall_lu * 100) / (cycles == 0 ? 1 : cycles));
    $display("  split-mem  = %0d", n_stall_ls);
    $display("  muldiv busy= %0d", n_stall_ex);
    $display("  --- predictor accuracy ---");
    $display("  ctrl-flow  = %0d   mispredict = %0d   accuracy = %0d%%",
             n_ctrl, n_mis, n_ctrl == 0 ? 0 : 100 - (n_mis * 100) / n_ctrl);
    $display("  --- redirect breakdown ---");
    $display("  cond branch total = %0d  (taken %0d = %0d%%)",
             n_bcond, n_br_taken, n_bcond == 0 ? 0 : (n_br_taken * 100) / n_bcond);
    $display("  JAL  = %0d", n_jal);
    $display("  JALR = %0d   <- 函数返回, 简单 BTB 难以预测, 需要 RAS", n_jalr);
    if (n_wb != 0)
      $display("  CPI        = %0d.%02d  (cycles/wb)",
               cycles / n_wb, ((cycles * 100) / n_wb) % 100);
    $display("  RESULT : PASS");
    $finish;
  end

  // ---- 时间级看门狗 ----
  initial begin : watchdog
    #(500ms);
    $display("[tb_sw] FAIL: global timeout at %0t, tohost=0x%08x cycles=%0d",
             $time, tohost_word, cycles);
    $fatal(1);
  end

endmodule
