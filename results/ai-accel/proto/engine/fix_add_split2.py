# -*- coding: utf-8 -*-
"""ADD/ADD_R 再切一级: S_AD_WR 只算 delta(=((qs-zp_s)*R)>>KADD 或 qs) 并寄存 dst 字;
   S_AD_WR2 用寄存后的 (dst,delta) 做饱和 pack + 写回 (组合 pack 到 b_wdata_q)。
   保持 4 拍/字不变 (R1,R2,WR,WR2)。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:250]
    s = s.replace(old, new, 1)


# 1) 用 delta/dst 寄存器替代整条 ad_pack 组合路径
rep("""  logic [63:0] ad_pack;
  logic [63:0] ad_pack_q;""",
    """  logic signed [8:0]  ad_delta [0:7];
  logic [63:0] ad_dst_q;
  logic [63:0] ad_pack;""")

# 2) 组合 pack: 用 ad_dst_q + ad_delta (均为寄存器输出)
rep("""  // ---------------------------------------------------------------- ADD 打包
  wire [63:0] ad_dst_word = rd_half_d ? a_rdata[127:64] : a_rdata[63:0];
  logic [63:0] ad_pack;
  always_comb begin
    logic signed [8:0]  s;
    logic signed [31:0] p;
    logic signed [7:0]  qs, qd;
    ad_pack = 64'd0;
    for (int l = 0; l < OCL; l++) begin
      if (l < 8) begin
        if (f_add_r) begin
          qs = $signed(src_word_q[l*8 +: 8]);
          qd = $signed(ad_dst_word[l*8 +: 8]);
          p  = ($signed(qs) - $signed(zp_s_r)) * $signed({1'b0, add_r_r});
          p  = p >>> kadd_r;
          p  = p + {{24{qd[7]}}, qd};
          if (p > 32'sd127)       ad_pack[l*8 +: 8] = 8'h7F;
          else if (p < -32'sd128) ad_pack[l*8 +: 8] = 8'h80;
          else                    ad_pack[l*8 +: 8] = p[7:0];
        end
        else begin
          s = $signed({src_word_q[l*8 + 7], src_word_q[l*8 +: 8]})
            + $signed({ad_dst_word[l*8 + 7], ad_dst_word[l*8 +: 8]});
          if (s > 9'sd127)       ad_pack[l*8 +: 8] = 8'h7F;
          else if (s < -9'sd128) ad_pack[l*8 +: 8] = 8'h80;
          else                   ad_pack[l*8 +: 8] = s[7:0];
        end
      end
    end
  end""",
    """  // ---------------------------------------------------------------- ADD 打包
  // S_AD_WR: delta 已在上一拍算好寄存; 这里只做 8-bit 加 + 饱和 + pack (短路径)
  logic [63:0] ad_pack;
  always_comb begin
    logic signed [9:0] s;
    logic signed [7:0] qd;
    ad_pack = 64'd0;
    for (int l = 0; l < OCL; l++) begin
      if (l < 8) begin
        qd = $signed(ad_dst_q[l*8 +: 8]);
        s  = $signed({qd[7], qd}) + $signed(ad_delta[l]);
        if (s > 10'sd127)       ad_pack[l*8 +: 8] = 8'h7F;
        else if (s < -10'sd128) ad_pack[l*8 +: 8] = 8'h80;
        else                    ad_pack[l*8 +: 8] = s[7:0];
      end
    end
  end""")

# 3) S_AD_WR: 算 delta + 存 dst; S_AD_WR2: 写 ad_pack
rep("""        S_AD_WR: begin
          ad_pack_q <= ad_pack;
          state     <= S_AD_WR2;
        end""",
    """        S_AD_WR: begin
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
        end""")

# 4) 端口块: S_AD_WR2 写 ad_pack (不再读 ad_pack_q)
rep("""      S_AD_WR2: begin
        begin : ad_wr
          logic [3:0] sh;
          sh = dst_la[3:0];
          b_we_c    = 1'b1;
          b_addr_c  = {dst_la[23:4], 4'h0};
          b_wdata_c = (sh == 4'd8) ? {ad_pack_q, 64'd0} : {64'd0, ad_pack_q};
          b_wstrb_c = (sh == 4'd8) ? 16'hFF00 : 16'h00FF;
        end
      end""",
    """      S_AD_WR2: begin
        begin : ad_wr
          logic [3:0] sh;
          sh = dst_la[3:0];
          b_we_c    = 1'b1;
          b_addr_c  = {dst_la[23:4], 4'h0};
          b_wdata_c = (sh == 4'd8) ? {ad_pack, 64'd0} : {64'd0, ad_pack};
          b_wstrb_c = (sh == 4'd8) ? 16'hFF00 : 16'h00FF;
        end
      end""")

# 5) reset
rep("""      ad_pack_q <= 64'd0;""",
    """      ad_dst_q <= 64'd0;
      for (int l = 0; l < 8; l++) ad_delta[l] <= 9'sd0;""")

io.open(P, "w", encoding="utf-8").write(s)
print("ADD path split into delta stage")
