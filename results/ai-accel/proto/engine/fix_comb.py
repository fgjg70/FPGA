# -*- coding: utf-8 -*-
"""(1) AD 路径回到 5 拍/字: ad_qs (src 字节) 在 S_AD_R2 直接寄存, S_AD_WR 从 ad_qs 算 qq+mul
     (A1 同块结构, use_dsp="no" 生效 -> DSP 160); 去掉 S_AD_WR3 那一级 -> 写回在 S_AD_WR3。
   (2) icb_last_r: 预打拍 (c_icb+1<icb_n) 标志, S_LDCAP 不再从 c_icb 比较出发 -> 修 c_icb->la 路径。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:220]
    s = s.replace(old, new, 1)


# ---------- (1) AD 5 拍 ----------
rep("""    S_CP_RD, S_CP_WR, S_AD_Q, S_AD_R1, S_AD_R2, S_AD_WR, S_AD_WR2, S_AD_WR3, S_AD_WR4, S_FIN""",
    """    S_CP_RD, S_CP_WR, S_AD_Q, S_AD_R1, S_AD_R2, S_AD_WR, S_AD_WR2, S_AD_WR3, S_FIN""")
rep("""  logic signed [8:0] ad_qq [0:7];
  (* use_dsp = "no" *) logic signed [31:0] ad_mul [0:7];""",
    """  logic signed [8:0] ad_qq [0:7];
  logic signed [7:0] ad_qs [0:7];
  (* use_dsp = "no" *) logic signed [31:0] ad_mul [0:7];""")

# S_AD_R2: 同时寄存 src 字节
rep("""        S_AD_R2: begin
          rd_half_d  <= dst_la[3];
          src_word_q <= rd_half_s ? a_rdata[127:64] : a_rdata[63:0];""",
    """        S_AD_R2: begin
          rd_half_d  <= dst_la[3];
          src_word_q <= rd_half_s ? a_rdata[127:64] : a_rdata[63:0];
          for (int l = 0; l < 8; l++)
            ad_qs[l] <= $signed((rd_half_s ? a_rdata[127:64] : a_rdata[63:0])[l*8 +: 8]);""")

# S_AD_WR: 从 ad_qs 算 qq + mul (同块, 属性生效); 删除原 S_AD_WR2 mul 级
rep("""            for (int l = 0; l < 8; l++) begin
              qs = $signed(src_word_q[l*8 +: 8]);
              ad_qq[l]  <= (qs - zp_s_r);
            end""",
    """            for (int l = 0; l < 8; l++) begin
              qs = ad_qs[l];
              ad_qq[l]  <= (qs - zp_s_r);
              ad_mul[l] <= ($signed(qs) - $signed(zp_s_r)) * $signed({1'b0, add_r_r});
            end""")
rep("""        S_AD_WR2: begin
          begin : ad_mul_calc
            for (int l = 0; l < 8; l++)
              ad_mul[l] <= $signed(ad_qq[l]) * $signed({1'b0, add_r_r});
          end
          state <= S_AD_WR3;
        end
        S_AD_WR: begin""",
    """        S_AD_WR: begin""")
rep("""        S_AD_WR3: begin
          begin : ad_delta_calc""",
    """        S_AD_WR2: begin
          begin : ad_delta_calc""")
rep("""          state <= S_AD_WR4;
        end""", """          state <= S_AD_WR3;
        end""")
rep("""      S_AD_WR4: begin
        begin : ad_wr""", """      S_AD_WR3: begin
        begin : ad_wr""")
rep("""        S_AD_WR4: begin
          if (c_cb + 16'd1 < icb_n_r) begin""", """        S_AD_WR3: begin
          if (c_cb + 16'd1 < icb_n_r) begin""")
rep("""      for (int l = 0; l < 8; l++) begin
        ad_delta[l] <= 9'sd0; ad_qq[l] <= 9'sd0; ad_mul[l] <= 32'sd0;
      end""",
    """      for (int l = 0; l < 8; l++) begin
        ad_delta[l] <= 9'sd0; ad_qq[l] <= 9'sd0; ad_mul[l] <= 32'sd0; ad_qs[l] <= 8'sd0;
      end""")

# ---------- (2) icb_last_r ----------
rep("""  logic [15:0] rem_ch;""",
    """  logic        icb_more_r;                  // (c_icb+1 < icb_n) 预打拍
  logic [15:0] rem_ch;""")
# S_BI 初始化
rep("""          c_ky   <= 16'd0;
          c_icb  <= 16'd0;
          c_m    <= 16'd0;
          c_ld   <= 16'd0;
          p3_ph  <= 2'd0;""",
    """          c_ky   <= 16'd0;
          c_icb  <= 16'd0;
          c_m    <= 16'd0;
          c_ld   <= 16'd0;
          p3_ph  <= 2'd0;
          icb_more_r <= (16'd1 < icb_n_r);""")
# S_MAC 里 c_icb++ 处 (dense)
rep("""              if (c_icb + 16'd1 < icb_n_r) begin
                c_icb <= c_icb + 16'd1;
                c_ld  <= 16'd0;
                x_ld  <= x0_ld;""",
    """              if (c_icb + 16'd1 < icb_n_r) begin
                c_icb <= c_icb + 16'd1;
                icb_more_r <= ((c_icb + 16'd2) < icb_n_r);
                c_ld  <= 16'd0;
                x_ld  <= x0_ld;""")
# ky advance 分支 (c_icb 归零) 两处: dense 与 dw; dw 不用 icb_more, 只 dense 需要
rep("""              else if (c_ky + 16'd1 < ks16) begin
                c_ky  <= c_ky + 16'd1;
                c_icb <= 16'd0;
                c_ld  <= 16'd0;
                x_ld  <= x0_ld;
                y_ld  <= y_ld + 16'sd1;
                y_ok_r <= ((y_ld + 16'sd1) >= 0) && ((y_ld + 16'sd1) < $signed(d_ih));
                state <= S_LD;
              end
              else begin
                c_drn <= 3'd0;
                state <= S_DRN;
              end
            end
          end
          else begin""",
    """              else if (c_ky + 16'd1 < ks16) begin
                c_ky  <= c_ky + 16'd1;
                c_icb <= 16'd0;
                icb_more_r <= (16'd1 < icb_n_r);
                c_ld  <= 16'd0;
                x_ld  <= x0_ld;
                y_ld  <= y_ld + 16'sd1;
                y_ok_r <= ((y_ld + 16'sd1) >= 0) && ((y_ld + 16'sd1) < $signed(d_ih));
                state <= S_LD;
              end
              else begin
                c_drn <= 3'd0;
                state <= S_DRN;
              end
            end
          end
          else begin""")
# S_LDCAP: 用寄存器标志
rep("""          else if (dense && (c_icb + 16'd1 < icb_n_r)) begin
            band_base <= band_base + 24'd8;
            la        <= band_base + 24'd8;
          end""",
    """          else if (dense && icb_more_r) begin
            band_base <= band_base + 24'd8;
            la        <= band_base + 24'd8;
          end""")

io.open(P, "w", encoding="utf-8").write(s)
print("AD 5-stage + icb_more_r applied")
