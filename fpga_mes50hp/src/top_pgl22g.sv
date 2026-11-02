`timescale 1ns/1ps

// ============================================================================
// top_pgl22g.sv — 紫光同创 Pango PDS 版顶层（第一版：50 MHz 直通时钟，无 PLL）
// ----------------------------------------------------------------------------
// 和 fpga/top_a100t.sv 的区别只有两处（其余端口/例化逐字一致，方便对照）：
//   1) 去掉 MMCME2_BASE + BUFG（Xilinx 原语），先把板载时钟直接送进内核。
//      => 本文件 **零厂商原语**，PDS 综合不需要 IP、不需要 PLL 黑盒。
//      等 PGL22G 板子到手、确认时钟管脚后，用 PDS 的 IP Compiler 生成 PLL，
//      再照下面的注释把时钟段换掉（记得同步改 .fdc 里的 create_generated_clock）。
//   2) CLK_HZ 从 150_000_000 改为 50_000_000：mmio_subsys 的周期计数器/定时器
//      按这个值分频，值必须等于内核实际跑的频率，否则 CoreMark 的 tick 数、
//      波特率、Timer 中断周期全都是错的。**改时钟必须同步改这里。**
//   3) 去掉 `ifdef USE_ILA 里的 ila_0（Xilinx IP）—— PDS 用 Fabric Debugger，
//      要抓波形时用 PDS 的 Inserter/Debugger 重新插入，不要搬 ila_0。
//
// 引脚：本文件不写管脚，全部在 riscv.fdc 里。板子未定时 fdc 里的 IO_LOC
// 是注释掉的占位，PDS 会自动分配 I/O（能综合、能布局布线，但不能上板）。
// ============================================================================

module top_pgl22g
  import rv32_pkg::*;
