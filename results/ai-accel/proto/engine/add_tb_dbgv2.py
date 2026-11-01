# -*- coding: utf-8 -*-
"""增强 +dbgv: 打印引擎内部关键状态。"""
import io

P = "tb_nn_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""        $display("TBDBG %s pre  A0=%08x_%08x", nm, dbgv1, dbgv0);""",
    """        $display("TBDBG %s pre  A0=%08x_%08x dst=%08x sel_b_dst=%b woff=%08x qoff=%08x",
                 nm, dbgv1, dbgv0, u_eng.d_dst, u_eng.sel_b_dst, u_eng.d_woff, u_eng.d_qoff);""")
io.open(P, "w", encoding="utf-8").write(s)
print("dbgv enhanced")
