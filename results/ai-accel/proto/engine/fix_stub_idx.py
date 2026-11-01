# -*- coding: utf-8 -*-
"""修 stub 的 act_idx：total_words 13 位装不下 8192 → 用 int。"""
import io

P = "nn_mem_v07_stub.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


rep("""  function automatic logic [12:0] act_idx(input logic [1:0] sel,
                                          input logic [23:0] addr,
                                          input logic [12:0] awords,
                                          input logic [12:0] total_words);""",
    """  function automatic logic [12:0] act_idx(input logic [1:0] sel,
                                          input logic [23:0] addr,
                                          input int unsigned total_words);""")
rep("""    if ((off >> 4) >= total_words) return 13'd0;
    act_idx = 13'(off >> 4);
    awords = awords;  // unused
  endfunction""",
    """    if ((off >> 4) >= total_words) return 13'd0;
    act_idx = 13'(off >> 4);
  endfunction""")
rep("""  wire [12:0] a_idx = act_idx(a_sel, a_addr, 13'(A_BYTES >> 4), 13'(ACT_WORDS));
  wire [12:0] b_idx = act_idx(b_sel, b_addr, 13'(A_BYTES >> 4), 13'(ACT_WORDS));""",
    """  wire [12:0] a_idx = act_idx(a_sel, a_addr, ACT_WORDS);
  wire [12:0] b_idx = act_idx(b_sel, b_addr, ACT_WORDS);""")
io.open(P, "w", encoding="utf-8").write(s)
print("stub act_idx fixed")
