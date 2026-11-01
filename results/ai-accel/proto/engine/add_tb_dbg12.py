# -*- coding: utf-8 -*-
"""TB 探针: packed3 每个 band 最后一次 emit 时打印 abuf[1]/abuf[8]/abuf[16] 当前值。"""
import io

P = "tb_nn_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""  always @(posedge clk) begin
    if ((u_eng.state == u_eng.S_LD) && u_eng.f_p3 && (u_eng.p3_ph == 2'd2) &&
        u_eng.ld_inb && (p3_emit_seen == 0) && $test$plusargs("dbgv")) begin""",
    """  integer band_cnt;
  always @(posedge clk) begin
    if ((u_eng.state == u_eng.S_LD) && u_eng.f_p3 && (u_eng.p3_ph == 2'd2) &&
        (u_eng.c_ld == 16'd16) && $test$plusargs("dbgv")) begin
      $display("TBBAND[%0d] abuf0=%016x abuf1=%016x abuf8=%016x abuf16=%016x la=%06x",
               band_cnt, u_eng.abuf[0], u_eng.abuf[1], u_eng.abuf[8], u_eng.abuf[16], u_eng.la);
      band_cnt <= band_cnt + 1;
    end
    if ((u_eng.state == u_eng.S_LD) && u_eng.f_p3 && (u_eng.p3_ph == 2'd2) &&
        u_eng.ld_inb && (p3_emit_seen == 0) && $test$plusargs("dbgv")) begin""")
rep("""    p3_ld_cyc = 0; are_cnt = 0; ldret_cnt = 0; p3_emit_seen = 0;""",
    """    p3_ld_cyc = 0; are_cnt = 0; ldret_cnt = 0; p3_emit_seen = 0; band_cnt = 0;""")
io.open(P, "w", encoding="utf-8").write(s)
print("band probe added")
