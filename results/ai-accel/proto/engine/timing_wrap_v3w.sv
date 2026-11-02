`timescale 1ns/1ps
// ASCII only. OOC synthesis wrapper for engine v3 + nn_mem v0.7 (T-accel-R3).
// - engine v3 (128 MAC) + REAL nn_mem v0.7 (W 128b / Q 64b / A 128b read / B 128b+strb write)
// - observable output ports so the datapath is not dead-code eliminated (R2 trap #2)
// - CPU window driven by a free-running counter (keeps CPU A/B path alive; not judged)
module nn_eng_timing_wrap_v3
  import nn_pkg::*;
(
  input  logic         clk,
  input  logic         rst,
  input  nn_pkg::nn_desc_t desc,
  input  logic         start,
  output logic         busy,
  output logic         done,
  output logic [31:0]  cycles,
  output logic [7:0]   err_code,
  // datapath probes (keep alive)
  output logic [127:0] w_rdata_o,
  output logic [63:0]  q_rdata_o,
  output logic [127:0] a_rdata_o,
  output logic [127:0] b_wdata_o,
  output logic [15:0]  b_wstrb_o,
  output logic [31:0]  cpu_rdata_o
);

  // engine <-> mem
  logic         w_re;   logic [23:0]  w_addr;   logic [127:0] w_rdata;
  logic         q_re;   logic [12:0]  q_addr;   logic [63:0]  q_rdata;
  logic [1:0]   a_sel;  logic         a_re;     logic [23:0]  a_addr;  logic [127:0] a_rdata;
  logic [1:0]   b_sel;  logic         b_we;     logic [23:0]  b_addr;
  logic [127:0] b_wdata; logic [15:0] b_wstrb;

  // CPU window (free-running; keeps CPU A/B read/write logic + rdata mux alive)
  logic [31:0] cnt;
  logic        cpu_re, cpu_we;
  logic [31:0] cpu_addr, cpu_wdata, cpu_rdata;
  logic [3:0]  cpu_wstrb;
  always @(posedge clk) begin
    if (rst) cnt <= 32'd0;
    else     cnt <= cnt + 32'd1;
  end
  always_comb begin
    cpu_re    = cnt[3];
    cpu_we    = cnt[4] & cnt[5];
    cpu_addr  = NN_A_OFF + {cnt[16:2], 2'b00};
    cpu_wdata = cnt;
    cpu_wstrb = cpu_we ? 4'hF : 4'h0;
  end

  nn_mem_wpipe u_mem (
    .clk(clk), .rst(rst),
    .cpu_re(cpu_re), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
    .cpu_wdata(cpu_wdata), .cpu_wstrb(cpu_wstrb), .cpu_rdata(cpu_rdata),
    .w_re(w_re), .w_addr(w_addr), .w_rdata(w_rdata),
    .q_re(q_re), .q_addr(q_addr), .q_rdata(q_rdata),
    .a_sel(a_sel), .a_re(a_re), .a_addr(a_addr), .a_rdata(a_rdata),
    .b_sel(b_sel), .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wdata), .b_wstrb(b_wstrb),
    .dbg_we(1'b0), .dbg_space(1'b0), .dbg_addr(17'd0), .dbg_wdata(32'd0)
  );

  nn_conv_engine #(.OC_LANES(16), .PX_LANES(8), .W_RD_LAT(2)) u_eng (
    .clk(clk), .rst(rst), .desc(desc), .start(start),
    .busy(busy), .done(done), .cycles(cycles), .err_code(err_code),
    .w_re(w_re), .w_addr(w_addr), .w_rdata(w_rdata),
    .q_re(q_re), .q_addr(q_addr), .q_rdata(q_rdata),
    .a_sel(a_sel), .a_re(a_re), .a_addr(a_addr), .a_rdata(a_rdata),
    .b_sel(b_sel), .b_we(b_we), .b_addr(b_addr),
    .b_wdata_128(b_wdata), .b_wstrb(b_wstrb)
  );

  assign w_rdata_o   = w_rdata;
  assign q_rdata_o   = q_rdata;
  assign a_rdata_o   = a_rdata;
  assign b_wdata_o   = b_wdata;
  assign b_wstrb_o   = b_wstrb;
  assign cpu_rdata_o = cpu_rdata;

endmodule
