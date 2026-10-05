`timescale 1ns/1ps

// ============================================================================
// mmio_subsys.sv — MMIO 外设子系统 (GPIO / 自由运行周期计数器 / UART)
// ----------------------------------------------------------------------------
// 由 core 的 ext_* 总线驱动 (地址译码已在 core 内完成: DMEM 窗口 -> 内部 dmem,
// 其它 -> ext_*)。寄存器映射见 rv32_pkg 的 MMIO_* 常量。
//
// 【为什么放顶层而不放 core 内】
//   保持 core 是纯 CPU, 外设可独立替换/裁剪; 迁移紫光同创时只需重写顶层,
//   外设本身是纯行为级 RTL, 不例化任何厂商 IP。
//
// 【组合读】
//   本核 LSU 是组合读 (与 dmem 一致), 所以 rdata 必须同拍给出, 用 assign 译码。
//
// 【周期计数器】
//   64 位自由运行计数器, 供 CoreMark 的 start_time()/stop_time() 使用 —— 这是
//   测出 CoreMark/MHz 的前提。读的时候低/高 32 位分开读 (RV32 无 64 位读)。
// ============================================================================

module mmio_subsys
  import rv32_pkg::*;
#(
  parameter int unsigned CLK_HZ  = 50_000_000,
  parameter int unsigned BAUD_HZ = 115_200
)(
  input  logic        clk,
  input  logic        rst,

  // 来自 core 的 MMIO 总线
  input  logic        we,
  input  logic        re,          // 读选通: 用于清粘滞的"数据就绪"标志
  input  logic [31:0] addr,
  input  logic [31:0] wdata,
  input  logic [3:0]  wstrb,
  output logic [31:0] rdata,

  // 外设引出
  output logic [31:0] gpio_out,
  input  logic [31:0] gpio_in,
  output logic        uart_txd,
  input  logic        uart_rxd,

  // 观测 (仿真/ILA)
  output logic [31:0] tx_byte_count,
  output logic [31:0] rx_byte_count,

  // 上板跑分观测: 软件写 MMIO_MARK 表示"测量开始"(单拍脉冲, 做 ILA 触发点),
  // 写 MMIO_RESULT 报告最终 tick 数并置 done。串口不通时靠这两个信号 +
  // ILA over JTAG 把结果读回来。
  output logic        mark,
  output logic        done,
  output logic [31:0] result
);

  localparam int unsigned BAUD_DIV = CLK_HZ / BAUD_HZ;   // 50MHz/115200 = 434

  // ------------------------------------------------------------------------
  // 地址译码 (组合读)
  // ------------------------------------------------------------------------
  logic sel_gpio_out, sel_gpio_in, sel_cyc_lo, sel_cyc_hi;
  logic sel_uart_tx, sel_uart_stat, sel_uart_rx, sel_uart_rstat;
  logic sel_mark, sel_result;
  logic wr_gpio_out, wr_uart_tx;

  assign sel_gpio_out   = (addr == MMIO_GPIO_OUT);
  assign sel_gpio_in    = (addr == MMIO_GPIO_IN);
  assign sel_cyc_lo     = (addr == MMIO_CYCLE_LO);
  assign sel_cyc_hi     = (addr == MMIO_CYCLE_HI);
  assign sel_uart_tx    = (addr == MMIO_UART_TX);
  assign sel_uart_stat  = (addr == MMIO_UART_STAT);
  assign sel_uart_rx    = (addr == MMIO_UART_RX);
  assign sel_uart_rstat = (addr == MMIO_UART_RSTAT);
  assign sel_mark       = (addr == MMIO_MARK);
  assign sel_result     = (addr == MMIO_RESULT);

  assign wr_gpio_out = we && sel_gpio_out;
  assign wr_uart_tx  = we && sel_uart_tx;

  // ------------------------------------------------------------------------
  // 跑分观测寄存器 (software -> hardware)
  //   mark   : 单拍脉冲, 写 MMIO_MARK 触发 (ILA 触发点 = 测量区间起点)
  //   done   : 粘滞, 写 MMIO_RESULT 后置位
  //   result : 锁存软件写进 MMIO_RESULT 的值 (CoreMark 最终 tick 数)
  // ------------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst) begin
      mark   <= 1'b0;
      done   <= 1'b0;
      result <= 32'd0;
    end
    else begin
      mark <= 1'b0;                                  // 默认清零 -> 单拍脉冲
      if (we && sel_mark)   mark <= 1'b1;
      if (we && sel_result) begin
        result <= wdata;
        done   <= 1'b1;
      end
    end
  end

  // ------------------------------------------------------------------------
  // GPIO 输出 (带写使能: 只在真正写时才更新, 避免组合回环)
  // ------------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst) gpio_out <= 32'h0;
    else if (wr_gpio_out) gpio_out <= wdata;
  end

  // ------------------------------------------------------------------------
  // 64 位自由运行周期计数器
  // ------------------------------------------------------------------------
  logic [63:0] cycle_cnt;
  always @(posedge clk) begin
    if (rst) cycle_cnt <= 64'd0;
    else     cycle_cnt <= cycle_cnt + 64'd1;
  end

  // ------------------------------------------------------------------------
  // UART 发送: 10 位帧 (start + 8 数据 + stop), LSB 先发
  // ------------------------------------------------------------------------
  logic [9:0]  tx_frame;
  logic [3:0]  tx_idx;
  logic [15:0] tx_cnt;
  logic        tx_busy;
  logic        tx_line;

  always @(posedge clk) begin
    if (rst) begin
      tx_busy  <= 1'b0;
      tx_idx   <= 4'd0;
      tx_cnt   <= 16'd0;
      tx_frame <= 10'h3FF;
      tx_line  <= 1'b1;
    end
    else if (!tx_busy) begin
      tx_line <= 1'b1;                       // 空闲高
      if (wr_uart_tx) begin
        tx_frame <= {1'b1, wdata[7:0], 1'b0}; // [9]=stop [8:1]=data [0]=start
        tx_busy  <= 1'b1;
        tx_idx   <= 4'd0;
        tx_cnt   <= 16'd0;
      end
    end
    else begin
      tx_line <= tx_frame[tx_idx];
      if (tx_cnt == BAUD_DIV[15:0] - 16'd1) begin
        tx_cnt <= 16'd0;
        if (tx_idx == 4'd9) tx_busy <= 1'b0;
        else                tx_idx  <= tx_idx + 4'd1;
      end
      else tx_cnt <= tx_cnt + 16'd1;
    end
  end

  assign uart_txd = tx_line;

  logic [31:0] tx_cnt_bytes;
  always @(posedge clk) begin
    if (rst) tx_cnt_bytes <= 32'd0;
    else if (wr_uart_tx) tx_cnt_bytes <= tx_cnt_bytes + 32'd1;
  end
  assign tx_byte_count = tx_cnt_bytes;

  // ------------------------------------------------------------------------
  // UART 接收: 起始位下降沿 -> 等半位 -> 采样 8 位 -> 停止位
  // ------------------------------------------------------------------------
  localparam logic [1:0] RX_IDLE = 2'd0, RX_START = 2'd1, RX_DATA = 2'd2, RX_STOP = 2'd3;

  logic [2:0]  rxd_sync;
  logic [1:0]  rx_state;
  logic [15:0] rx_div;
  logic [3:0]  rx_bit;
  logic [7:0]  rx_sh, rx_byte;
  logic        rx_rdy;      // 粘滞: 有数据待读 (读 MMIO_UART_RX 清)
  logic        rx_done;     // 单拍脉冲: 一个字节收完 (用于计数)

  always @(posedge clk) begin
    if (rst) begin
      rxd_sync <= 3'b111;
      rx_state <= RX_IDLE;
      rx_div   <= 16'd0;
      rx_bit   <= 4'd0;
      rx_sh    <= 8'd0;
      rx_byte  <= 8'd0;
      rx_rdy   <= 1'b0;
      rx_done  <= 1'b0;
    end
    else begin
      rxd_sync <= {rxd_sync[1:0], uart_rxd};
      rx_done  <= 1'b0;                                  // 默认清零
      if (rx_rdy && re && sel_uart_rx) rx_rdy <= 1'b0;   // 读清 (必须用读选通,
                                                         // 不能用 we: 读操作不会拉 we)

      case (rx_state)
        // 下降沿检测: rxd_sync[2] 最旧, [0] 最新。1->0 的样点序列是
        // 111 -> 110 -> 100 -> 000, 即 [2:1] 走 11 -> 11 -> 10 -> 00。
        // 因此判据是 2'b10 (曾在 2'b01 上错过一次: 那个组合永远不会出现,
        // 表现为"发送正常但内部接收通路一次都没收到")。
        RX_IDLE: if (rxd_sync[2:1] == 2'b10) begin
                   rx_state <= RX_START;
                   rx_div   <= 16'd0;
                 end
        RX_START: begin
          if (rx_div == (BAUD_DIV[15:0] >> 1)) begin
            rx_div <= 16'd0;
            if (rxd_sync[2] == 1'b0) begin rx_state <= RX_DATA; rx_bit <= 4'd0; end
            else                     rx_state <= RX_IDLE;  // 假起始位
          end
          else rx_div <= rx_div + 16'd1;
        end
        RX_DATA: begin
          if (rx_div == BAUD_DIV[15:0] - 16'd1) begin
            rx_div <= 16'd0;
            rx_sh  <= {rxd_sync[2], rx_sh[7:1]};          // LSB 先收
            if (rx_bit == 4'd7) rx_state <= RX_STOP;
            else                rx_bit   <= rx_bit + 4'd1;
          end
          else rx_div <= rx_div + 16'd1;
        end
        RX_STOP: begin
          if (rx_div == BAUD_DIV[15:0] - 16'd1) begin
            rx_div   <= 16'd0;
            rx_state <= RX_IDLE;
            rx_byte  <= rx_sh;
            rx_rdy   <= 1'b1;
            rx_done  <= 1'b1;      // 单拍脉冲, 供 rx_cnt_bytes 计数
          end
          else rx_div <= rx_div + 16'd1;
        end
        default: rx_state <= RX_IDLE;
      endcase
    end
  end

  // 必须用"收完一个字节"的单拍脉冲计数, 不能用粘滞的 rx_rdy ——
  // rx_rdy 在程序读走数据前一直为 1, 拿它计数会变成每拍 +1。
  logic [31:0] rx_cnt_bytes;
  always @(posedge clk) begin
    if (rst) rx_cnt_bytes <= 32'd0;
    else if (rx_done) rx_cnt_bytes <= rx_cnt_bytes + 32'd1;
  end
  assign rx_byte_count = rx_cnt_bytes;

  // ------------------------------------------------------------------------
  // 组合读回选 (与 LSU 的组合读匹配)
  // ------------------------------------------------------------------------
  always_comb begin
    rdata = 32'h0;
    if      (sel_gpio_in)   rdata = gpio_in;
    else if (sel_cyc_lo)    rdata = cycle_cnt[31:0];
    else if (sel_cyc_hi)    rdata = cycle_cnt[63:32];
    else if (sel_uart_stat) rdata = {31'b0, tx_busy};
    else if (sel_uart_rx)   rdata = {24'b0, rx_byte};
    else if (sel_uart_rstat)rdata = {31'b0, rx_rdy};
    else if (sel_result)    rdata = result;
    else                    rdata = 32'h0;    // 未映射地址读 0
  end

endmodule
