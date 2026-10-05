`timescale 1ns/1ps

// ============================================================================
// top_a100t.sv — 正点原子 达芬奇Pro (XC7A100T-FGG484-2) 上板顶层
// ----------------------------------------------------------------------------
// 引脚来源: 厂商 DaVinci_Pro_PIN.xdc (零猜测)
//   sys_clk     R4   LVCMOS15  50 MHz
//   sys_rst_n   U7   LVCMOS15  低有效 (按键)
//   led[0..3]   V9 Y8 Y7 W7    LVCMOS15   高电平点亮 (已实测确认)
//   uart_txd    D17  LVCMOS33
//   uart_rxd    E14  LVCMOS33
//
// LED 语义 (已在真实硬件上验证过, 不要随意改动):
//   led[0] = 心跳 ~3 Hz          led[1] = PASS (tohost 写入 1)
//   led[2] = FAIL                led[3] = 非法指令
//
// 结构: core (纯 CPU) + mmio_subsys (GPIO/周期计数器/UART), 二者用 ext_* 总线相连。
// 不例化任何厂商 IP; 时钟不做 MMCM, 直接用板载 50 MHz —— 迁移紫光同创时
// 只需重写本文件与约束, 下层 RTL 可原样搬。
// ============================================================================

module top_a100t
  import rv32_pkg::*;
(
  input  logic       sys_clk,
  input  logic       sys_rst_n,
  output logic [3:0] led,
  output logic       uart_txd,
  input  logic       uart_rxd
);

  localparam logic [31:0] TOHOST_ADDR = DMEM_BASE + 32'h2000;   // 与 sw/link.ld 保持一致

  // ---- 复位同步: 异步置位 / 同步释放 ----
  (* ASYNC_REG = "TRUE" *) logic [2:0] rst_sync;
  logic rst;

  always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) rst_sync <= 3'b000;
    else            rst_sync <= {rst_sync[1:0], 1'b1};
  end
  assign rst = ~rst_sync[2];

  // ---- 内核 ----
  logic [31:0] dbg_pc, dbg_id_pc, dbg_instr, dbg_rdata, dbg_mem_addr, dbg_mem_wdata;
  logic        dbg_illegal, dbg_mem_we, dbg_stall, dbg_redirect;
  logic        ext_we, ext_re;
  logic [31:0] ext_addr, ext_wdata, ext_rdata;
  logic [3:0]  ext_wstrb;

  core u_core (
    .clk            (sys_clk),
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
    .ext_rdata      (ext_rdata)
  );

  // ---- 外设: GPIO / 周期计数器 / UART ----
  logic [31:0] gpio_out, tx_bytes, rx_bytes, score_result;
  logic        score_mark, score_done;

  mmio_subsys #(
    .CLK_HZ  (50_000_000),
    .BAUD_HZ (115_200)
  ) u_mmio (
    .clk           (sys_clk),
    .rst           (rst),
    .we            (ext_we),
    .re            (ext_re),
    .addr          (ext_addr),
    .wdata         (ext_wdata),
    .wstrb         (ext_wstrb),
    .rdata         (ext_rdata),
    .gpio_out      (gpio_out),
    .gpio_in       (32'h0),        // 按键/拨码后续接
    .uart_txd      (uart_txd),
    .uart_rxd      (uart_rxd),
    .tx_byte_count (tx_bytes),
    .rx_byte_count (rx_bytes),
    .mark          (score_mark),
    .done          (score_done),
    .result        (score_result)
  );

  // ---- 结果观测: 监视程序对 tohost 的写入 ----
  logic pass_r, fail_r;
  always @(posedge sys_clk) begin
    if (rst) begin
      pass_r <= 1'b0;
      fail_r <= 1'b0;
    end
    else if (dbg_mem_we && (dbg_mem_addr == TOHOST_ADDR)) begin
      if (dbg_mem_wdata == 32'd1) pass_r <= 1'b1;
      else                        fail_r <= 1'b1;
    end
  end

  // ---- 心跳: 50 MHz / 2^24 ≈ 3 Hz ----
  logic [23:0] heartbeat;
  always @(posedge sys_clk) begin
    if (rst) heartbeat <= 24'd0;
    else     heartbeat <= heartbeat + 24'd1;
  end

  assign led[0] = heartbeat[23];
  assign led[1] = pass_r;
  assign led[2] = fail_r;
  assign led[3] = dbg_illegal;

  // 未用的外设输出保留为寄存器, 防止被优化掉 (后续接数码管/扩展口)
  (* keep = "true" *) logic [31:0] gpio_out_keep;
  assign gpio_out_keep = gpio_out;

  // ==========================================================================
  // 上板自主读回 (串口在本板不通, 只能走 ILA over JTAG)
  // --------------------------------------------------------------------------
  // 软件在 CoreMark 测量区间起点写 MMIO_MARK (单拍脉冲, 做触发点), 结束时把
  // 最终 tick 数写进 MMIO_RESULT。这里用 ILA 抓下来, 于是"是否跑完、跑了多少
  // 周期"可以在 PC 端直接读回, 不必靠人看 LED。
  //
  // ILA 只在 `USE_ILA 时例化: CPU core 本身保持纯净、不含任何厂商 IP,
  // 正式评分构建不带 ILA。
  // ==========================================================================
`ifdef USE_ILA
  logic [7:0]  ila_ctrl;
  assign ila_ctrl = {1'b0, score_done, score_mark, dbg_redirect, dbg_stall, dbg_illegal, pass_r, fail_r};

  ila_0 u_ila (
    .clk    (sys_clk),
    .probe0 (dbg_pc),        // IF 段取指地址: 看流水线推进
    .probe1 (dbg_instr),     // 与 dbg_id_pc 配对的指令
    .probe2 (ila_ctrl),      // {done, mark, redirect, stall, illegal, pass, fail}
    .probe3 (score_result)   // 最终 tick 数
  );
`endif

endmodule
