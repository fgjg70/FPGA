# -*- coding: utf-8 -*-
"""TB 探针: 第一次 in-bounds packed3 emit 时打印 la/p3w0/a_rdata/abuf 写值。"""
import io

P = "tb_nn_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""  integer      p3_ld_cyc, are_cnt, ldret_cnt;""",
    """  integer      p3_ld_cyc, are_cnt, ldret_cnt;
  integer      p3_emit_seen;
  always @(posedge clk) begin
    if ((u_eng.state == u_eng.S_LD) && u_eng.f_p3 && (u_eng.p3_ph == 2'd2) &&
        u_eng.ld_inb && (p3_emit_seen == 0) && $test$plusargs("dbgv")) begin
      p3_emit_seen <= 1;
      $display("TBP3 emit la=%06x p3w0=%032x a_rdata=%032x abuf1_next=%016x",
               u_eng.la, u_eng.p3w0, a_rdata, u_eng.abuf[1]);
    end
  end""")
rep("""    p3_ld_cyc = 0; are_cnt = 0; ldret_cnt = 0;""",
    """    p3_ld_cyc = 0; are_cnt = 0; ldret_cnt = 0; p3_emit_seen = 0;""")
io.open(P, "w", encoding="utf-8").write(s)
print("p3 emit probe added")
