# -*- coding: utf-8 -*-
"""TB 探针: 统计 f_p3 / S_LD 拍数 / a_re / S_Q 进入 (packed3 定位)。"""
import io

P = "tb_nn_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""  integer      qre_cnt;""",
    """  integer      p3_ld_cyc, are_cnt, ldret_cnt;
  always @(posedge clk) begin
    if ((u_eng.state == u_eng.S_LD) && u_eng.f_p3) p3_ld_cyc <= p3_ld_cyc + 1;
    if (a_re) are_cnt <= are_cnt + 1;
    if (u_eng.ld_ret_v) ldret_cnt <= ldret_cnt + 1;
  end

  integer      qre_cnt;""")
rep("""        $display("TBDBG4 %s lo0""",
    """        $display("TBDBG6 %s p3_ld=%0d are=%0d ldret=%0d flags=%02x", nm, p3_ld_cyc, are_cnt, ldret_cnt, u_eng.d_flags);
        $display("TBDBG4 %s lo0""")
rep("""    qre_cnt = 0; qre_first = 64'd0; sq_cnt = 0; wr_cnt = 0;""",
    """    qre_cnt = 0; qre_first = 64'd0; sq_cnt = 0; wr_cnt = 0;
    p3_ld_cyc = 0; are_cnt = 0; ldret_cnt = 0;""")
io.open(P, "w", encoding="utf-8").write(s)
print("probe6 added")
