# -*- coding: utf-8 -*-
"""TB: q_re 首次两次打印地址+mem 内容, 确认 Q 是否装载/地址是否正确。"""
import io

P = "tb_nn_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""    if (q_re) begin
      qre_cnt <= qre_cnt + 1;
      if (qre_cnt == 0) qre_first <= q_rdata;
    end""",
    """    if (q_re) begin
      qre_cnt <= qre_cnt + 1;
      if (qre_cnt == 0) qre_first <= q_rdata;
      if ((qre_cnt < 2) && $test$plusargs("dbgv"))
        $display("TBQRE addr=%0d mem63=%08x mem64=%08x mem65=%08x mem66=%08x",
                 q_addr, u_mem.q_mem[63], u_mem.q_mem[64], u_mem.q_mem[65], u_mem.q_mem[66]);
    end""")
io.open(P, "w", encoding="utf-8").write(s)
print("qre mem probe added")