(
  input  logic       sys_clk,       // 板载时钟（默认按 50 MHz 算，见 CLK_HZ）
  input  logic       sys_rst_n,     // 低有效复位
`ifdef DIGIT_APP
  input wire video_clk,
  input wire [6:0] keys_n,
  output wire [7:0] led,
  inout wire eeprom_scl,
  inout wire eeprom_sda,
  inout wire hdmi_scl,
  inout wire hdmi_sda,
  output wire hdmi_reset_n,
  output wire hdmi_pclk,
  output wire hdmi_hsync,
  output wire hdmi_vsync,
  output wire hdmi_de,
  output wire [23:0] hdmi_data,
`else
  output logic [3:0] led,
`endif
  output logic       uart_txd,
  input  logic       uart_rxd
);

  localparam logic [31:0] TOHOST_ADDR = DMEM_BASE + 32'h2000;   // 与 sw/link.ld 一致
  localparam int unsigned CLK_HZ      = 50_000_000;             // 必须 = 板上实际频率

  // ---- 时钟：直通（第一版） ----
  // Pango 版留的替换位：IP Compiler 生成的 PLL 形如
  //   PLL #(.CLKIN_FREQ("50MHZ"), .STATIC_RATIOI(1), .STATIC_RATIOF(...)) u_pll (...);
  // 生成的 .v 由 IP 编译器自动加进工程，这里只改 u_pll 的例化和下面的 rst 逻辑。
  logic sys_clk_core;
  logic pll_locked;
  assign sys_clk_core = sys_clk;
  assign pll_locked   = 1'b1;          // 没有 PLL 时视为常锁定，复位链照常工作

  // ---- 复位同步: 异步置位 / 同步释放（与 A100T 版一致） ----
  (* ASYNC_REG = "TRUE" *) logic [2:0] rst_sync;
  logic rst;

  always @(posedge sys_clk_core or negedge sys_rst_n) begin
    if (!sys_rst_n)      rst_sync <= 3'b000;
    else if (pll_locked) rst_sync <= {rst_sync[1:0], 1'b1};
    else                 rst_sync <= 3'b000;
  end
  assign rst = ~rst_sync[2];

  // ---- 内核 ----
  logic [31:0] dbg_pc, dbg_id_pc, dbg_instr, dbg_rdata, dbg_mem_addr, dbg_mem_wdata;
  logic        dbg_illegal, dbg_mem_we, dbg_stall, dbg_redirect;
  logic        ext_we, ext_re;
  logic [31:0] ext_addr, ext_wdata, ext_rdata;
  logic [3:0]  ext_wstrb;
  logic        irq_timer;

  core u_core (
    .clk            (sys_clk_core),
    .rst            (rst),
    .dbg_pc         (dbg_pc),
    .dbg_id_pc      (dbg_id_pc),
    .dbg_instr      (dbg_instr),
    .dbg_illegal    (dbg_illegal),
    .dbg_raddr      (5'd0),
    .dbg_rdata      (dbg_rdata),
    .dbg_mem_we     (dbg_mem_we),
    .dbg_mem_addr   (dbg_mem_addr),
    .dbg_mem_wdata  (dbg_mem_wdata),
    .dbg_stall      (dbg_stall),
    .dbg_redirect   (dbg_redirect),
    .ext_we         (ext_we),
    .ext_re         (ext_re),
    .ext_addr       (ext_addr),
    .ext_wdata      (ext_wdata),
    .ext_wstrb      (ext_wstrb),
    .ext_rdata      (ext_rdata),
    .irq_timer      (irq_timer)
  );

  // ---- 外设: GPIO / 周期计数器 / UART / 定时器 ----
  logic [31:0] gpio_out, tx_bytes, rx_bytes, score_result;
  logic        score_mark, score_done;

  mmio_subsys #(
    .CLK_HZ  (CLK_HZ),
    .BAUD_HZ (115_200)
  ) u_mmio (
    .clk           (sys_clk_core),
    .rst           (rst),
    .we            (ext_we),
    .re            (ext_re),
    .addr          (ext_addr),
    .wdata         (ext_wdata),
    .wstrb         (ext_wstrb),
    .rdata         (ext_rdata),
    .gpio_out      (gpio_out),
    .gpio_in       (32'h0),
`ifdef DIGIT_APP
    .video_clk(video_clk), .keys_n(keys_n),
    .eeprom_scl(eeprom_scl), .eeprom_sda(eeprom_sda),
    .hdmi_scl(hdmi_scl), .hdmi_sda(hdmi_sda),
    .hdmi_reset_n(hdmi_reset_n), .hdmi_pclk(hdmi_pclk),
    .hdmi_hsync(hdmi_hsync), .hdmi_vsync(hdmi_vsync), .hdmi_de(hdmi_de), .hdmi_data(hdmi_data),
`endif
    .uart_txd      (uart_txd),
    .uart_rxd      (uart_rxd),
    .tx_byte_count (tx_bytes),
    .rx_byte_count (rx_bytes),
    .mark          (score_mark),
    .done          (score_done),
    .result        (score_result),
    .irq_timer     (irq_timer)
  );

  // ---- 结果观测: 监视程序对 tohost 的写入 ----
  logic pass_r, fail_r;
  always @(posedge sys_clk_core) begin
    if (rst) begin
      pass_r <= 1'b0;
      fail_r <= 1'b0;
    end
    else if (dbg_mem_we && (dbg_mem_addr == TOHOST_ADDR)) begin
      if (dbg_mem_wdata == 32'd1) pass_r <= 1'b1;
      else                        fail_r <= 1'b1;
    end
  end

  // ---- 心跳: 50 MHz / 2^24 = 2.98 Hz ----
  logic [23:0] heartbeat;
  always @(posedge sys_clk_core) begin
    if (rst) heartbeat <= 24'd0;
    else     heartbeat <= heartbeat + 24'd1;
  end

  assign led[0] = heartbeat[23];
`ifdef DIGIT_APP
  assign led[1] = gpio_out[0];
  assign led[2] = gpio_out[1];
  assign led[3] = gpio_out[2] | dbg_illegal;
  assign led[7:4] = gpio_out[7:4];
`else
  assign led[1] = pass_r;
  assign led[2] = fail_r;
  assign led[3] = dbg_illegal;
`endif

  (* keep = "true" *) logic [31:0] gpio_out_keep;
  assign gpio_out_keep = gpio_out;

endmodule
