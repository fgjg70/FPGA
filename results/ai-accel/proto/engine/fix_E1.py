# -*- coding: utf-8 -*-
"""E1(窄版, 周期 0): 非 PACKED3 的 band 装载 a_addr 改为"预寄存下一拍地址":
   - a_addr_q 在进入 S_LD 的上一状态装入 la, S_LD 内每拍装入 la+band_step_a (均为 FF+加法)
   - 输出 a_addr = (S_LD && !f_p3) ? a_addr_q : a_addr_c
   mem 读时延/FSM/ld_ret 完全不变 -> 周期不变; 其它状态(copy/add/packed3)仍走原组合路径。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


rep("""  logic        q_re_q;
  logic [12:0] q_addr_q;""",
    """  logic        q_re_q;
  logic [12:0] q_addr_q;
  logic [23:0] a_addr_q;      // E1: band 装载地址预寄存 (下一拍用)""")

# 输出 mux
rep("""  assign a_addr    = a_addr_c;""",
    """  assign a_addr    = ((state == S_LD) && !f_p3) ? a_addr_q : a_addr_c;""")

# 时序: 进 S_LD 的状态装入 la; S_LD 内每拍装入 la+step
rep("""      q_re_q    <= q_re_c;
      q_addr_q  <= q_addr_c;""",
    """      q_re_q    <= q_re_c;
      q_addr_q  <= q_addr_c;

      // E1: band 装载地址预寄存 (仅非 PACKED3; packed3/其它状态用组合路径)
      if (state == S_LD)                     a_addr_q <= la + band_step_a;
      else if (state == S_BI)                a_addr_q <= la;
      else if (state == S_PINIT)             a_addr_q <= la;
      else if (state == S_MAC)               a_addr_q <= la;   // 回到 S_LD 前的 la 已由 S_LDCAP 设好""")

rep("""      q_re_q   <= 1'b0; q_addr_q <= 13'd0;""",
    """      q_re_q   <= 1'b0; q_addr_q <= 13'd0; a_addr_q <= 24'd0;""")

io.open(P, "w", encoding="utf-8").write(s)
print("E1 narrow applied")
