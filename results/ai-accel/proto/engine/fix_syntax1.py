# -*- coding: utf-8 -*-
"""修 S_AD_R2 的语法: 用 module wire ad_src_word 代替函数返回值索引。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()

old = """        S_AD_R2: begin
          rd_half_d  <= dst_la[3];
          src_word_q <= rd_half_s ? a_rdata[127:64] : a_rdata[63:0];
          for (int l = 0; l < 8; l++)
            ad_qs[l] <= $signed((rd_half_s ? a_rdata[127:64] : a_rdata[63:0])[l*8 +: 8]);"""
new = """        S_AD_R2: begin
          rd_half_d  <= dst_la[3];
          src_word_q <= ad_src_word;
          for (int l = 0; l < 8; l++)
            ad_qs[l] <= $signed(ad_src_word[l*8 +: 8]);"""
assert old in s, "S_AD_R2 block not found"
s = s.replace(old, new, 1)

anchor = "  wire [5:0] sel_byte_base = {c_m[2:0], 3'b000};"
ins = "  wire [63:0] ad_src_word = rd_half_s ? a_rdata[127:64] : a_rdata[63:0];\n\n" + anchor
assert anchor in s
s = s.replace(anchor, ins, 1)

io.open(P, "w", encoding="utf-8").write(s)
print("syntax fix applied")
