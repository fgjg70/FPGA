# -*- coding: utf-8 -*-
"""TB 探针: w_re 次数 / prod 非零次数 (packed3)。"""
import io

P = "tb_nn_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""  integer mac_cyc, win_nz;""",
    """  integer mac_cyc, win_nz, wre_cnt, prod_nz;
  always @(posedge clk) begin
    if (w_re) wre_cnt <= wre_cnt + 1;
    if (u_eng.state == u_eng.S_REQ && (u_eng.prod[0][0] != 16'sd0)) prod_nz <= prod_nz + 1;
  end""")
rep("""        $display("TBDBG8 %s wby0=%0d wby1=%0d ap2_10=%0d prod_10=%0d",
                 nm, u_eng.wby_r[0], u_eng.wby_r[1], u_eng.a_pipe2[1][0], u_eng.prod[1][0]);""",
    """        $display("TBDBG8 %s wby0=%0d wby1=%0d ap2_10=%0d prod_10=%0d wre=%0d prodnz=%0d",
                 nm, u_eng.wby_r[0], u_eng.wby_r[1], u_eng.a_pipe2[1][0], u_eng.prod[1][0],
                 wre_cnt, prod_nz);""")
rep("""    mac_cyc = 0; win_nz = 0;""",
    """    mac_cyc = 0; win_nz = 0; wre_cnt = 0; prod_nz = 0;""")
io.open(P, "w", encoding="utf-8").write(s)
print("wre probe added")
