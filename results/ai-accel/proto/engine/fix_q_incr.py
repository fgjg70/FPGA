# -*- coding: utf-8 -*-
"""Q 参数下一 tile 的增量计算 (去掉 S_NEXT2 里 ocb*ocw 乘法, 修 OOC 最差路径 c_ocb->q_tot_r)。
   新增 rem_ch 寄存器: 当前 tile 之后剩余通道数; 每 tile -ocw_r。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


rep("""  logic [4:0]  q_tot_r, qb_w_r, qm_w_r;     // Q 装载拍数/字数 (寄存器)""",
    """  logic [4:0]  q_tot_r, qb_w_r, qm_w_r;     // Q 装载拍数/字数 (寄存器)
  logic [15:0] rem_ch;                      // 当前 tile 之后剩余通道数 (增量)""")

# CPREP c_p=5: 顺便初始化 rem_ch
rep("""                q_tail_w <= 13'((d_qoff[15:0] + (oc8_r << 2) + (oc8_r << 1)) >> 3);
              end""",
    """                q_tail_w <= 13'((d_qoff[15:0] + (oc8_r << 2) + (oc8_r << 1)) >> 3);
                rem_ch   <= (oc8_r > ocw_r) ? (oc8_r - ocw_r) : 16'd0;
              end""")

# S_NEXT2 wrap: 用增量替换乘法版 qc1
old_qc1 = """                begin : qc1
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
                end"""
new_qc1 = """                begin : qc1
                  logic [15:0] rem_n, a_n;
                  rem_n = (rem_ch > ocw_r) ? (rem_ch - ocw_r) : 16'd0;
                  a_n   = (rem_n >= ocw_r) ? ocw_r : rem_n;
                  rem_ch   <= rem_n;
                  qb_w_r   <= 5'(a_n >> 1);
                  qm_w_r   <= 5'(a_n >> 2);
                  q_tot_r  <= 5'((a_n >> 1) + (a_n >> 2) + 16'd1);
                  q_bias_w <= q_bias_w + 13'(ocw_r >> 1);
                  q_mpos_w <= q_mpos_w + 13'(ocw_r >> 2);
                end"""
rep(old_qc1, new_qc1)

# reset
rep("""      q_bias_w <= 13'd0; q_mpos_w <= 13'd0; q_tail_w <= 13'd0;""",
    """      q_bias_w <= 13'd0; q_mpos_w <= 13'd0; q_tail_w <= 13'd0; rem_ch <= 16'd0;""")

io.open(P, "w", encoding="utf-8").write(s)
print("q-param incremental update applied")
