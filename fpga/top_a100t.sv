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
//   led[0] = 心跳 ~4 Hz          led[1] = PASS (tohost 写入 1)
//   led[2] = FAIL                led[3] = 非法指令
//
// 结构: core (纯 CPU) + mmio_subsys (GPIO/周期计数器/UART), 二者用 ext_* 总线相连。
// 不例化任何厂商 IP; 时钟用 MMCME2_BASE **原语**(非 IP)把板载 50 MHz 倍频到
// 70 MHz (VCO = 50*21 = 1050 MHz, CLKOUT0 = 1050/15 = 70.000 MHz), 见下方
// u_mmcm 的核算注释。写原语而不是 IP 有两个原因: ① CPU core 侧保持"零厂商 IP";
// ② 本机 Vivado 2018.3 的 IP 生成流程会撞上 IP_Flow 19-3505 (PITFALLS R33),
// 原语不需要工程模式、不产生 IP 目录。迁移紫光同创时只需重写本文件与约束,
// 下层 RTL 可原样搬。
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

  // ==========================================================================
  // 时钟: 板载 50 MHz -> MMCM -> 70 MHz  (MMCME2_BASE 原语 + BUFG, 不用 IP)
  // --------------------------------------------------------------------------
  // 核算 (XC7A100T-2, Artix-7 MMCME2 的合法区间):
  //   Fvco = Fclkin * CLKFBOUT_MULT_F / DIVCLK_DIVIDE
  //        = 50 MHz * 21 / 1 = **1050.000 MHz**
  //   Artix-7 MMCME2 的 VCO 合法区间 = 600 ~ 1200 MHz (SpeedGrade -2, BANDWIDTH
  //   OPTIMIZED) ==> 1050 MHz 落在区间内, 且距上下限都有余量。
  //   Fclkout0 = Fvco / CLKOUT0_DIVIDE_F = 1050 / 15 = **70.000 MHz** (精确相等,
  //   无小数误差)  ==> 周期 1/70 MHz = 14.2857 ns。
  //   PFD 频率 = Fclkin / DIVCLK_DIVIDE = 50 / 1 = 50 MHz, 合法区间 10 ~ 500 MHz。
  //   为什么是 21/1 而不是 7/5: CLKFBOUT_MULT_F / DIVCLK_DIVIDE 是 MMCM 内部
  //   反馈分频比, 它决定"输出对输入的倍率" = 21/1 = 21; 而 1050/15 = 70 正好是
  //   50 的 7/5。两个比值的乘积才是最终结果: 21/1 * 1/15 = 7/5。XDC 里的
  //   create_generated_clock 用 -multiply_by 21 -divide_by 15 (等价于 7/5) 与本例化
  //   **逐项对齐**, 不靠人脑换算。
  //
  // 【R43 根因修复 / 必须保留 CLKFBIN】70 MHz 版首次上板时 CPU 被永久复位:
  //   ILA 抓到 2048 拍全是 ila_ctrl=0x00 / score_result=0, dbg_pc 冻在 0x80000000,
  //   而 dbg_instr 能读出合法指令 0x10003117 => 时钟在跑, 但复位从未释放。
  //   原因: 本实例**漏接了 .CLKFBIN** —— CLKFBOUT 只驱动了悬空的 clk_fb,
  //   反馈环断开 => MMCM 永远不锁定 => LOCKED=0 => rst 恒有效。
  //   综合期唯一的证据是这条警告(当时被当成"标准提示"放过):
  //     [Timing 38-1] DLL output pin(s) used on clock modifying cell u_mmcm
  //                   without a feedback net: CLKOUT0
  //   **修复判据: 重新综合后该警告必须消失。**
  //   MMCME2_BASE 用内部反馈(CLKFBOUT -> CLKFBIN 直连)即可, 不需要外部 BUFG;
  //   绝不能把这行删掉, 也不要改成空连接。
  // ==========================================================================
  logic clk_fb;
  logic clk_70_raw;
  logic sys_clk_70;
  logic mmcm_locked;

  MMCME2_BASE #(
    .BANDWIDTH          ("OPTIMIZED"),
    .CLKFBOUT_MULT_F    (21.0),     // VCO = 50 * 21 / 1 = 1050 MHz  (600~1200 OK)
    .CLKFBOUT_PHASE     (0.0),
    .CLKIN1_PERIOD      (20.000),   // 板载 50 MHz
    .CLKOUT0_DIVIDE_F   (15.0),     // 1050 / 15 = 70.000 MHz
    .CLKOUT0_DUTY_CYCLE (0.5),
    .CLKOUT0_PHASE      (0.0),
    .DIVCLK_DIVIDE      (1),
    .REF_JITTER1        (0.010),
    .STARTUP_WAIT       ("FALSE")
  ) u_mmcm (
    .CLKOUT0  (clk_70_raw),
    .CLKOUT0B (),
    .CLKOUT1  (),
    .CLKOUT1B (),
    .CLKOUT2  (),
    .CLKOUT2B (),
    .CLKOUT3  (),
    .CLKOUT3B (),
    .CLKOUT4  (),
    .CLKOUT5  (),
    .CLKOUT6  (),
    .CLKFBOUT (clk_fb),
    .CLKFBOUTB(),
    .CLKFBIN  (clk_fb),             // 【关键】反馈必须回到 CLKFBIN: 缺这行 => MMCM 不锁定
    .LOCKED   (mmcm_locked),
    .CLKIN1   (sys_clk),
    .PWRDWN   (1'b0),
    .RST      (1'b0)                // 复位走 sys_rst_n -> 下方的复位同步链
  );

  // MMCM 出来的时钟**必须**过 BUFG 才能上全局时钟树。
  // BUFG 的输出网就叫 sys_clk_70, 与 XDC 里 create_generated_clock -name sys_clk_70
  // 同名, 所以 timing summary 的时钟表里能直接看到这条约束的名字与周期
  // (14.286 ns), 不用靠自动推导名去反推。
  BUFG u_bufg_sys (
    .I (clk_70_raw),
    .O (sys_clk_70)
  );

  // ---- 复位同步: 异步置位 / 同步释放, 且**要求 MMCM 已锁定** ----
  // rst 只有在 "sys_rst_n 释放" 且 "MMCM 已锁定" 之后才会拉低; 未锁定时
  // (上电 / 掉锁) 内核一直被复位, 不会在 70 MHz 未稳的时钟上跑。
  (* ASYNC_REG = "TRUE" *) logic [2:0] rst_sync;
  logic rst;

  always @(posedge sys_clk_70 or negedge sys_rst_n) begin
    if (!sys_rst_n)      rst_sync <= 3'b000;
    else if (mmcm_locked) rst_sync <= {rst_sync[1:0], 1'b1};
    else                  rst_sync <= 3'b000;
  end
  assign rst = ~rst_sync[2];

  // ---- 内核 ----
  logic [31:0] dbg_pc, dbg_id_pc, dbg_instr, dbg_rdata, dbg_mem_addr, dbg_mem_wdata;
  logic        dbg_illegal, dbg_mem_we, dbg_stall, dbg_redirect;
  logic        ext_we, ext_re;
  logic [31:0] ext_addr, ext_wdata, ext_rdata;
  logic [3:0]  ext_wstrb;
  // 定时器中断: mmio_subsys 产出 -> core 的 csr_file (mip.MTIP)。
  // 声明必须在两个例化之前, 否则具名端口连接会把它隐式声明成 net (vlog-2388)。
  logic        irq_timer;

  core u_core (
    .clk            (sys_clk_70),
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
    .CLK_HZ  (70_000_000),         // 必须跟着 MMCM 改: 周期计数器/定时器按它分频
    .BAUD_HZ (115_200)
  ) u_mmio (
    .clk           (sys_clk_70),
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
    .result        (score_result),
    .irq_timer     (irq_timer)
  );

  // ---- 结果观测: 监视程序对 tohost 的写入 ----
  logic pass_r, fail_r;
  always @(posedge sys_clk_70) begin
    if (rst) begin
      pass_r <= 1'b0;
      fail_r <= 1'b0;
    end
    else if (dbg_mem_we && (dbg_mem_addr == TOHOST_ADDR)) begin
      if (dbg_mem_wdata == 32'd1) pass_r <= 1'b1;
      else                        fail_r <= 1'b1;
    end
  end

  // ---- 心跳: heartbeat[23] 作 LED => 翻转间隔 2^23 拍, 方波**全周期 2^24 拍** ----
  // 70 MHz / 2^24 = **4.172 Hz** (板上 50 MHz 时是 2.98 Hz), 肉眼可辨。
  // 注意: 心跳计数器被 rst 清零, 而 rst 依赖 mmcm_locked => MMCM 没锁时
  // led[0] **熄灭**。这正好是一个不用 ILA 的粗判据: LED0 不闪 => 先查 MMCM/复位。
  logic [23:0] heartbeat;
  always @(posedge sys_clk_70) begin
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
  //
  // 【R43 可观测性】bit7 现在 = mmcm_locked (原来是常数 0)。这样下次上板一眼就能
  //   区分两种失败: bit7=0 => 时钟/MMCM 没锁定(复位没释放); bit7=1 但 PC 不动
  //   => MMCM 已锁, 是别的问题(复位同步/逻辑)。软件语义位完全不变 ——
  //   0x42 = 0100_0010 的 bit7 本来就是 0, 所以 bit1=pass / bit6=done 的解释
  //   一个字都不用改; 锁定成功后读出来应是 0xC2。
  // ==========================================================================
`ifdef USE_ILA
  logic [7:0]  ila_ctrl;
  assign ila_ctrl = {mmcm_locked, score_done, score_mark, dbg_redirect, dbg_stall, dbg_illegal, pass_r, fail_r};

  ila_0 u_ila (
    .clk    (sys_clk_70),
    .probe0 (dbg_pc),        // IF 段取指地址: 看流水线推进
    .probe1 (dbg_instr),     // 与 dbg_id_pc 配对的指令
    .probe2 (ila_ctrl),      // {mmcm_locked, done, mark, redirect, stall, illegal, pass, fail}
    .probe3 (score_result)   // 最终 tick 数
  );
`endif

endmodule
