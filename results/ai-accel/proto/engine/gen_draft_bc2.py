# -*- coding: utf-8 -*-
"""v2bc2 = B(one-hot) + C(48bit requant) + base0_a 两级拆分 (pad*row_step 先寄存)。"""
import io

src = io.open("draft/nn_conv_engine_v2b.sv", encoding="utf-8").read()
d = src


def rep(old, new):
    global d
    assert old in d, "NOT FOUND:\n" + old[:200]
    d = d.replace(old, new, 1)


# ---- C: 48 位 requant ----
rep("""  logic signed [63:0] y64_q   [0:OCL-1];      // 右移后 (第 3 级)
  logic signed [63:0] y2_q    [0:OCL-1];      // +zp 后 (第 4 级)""",
    """  // |acc*M| < 2^46 (acc int32 x M int16), 右移只减小 -> 48 位足够
  logic signed [47:0] y64_q   [0:OCL-1];
  logic signed [47:0] y2_q    [0:OCL-1];""")
rep("""    logic signed [63:0] y2;
    logic [7:0] bb;
    logic fits;
    rq_pack = 64'd0;
    for (int l = 0; l < OCL; l++) begin
      y2   = y2_q[l];
      fits = (&y2[63:7]) || (~|y2[63:7]);        // -128 <= y2 <= 127
      if (fits) bb = y2[7:0];
      else      bb = y2[63] ? 8'h80 : 8'h7F;""",
    """    logic signed [47:0] y2;
    logic [7:0] bb;
    logic fits;
    rq_pack = 64'd0;
    for (int l = 0; l < OCL; l++) begin
      y2   = y2_q[l];
      fits = (&y2[47:7]) || (~|y2[47:7]);
      if (fits) bb = y2[7:0];
      else      bb = y2[47] ? 8'h80 : 8'h7F;""")
rep("""            y2_q[l] <= y64_q[l] + {{56{zp_out[7]}}, zp_out};""",
    """            y2_q[l] <= y64_q[l] + {{40{zp_out[7]}}, zp_out};""")
rep("""      for (int l = 0; l < OCL; l++) begin y64_q[l] <= 64'sd0; y2_q[l] <= 64'sd0; end""",
    """      for (int l = 0; l < OCL; l++) begin y64_q[l] <= 48'sd0; y2_q[l] <= 48'sd0; end""")

# ---- base0_a: pad*row_step 先在 c_p=3 算好, c_p=4 只做减法 ----
rep("""              base0_a     <= d_src[23:0]
                             - ({21'd0, pad_r} * (row_step_a + {8'd0, ic8_r}));""",
    """              base0_t     <= {21'd0, pad_r} * row_step_a;      // c_p=3: 一级乘法
              base0_t2    <= {21'd0, pad_r} * {8'd0, ic8_r};""")
rep("""            16'd4: begin
              // 再一级乘法 (与地址无关的常量)""",
    """            16'd4: begin
              base0_a     <= d_src[23:0] - base0_t - base0_t2;   // 只减法
              // 再一级乘法 (与地址无关的常量)""")
rep("""  logic [23:0] p1_2, p1_3, p1_4;""",
    """  logic [23:0] p1_2, p1_3, p1_4;
  logic [23:0] base0_t, base0_t2;""")
rep("""      p1 <= 24'd0; p1_2 <= 24'd0; p1_3 <= 24'd0; p1_4 <= 24'd0;""",
    """      p1 <= 24'd0; p1_2 <= 24'd0; p1_3 <= 24'd0; p1_4 <= 24'd0;
      base0_t <= 24'd0; base0_t2 <= 24'd0;""")

io.open("draft/nn_conv_engine_v2bc2.sv", "w", encoding="utf-8").write(d)
print("v2bc2 draft written")
