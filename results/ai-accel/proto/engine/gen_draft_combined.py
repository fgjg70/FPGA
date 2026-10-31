# -*- coding: utf-8 -*-
"""生成叠加草稿 v2bc = B(one-hot) + C(48 位 requant) + base0 去 DSP。
只落盘 proto/engine/draft/。"""
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
    """  // v2bc: |acc*M| < 2^46 (acc int32 x M int16), 右移只减小 -> 48 位足够
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

# ---- base0_a: pad*(row_step+ic8) 用移位/加法 (pad<=4) 代替乘法 ----
rep("""              base0_a     <= d_src[23:0]
                             - ({21'd0, pad_r} * (row_step_a + {8'd0, ic8_r}));""",
    """              // pad<=4: 用移位/加法代替小乘法, 去掉一个 DSP (原 DSP->base0_a 是 6.5ns 链)
              base0_a     <= d_src[23:0] - base0_sub;""")
rep("""  wire signed [15:0] y_ky0 = $signed({2'b0, c_oy}) * (st2_r ? 16'sd2 : 16'sd1)
                             - $signed({13'd0, pad_r});""",
    """  wire [23:0] rs_ic    = row_step_a + {8'd0, ic8_r};
  wire [23:0] base0_sub = (pad_r == 3'd0) ? 24'd0 :
                          (pad_r == 3'd1) ? rs_ic :
                          (pad_r == 3'd2) ? (rs_ic << 1) :
                          (pad_r == 3'd3) ? ((rs_ic << 1) + rs_ic) : (rs_ic << 2);
  wire signed [15:0] y_ky0 = $signed({2'b0, c_oy}) * (st2_r ? 16'sd2 : 16'sd1)
                             - $signed({13'd0, pad_r});""")

io.open("draft/nn_conv_engine_v2bc.sv", "w", encoding="utf-8").write(d)
print("v2bc draft written")
