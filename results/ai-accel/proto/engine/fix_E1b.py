# -*- coding: utf-8 -*-
"""修 E1: S_BI/S_PINIT 里 a_addr_q 必须装"与 la 同拍的新值"(nonblocking 下 la 还是旧值)。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


rep("""      else if (state == S_BI)                a_addr_q <= la;
      else if (state == S_PINIT)             a_addr_q <= la;""",
    """      else if (state == S_BI)                a_addr_q <= f_p3 ? blk_base
                                                          : (f_dw ? (blk_base + (c_ocb << 3)) : blk_base);
      else if (state == S_PINIT)             a_addr_q <= blk_base + (c_ocb << 3);""")
io.open(P, "w", encoding="utf-8").write(s)
print("E1 entry fix applied")
