# -*- coding: utf-8 -*-
"""DSP 169->160 第一步: ADD_R 的 8 路 (qs-zp_s)*R 乘法移到 LUT。
   做法: S_AD_WR 用 src_word_q 直接算乘积存入 (* use_dsp="no" *) ad_mul[8];
        S_AD_WR2 用寄存后的 ad_mul 做 >>>KADD 得 delta (仍是加法/移位, 不占 DSP)。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:220]
    s = s.replace(old, new, 1)


rep("""  logic signed [8:0] ad_qq [0:7];""",
    """  logic signed [8:0] ad_qq [0:7];
  (* use_dsp = "no" *) logic signed [31:0] ad_mul [0:7];""")

# S_AD_WR: 用 src_word_q 直接算乘积 (LUT)
rep("""            for (int l = 0; l < 8; l++) begin
              qs = $signed(src_word_q[l*8 +: 8]);
              ad_qq[l] <= (qs - zp_s_r);
            end""",
    """            for (int l = 0; l < 8; l++) begin
              qs = $signed(src_word_q[l*8 +: 8]);
              ad_qq[l]  <= (qs - zp_s_r);
              ad_mul[l] <= ($signed(qs) - $signed(zp_s_r)) * $signed({1'b0, add_r_r});
            end""")

# S_AD_WR2: 用寄存后的 ad_mul >>> KADD
rep("""            for (int l = 0; l < 8; l++) begin
              if (f_add_r) begin
                p = $signed(ad_qq[l]) * $signed({1'b0, add_r_r});
                p = p >>> kadd_r;
                ad_delta[l] <= 9'(p[8:0]);
              end
              else begin
                ad_delta[l] <= ad_qq[l];
              end
            end""",
    """            for (int l = 0; l < 8; l++) begin
              if (f_add_r) begin
                p = ad_mul[l] >>> kadd_r;
                ad_delta[l] <= 9'(p[8:0]);
              end
              else begin
                ad_delta[l] <= ad_qq[l];
              end
            end""")

rep("""      for (int l = 0; l < 8; l++) begin ad_delta[l] <= 9'sd0; ad_qq[l] <= 9'sd0; end""",
    """      for (int l = 0; l < 8; l++) begin
        ad_delta[l] <= 9'sd0; ad_qq[l] <= 9'sd0; ad_mul[l] <= 32'sd0;
      end""")

io.open(P, "w", encoding="utf-8").write(s)
print("ADD_R multiply moved to LUT (ad_mul)")
