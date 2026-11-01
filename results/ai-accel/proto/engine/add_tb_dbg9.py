# -*- coding: utf-8 -*-
"""TB 探针: 打印 out_lo/out_hi 前 4 行 + abuf/bshift 前 4 项 (packed3 调试)。"""
import io

P = "tb_nn_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""        $display("TBDBG3 %s qre=%0d sq=%0d qfirst=%016x", nm, qre_cnt, sq_cnt, qre_first);""",
    """        $display("TBDBG3 %s qre=%0d sq=%0d qfirst=%016x", nm, qre_cnt, sq_cnt, qre_first);
        $display("TBDBG4 %s lo0=%016x lo1=%016x lo2=%016x lo3=%016x",
                 nm, u_eng.out_lo[0], u_eng.out_lo[1], u_eng.out_lo[2], u_eng.out_lo[3]);
        $display("TBDBG5 %s abuf0=%016x abuf1=%016x abuf2=%016x abuf3=%016x bs0=%016x",
                 nm, u_eng.abuf[0], u_eng.abuf[1], u_eng.abuf[2], u_eng.abuf[3], u_eng.bshift[0]);""")
io.open(P, "w", encoding="utf-8").write(s)
print("probe4 added")
