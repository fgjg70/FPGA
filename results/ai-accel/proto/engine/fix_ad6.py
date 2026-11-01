# -*- coding: utf-8 -*-
"""ADD_R LUT 乘法再打一拍: ad_qq(FF) -> ad_mul(FF) 单独一级, 修 125MHz 最差路径;
   写回路径: R1,R2,WR(qq+dst),WR2(mul),WR3(delta shift),WR4(write+advance) = 6 拍/字。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:220]
    s = s.replace(old, new, 1)


rep("""    S_CP_RD, S_CP_WR, S_AD_Q, S_AD_R1, S_AD_R2, S_AD_WR, S_AD_WR2, S_AD_WR3, S_FIN""",
    """    S_CP_RD, S_CP_WR, S_AD_Q, S_AD_R1, S_AD_R2, S_AD_WR, S_AD_WR2, S_AD_WR3, S_AD_WR4, S_FIN""")

# S_AD_WR: 只算 qq + 存 dst (去掉 mul)
rep("""            for (int l = 0; l < 8; l++) begin
              qs = $signed(src_word_q[l*8 +: 8]);
              ad_qq[l]  <= (qs - zp_s_r);
              ad_mul[l] <= ($signed(qs) - $signed(zp_s_r)) * $signed({1'b0, add_r_r});
            end""",
    """            for (int l = 0; l < 8; l++) begin
              qs = $signed(src_word_q[l*8 +: 8]);
              ad_qq[l]  <= (qs - zp_s_r);
            end""")
rep("""        S_AD_WR: begin
          begin : ad_qq_calc""",
    """        S_AD_WR2: begin
          begin : ad_mul_calc
            for (int l = 0; l < 8; l++)
              ad_mul[l] <= $signed(ad_qq[l]) * $signed({1'b0, add_r_r});
          end
          state <= S_AD_WR3;
        end
        S_AD_WR: begin
          begin : ad_qq_calc""")

# 原 S_AD_WR2 (算 delta) 改名为 WR3; 新 WR2 只管 mul (上面已插)
rep("""        S_AD_WR2: begin
          begin : ad_delta_calc
            logic signed [31:0] p;
            for (int l = 0; l < 8; l++) begin
              if (f_add_r) begin
                p = ad_mul[l] >>> kadd_r;
                ad_delta[l] <= 9'(p[8:0]);
              end
              else begin
                ad_delta[l] <= ad_qq[l];
              end
            end
          end
          state <= S_AD_WR3;
        end""",
    """        S_AD_WR3: begin
          begin : ad_delta_calc
            logic signed [31:0] p;
            for (int l = 0; l < 8; l++) begin
              if (f_add_r) begin
                p = ad_mul[l] >>> kadd_r;
                ad_delta[l] <= 9'(p[8:0]);
              end
              else begin
                ad_delta[l] <= ad_qq[l];
              end
            end
          end
          state <= S_AD_WR4;
        end""")

# 端口块写 + 推进: S_AD_WR3 -> S_AD_WR4
rep("""      S_AD_WR3: begin
        begin : ad_wr""", """      S_AD_WR4: begin
        begin : ad_wr""")
rep("""        S_AD_WR3: begin
          if (c_cb + 16'd1 < icb_n_r) begin""", """        S_AD_WR4: begin
          if (c_cb + 16'd1 < icb_n_r) begin""")
# 推进分支里回到 S_AD_R1 的不变; FIN 也不变

io.open(P, "w", encoding="utf-8").write(s)
print("AD path 6 stages applied")
