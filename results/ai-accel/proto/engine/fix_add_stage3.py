# -*- coding: utf-8 -*-
"""ADD/ADD_R 再切一级 (S_AD_WR3): S_AD_WR 存 dst + qs-zp_s; S_AD_WR2 算 delta(*R>>KADD);
   S_AD_WR3 饱和 pack + 写回 + 推进。修最差路径 src_word_q -> ad_delta。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:220]
    s = s.replace(old, new, 1)


rep("""    S_CP_RD, S_CP_WR, S_AD_Q, S_AD_R1, S_AD_R2, S_AD_WR, S_AD_WR2, S_FIN""",
    """    S_CP_RD, S_CP_WR, S_AD_Q, S_AD_R1, S_AD_R2, S_AD_WR, S_AD_WR2, S_AD_WR3, S_FIN""")
rep("""  logic signed [8:0] ad_delta [0:7];
  logic [63:0] ad_dst_q;""",
    """  logic signed [8:0] ad_delta [0:7];
  logic signed [8:0] ad_qq [0:7];
  logic [63:0] ad_dst_q;""")

# S_AD_WR: 只做 qs-zp_s + 存 dst
rep("""        S_AD_WR: begin
          begin : ad_delta_calc
            logic signed [7:0]  qs;
            logic signed [31:0] p;
            logic [63:0]        dword;
            dword = rd_half_d ? a_rdata[127:64] : a_rdata[63:0];
            ad_dst_q <= dword;
            for (int l = 0; l < 8; l++) begin
              qs = $signed(src_word_q[l*8 +: 8]);
              if (f_add_r) begin
                p = ($signed(qs) - $signed(zp_s_r)) * $signed({1'b0, add_r_r});
                p = p >>> kadd_r;
                ad_delta[l] <= 9'(p[8:0]);
              end
              else begin
                ad_delta[l] <= {qs[7], qs};
              end
            end
          end
          state <= S_AD_WR2;
        end""",
    """        S_AD_WR: begin
          begin : ad_qq_calc
            logic signed [7:0] qs;
            logic [63:0]       dword;
            dword = rd_half_d ? a_rdata[127:64] : a_rdata[63:0];
            ad_dst_q <= dword;
            for (int l = 0; l < 8; l++) begin
              qs = $signed(src_word_q[l*8 +: 8]);
              ad_qq[l] <= (qs - zp_s_r);
            end
          end
          state <= S_AD_WR2;
        end
        S_AD_WR2: begin
          begin : ad_delta_calc
            logic signed [31:0] p;
            for (int l = 0; l < 8; l++) begin
              if (f_add_r) begin
                p = $signed(ad_qq[l]) * $signed({1'b0, add_r_r});
                p = p >>> kadd_r;
                ad_delta[l] <= 9'(p[8:0]);
              end
              else begin
                ad_delta[l] <= ad_qq[l];
              end
            end
          end
          state <= S_AD_WR3;
        end""")

# 端口块: 写移到 S_AD_WR3; 原 S_AD_WR2 推进逻辑改到 S_AD_WR3
rep("""      S_AD_WR2: begin
        begin : ad_wr""", """      S_AD_WR3: begin
        begin : ad_wr""")
rep("""        S_AD_WR2: begin
          if (c_cb + 16'd1 < icb_n_r) begin""", """        S_AD_WR3: begin
          if (c_cb + 16'd1 < icb_n_r) begin""")

# reset
rep("""      for (int l = 0; l < 8; l++) ad_delta[l] <= 9'sd0;""",
    """      for (int l = 0; l < 8; l++) begin ad_delta[l] <= 9'sd0; ad_qq[l] <= 9'sd0; end""")

io.open(P, "w", encoding="utf-8").write(s)
print("ADD pipeline add one more stage")
