# -*- coding: utf-8 -*-
"""回退 E1 窄版: 静态时序仍会计 mux 的未选输入路径 (a_addr_c), 实测无收益(@8 +1.371->+1.272,
   @7 不变 +0.371), 故还原为已验收的 LUT 友好版 (prod_hi/prod_lo 均 DSP, WNS@125 +1.371)。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


rep("""  logic [12:0] q_addr_q;
  logic [23:0] a_addr_q;      // E1: band 装载地址预寄存 (下一拍用)""",
    """  logic [12:0] q_addr_q;""")
rep("""  assign a_addr    = ((state == S_LD) && !f_p3) ? a_addr_q : a_addr_c;""",
    """  assign a_addr    = a_addr_c;""")
rep("""      q_addr_q  <= q_addr_c;

      // E1: band 装载地址预寄存 (仅非 PACKED3; packed3/其它状态用组合路径)
      if (state == S_LD)                     a_addr_q <= la + band_step_a;
      else if (state == S_BI)                a_addr_q <= f_p3 ? blk_base
                                                          : (f_dw ? (blk_base + (c_ocb << 3)) : blk_base);
      else if (state == S_PINIT)             a_addr_q <= blk_base + (c_ocb << 3);
      else if (state == S_MAC)               a_addr_q <= la;   // 回到 S_LD 前的 la 已由 S_LDCAP 设好
      else if (state == S_PMAX)              a_addr_q <= la;""",
    """      q_addr_q  <= q_addr_c;""")
rep("""      q_re_q   <= 1'b0; q_addr_q <= 13'd0; a_addr_q <= 24'd0;""",
    """      q_re_q   <= 1'b0; q_addr_q <= 13'd0;""")

io.open(P, "w", encoding="utf-8").write(s)
print("E1 reverted")
