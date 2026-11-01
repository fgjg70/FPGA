# -*- coding: utf-8 -*-
"""TB: 统计 q_re 次数 + 首个 q 数据 + S_Q 进入次数 (dbgv 打印)。"""
import io

P = "tb_nn_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""  logic        cap_seen;""",
    """  integer      qre_cnt;
  logic [63:0] qre_first;
  integer      sq_cnt;
  always @(posedge clk) begin
    if (q_re) begin
      qre_cnt <= qre_cnt + 1;
      if (qre_cnt == 0) qre_first <= q_rdata;
    end
    if (u_eng.state == u_eng.S_Q) sq_cnt <= sq_cnt + 1;
  end

  logic        cap_seen;""")

rep("""        $display("TBDBG2 %s zp_out""",
    """        $display("TBDBG3 %s qre=%0d sq=%0d qfirst=%016x", nm, qre_cnt, sq_cnt, qre_first);
        $display("TBDBG2 %s zp_out""")

rep("""    cap_seen = 1'b0; cap_addr = 24'd0; cap_sel = 2'd0; cap_strb = 16'd0;""",
    """    qre_cnt = 0; qre_first = 64'd0; sq_cnt = 0;
    cap_seen = 1'b0; cap_addr = 24'd0; cap_sel = 2'd0; cap_strb = 16'd0;""")
io.open(P, "w", encoding="utf-8").write(s)
print("qre monitor added")
