// addmode_probe.sv -- Step A（conv add-mode）OOC 数据通路探针（task-14 pre-green-light）
// ASCII only, self-contained, Verilog-2001/2018.3 friendly.
//
// 结构对齐当前 v0.8 引擎（nn_conv_engine.sv:777-811 requant + :388-441 ADD_R/ReLU）：
//   16 lane 时间复用：acc_sel -> (prod_hi, prod_lo) 17x16 DSP -> prod64 -> y2 -> +zp_out = q_s
//   WITH_ADD=1 时：q_s -> (q_s - zp_s)*R >> KADD + q_d -> clamp -> ReLU(zp_d)
// 对比两个配置的 LUT/FF/DSP/fmax，得到 Step A conv add-mode 的硬件增量。
`timescale 1ns/1ps

module addmode_probe #(
  parameter bit WITH_ADD = 1'b1
)(
  input  logic        clk,
  input  logic        rst,
  output logic [31:0] probe_o
);
  localparam int LANE = 16;

  logic [15:0] cnt;
  logic [31:0] lfsr;
  logic        vld;
  logic signed [31:0] acc_sel [0:LANE-1];
  logic signed [15:0] m_sel   [0:LANE-1];

  always_ff @(posedge clk) begin
    if (rst) begin
      cnt <= 16'd0; lfsr <= 32'h1; vld <= 1'b0;
    end else begin
      cnt  <= cnt + 16'd1;
      lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      vld  <= 1'b1;
    end
  end

  // ---- 输入激励 ----
  integer i;
  always_ff @(posedge clk) begin
    for (i = 0; i < LANE; i++) begin
      acc_sel[i] <= $signed({lfsr[15:0], cnt[15:0]}) + $signed(i[15:0]);
      m_sel[i]   <= $signed({lfsr[11:0], 4'h0}) + $signed(i[15:0]);
    end
  end

  // ---- requant（17x16 DSP 乘，与引擎同构）----
  logic signed [31:0] prod_hi [0:LANE-1];
  logic signed [31:0] prod_lo [0:LANE-1];
  logic signed [47:0] prod64  [0:LANE-1];
  logic signed [47:0] y2_q    [0:LANE-1];
  logic signed [7:0]  zp_out, zp_s, zp_d;
  logic [3:0]         kadd;
  logic [15:0]        add_r_16;

  assign zp_out  = 8'sd12;
  assign zp_s    = 8'sd3;
  assign zp_d    = 8'sd3;
  assign kadd    = 4'd6;
  assign add_r_16 = 16'd4096;

  genvar gl;
  generate
    for (gl = 0; gl < LANE; gl++) begin : g_rq
      (* use_dsp = "yes" *) wire signed [31:0] ph = $signed(acc_sel[gl][31:16]) * m_sel[gl];
      (* use_dsp = "yes" *) wire signed [31:0] pl = $signed({1'b0, acc_sel[gl][15:0]}) * m_sel[gl];
      assign prod_hi[gl] = ph;
      assign prod_lo[gl] = pl;
      assign prod64[gl]  = $signed({{16{ph[31]}}, ph}) + ($signed({{16{pl[31]}}, pl}) <<< 16);
      assign y2_q[gl]    = prod64[gl] >>> 16;
    end
  endgenerate

  // ---- q_s（requant 后的 int8）----
  logic signed [7:0] qs [0:LANE-1];
  always_ff @(posedge clk) begin
    for (i = 0; i < LANE; i++) qs[i] <= y2_q[i][7:0] + zp_out;
  end

  // ---- ADD_R 累加 + 后置 ReLU（WITH_ADD=1 才有）----
  logic signed [7:0] ad_qd [0:LANE-1];
  logic signed [7:0] out_b [0:LANE-1];
  always_ff @(posedge clk) begin
    for (i = 0; i < LANE; i++) ad_qd[i] <= $signed(lfsr[7:0]) + $signed(i[7:0]);
  end

  generate
    if (WITH_ADD) begin : g_add
      logic signed [8:0]  d;
      logic signed [31:0] m;
      logic signed [31:0] p;
      logic signed [9:0]  s;
      integer j;
      always_comb begin
        for (j = 0; j < LANE; j++) begin
          d = $signed(qs[j]) - $signed(zp_s);
          (* use_dsp = "no" *) m = d * $signed({1'b0, add_r_16});
          p = m >>> kadd;
          s = $signed(ad_qd[j]) + $signed(p[9:0]);
          if (s > 10'sd127)       out_b[j] = 8'sd127;
          else if (s < -10'sd128) out_b[j] = -8'sd128;
          else                    out_b[j] = s[7:0];
          if (out_b[j] < zp_d)    out_b[j] = zp_d;   // 后置 ReLU（下界=zp_d）
        end
      end
    end else begin : g_noadd
      integer j;
      always_comb begin
        for (j = 0; j < LANE; j++) out_b[j] = qs[j];
      end
    end
  endgenerate

  // ---- 观测口（keep 住整条链）----
  logic [31:0] fold;
  integer k;
  always_comb begin
    fold = 32'd0;
    for (k = 0; k < LANE; k++) fold = fold ^ {24'd0, out_b[k]} ^ (32'(k) << 8);
  end
  (* keep = "true" *) logic [31:0] fold_q;
  always_ff @(posedge clk) fold_q <= fold;
  assign probe_o = fold_q;
endmodule


// ---- 顶层包装（用参数区分配置；-verilog_define 只对宏生效，不改 parameter）----
module addmode_top_noadd (
  input  logic        clk,
  input  logic        rst,
  output logic [31:0] probe_o
);
  addmode_probe #(.WITH_ADD(1'b0)) u_dut (.clk(clk), .rst(rst), .probe_o(probe_o));
endmodule

module addmode_top_add (
  input  logic        clk,
  input  logic        rst,
  output logic [31:0] probe_o
);
  addmode_probe #(.WITH_ADD(1'b1)) u_dut (.clk(clk), .rst(rst), .probe_o(probe_o));
endmodule
