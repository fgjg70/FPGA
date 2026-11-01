# -*- coding: utf-8 -*-
"""TB 探针: mac_v2 时 wby_r[0] / a_pipe2[1][0] 非零计数。"""
import io

P = "tb_nn_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""    if (w_re) wre_cnt <= wre_cnt + 1;""",
    """    if (u_eng.mac_v2 && (u_eng.wby_r[0] != 16'sd0)) wby_nz <= wby_nz + 1;
    if (u_eng.mac_v2 && (u_eng.a_pipe2[1][0] != 8'sd0)) ap2_nz <= ap2_nz + 1;
    if (w_re) wre_cnt <= wre_cnt + 1;""")
rep("""  integer mac_cyc, win_nz, wre_cnt, prod_nz;""",
    """  integer mac_cyc, win_nz, wre_cnt, prod_nz, wby_nz, ap2_nz;""")
rep("""                 wre_cnt, prod_nz);""",
    """                 wre_cnt, prod_nz, wby_nz, ap2_nz);
        $display("TBDBG9 %s wby_nz=%0d ap2_nz=%0d", nm, wby_nz, ap2_nz);""")
rep("""    mac_cyc = 0; win_nz = 0; wre_cnt = 0; prod_nz = 0;""",
    """    mac_cyc = 0; win_nz = 0; wre_cnt = 0; prod_nz = 0; wby_nz = 0; ap2_nz = 0;""")
io.open(P, "w", encoding="utf-8").write(s)
print("mul counts added")
