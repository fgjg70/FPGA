// perf_probe.sv -- 256-MAC 草稿的 OOC 数据通路探针（task-12 item 5）
//
// 目的：在**不改仓库 RTL** 的前提下，用与 nn_conv_engine.sv 同构的
//      "a_pipe2 x wby_r -> prod(16b) -> acc(32b) -> requant(17x16 乘)" 数据通路，
//      测量 MAC 阵列加宽（128 -> 192/256）对 资源(LUT/FF/DSP) 与 OOC fmax 的影响。
//
// 与真实引擎的差异（务必在报告里声明）：
//   * 不含控制 FSM / 地址生成 / Q-RO / 输出打包（这些在真实引擎里占 LUT 大头，
//     但它们不随 MAC 宽度线性增长，所以本探针给的是"数据通路增量"）。
//   * 因此绝对 LUT 数偏小；**可用的量是 Δ(256-128) 与 fmax 的相对退化**。
//
// 结构对齐（证据）：
//   nn_conv_engine.sv:207 mac_v1..mac_v4 (4 级 MAC 流水)
//   nn_conv_engine.sv:223 prod[px][oc] = a_pipe2[px][oc] * wby_r[oc]
//   nn_conv_engine.sv:239-247 acc_sel/acc_hi/acc_lo/prod_hi/prod_lo/prod64 (requant)
`timescale 1ns/1ps

module mac_dsp (
  input  logic signed [7:0]  a,
  input  logic signed [15:0] b,
  output logic signed [23:0] p
);
  (* use_dsp = "yes" *) wire signed [23:0] p_w = a * b;
  assign p = p_w;
endmodule

module mac_lut (
  input  logic signed [7:0]  a,
  input  logic signed [15:0] b,
  output logic signed [23:0] p
);
  (* use_dsp = "no" *) wire signed [23:0] p_w = a * b;
  assign p = p_w;
endmodule

module req_dsp (
  input  logic signed [16:0] hi,
  input  logic signed [15:0] m,
  output logic signed [31:0] p
);
  (* use_dsp = "yes" *) wire signed [31:0] p_w = hi * m;
  assign p = p_w;
endmodule

module perf_probe #(
  parameter int PX        = 8,   // 像素并行
  parameter int LANE      = 16,  // OC lane
  parameter int DSP_PX    = 8,   // 前 DSP_PX 个像素行用 DSP 乘（其余用 LUT 乘）
  parameter int REQ_LANES = 16   // requant 并行 lane 数（时间复用口径：16 或 LANE）
)(
  input  logic clk,
  input  logic rst,
  input  logic vld,
  input  logic signed [7:0]  a_in  [0:PX-1],
  input  logic signed [15:0] w_in  [0:LANE-1],
  output logic signed [7:0]  y_out [0:PX-1][0:LANE-1]
);
  localparam int MAC_W   = PX * LANE;
  localparam int LUT_PX  = PX - DSP_PX;

  // ---- 输入寄存级（引擎的 a_pipe/a_pipe1/a_pipe2 与 wby_r）----
  logic signed [7:0]  a_pipe  [0:PX-1][0:LANE-1];
  logic signed [7:0]  a_pipe1 [0:PX-1][0:LANE-1];
  logic signed [7:0]  a_pipe2 [0:PX-1][0:LANE-1];
  logic signed [15:0] wby_r   [0:LANE-1];

  // ---- MAC 4 级流水（与 nn_conv_engine.sv:207 的 mac_v1..v4 对齐）----
  logic mac_v1, mac_v2, mac_v3, mac_v4;

  // ---- 乘法阵列：DSP 组 + LUT 组 ----
  logic signed [23:0] prod_dsp [0:DSP_PX-1][0:LANE-1];
  logic signed [23:0] prod_lut [0:LUT_PX-1][0:LANE-1];
  logic signed [15:0] prod     [0:PX-1][0:LANE-1];
  logic signed [31:0] acc      [0:PX-1][0:LANE-1];

  // ---- requant：17x16 乘（引擎 prod_hi/prod_lo 口径），REQ_LANES 路 ----
  logic signed [16:0]  acc_hi [0:REQ_LANES-1];
  logic signed [16:0]  acc_lo [0:REQ_LANES-1];
  logic signed [15:0]  m_sel  [0:REQ_LANES-1];
  logic signed [31:0]  req_hi [0:REQ_LANES-1];
  logic signed [31:0]  req_lo [0:REQ_LANES-1];
  logic signed [47:0]  prod64 [0:REQ_LANES-1];
  logic signed [47:0]  y64    [0:REQ_LANES-1];

  genvar g, l;
  generate
    for (g = 0; g < DSP_PX; g++) begin : g_dsp
      for (l = 0; l < LANE; l++) begin : g_lane
        mac_dsp u_mac (.a(a_pipe2[g][l]), .b(wby_r[l]), .p(prod_dsp[g][l]));
      end
    end
    for (g = 0; g < LUT_PX; g++) begin : g_lut
      for (l = 0; l < LANE; l++) begin : g_lane
        mac_lut u_mac (.a(a_pipe2[DSP_PX+g][l]), .b(wby_r[l]),
                       .p(prod_lut[g][l]));
      end
    end
    for (g = 0; g < PX; g++) begin : g_mux
      for (l = 0; l < LANE; l++) begin : g_lane
        assign prod[g][l] = (g < DSP_PX) ? prod_dsp[g][l][15:0]
                                         : prod_lut[g-DSP_PX][l][15:0];
      end
    end
    for (g = 0; g < REQ_LANES; g++) begin : g_req
      req_dsp u_hi (.hi(acc_hi[g]), .m(m_sel[g]), .p(req_hi[g]));
      req_dsp u_lo (.hi(acc_lo[g]), .m(m_sel[g]), .p(req_lo[g]));
      assign prod64[g] = {{16{req_hi[g][31]}}, req_hi[g]} + ({{16{req_lo[g][31]}},
                          req_lo[g]} <<< 16);
      assign y64[g]    = prod64[g] >>> m_sel[g][3:0];
    end
  endgenerate

  // ---- 时序：4 级 MAC 流水 + acc 累加 + requant 输出 ----
  integer px, oc, r;
  always_ff @(posedge clk) begin
    if (rst) begin
      mac_v1 <= 1'b0; mac_v2 <= 1'b0; mac_v3 <= 1'b0; mac_v4 <= 1'b0;
      for (px = 0; px < PX; px++) begin
        for (oc = 0; oc < LANE; oc++) begin
          a_pipe[px][oc]  <= 8'sd0;
          a_pipe1[px][oc] <= 8'sd0;
          a_pipe2[px][oc] <= 8'sd0;
          acc[px][oc]     <= 32'sd0;
        end
      end
      for (oc = 0; oc < LANE; oc++) begin
        wby_r[oc] <= 16'sd0;
        m_sel[oc] <= 16'sd0;
      end
    end else begin
      mac_v1 <= vld; mac_v2 <= mac_v1; mac_v3 <= mac_v2; mac_v4 <= mac_v3;
      for (oc = 0; oc < LANE; oc++) wby_r[oc] <= w_in[oc];
      for (px = 0; px < PX; px++) begin
        a_pipe[px][0] <= a_in[px];
        for (oc = 1; oc < LANE; oc++) a_pipe[px][oc] <= a_pipe[px][oc-1];
        for (oc = 0; oc < LANE; oc++) begin
          a_pipe1[px][oc] <= a_pipe[px][oc];
          a_pipe2[px][oc] <= a_pipe1[px][oc];
        end
      end
      if (mac_v3) begin
        for (oc = 0; oc < REQ_LANES; oc++) begin
          acc_hi[oc] <= acc[oc % PX][oc][16:0];
          acc_lo[oc] <= acc[oc % PX][oc][31:16];
          m_sel[oc]  <= wby_r[oc];
        end
      end
      if (mac_v4) begin
        for (px = 0; px < PX; px++)
          for (oc = 0; oc < LANE; oc++) acc[px][oc] <= acc[px][oc] + prod[px][oc];
      end
      for (px = 0; px < PX; px++)
        for (oc = 0; oc < LANE; oc++)
          y_out[px][oc] <= y64[oc % REQ_LANES][7:0] ^ prod[px][oc][7:0];
    end
  end
endmodule
