# -*- coding: utf-8 -*-
"""TB 探针: packed3 的 wby_r / a_pipe2 / prod (确认乘法输入)。"""
import io

P = "tb_nn_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""        $display("TBDBG7 %s acc[0][0]""",
    """        $display("TBDBG8 %s wby0=%0d wby1=%0d ap2_10=%0d prod_10=%0d",
                 nm, u_eng.wby_r[0], u_eng.wby_r[1], u_eng.a_pipe2[1][0], u_eng.prod[1][0]);
        $display("TBDBG7 %s acc[0][0]""")
io.open(P, "w", encoding="utf-8").write(s)
print("mul probe added")
