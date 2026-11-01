# -*- coding: utf-8 -*-
"""把 Q 参数 (q_tot/qb_w/qm_w/bias/mpos/tail 字索引) 变成寄存器:
   首 tile 在 CPREP c_p=5 计算, 后续 tile 在 S_NEXT2 wrap 时计算。
   目的: S_Q 的地址/捕获使能路径不再从 ocw_r/oc8_r 组合展开 (OOC 100MHz 最差路径)。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:250]
    s = s.replace(old, new, 1)


# 1) 声明
rep("""  logic [15:0] ic8_r, oc8_r, ocw_r, oc_limit_r, icb_n_r;""",
    """  logic [15:0] ic8_r, oc8_r, ocw_r, oc_limit_r, icb_n_r;
  logic [4:0]  q_tot_r, qb_w_r, qm_w_r;     // Q 装载拍数/字数 (寄存器)
  logic [12:0] q_bias_w, q_mpos_w, q_tail_w; // Q 三段 64b 字索引 (寄存器)""")

# 2) 用寄存器替换组合线网
rep("""  wire [15:0] qb_w  = act_l >> 1;               // bias 64b 字数 (2 lane/字)
  wire [15:0] qm_w  = act_l >> 2;               // mpos 64b 字数 (4 lane/字)
  wire [15:0] q_tot = qb_w + qm_w + 16'd1;      // + tail 1 字""",
    """  wire [15:0] qb_w  = {11'd0, qb_w_r};          // bias 64b 字数 (2 lane/字)
  wire [15:0] qm_w  = {11'd0, qm_w_r};          // mpos 64b 字数 (4 lane/字)
  wire [15:0] q_tot = {11'd0, q_tot_r};         // 总字数""")
rep("""  // Q 三段的 64b 字索引
  wire [12:0] q_bias_base = 13'((d_qoff + c_ocb * ocw_r * 4) >> 3);
  wire [12:0] q_mpos_base = 13'((d_qoff + 4 * oc8_r + c_ocb * ocw_r * 2) >> 3);
  wire [12:0] q_tail_base = 13'((d_qoff + 6 * oc8_r) >> 3);""",
    """  // Q 三段的 64b 字索引 (寄存器)
  wire [12:0] q_bias_base = q_bias_w;
  wire [12:0] q_mpos_base = q_mpos_w;
  wire [12:0] q_tail_base = q_tail_w;""")

# 3) CPREP c_p=5: 首 tile 的 Q 参数 (c_ocb=0)
rep("""            16'd5: begin
              w_sub       <= {8'd0, oc8_r}""",
    """            16'd5: begin
              // 首个 OC tile (c_ocb=0) 的 Q 参数打拍
              begin : qc0
                logic [15:0] a0;
                a0 = (oc8_r >= ocw_r) ? ocw_r : oc8_r;
                qb_w_r   <= 5'(a0 >> 1);
                qm_w_r   <= 5'(a0 >> 2);
                q_tot_r  <= 5'((a0 >> 1) + (a0 >> 2) + 16'd1);
                q_bias_w <= 13'(d_qoff[15:0] >> 3);
                q_mpos_w <= 13'((d_qoff[15:0] + (oc8_r << 2)) >> 3);
                q_tail_w <= 13'((d_qoff[15:0] + (oc8_r << 2) + (oc8_r << 1)) >> 3);
              end
              w_sub       <= {8'd0, oc8_r}""")

# 4) S_NEXT2 wrap: 下一个 tile 的 Q 参数 (c_ocb+1)
rep("""                row_base_w <= d_dst[23:0] + ((c_ocb + 16'd1) * ocw_r);
                wr_base    <= d_dst[23:0] + ((c_ocb + 16'd1) * ocw_r);""",
    """                row_base_w <= d_dst[23:0] + ((c_ocb + 16'd1) * ocw_r);
                wr_base    <= d_dst[23:0] + ((c_ocb + 16'd1) * ocw_r);
                begin : qc1
                  logic [15:0] ocb1, rem, a1;
                  logic [31:0] qo32;
                  qo32 = d_qoff;
                  ocb1 = c_ocb + 16'd1;
                  rem  = oc8_r - (ocb1 * ocw_r);
                  a1   = (rem >= ocw_r) ? ocw_r : rem;
                  qb_w_r   <= 5'(a1 >> 1);
                  qm_w_r   <= 5'(a1 >> 2);
                  q_tot_r  <= 5'((a1 >> 1) + (a1 >> 2) + 16'd1);
                  q_bias_w <= 13'((qo32 + (ocb1 * ocw_r * 4)) >> 3);
                  q_mpos_w <= 13'((qo32 + (oc8_r << 2) + (ocb1 * ocw_r * 2)) >> 3);
                  q_tail_w <= 13'((qo32 + (oc8_r << 2) + (oc8_r << 1)) >> 3);
                end""")

# 5) reset
rep("""      ic8_r <= 16'd0; oc8_r <= 16'd0; ocw_r <= 16'd8; oc_limit_r <= 16'd0;""",
    """      ic8_r <= 16'd0; oc8_r <= 16'd0; ocw_r <= 16'd8; oc_limit_r <= 16'd0;
      q_tot_r <= 5'd0; qb_w_r <= 5'd0; qm_w_r <= 5'd0;
      q_bias_w <= 13'd0; q_mpos_w <= 13'd0; q_tail_w <= 13'd0;""")

io.open(P, "w", encoding="utf-8").write(s)
print("Q params registered")
