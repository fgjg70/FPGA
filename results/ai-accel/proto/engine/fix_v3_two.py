# -*- coding: utf-8 -*-
"""修 (a) 2-beat wpx 步进奇偶 (beat 从 c_p=6 起, c_p 偶 = beat 偶 -> +8);
      (b) ADD_R Q 参数捕获移到 S_AD_R2 (q 打拍后 2 拍有效)。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


rep("""            wpx <= wpx + (c_p[0] ? 24'd8 : (px_bytes - 24'd8));""",
    """            wpx <= wpx + (c_p[0] ? (px_bytes - 24'd8) : 24'd8);""")

rep("""        S_AD_R1: begin
          rd_half_s <= src_la[3];
          if (f_add_r && (c_iy == 16'd0) && (c_ix == 16'd0) && (c_cb == 16'd0)) begin
            zp_s_r  <= q_rdata[7:0];
            zp_d_r  <= q_rdata[15:8];
            add_r_r <= {q_rdata[31:24], q_rdata[23:16]};
            kadd_r  <= q_rdata[39:32];
          end
          state <= S_AD_R2;
        end
        S_AD_R2: begin
          rd_half_d  <= dst_la[3];
          src_word_q <= rd_half_s ? a_rdata[127:64] : a_rdata[63:0];
          state      <= S_AD_WR;
        end""",
    """        S_AD_R1: begin
          rd_half_s <= src_la[3];
          state <= S_AD_R2;
        end
        S_AD_R2: begin
          rd_half_d  <= dst_la[3];
          src_word_q <= rd_half_s ? a_rdata[127:64] : a_rdata[63:0];
          // q 口打拍后: S_AD_Q 发出 -> 第 2 拍(本拍)数据有效
          if (f_add_r && (c_iy == 16'd0) && (c_ix == 16'd0) && (c_cb == 16'd0)) begin
            zp_s_r  <= q_rdata[7:0];
            zp_d_r  <= q_rdata[15:8];
            add_r_r <= {q_rdata[31:24], q_rdata[23:16]};
            kadd_r  <= q_rdata[39:32];
          end
          state      <= S_AD_WR;
        end""")

io.open(P, "w", encoding="utf-8").write(s)
print("wpx parity + add_r capture fixes applied")
