# -*- coding: utf-8 -*-
"""ADD/ADD_R 组合路径切分: S_AD_WR 只算 ad_pack 并寄存, 新增 S_AD_WR2 写回 (+1 拍/字)。
   修 OOC 100MHz 最差路径 src_word_q -> b_wdata_q (ad_pack 乘法+移位+饱和+pack 一拍)。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:250]
    s = s.replace(old, new, 1)


# 1) 状态枚举 + 寄存器
rep("""    S_CP_RD, S_CP_WR, S_AD_Q, S_AD_R1, S_AD_R2, S_AD_WR, S_FIN""",
    """    S_CP_RD, S_CP_WR, S_AD_Q, S_AD_R1, S_AD_R2, S_AD_WR, S_AD_WR2, S_FIN""")
rep("""  logic [63:0] ad_pack;""", """  logic [63:0] ad_pack;
  logic [63:0] ad_pack_q;""")

# 2) 端口块: S_AD_WR 不再写, S_AD_WR2 写 (用寄存的 ad_pack_q)
rep("""      S_AD_WR: begin
        begin : ad_wr
          logic [3:0] sh;
          sh = dst_la[3:0];
          b_we_c    = 1'b1;
          b_addr_c  = {dst_la[23:4], 4'h0};
          b_wdata_c = (sh == 4'd8) ? {ad_pack, 64'd0} : {64'd0, ad_pack};
          b_wstrb_c = (sh == 4'd8) ? 16'hFF00 : 16'h00FF;
        end
      end""",
    """      S_AD_WR2: begin
        begin : ad_wr
          logic [3:0] sh;
          sh = dst_la[3:0];
          b_we_c    = 1'b1;
          b_addr_c  = {dst_la[23:4], 4'h0};
          b_wdata_c = (sh == 4'd8) ? {ad_pack_q, 64'd0} : {64'd0, ad_pack_q};
          b_wstrb_c = (sh == 4'd8) ? 16'hFF00 : 16'h00FF;
        end
      end""")

# 3) FSM: S_AD_WR 计算 -> 新 S_AD_WR2 推进; 原推进逻辑移入 S_AD_WR2
rep("""        S_AD_R2: begin
          rd_half_d  <= dst_la[3];
          src_word_q <= rd_half_s ? a_rdata[127:64] : a_rdata[63:0];""",
    """        S_AD_R2: begin
          rd_half_d  <= dst_la[3];
          src_word_q <= rd_half_s ? a_rdata[127:64] : a_rdata[63:0];""")
rep("""        S_AD_WR: begin
          if (c_cb + 16'd1 < icb_n_r) begin
            c_cb   <= c_cb + 16'd1;
            src_la <= src_la + 24'd8;
            dst_la <= dst_la + 24'd8;
            state  <= S_AD_R1;
          end
          else if (c_ix + 16'd1 < d_iw) begin
            c_cb   <= 16'd0;
            c_ix   <= c_ix + 16'd1;
            src_la <= src_la + 24'd8;
            dst_la <= dst_la + 24'd8;
            state  <= S_AD_R1;
          end
          else if (c_iy + 16'd1 < d_ih) begin
            c_cb   <= 16'd0;
            c_ix   <= 16'd0;
            c_iy   <= c_iy + 16'd1;
            src_la <= src_la + 24'd8;
            dst_la <= dst_la + 24'd8;
            state  <= S_AD_R1;
          end
          else state <= S_FIN;
        end""",
    """        S_AD_WR: begin
          ad_pack_q <= ad_pack;
          state     <= S_AD_WR2;
        end
        S_AD_WR2: begin
          if (c_cb + 16'd1 < icb_n_r) begin
            c_cb   <= c_cb + 16'd1;
            src_la <= src_la + 24'd8;
            dst_la <= dst_la + 24'd8;
            state  <= S_AD_R1;
          end
          else if (c_ix + 16'd1 < d_iw) begin
            c_cb   <= 16'd0;
            c_ix   <= c_ix + 16'd1;
            src_la <= src_la + 24'd8;
            dst_la <= dst_la + 24'd8;
            state  <= S_AD_R1;
          end
          else if (c_iy + 16'd1 < d_ih) begin
            c_cb   <= 16'd0;
            c_ix   <= 16'd0;
            c_iy   <= c_iy + 16'd1;
            src_la <= src_la + 24'd8;
            dst_la <= dst_la + 24'd8;
            state  <= S_AD_R1;
          end
          else state <= S_FIN;
        end""")

# 4) reset
rep("""      zp_s_r <= 8'sd0; zp_d_r <= 8'sd0; add_r_r <= 16'd0; kadd_r <= 8'd0;""",
    """      zp_s_r <= 8'sd0; zp_d_r <= 8'sd0; add_r_r <= 16'd0; kadd_r <= 8'd0;
      ad_pack_q <= 64'd0;""")

io.open(P, "w", encoding="utf-8").write(s)
print("add pipeline split applied")
