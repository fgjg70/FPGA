`timescale 1ns/1ps
// Debug wrapper: nn_mem alone, NPU ports driven by counters (no engine).
module nn_mem_only_wrap
  import nn_pkg::*;
(
  input  logic        clk,
  input  logic        rst
);
  logic [19:0] cnt;
  always @(posedge clk) begin
    if (rst) cnt <= 20'd0;
    else     cnt <= cnt + 20'd1;
  end

  logic [31:0] cpu_rdata, w_rdata_lo;
  logic [63:0] w_rdata, b_wdata;
  logic [127:0] a_rdata;

  nn_mem u_mem (
    .clk(clk), .rst(rst),
    .cpu_re(cnt[2]), .cpu_we(cnt[3]), .cpu_addr({13'd0, cnt[18:0]}),
    .cpu_wdata({12'd0, cnt}), .cpu_wstrb(4'hF), .cpu_rdata(cpu_rdata),
    .w_re(cnt[4]), .w_addr({4'd0, cnt[19:0]}), .w_rdata(w_rdata),
    .a_sel(cnt[1:0]), .a_re(cnt[5]), .a_addr({4'd0, cnt[19:0]}), .a_rdata(a_rdata),
    .b_sel(cnt[1:0]), .b_we(cnt[6]), .b_addr({4'd0, cnt[19:0]}),
    .b_wdata({cnt[19:0], 44'd0})
  );

endmodule
