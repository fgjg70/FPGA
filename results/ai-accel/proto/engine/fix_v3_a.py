# -*- coding: utf-8 -*-
"""修 v3 首版编译问题（proto 草稿）。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


# 1) 端口名 b_wdata_128 -> b_wdata；去掉误留的 stray 变量
rep("""  output logic [127:0] b_wdata_128,
  output logic [15:0]  b_wstrb""",
    """  output logic [127:0] b_wdata,
  output logic [15:0]  b_wstrb""")
rep("""  logic        b_we_q, x;
  logic [23:0] b_addr_q;""",
    """  logic        b_we_q;
  logic [23:0] b_addr_q;""")
rep("""  assign b_wdata_128 = b_wdata_q;""", """  assign b_wdata   = b_wdata_q;""")

# 2) x0_c/y_ky0 声明提前（放到 ox0 之后）
rep("""  wire [15:0] ox0 = c_oxg << 3;""",
    """  wire [15:0] ox0 = c_oxg << 3;
  wire signed [15:0] x0_c  = $signed(ox0) * (st2_r ? 16'sd2 : 16'sd1)
                             - $signed({13'd0, pad_r});
  wire signed [15:0] y_ky0 = $signed(c_oy) * (st2_r ? 16'sd2 : 16'sd1)
                             - $signed({13'd0, pad_r});""")
rep("""  // ---- x/y 位置 (band 装载) ----
  wire signed [15:0] x0_c  = $signed({3'd0, ox0}) * (st2_r ? 16'sd2 : 16'sd1)
                             - $signed({13'd0, pad_r});
  wire signed [15:0] y_ky0 = $signed({2'b0, c_oy}) * (st2_r ? 16'sd2 : 16'sd1)
                             - $signed({13'd0, pad_r});

""", "")

# 3) S_NEXT2 case0: 去掉错误的 x_ld 更新（S_BI 会用新 c_oxg 重算 x0_c）
rep("""              wr_base  <= wr_base + ox_step_w;
              x_ld     <= x0_ld + (f_p3 ? $signed(24'(p3_ox)) : $signed({8'd0, ic8_r[15:0]}));
              state    <= is_pool ? S_PINIT : S_BI;""",
    """              wr_base  <= wr_base + ox_step_w;
              state    <= is_pool ? S_PINIT : S_BI;""")

# 4) ADD_R 公式简化（避免 9 位拼接写错）
rep("""          p  = (($signed({24{qs[7]}} + 24'sd0) + {{24{qs[7]}}, qs})
                - {{24{zp_s_r[7]}}, zp_s_r}) * $signed({1'b0, add_r_r});""",
    """          p  = ($signed(qs) - $signed(zp_s_r)) * $signed({1'b0, add_r_r});""")

# 5) S_Q 里 q_iss 与 q_tot 比较的位宽收敛（统一 16 位）
rep("""          if (q_iss < q_tot) q_iss <= q_iss + 5'd1;
          if ((q_iss >= 5'd1) && (q_iss <= q_tot)) begin""",
    """          if (16'(q_iss) < q_tot) q_iss <= q_iss + 5'd1;
          if ((q_iss >= 5'd1) && (16'(q_iss) <= q_tot)) begin""")
rep("""          if (q_iss == q_tot) state <= S_QLOAD;""",
    """          if (16'(q_iss) == q_tot) state <= S_QLOAD;""")
rep("""      q_re_c   = (q_iss < q_tot);""",
    """      q_re_c   = (16'(q_iss) < q_tot);""")
rep("""               : (q_iss < (qb_w + qm_w))""",
    """               : (16'(q_iss) < (qb_w + qm_w))""")

io.open(P, "w", encoding="utf-8").write(s)
print("v3 fixes applied")
