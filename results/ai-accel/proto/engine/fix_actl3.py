# -*- coding: utf-8 -*-
"""重试: act_l=2*qb_w_r + oc_base_w 简化 (用短唯一子串, 避免缩进匹配问题)。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""  wire [15:0] act_l = (oc8_r > (c_ocb * ocw_r))
                     ? (((oc8_r - c_ocb * ocw_r) >= ocw_r) ? ocw_r
                                                           : (oc8_r - c_ocb * ocw_r))
                     : 16'd0;""",
    """  wire [15:0] act_l = {{10{1'b0}}, qb_w_r, 1'b0};      // 2*qb_w_r (寄存器)
  wire [15:0] oc_base_w = oc8_r - act_l - rem_ch;     // 当前 tile 起始 OC 通道 (加法, 无乘法)""")

rep("""if ((c_ocb * ocw_r + l) >= d_oc) bb = zp_out;""",
    """if ((oc_base_w + 16'(l)) >= d_oc) bb = zp_out;""")

rep("""d_woff[23:0] + (c_ocb * ocw_r)""",
    """d_woff[23:0] + {8'd0, oc_base_w}""")

io.open(P, "w", encoding="utf-8").write(s)
print("act_l/oc_base retried OK")
