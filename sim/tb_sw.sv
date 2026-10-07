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
  // 【声明必须在例化之前】具名端口连接 `.irq_timer (irq_timer)` 里若 irq_timer
  // 尚未声明, 仿真器会在此处**隐式声明**一条 net; 之后那句 `logic irq_timer;`
  // 就变成重复声明 -> vlog-2388 'already declared in this scope'。
  // (实测踩过: 把声明写在例化后面, tb_sw/tb_soc 全部编译失败)
  logic        irq_timer;

  core u_dut (
    .clk (clk), .rst (rst),
    .dbg_pc (dbg_pc), .dbg_id_pc (dbg_id_pc), .dbg_instr (dbg_instr),
    .dbg_illegal (dbg_illegal),
    .dbg_raddr (5'd0), .dbg_rdata (dbg_rdata),
    .dbg_mem_we (dbg_mem_we), .dbg_mem_addr (dbg_mem_addr), .dbg_mem_wdata (dbg_mem_wdata),
    .ext_we (ext_we), .ext_re (ext_re), .ext_addr (ext_addr), .ext_wdata (ext_wdata),
    .ext_wstrb (ext_wstrb), .ext_rdata (ext_rdata),
    .irq_timer (irq_timer)
  );

  mmio_subsys #(.CLK_HZ(50_000_000), .BAUD_HZ(115_200)) u_mmio (
    .clk (clk), .rst (rst),
    .we (ext_we), .re (ext_re), .addr (ext_addr), .wdata (ext_wdata), .wstrb (ext_wstrb),
    .rdata (ext_rdata),
    .gpio_out (gpio_out), .gpio_in (32'h0),
    .uart_txd (uart_txd), .uart_rxd (uart_rxd),
    .tx_byte_count (tx_bytes), .rx_byte_count (rx_bytes),
    .irq_timer (irq_timer)
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
  // 【为什么要数 load】用周期换频率的改动必须先把账算平: 例如"让 load 在 MEM
  //   多停一拍"会让**每一次 load** 都多花 1 拍, 代价 = n_load / cycles。
  //   没有这个数就只能凭感觉估。
  int unsigned n_load = 0;       // load 在 MEM 且流水线前进的周期数 ≈ load 条数
  // 预测器精度
  int unsigned n_ctrl = 0;       // 控制流指令数 (每条做一次预测)
  int unsigned n_mis  = 0;       // 预测错误数
  // 【按类型分】决定下一步该优化哪一类预测器:
  //   条件分支错多 -> 方向预测器 (2 位 Smith / 更深的表)
  //   JALR(返回) 错多 -> 需要 RAS (返回地址栈)
  int unsigned n_mis_br = 0, n_mis_jal = 0, n_mis_jalr = 0;
  // 【条件分支误判再细分】决定该修 BTB 组织还是方向预测器:
  //   BTB 没命中      -> 预测"不跳", 若实际 taken 则误判 => 该扩表 / 改组织
  //   BTB 命中但方向错 -> 表命中了, 2 位计数器的方向判断错了 => 该改方向预测器
  int unsigned n_align_err = 0;    // 取指对齐自检失败次数 (必须为 0)
  int unsigned n_ras_push = 0, n_ras_pop = 0, n_ras_nonempty = 0;  // RAS 自证
  int unsigned n_pred_is_ret = 0, n_ras_diff = 0;   // 预测被判为返回的次数 / 与 BTB 目标不同的次数
  int unsigned n_mis_br_nohit = 0, n_mis_br_dir = 0;
  int unsigned n_br_hit = 0, n_br_nohit = 0;      // 条件分支的 BTB 命中情况

  // 复现 btb.sv 的"有没有表项"判据 (纯观测用)。
  // btb 实例化参数: IDX_BITS=6, PC_TOP=14 -> 6 位索引 + 6 位 tag。
  // btb.sv 原文: pidx = pc[IDX_BITS+1:2], ptag = pc[PC_TOP-1:IDX_BITS+2]
  //              pred_hit = vld[pidx] && (tag[pidx] == ptag)
  function automatic logic btb_has_entry(input logic [31:0] pc);
    logic [5:0] idx;
    logic [5:0] tg;
    begin
      idx = pc[7:2];
      tg  = pc[13:8];
      btb_has_entry = u_dut.u_btb.vld[idx] && (u_dut.u_btb.tag[idx] == tg);
    end
  endfunction

  always @(posedge clk) begin
    if (!rst) begin
      // ----------------------------------------------------------------------
      // 【取指对齐自检】if_pc 处的指令字必须真的等于 if_instr。
      // 为什么必须有这条: 一旦取指存储器改成寄存读, rdata 会比 addr 晚一拍;
      // 若 PC 与指令没有做对应的相位对齐, 就变成"pc_N 配 instr(pc_{N-1})",
      // 症状是程序行为莫名错乱(先是 timeout, 之后是某个测试组失败), 而
      // RTL 语法/编译全部正常 —— 属于极难定位的静默错位。
      // 这条检查把"错位"变成一行直接报错。
      //
      // 两个坑 (都实测踩过, 见注释避免后人重踩):
      //  1) 索引位宽必须是 imem 真实的 AW 位, 不是随便切 16 位。
      //     16KB = 4096 字 -> AW=12 -> 用 if_pc[13:2]。
      //  2) **flush 那一拍 if_id 里留的是上一拍的旧值, 而且 pc 被清成 0**。
      //     所以必须跳过 flush 的拍, 否则会在 pc=0 上报一堆假错位。
      //     用 if_pc==0 作废值判据 (PC_RESET=0x8000_0000, 合法 PC 不会是 0)。
      // ----------------------------------------------------------------------
      //  3) 前几拍要跳过: imem 的 initial 先把整块填成 NOP, $readmemh 在同一次
      //     initial 里随后才覆盖。复位期间 if_id 先锁到的是"填 NOP 阶段"的内容,
      //     于是 cycle 0 会报一次假错位。用 cycles 门限跳过启动窗口。
      if (cycles > 4 && !u_dut.if_id_flush && u_dut.if_pc != 32'd0) begin
        logic [31:0] exp_instr;
        exp_instr = u_dut.u_imem.mem[u_dut.if_pc[13:2]];
        if (u_dut.if_instr !== exp_instr) begin
          n_align_err++;
          if (n_align_err <= 5)
            $display("[ALIGN] cycle %0d: if_pc=0x%08x if_instr=0x%08x 期望 0x%08x  <-- 取指错位!",
                     cycles, u_dut.if_pc, u_dut.if_instr, exp_instr);
        end
      end

      if (!u_dut.if_id_flush && !u_dut.pipe_stall) n_fetch++;
      if (u_dut.redirect)    n_redirect++;
      if (u_dut.pipe_stall)  n_stall++;
      if (u_dut.lsu_stall)   n_stall_lsu++;
      if (u_dut.mem_wb_ctrl != '0) n_wb++;

      // 停顿构成 (pipe_stall = load_use || lsu_stall || ex_busy)
      if (u_dut.u_hazard.load_use) n_stall_lu++;   // load_use 在 hazard_unit 内部
      if (u_dut.lsu_stall) n_stall_ls++;
      if (u_dut.md_busy)   n_stall_ex++;
      // load 在 MEM 段且本拍流水线前进 -> 一次 load "消耗" 一个 MEM 周期
      if (u_dut.ex_mem_ctrl.mem_read && !u_dut.pipe_stall) n_load++;

      // RAS 自证 (仅在 RAS_EN 打开时存在)
`ifdef RAS_EN
      if (u_dut.ex_is_call)      n_ras_push++;
      if (u_dut.ex_is_ret)       n_ras_pop++;
      if (!u_dut.u_ras.empty)    n_ras_nonempty++;
      // 预测时"这条 PC 被识别为返回"以及"RAS 目标与 BTB 目标不同"的次数。
      // 若 pred_is_ret 一直是 0, 说明 is_ret 标记没起作用 (而非 RAS 无用) ——
      // 这个区分非常关键: 实测就先踩过"只把 is_ret 写进 gshare 分支、
      // 默认的 Smith 分支没写", 导致 RAS 压栈弹栈都正常却完全不改变预测。
      if (u_dut.pred_is_ret) begin
        n_pred_is_ret++;
        if (u_dut.ras_top !== u_dut.btb_pred_target) n_ras_diff++;
      end
`endif

      // 预测器精度: 每条控制流指令做一次预测 (停顿期间不重复计)
      if (u_dut.id_ex_ctrl.pc_sel != 2'd0) begin
        if (!u_dut.pipe_stall) n_ctrl++;
        if (u_dut.redirect_raw) n_mis++;
      end
      // 按类型统计预测错误 (pc_sel: 1=BR 2=J 3=JR)
      if (u_dut.redirect_raw && !u_dut.pipe_stall) begin
        if      (u_dut.id_ex_ctrl.pc_sel == 2'd1) n_mis_br++;
        else if (u_dut.id_ex_ctrl.pc_sel == 2'd2) n_mis_jal++;
        else if (u_dut.id_ex_ctrl.pc_sel == 2'd3) n_mis_jalr++;
      end
      // 【条件分支误判再细分】纯观测 (层次化读 BTB 阵列, 不改 RTL)。
      // 目的: 分清两种完全不同的病因 ——
      //   (a) BTB 没表项 -> 只能预测"不跳"; 若实际 taken 就是"容量/冲突"问题
      //   (b) BTB 有表项但方向计数器判反 -> 是"方向预测器"问题
      // 修法完全不同, 必须先分清。
      // 做法: 用与 btb.sv 完全相同的 index/tag 切片, 在 EX 段 PC 上复现它的
      // 组合读公式 (btb.sv: pidx=pc[IDX+1:2], ptag=pc[PC_TOP-1:IDX+2])。
      if (u_dut.id_ex_ctrl.pc_sel == 2'd1) begin
        if (btb_has_entry(u_dut.id_ex_pc)) n_br_hit++;
        else                         n_br_nohit++;
        if (u_dut.redirect_raw && !u_dut.pipe_stall) begin
          if (btb_has_entry(u_dut.id_ex_pc)) n_mis_br_dir++;
          else                         n_mis_br_nohit++;
        end
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
    // 【代价估算用】每让一次 load 多占 1 个 MEM 周期, 时间就多 n_load/cycles
    $display("  load(MEM)  = %0d  (%0d%% of cycles)  <- 每次 load 多停 1 拍的代价就是这个百分比",
             n_load, (n_load * 100) / (cycles == 0 ? 1 : cycles));
    $display("  --- 取指对齐自检 (寄存读改动的守门人) ---");
    if (n_align_err != 0)
      $display("  *** 失败 %0d 次: if_pc 与 if_instr 不同源 (取指错位!) ***", n_align_err);
    else
      $display("  OK (0 次错位)");
`ifdef RAS_EN
    // RAS 自证: 必须能区分"RAS 没用"和"RAS 没生效"。
    // 实测踩过: is_ret 只写进了 gshare 分支, 默认的 Smith 分支没写 ->
    // 压栈/弹栈计数都正常, 但 pred_is_ret 恒为 0, 对误判毫无影响。
    $display("  --- RAS (返回地址栈) ---");
    $display("  push(call) = %0d   pop(ret) = %0d   栈顶非空拍数 = %0d",
             n_ras_push, n_ras_pop, n_ras_nonempty);
    $display("  预测判为返回 = %0d   其中 RAS 目标 != BTB 目标 = %0d",
             n_pred_is_ret, n_ras_diff);
    begin : btb_ret_count
      int unsigned n_ret_entries;
      n_ret_entries = 0;
      for (int bi = 0; bi < 64; bi++)
        if (u_dut.u_btb.vld[bi] && u_dut.u_btb.is_ret[bi]) n_ret_entries++;
      $display("  BTB 中 is_ret=1 的表项 = %0d (为 0 则标记没写进表)", n_ret_entries);
    end
`endif
    $display("  --- predictor accuracy ---");
    $display("  ctrl-flow  = %0d   mispredict = %0d   accuracy = %0d%%",
             n_ctrl, n_mis, n_ctrl == 0 ? 0 : 100 - (n_mis * 100) / n_ctrl);
    $display("  --- mispredict by type (决定下一个优化方向) ---");
    $display("  cond branch = %0d  (%0d%% of mispredicts)", n_mis_br,
             n_mis == 0 ? 0 : (n_mis_br * 100) / n_mis);
    $display("  JAL         = %0d  (%0d%%)", n_mis_jal,
             n_mis == 0 ? 0 : (n_mis_jal * 100) / n_mis);
    $display("  JALR        = %0d  (%0d%%)  <- 若这项大, RAS 才有价值", n_mis_jalr,
             n_mis == 0 ? 0 : (n_mis_jalr * 100) / n_mis);
    $display("  --- 条件分支: BTB 冲突 vs 方向预测 (决定改表组织还是改方向预测器) ---");
    $display("  条件分支总数 = %0d   BTB 有表项 = %0d (%0d%%)   无表项 = %0d (%0d%%)",
             n_br_hit + n_br_nohit, n_br_hit,
             (n_br_hit + n_br_nohit) == 0 ? 0 : (n_br_hit * 100) / (n_br_hit + n_br_nohit),
             n_br_nohit,
             (n_br_hit + n_br_nohit) == 0 ? 0 : (n_br_nohit * 100) / (n_br_hit + n_br_nohit));
    $display("  误判细分: 无表项(容量/冲突) = %0d   有表项但方向错 = %0d",
             n_mis_br_nohit, n_mis_br_dir);
    $display("           无表项占条件分支误判 %0d%% (这项大 => 该扩容/改组织)",
             n_mis_br == 0 ? 0 : (n_mis_br_nohit * 100) / n_mis_br);
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
