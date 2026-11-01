# -*- coding: utf-8 -*-
"""WNS 收尾: act_l 改为 2*qb_w_r (寄存器, 去掉 c_ocb*ocw_r 乘法);
   新增 oc_base_w = oc8_r - act_l - rem_ch 用于 padding 比较/权重基址 (加法代替乘法)。
   目标: 修 OOC 最差路径 ocw_r -> wrbeats_r。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


rep("""  wire [15:0] act_l = (oc8_r > (c_ocb * ocw_r))
                     ? (((oc8_r - c_ocb * ocw_r) >= ocw_r) ? ocw_r
                                                           : (oc8_r - c_ocb * ocw_r))
                     : 16'd0;""",
    """  wire [15:0] act_l = {{10{1'b0}}, qb_w_r, 1'b0};      // 2*qb_w_r (寄存器)
  wire [15:0] oc_base_w = oc8_r - act_l - rem_ch;     // 当前 tile 起始 OC 通道 (加法, 无乘法)""")

rep("""      if ((c_ocb * ocw_r + l) >= d_oc) bb = zp_out;""",
    """      if ((oc_base_w + 16'(l)) >= d_oc) bb = zp_out;""")

rep("""              wa_r   <= d_woff[23:0] + (c_ocb * ocw_r);""",
    """              wa_r   <= d_woff[23:0] + {8'd0, oc_base_w[15:0]};""")

io.open(P, "w", encoding="utf-8").write(s)
print("act_l/oc_base simplifications applied")
