# -*- coding: utf-8 -*-
"""calc_cycles_v3 支持 W_RD_LAT: DRN = W_RD_LAT + 2 (1->3, 2->4)。"""
import io

P = "calc_cycles_v3.py"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""BASE = 8          # INIT 1 + VCHK 1 + CPREP 6
DRN = 3""",
    """BASE = 8          # INIT 1 + VCHK 1 + CPREP 6
W_RD_LAT = 2      # 引擎 W 读有效时延 (1=旧; 2=mem 侧 w_addr 寄存一拍)
DRN = W_RD_LAT + 2""")
io.open(P, "w", encoding="utf-8").write(s)
print("calc W_RD_LAT support added")
