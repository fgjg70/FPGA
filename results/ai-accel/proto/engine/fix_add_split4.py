# -*- coding: utf-8 -*-
"""ADD/ADD_R 两级切分 (纯 ASCII 锚点版)。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


rep("""  logic [63:0] ad_pack;
  logic [63:0] ad_pack_q;""",
    """  logic [63:0] ad_pack;
  logic [63:0] ad_pack_q;
  logic signed [8:0] ad_delta [0:7];
  logic [63:0] ad_dst_q;""")

rep("""  wire [5:0] sel_byte_base = {c_m[2:0], 3'b000};""",
    """  logic [63:0] ad_pack2;
  always_comb begin
    logic signed [9:0] s2;
    logic signed [7:0] qd2;
    ad_pack2 = 64'd0;
    for (int l = 0; l < 8; l++) begin
      qd2 = $signed(ad_dst_q[l*8 +: 8]);
      s2  = $signed({qd2[7], qd2}) + $signed(ad_delta[l]);
      if (s2 > 10'sd127)       ad_pack2[l*8 +: 8] = 8'h7F;
      else if (s2 < -10'sd128) ad_pack2[l*8 +: 8] = 8'h80;
      else                     ad_pack2[l*8 +: 8] = s2[7:0];
    end
  end

  wire [5:0] sel_byte_base = {c_m[2:0], 3'b000};""")

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

rep("""          b_wdata_c = (sh == 4'd8) ? {ad_pack_q, 64'd0} : {64'd0, ad_pack_q};""",
    """          b_wdata_c = (sh == 4'd8) ? {ad_pack2, 64'd0} : {64'd0, ad_pack2};""")

rep("""      ad_pack_q <= 64'd0;""",
    """      ad_pack_q <= 64'd0; ad_dst_q <= 64'd0;
      for (int l = 0; l < 8; l++) ad_delta[l] <= 9'sd0;""")

io.open(P, "w", encoding="utf-8").write(s)
print("ADD two-stage split applied (ascii anchors)")
