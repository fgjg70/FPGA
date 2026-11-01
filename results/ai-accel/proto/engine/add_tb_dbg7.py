# -*- coding: utf-8 -*-
"""TB load_wq 统计 W/Q 写入次数并打印 (调试 Q 未装载)。"""
import io

P = "tb_nn_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""  task automatic load_wq(input string nm, output integer nw);
    integer fh, rc;
    logic [31:0] off, wd;
    begin
      nw = 0;""",
    """  task automatic load_wq(input string nm, output integer nw);
    integer fh, rc;
    integer n_w, n_q;
    logic [31:0] off, wd;
    begin
      nw = 0;
      n_w = 0; n_q = 0;""")
rep("""        if (off >= NN_Q_OFF)
          dbg_wr(1'b1, 17'((off - NN_Q_OFF) >> 2), wd);
        else
          dbg_wr(1'b0, 17'(off >> 2), wd);""",
    """        if (off >= NN_Q_OFF) begin
          dbg_wr(1'b1, 17'((off - NN_Q_OFF) >> 2), wd);
          n_q = n_q + 1;
        end
        else begin
          dbg_wr(1'b0, 17'(off >> 2), wd);
          n_w = n_w + 1;
        end""")
rep("""      $fclose(fh);
    end
  endtask""",
    """      $fclose(fh);
      if ($test$plusargs("dbgv"))
        $display("TBLOAD %s W=%0d Q=%0d", nm, n_w, n_q);
    end
  endtask""")
io.open(P, "w", encoding="utf-8").write(s)
print("load_wq counters added")
