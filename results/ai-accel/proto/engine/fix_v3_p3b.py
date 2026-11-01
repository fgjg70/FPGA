# -*- coding: utf-8 -*-
"""修: (1) packed3 row_base_a 初值; (2) S_NEXT 用 p3_oy; (3) ADD_R 参数只捕获一次。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


# (1) CPREP c_p=5: row_base_a packed3 初值
rep("""              row_base_a  <= f_p3 ? 24'd0 : base0_a;""",
    """              row_base_a  <= f_p3 ? (d_src[23:0] - ({21'd0, pad_r} * (p3_row + 24'd3)))
                                  : base0_a;""")

# (2) S_NEXT: 行步长按 packed3
rep("""          row_base_a_n <= row_base_a + oy_step_a;""",
    """          row_base_a_n <= row_base_a + (f_p3 ? p3_oy : oy_step_a);""")

# (3) ADD_R: 只在第一个字捕获 Q 参数 (q_rdata 只在 q_re 后一拍有效)
rep("""          if (f_add_r) begin
            zp_s_r  <= q_rdata[7:0];
            zp_d_r  <= q_rdata[15:8];
            add_r_r <= {q_rdata[31:24], q_rdata[23:16]};
            kadd_r  <= q_rdata[39:32];
          end""",
    """          if (f_add_r && (c_iy == 16'd0) && (c_ix == 16'd0) && (c_cb == 16'd0)) begin
            zp_s_r  <= q_rdata[7:0];
            zp_d_r  <= q_rdata[15:8];
            add_r_r <= {q_rdata[31:24], q_rdata[23:16]};
            kadd_r  <= q_rdata[39:32];
          end""")
io.open(P, "w", encoding="utf-8").write(s)
print("packed3/add_r fixes applied")
