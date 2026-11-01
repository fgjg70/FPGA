# -*- coding: utf-8 -*-
"""1) oc_base_r/act_l_r 增量寄存器: 去掉 rq_pack/写 strobe/S_DRN 里的 c_ocb*ocw_r 乘法
   2) 小常量乘法 LUT 化: p1=ICB*OCB<<6, base0_t/base0_t2 用移位/加, tile 偏移用移位"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:220]
    s = s.replace(old, new, 1)


# ---- 声明 ----
rep("""  logic [15:0] rem_ch;                      // 当前 tile 之后剩余通道数 (增量)""",
    """  logic [15:0] rem_ch;                      // 当前 tile 之后剩余通道数 (增量)
  logic [15:0] oc_base_r;                   // 当前 tile 的起始 OC 通道 (增量)
  logic [15:0] act_l_r;                     // 当前 tile 的 active lane 数 (2*qb_w)""")

# ---- act_l 用寄存器 (原组合) ----
rep("""  wire [15:0] act_l = (oc8_r > (c_ocb * ocw_r))
                     ? (((oc8_r - c_ocb * ocw_r) >= ocw_r) ? ocw_r
                                                           : (oc8_r - c_ocb * ocw_r))
                     : 16'd0;""",
    """  wire [15:0] act_l = act_l_r;""")

# ---- rq_pack: 用 oc_base_r ----
rep("""      if ((c_ocb * ocw_r + l) >= d_oc) bb = zp_out;""",
    """      if ((oc_base_r + 16'(l)) >= d_oc) bb = zp_out;""")

# ---- 写 strobe: 用 oc_base_r ----
rep("""            for (int i = 0; i < 16; i++)
              b_wstrb_c[i] = ((c_ocb * ocw_r + 16'(i)) < oc8_r);""",
    """            for (int i = 0; i < 16; i++)
              b_wstrb_c[i] = ((oc_base_r + 16'(i)) < oc8_r);""")
rep("""          for (int i = 0; i < 8; i++)
            b_wstrb_c[i] = ((c_ocb * 16'd8 + 16'(i)) < ic8_r);""",
    """          for (int i = 0; i < 8; i++)
            b_wstrb_c[i] = ((oc_base_r + 16'(i)) < ic8_r);""")

# ---- S_DRN: wr 控制用 act_l_r ----
rep("""  wire wr_dense16 = dense && (act_l == 16'd16);
  wire [15:0] req_beats = wr_dense16 ? (single16 ? 16'd8 : 16'd16) : 16'd8;""",
    """  wire wr_dense16 = dense && (act_l_r == 16'd16);
  wire [15:0] req_beats = wr_dense16 ? (single16 ? 16'd8 : 16'd16) : 16'd8;""")
rep("""  wire single16 = (dense && (act_l == 16'd16) && (oc8_r[3:0] == 4'd0) &&
                   (d_dst[3:0] == 4'd0));""",
    """  wire single16 = (dense && (act_l_r == 16'd16) && (oc8_r[3:0] == 4'd0) &&
                   (d_dst[3:0] == 4'd0));""")

# ---- CPREP: p1 / base0_t / base0_t2 LUT 化; oc_base_r/act_l_r/rem 初值 ----
rep("""              p1          <= {8'd0, ic8_r} * {8'd0, oc8_r};""",
    """              p1          <= ({11'd0, ic8_r[8:3]} * {11'd0, oc8_r[8:3]}) << 6;""")
rep("""              base0_t     <= {21'd0, pad_r} * row_step_a;
              base0_t2    <= {21'd0, pad_r} * {8'd0, ic8_r};""",
    """              base0_t     <= (pad_r == 3'd0) ? 24'd0 :
                             (pad_r == 3'd1) ? row_step_a :
                             (pad_r == 3'd2) ? (row_step_a << 1) :
                             (pad_r == 3'd3) ? ((row_step_a << 1) + row_step_a)
                                             : (row_step_a << 2);
              base0_t2    <= (pad_r == 3'd0) ? 24'd0 :
                             (pad_r == 3'd1) ? {8'd0, ic8_r} :
                             (pad_r == 3'd2) ? ({8'd0, ic8_r} << 1) :
                             (pad_r == 3'd3) ? (({8'd0, ic8_r} << 1) + {8'd0, ic8_r})
                                             : ({8'd0, ic8_r} << 2);""")

rep("""                rem_ch   <= (oc8_r > ocw_r) ? (oc8_r - ocw_r) : 16'd0;
              end""",
    """                rem_ch    <= (oc8_r > a0) ? (oc8_r - a0) : 16'd0;
                act_l_r   <= a0;
                oc_base_r <= 16'd0;
              end""")

# ---- tile wrap: oc_base/act_l 增量 ----
rep("""                  rem_ch   <= rem_n;""",
    """                  rem_ch   <= rem_n;
                  act_l_r  <= a_n;
                  oc_base_r <= oc_base_r + act_l_r;""")

# ---- reset ----
rep("""      q_bias_w <= 13'd0; q_mpos_w <= 13'd0; q_tail_w <= 13'd0; rem_ch <= 16'd0;""",
    """      q_bias_w <= 13'd0; q_mpos_w <= 13'd0; q_tail_w <= 13'd0; rem_ch <= 16'd0;
      oc_base_r <= 16'd0; act_l_r <= 16'd8;""")

io.open(P, "w", encoding="utf-8").write(s)
print("oc_base/act_l regs + small-mult LUT applied")
