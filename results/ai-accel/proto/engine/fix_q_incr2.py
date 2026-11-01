# -*- coding: utf-8 -*-
"""修 q 增量: 下一 tile 的 act = min(ocw, rem_ch); rem_ch 扣掉本 tile 后再更新。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


rep("""                  logic [15:0] rem_n, a_n;
                  rem_n = (rem_ch > ocw_r) ? (rem_ch - ocw_r) : 16'd0;
                  a_n   = (rem_n >= ocw_r) ? ocw_r : rem_n;
                  rem_ch   <= rem_n;""",
    """                  logic [15:0] rem_n, a_n;
                  a_n   = (rem_ch >= ocw_r) ? ocw_r : rem_ch;
                  rem_n = (rem_ch > a_n) ? (rem_ch - a_n) : 16'd0;
                  rem_ch   <= rem_n;""")
io.open(P, "w", encoding="utf-8").write(s)
print("q incr fixed")
