`timescale 1ns/1ps

// ============================================================================
// tb_sw_nn_job.sv — S1 单时钟 job 模式 SoC 级测试台（task-13）
// ----------------------------------------------------------------------------
// 与 tb_sw.sv 的关系：**独立 TB，不改 tb_sw**（Lead 要求先问再动 tb_sw）。
// 接线按 top_a100t.sv 的 NN_EN 分支复刻（tb_sw 不能例化 top_a100t：后者有 MMCM 原语，
// ModelSim 不加载 unisim）—— 与 sim/tb_sw.sv:83-144 的接线逐项一致。
//
// 被测程序：sim/prog/nn_job_demo.hex（+ dmem），由 sw/nn_job_demo.c 生成。
// 判据：
//   · 程序写 tohost==1（report_done）→ 打印日志 + `NN_JOB_TB: PASS`
//   · tohost==2 或其它值 / 超时 / 非法指令 / 未打印 RESULT : PASS → FAIL（$fatal）
// 另：把程序日志缓冲区（0x9000_3000）在结束时 dump 出来，便于读 [nnjob] 行。
//
// 运行（workflow 注册前的手动入口）：
//   python sim/run_prog.py --top tb_sw_nn_job --tb sim/tb_sw_nn_job.sv \
//       --imem sim/prog/nn_job_demo.hex --dmem sim/prog/nn_job_demo.dmem.hex \
//       --plus +nnwq=sim/prog/yolo/yolo_wq.hex +max_cycles=30000000
// ============================================================================
module tb_sw_nn_job;
  import rv32_pkg::*;

  localparam time TCLK_HALF = 10ns;      // 50 MHz（与 tb_sw 同频；job 模式单时钟）

  localparam logic [31:0] TOHOST_ADDR = DMEM_BASE + 32'h2000;
  localparam int unsigned TOHOST_IDX  = (TOHOST_ADDR - DMEM_BASE) / 4;
  localparam logic [31:0] LOG_ADDR    = 32'h9000_3000;
  localparam int unsigned LOG_IDX     = (LOG_ADDR - DMEM_BASE) / 4;
  localparam int unsigned LOG_MAX     = 4096;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #(TCLK_HALF) clk = ~clk;

  int unsigned cycles = 0;
  int unsigned max_cycles = 30_000_000;
  bit finished = 1'b0;
  bit pass_seen = 1'b0;

  // ---- core 观测/总线 ----
  logic [31:0] dbg_pc, dbg_id_pc, dbg_instr, dbg_rdata, dbg_mem_addr, dbg_mem_wdata;
  logic        dbg_illegal, dbg_mem_we;
  logic        ext_we, ext_re, uart_txd, uart_rxd;
  logic [31:0] ext_addr, ext_wdata, ext_rdata;
  logic [3:0]  ext_wstrb;
  logic [31:0] gpio_out, tx_bytes, rx_bytes;
  // 声明必须在例化之前（否则具名端口连接会隐式声明 -> vlog-2388）
  logic        irq_timer;

  logic        nn_we, nn_re;
  logic [31:0] nn_addr, nn_wdata, nn_rdata;
  logic [3:0]  nn_wstrb;
  logic        nn_mmio_sel;
  logic [31:0] mmio_rdata, nn_ctl_rdata;
  logic        nn_busy, nn_done, nn_err;

  core u_dut (
    .clk (clk), .rst (rst),
    .dbg_pc (dbg_pc), .dbg_id_pc (dbg_id_pc), .dbg_instr (dbg_instr),
    .dbg_illegal (dbg_illegal),
    .dbg_raddr (5'd0), .dbg_rdata (dbg_rdata),
    .dbg_mem_we (dbg_mem_we), .dbg_mem_addr (dbg_mem_addr), .dbg_mem_wdata (dbg_mem_wdata),
    .ext_we (ext_we), .ext_re (ext_re), .ext_addr (ext_addr), .ext_wdata (ext_wdata),
    .ext_wstrb (ext_wstrb), .ext_rdata (ext_rdata),
    .irq_timer (irq_timer),
    .nn_we (nn_we), .nn_re (nn_re), .nn_addr (nn_addr),
    .nn_wdata (nn_wdata), .nn_wstrb (nn_wstrb), .nn_rdata (nn_rdata)
  );

  mmio_subsys #(.CLK_HZ(50_000_000), .BAUD_HZ(115_200)) u_mmio (
    .clk (clk), .rst (rst),
    .we (ext_we), .re (ext_re), .addr (ext_addr), .wdata (ext_wdata), .wstrb (ext_wstrb),
    .rdata (mmio_rdata),
    .gpio_out (gpio_out), .gpio_in (32'h0),
    .uart_txd (uart_txd), .uart_rxd (uart_rxd),
    .tx_byte_count (tx_bytes), .rx_byte_count (rx_bytes),
    .irq_timer (irq_timer)
  );

  // ---- AI 加速子系统：控制寄存器段回选 + nn_subsys（与 tb_sw.sv:129-144 一致）----
  assign nn_mmio_sel = (ext_addr[31:8] == 24'hA00001);
  assign ext_rdata   = nn_mmio_sel ? nn_ctl_rdata : mmio_rdata;

  nn_subsys u_nn (
    .clk (clk), .rst (rst),
    .ctl_we (ext_we && nn_mmio_sel), .ctl_re (ext_re && nn_mmio_sel),
    .ctl_addr (ext_addr), .ctl_wdata (ext_wdata), .ctl_wstrb (ext_wstrb),
    .ctl_rdata (nn_ctl_rdata),
    .cpu_re (nn_re), .cpu_we (nn_we), .cpu_addr (nn_addr),
    .cpu_wdata (nn_wdata), .cpu_wstrb (nn_wstrb), .cpu_rdata (nn_rdata),
    .busy_o (nn_busy), .done_o (nn_done), .err_o (nn_err),
    .cycles_o (), .err_code_o ()
  );

  wire [31:0] tohost_word = u_dut.u_dmem.mem[TOHOST_IDX];

  // ---- 程序日志 dump（0x9000_3000，NUL 结尾；与 tb_sw 同口径）----
  task automatic dump_log;
    begin
      $write("  --- program output ---\n");
      for (int i = 0; i < LOG_MAX; i++) begin
        logic [7:0] b;
        b = u_dut.u_dmem.mem[LOG_IDX + i/4] >> (8 * (i % 4));
        if (b == 8'h00) break;
        $write("%c", b);
      end
      $display("  --- end of output ---");
    end
  endtask

  // ---- 启动 ----
  initial begin : boot
    string f;
    if ($value$plusargs("dump=%s", f)) begin $dumpfile(f); $dumpvars(0, tb_sw_nn_job); end
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 30_000_000;
    repeat (4) @(posedge clk);
    rst = 1'b0;
    $display("[tb_sw_nn_job] reset released, max_cycles=%0d", max_cycles);
  end

  // ---- 主循环 ----
  always_ff @(posedge clk) begin
    if (!rst && !finished) begin
      cycles <= cycles + 1;

      if (cycles > max_cycles) begin
        finished = 1'b1;
        $display("[tb_sw_nn_job] FAIL: timeout (%0d cycles), id_pc=0x%08x instr=0x%08x",
                 max_cycles, dbg_id_pc, dbg_instr);
        dump_log();
        $fatal(1);
      end

      if (dbg_illegal) begin
        finished = 1'b1;
        $display("[tb_sw_nn_job] FAIL: illegal instruction id_pc=0x%08x instr=0x%08x",
                 dbg_id_pc, dbg_instr);
        dump_log();
        $fatal(1);
      end

      if (tohost_word == 32'd1) begin
        finished  = 1'b1;
        pass_seen = 1'b1;
      end
      else if (tohost_word != 32'd0) begin
        finished = 1'b1;
        $display("[tb_sw_nn_job] FAIL: tohost=0x%08x (not 1), id_pc=0x%08x",
                 tohost_word, dbg_id_pc);
        dump_log();
        $fatal(1);
      end
    end
  end

  // ---- 结束：等 8 拍让日志缓冲落盘，再 dump + 判据 ----
  initial begin : finish_check
    @(finished);
    repeat (8) @(posedge clk);
    dump_log();
    $display("[tb_sw_nn_job] cycles=%0d nn_busy=%0b nn_done=%0b nn_err=%0b",
             cycles, nn_busy, nn_done, nn_err);
    if (pass_seen) begin
      $display("NN_JOB_TB: PASS");
      $finish;
    end else begin
      $display("NN_JOB_TB: FAIL (no tohost==1)");
      $fatal(1);
    end
  end

  // 常规仿真看门狗（plusarg +watchdog_ms，与 tb_sw 一致；默认 3000 ms）
  initial begin : watchdog
    int unsigned wd_ms;
    if (!$value$plusargs("watchdog_ms=%d", wd_ms)) wd_ms = 3000;
    #(1ms * wd_ms);
    if (!finished) begin
      $display("[tb_sw_nn_job] FAIL: wall-clock watchdog (%0d ms), cycles=%0d, id_pc=0x%08x",
               wd_ms, cycles, dbg_id_pc);
      dump_log();
      $fatal(1);
    end
  end

endmodule
