# -*- coding: utf-8 -*-
"""TB 探针: 打印 acc/a_pipe/prod 行差异 (packed3)。"""
import io

P = "tb_nn_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""        $display("TBDBG4 %s lo0""",
    """        $display("TBDBG7 %s acc[0][0]=%0d acc[1][0]=%0d acc[2][0]=%0d acc[3][0]=%0d ap[1][0]=%0d ap[1][1]=%0d",
                 nm, u_eng.acc[0][0], u_eng.acc[1][0], u_eng.acc[2][0], u_eng.acc[3][0],
                 u_eng.a_pipe[1][0], u_eng.a_pipe[1][1]);
        $display("TBDBG4 %s lo0""")
io.open(P, "w", encoding="utf-8").write(s)
print("acc probe added")
