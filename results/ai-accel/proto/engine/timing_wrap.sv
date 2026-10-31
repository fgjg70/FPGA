`timescale 1ns/1ps
// ============================================================================
// timing_wrap.sv — OOC 时序评估用顶层 (T-accel-R2, 不进 RTL 清单)
//   把 nn_conv_engine + nn_mem 接起来, 复现真实实现里
//   engine w_addr/a_addr/b_addr -> nn_mem BRAM 地址 的路径。
//
//   注意 (踩过的坑):
//   1) 顶层**必须把数据通路作为输出端口引出**, 否则 Vivado 把"只写回 nn_mem、
//      没有可观测输出"的整条数据通路 (acc/requant/写口/激活 RAM) 当死代码删掉,
//      综合出来只剩 ~500 LUT, 资源/时序全失真。
//   2) WQ RAM 若只靠 $readmemh 初始化且 CPU 写口全 0, 会被当常量 ROM 折叠;
//      这里用自由计数器驱动 CPU 写口, 与真实 boot 加载等价。
// ============================================================================
module nn_eng_timing_wrap
  import nn_pkg::*;
(
  input  logic        clk,
  input  logic        rst,
  input  nn_pkg::nn_desc_t desc,
  input  logic        start,
  output logic        busy,
  output logic        done,
  output logic [31:0] cycles,
  output logic [7:0]  err_code,
  // 数据通路观测口 (仅为了让综合保留数据通路; 不参与时序判定)
  output logic [127:0] a_rdata_o,
  output logic [63:0]  w_rdata_o,
  output logic [63:0]  b_wdata_o
);

  logic        cpu_re, cpu_we;
  logic [31:0] cpu_addr, cpu_wdata;
  logic [3:0]  cpu_wstrb;
  logic [31:0] cpu_rdata;
  logic        w_re;
  logic [23:0] w_addr;
  logic [63:0] w_rdata;
  logic [1:0]  a_sel;
  logic        a_re;
  logic [23:0] a_addr;
  logic [127:0] a_rdata;
  logic [1:0]  b_sel;
  logic        b_we;
  logic [23:0] b_addr;
  logic [63:0] b_wdata;

  nn_mem u_mem (
    .clk(clk), .rst(rst),
    .cpu_re(cpu_re), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
    .cpu_wdata(cpu_wdata), .cpu_wstrb(cpu_wstrb), .cpu_rdata(cpu_rdata),
    .w_re(w_re), .w_addr(w_addr), .w_rdata(w_rdata),
    .a_sel(a_sel), .a_re(a_re), .a_addr(a_addr), .a_rdata(a_rdata),
    .b_sel(b_sel), .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wdata)
  );

  nn_conv_engine u_eng (
    .clk(clk), .rst(rst), .desc(desc), .start(start),
    .busy(busy), .done(done), .cycles(cycles), .err_code(err_code),
    .w_re(w_re), .w_addr(w_addr), .w_rdata(w_rdata),
    .a_sel(a_sel), .a_re(a_re), .a_addr(a_addr), .a_rdata(a_rdata),
    .b_sel(b_sel), .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wdata)
  );

  always @(posedge clk) begin
    if (rst) begin
      a_rdata_o <= 128'd0;
      w_rdata_o <= 64'd0;
      b_wdata_o <= 64'd0;
    end
    else begin
      a_rdata_o <= a_rdata;
      w_rdata_o <= w_rdata;
      b_wdata_o <= b_wdata;
    end
  end

  // CPU 窗口: 自由计数器驱动 (仅综合资源/时序评估用; 让 WQ RAM 有真实写口)
  logic [19:0] probe_cnt;
  always @(posedge clk) begin
    if (rst) probe_cnt <= 20'd0;
    else     probe_cnt <= probe_cnt + 20'd1;
  end
  assign cpu_re    = probe_cnt[2];
  assign cpu_we    = probe_cnt[3];
  assign cpu_addr  = {13'd0, probe_cnt[18:0]};
  assign cpu_wdata = {12'd0, probe_cnt};
  assign cpu_wstrb = 4'hF;

endmodule
