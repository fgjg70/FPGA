# -*- coding: utf-8 -*-
"""补 TB v3 的 dbg_wdata 声明 + 初值。"""
import io

P = "tb_nn_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""  logic [16:0] dbg_addr;
""", """  logic [16:0] dbg_addr;
  logic [31:0] dbg_wdata;
""")
rep("""  initial begin
    // 输出表格初始化""",
    """  initial begin
    dbg_we = 1'b0; dbg_space = 1'b0; dbg_addr = 17'd0; dbg_wdata = 32'd0;
    // 输出表格初始化""")
io.open(P, "w", encoding="utf-8").write(s)
print("tb v3 dbg fixed")
