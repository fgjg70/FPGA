# -*- coding: utf-8 -*-
"""TB: +dbgv 时打印前 6 次 NPU 写的 (addr,strb,data)。"""
import io

P = "tb_nn_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""  always @(posedge clk) begin
    if (b_we && !cap_seen) begin""",
    """  integer wr_cnt;
  always @(posedge clk) begin
    if (b_we) begin
      if ($test$plusargs("dbgv") && (wr_cnt < 6))
        $display("TBWR[%0d] addr=%06x strb=%04x data=%032x", wr_cnt, b_addr, b_wstrb, b_wdata);
      wr_cnt <= wr_cnt + 1;
    end
    if (b_we && !cap_seen) begin""")
rep("""    qre_cnt = 0; qre_first = 64'd0; sq_cnt = 0;""",
    """    qre_cnt = 0; qre_first = 64'd0; sq_cnt = 0; wr_cnt = 0;""")
io.open(P, "w", encoding="utf-8").write(s)
print("wr print added")
