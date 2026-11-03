`timescale 1ns/1ps

// ============================================================================
// tb_sw_nn_slim.sv — M6a：瘦身模型（96x96，71 op）SoC 级 E2E 测试台（task-16）
// ----------------------------------------------------------------------------
// 与 tb_sw_nn_job.sv 同范式（独立 TB，不改 tb_sw）：复刻 tb_sw.sv:99-144 的
// core + mmio_subsys + nn_subsys 接线，50MHz 单时钟，NN_EN 编译。
//
// 与 job TB 的差异：
//   1. imem/dmem = sim/prog/slim_demo.hex / .dmem.hex（sw/slim_demo.c）
//   2. W/Q 镜像 = results/bottlecap/plan/slim/{w,q}.hex（由 workflow 以
//      +nnw= / +nnq= 传给 nn_mem 的仿真 loader；**不用 slim_wq.hex**，
//      因为 nn_mem 的 +nnwq 通道按 YOLO 固定行数 81920/12288 解析）
//   3. 真实图输入 0349（96x96x3 PACKED3，27,648 B）：reset 释放前由本 TB 从
//      +slim_input=<repo>/results/bottlecap/plan/slim/opvec/0349/input.hex
//      （6,912 行 u32 小端）**原样逐字节**写入 NN 窗口 A 区 offset 0
//      （= plan.input.act_off；A_OFF 的高位在 nn_mem act_rd_idx 位宽外被截断，
//       故 A[0] 对应 act_mem[0]，见 A_ACT_IDX），不做反量化。
//   4. pass_marker = "SLIM_TB: PASS"（固件 self-check 通过后打印；TB 在 tohost==1
//      时再打印一次，workflow 只需捕获该字符串）。
//
// 判据（固件自检 + TB 只看 tohost/log）：
//   real_input_csum=0xbb23c676 且 real_hw_bad=0（23 个代表 op，含 3 head；
//     opvec/0349/checksums.txt 只导出 23 个代表 op，不是全部 71 op）
//   pattern_input_csum=0xe40efcc5 且 pattern_hw_bad=0（71 op 全量，slim_plan.h csum）
//   auto_bad=0、auto_npu_cycles==pattern_npu_cycles、npu_cycles 在 v3 公式
//     799,520 ±1.1% 内（HANDOFF 的 504,895 是 converter 粗估，见报告 §6）
//
// 手动运行：
//   python sim/run_prog.py --top tb_sw_nn_slim --tb sim/tb_sw_nn_slim.sv \
//     --imem sim/prog/slim_demo.hex --dmem sim/prog/slim_demo.dmem.hex \
//     --plus +nnw=results/bottlecap/plan/slim/w.hex +nnq=results/bottlecap/plan/slim/q.hex \
//            +slim_input=results/bottlecap/plan/slim/opvec/0349/input.hex +max_cycles=60000000
// （run_prog.py 不支持 -d NN_EN，故实际用 workflow 注册或手工 vlog/vsim；
//   见 results/bottlecap/reports/M6A-SLIM-E2E.md）
// ============================================================================
module tb_sw_nn_slim;
  import rv32_pkg::*;

  localparam time TCLK_HALF = 10ns;      // 50 MHz（与 tb_sw 同频）

  localparam logic [31:0] TOHOST_ADDR = DMEM_BASE + 32'h2000;
  localparam int unsigned TOHOST_IDX  = (TOHOST_ADDR - DMEM_BASE) / 4;
  localparam logic [31:0] LOG_ADDR    = 32'h9000_3000;
  localparam int unsigned LOG_IDX     = (LOG_ADDR - DMEM_BASE) / 4;
  localparam int unsigned LOG_MAX     = 4096;

  // 真实图 0349：96*96*3 = 27,648 B PACKED3 → 6,912 个 u32 小端字
  localparam int unsigned IMG_WORDS   = 96*96*3/4;      // 6912
  localparam int unsigned IMG_BYTES   = 96*96*3;        // 27648
  localparam int unsigned A_ACT_IDX   = 0;   // A_OFF 高位在 act_rd_idx 位宽外被截断 => A[0] = act_mem[0]

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #(TCLK_HALF) clk = ~clk;

  int unsigned cycles = 0;
  int unsigned max_cycles = 60_000_000;
  bit finished = 1'b0;
  bit pass_seen = 1'b0;

  // ---- core 观测/总线 ----
  logic [31:0] dbg_pc, dbg_id_pc, dbg_instr, dbg_rdata, dbg_mem_addr, dbg_mem_wdata;
  logic        dbg_illegal, dbg_mem_we;
  logic        ext_we, ext_re, uart_txd, uart_rxd;
  logic [31:0] ext_addr, ext_wdata, ext_rdata;
  logic [3:0]  ext_wstrb;
  logic [31:0] gpio_out, tx_bytes, rx_bytes;
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

  // ---- 真实图输入预载（reset 释放前；A 区 offset 0） ----
  logic [31:0] simg [0:IMG_WORDS-1];
  initial begin : preload_image
    string fname;
    if (!$value$plusargs("slim_input=%s", fname)) begin
      $display("[tb_sw_nn_slim] ERROR: +slim_input=<input.hex> not given");
      $fatal(1);
    end
    $readmemh(fname, simg);
    // 等 2 拍让 nn_mem 的 time-0 零初始化完成，再写 A 区（此时 CPU 仍在复位）
    repeat (2) @(posedge clk);
    for (int i = 0; i < IMG_BYTES; i++) begin
      logic [7:0] b;
      b = simg[i/4] >> (8 * (i % 4));
      u_nn.u_mem.act_mem[A_ACT_IDX + (i/16)][(i % 16) * 8 +: 8] = b;
    end
    $display("[tb_sw_nn_slim] real image preloaded: %s (%0d bytes @ A[0])", fname, IMG_BYTES);
    @(negedge clk);
    rst = 1'b0;
    $display("[tb_sw_nn_slim] reset released, max_cycles=%0d", max_cycles);
  end

  // ---- 程序日志 dump ----
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

  initial begin : boot
    string f;
    if ($value$plusargs("dump=%s", f)) begin $dumpfile(f); $dumpvars(0, tb_sw_nn_slim); end
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 60_000_000;
  end

  // ---- 主循环 ----
  always_ff @(posedge clk) begin
    if (!rst && !finished) begin
      cycles <= cycles + 1;

      if (cycles > max_cycles) begin
        finished = 1'b1;
        $display("[tb_sw_nn_slim] FAIL: timeout (%0d cycles), id_pc=0x%08x instr=0x%08x",
                 max_cycles, dbg_id_pc, dbg_instr);
        dump_log();
        $fatal(1);
      end

      if (dbg_illegal) begin
        finished = 1'b1;
        $display("[tb_sw_nn_slim] FAIL: illegal instruction id_pc=0x%08x instr=0x%08x",
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
        $display("[tb_sw_nn_slim] FAIL: tohost=0x%08x (not 1), id_pc=0x%08x",
                 tohost_word, dbg_id_pc);
        dump_log();
        $fatal(1);
      end
    end
  end

  initial begin : finish_check
    @(finished);
    repeat (8) @(posedge clk);
    dump_log();
    $display("[tb_sw_nn_slim] cycles=%0d nn_busy=%0b nn_done=%0b nn_err=%0b",
             cycles, nn_busy, nn_done, nn_err);
    if (pass_seen) begin
      $display("SLIM_TB: PASS");
      $finish;
    end else begin
      $display("SLIM_TB: FAIL (no tohost==1)");
      $fatal(1);
    end
  end

  initial begin : watchdog
    int unsigned wd_ms;
    if (!$value$plusargs("watchdog_ms=%d", wd_ms)) wd_ms = 6000;
    #(1ms * wd_ms);
    if (!finished) begin
      $display("[tb_sw_nn_slim] FAIL: wall-clock watchdog (%0d ms), cycles=%0d, id_pc=0x%08x",
               wd_ms, cycles, dbg_id_pc);
      dump_log();
      $fatal(1);
    end
  end

endmodule
