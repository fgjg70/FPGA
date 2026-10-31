`timescale 1ns/1ps
// Temporary micro test for nn_mem A/B cpu + npu paths (not a deliverable).
module dbg_mem;
  import nn_pkg::*;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic cpu_re, cpu_we;
  logic [31:0] cpu_addr, cpu_wdata;
  logic [3:0] cpu_wstrb;
  logic [31:0] cpu_rdata;
  logic w_re; logic [23:0] w_addr; logic [63:0] w_rdata;
  logic [1:0] a_sel; logic a_re; logic [23:0] a_addr; logic [127:0] a_rdata;
  logic [1:0] b_sel; logic b_we; logic [23:0] b_addr; logic [63:0] b_wdata;

  nn_mem u_mem (.clk(clk), .rst(rst), .cpu_re(cpu_re), .cpu_we(cpu_we),
    .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_wstrb(cpu_wstrb),
    .cpu_rdata(cpu_rdata), .w_re(w_re), .w_addr(w_addr), .w_rdata(w_rdata),
    .a_sel(a_sel), .a_re(a_re), .a_addr(a_addr), .a_rdata(a_rdata),
    .b_sel(b_sel), .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wdata));

  logic [31:0] rd;
  task automatic cw(input logic [31:0] aa, input logic [31:0] dd);
    begin @(negedge clk); cpu_we = 1; cpu_re = 0; cpu_addr = aa; cpu_wdata = dd; cpu_wstrb = 4'hF; end
  endtask
  task automatic cr(input logic [31:0] aa, output logic [31:0] dd);
    begin @(negedge clk); cpu_we = 0; cpu_re = 1; cpu_addr = aa; @(negedge clk); dd = cpu_rdata; end
  endtask

  initial begin
    cpu_re = 0; cpu_we = 0; cpu_addr = 0; cpu_wdata = 0; cpu_wstrb = 0;
    w_re = 0; w_addr = 0; a_sel = 0; a_re = 0; a_addr = 0;
    b_sel = 0; b_we = 0; b_addr = 0; b_wdata = 0;
    repeat (4) @(negedge clk); rst = 0; @(negedge clk);
    $display("A_OFF=%h B_OFF=%h", NN_A_OFF, NN_B_OFF);
    // --- CPU write 64-bit word at A+0x40 (idx 8) ---
    cw(NN_A_OFF + 32'h40, 32'h11223344);
    cw(NN_A_OFF + 32'h44, 32'h55667788);
    // --- CPU write 64-bit word at B+0x40 ---
    cw(NN_B_OFF + 32'h40, 32'h99aabbcc);
    cw(NN_B_OFF + 32'h44, 32'hddeeff00);
    @(negedge clk); cpu_we = 0;
    // --- read back via CPU ---
    cr(NN_A_OFF + 32'h40, rd); $display("CPU read A+40 lo = %h (exp 11223344)", rd);
    cr(NN_A_OFF + 32'h44, rd); $display("CPU read A+44 hi = %h (exp 55667788)", rd);
    cr(NN_B_OFF + 32'h40, rd); $display("CPU read B+40 lo = %h (exp 99aabbcc)", rd);
    cr(NN_B_OFF + 32'h44, rd); $display("CPU read B+44 hi = %h (exp ddeeff00)", rd);
    // --- NPU b write to B+0x80, then CPU + a read ---
    @(negedge clk); b_sel = 1; b_we = 1; b_addr = NN_B_OFF + 32'h80; b_wdata = 64'h0123456789abcdef;
    @(negedge clk); b_we = 0;
    cr(NN_B_OFF + 32'h80, rd); $display("CPU read B+80 lo = %h (exp 89abcdef)", rd);
    cr(NN_B_OFF + 32'h84, rd); $display("CPU read B+84 hi = %h (exp 01234567)", rd);
    // --- a port read B+0x80 (128b aligned) ---
    @(negedge clk); a_sel = 1; a_re = 1; a_addr = NN_B_OFF + 32'h80;
    @(negedge clk); a_re = 0;
    $display("NPU a read B+80 = %h", a_rdata);
    $finish;
  end
endmodule
