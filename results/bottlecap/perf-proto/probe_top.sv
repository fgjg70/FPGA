// probe_top.sv -- perf_probe 的自包含 OOC 顶层（task-12 item 5）
// 只有 clk/rst 输入 + 一个观测输出；内部激励用计数器/LFSR，保证输出去不掉。
// 参数由 -verilog_define 传入（非工程模式）：
//   PROBE_PX / PROBE_LANE / PROBE_DSP_PX / PROBE_REQ_LANES
`timescale 1ns/1ps

module probe_top #(
  parameter int PX        = `PROBE_PX,
  parameter int LANE      = `PROBE_LANE,
  parameter int DSP_PX    = `PROBE_DSP_PX,
  parameter int REQ_LANES = `PROBE_REQ_LANES
)(
  input  logic clk,
  input  logic rst,
  output logic [31:0] probe_o
);
  logic vld;
  logic [15:0] cnt;
  logic [31:0] lfsr;
  logic signed [7:0]  a_in  [0:PX-1];
  logic signed [15:0] w_in  [0:LANE-1];
  logic signed [7:0]  y_out [0:PX-1][0:LANE-1];

  // 全地址/全数据激励（避免被综合裁掉）
  always_ff @(posedge clk) begin
    if (rst) begin
      cnt  <= 16'd0;
      lfsr <= 32'h1;
      vld  <= 1'b0;
    end else begin
      cnt  <= cnt + 16'd1;
      lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      vld  <= (cnt[2:0] != 3'd0);
    end
  end

  genvar g, l;
  generate
    for (g = 0; g < PX; g++) begin : g_a
      assign a_in[g] = $signed(lfsr[7:0]) + $signed(cnt[7:0]);
    end
    for (l = 0; l < LANE; l++) begin : g_w
      assign w_in[l] = $signed({lfsr[15:8], lfsr[7:0]}) + $signed({8'd0, cnt[7:0]});
    end
  endgenerate

  perf_probe #(.PX(PX), .LANE(LANE), .DSP_PX(DSP_PX), .REQ_LANES(REQ_LANES))
  u_dut (
    .clk(clk), .rst(rst), .vld(vld),
    .a_in(a_in), .w_in(w_in), .y_out(y_out)
  );

  // 观测口：把结果异或折叠成一个 32bit 输出（keep 住整条链）
  logic [31:0] fold;
  integer i, j;
  always_comb begin
    fold = 32'd0;
    for (i = 0; i < PX; i++)
      for (j = 0; j < LANE; j++)
        fold = fold ^ {24'd0, y_out[i][j]} ^ (32'(i * LANE + j) << 8);
  end
  (* keep = "true" *) logic [31:0] fold_q;
  always_ff @(posedge clk) fold_q <= fold;
  assign probe_o = fold_q;
endmodule
