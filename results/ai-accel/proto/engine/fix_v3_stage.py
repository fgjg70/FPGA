# -*- coding: utf-8 -*-
"""修 requant 流水级数: 32x16 拆 DSP 后多了一级 (prod_hi/lo 寄存器), 需要整体后移 1 拍:
   acc_sel c_p0..7 / prod_hi,lo 1..8 / prod64 2..9 / y64 3..10 / y2 4..11 / out 5..12 /
   写 beat 6..5+beats; REQN = 6+beats+2。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


# 1) reqn 定义
rep("""  wire [15:0] reqn_w    = 16'd5 + req_beats + 16'd2;   // 5 拍流水 + beats + NEXT""",
    """  wire [15:0] reqn_w    = 16'd6 + req_beats + 16'd2;   // 6 拍流水 + beats + NEXT""")

# 2) y64 / y2 / out 级后移
rep("""        if ((c_p >= 16'd2) && (c_p <= 16'd9)) begin
          logic signed [47:0] ph;
          for (int l = 0; l < OCL; l++) begin
            ph = $signed({{16{prod_hi[l][31]}}, prod_hi[l]}) <<< 16;
            prod64[l] <= ph + $signed({{16{prod_lo[l][31]}}, prod_lo[l]});
            if (shift_q >= 8'd16)
              y64_q[l] <= (prod64[l] >>> 16) >>> shift_q[3:0];
            else
              y64_q[l] <= prod64[l] >>> shift_q[3:0];
          end
        end
        if ((c_p >= 16'd3) && (c_p <= 16'd10)) begin
          for (int l = 0; l < OCL; l++) y2_q[l] <= y64_q[l] + {{40{zp_out[7]}}, zp_out};
        end
        if ((c_p >= 16'd4) && (c_p <= 16'd11)) begin
          out_lo[c_p[2:0] - 3'd4] <= rq_pack[63:0];
          out_hi[c_p[2:0] - 3'd4] <= rq_pack[127:64];
        end""",
    """        if ((c_p >= 16'd2) && (c_p <= 16'd9)) begin
          logic signed [47:0] ph;
          for (int l = 0; l < OCL; l++) begin
            ph = $signed({{16{prod_hi[l][31]}}, prod_hi[l]}) <<< 16;
            prod64[l] <= ph + $signed({{16{prod_lo[l][31]}}, prod_lo[l]});
          end
        end
        if ((c_p >= 16'd3) && (c_p <= 16'd10)) begin
          for (int l = 0; l < OCL; l++)
            if (shift_q >= 8'd16)
              y64_q[l] <= (prod64[l] >>> 16) >>> shift_q[3:0];
            else
              y64_q[l] <= prod64[l] >>> shift_q[3:0];
        end
        if ((c_p >= 16'd4) && (c_p <= 16'd11)) begin
          for (int l = 0; l < OCL; l++) y2_q[l] <= y64_q[l] + {{40{zp_out[7]}}, zp_out};
        end
        if ((c_p >= 16'd5) && (c_p <= 16'd12)) begin
          out_lo[c_p[2:0] - 3'd5] <= rq_pack[63:0];
          out_hi[c_p[2:0] - 3'd5] <= rq_pack[127:64];
        end""")

# 3) 写 beat: c_p 从 6 开始
rep("""          beat = c_p - 16'd5;""", """          beat = c_p - 16'd6;""")
rep("""          if ((c_p >= 16'd5) && (c_p <= (16'd4 + req_beats)) && ((ox0 + px) < ow_w)) begin""",
    """          if ((c_p >= 16'd6) && (c_p <= (16'd5 + req_beats)) && ((ox0 + px) < ow_w)) begin""")

# 4) wpx 初始化/步进
rep("""        if (c_p == 16'd4) wpx <= wr_base;
        else if ((c_p >= 16'd5) && (c_p < (16'd5 + req_beats))) begin""",
    """        if (c_p == 16'd5) wpx <= wr_base;
        else if ((c_p >= 16'd6) && (c_p < (16'd6 + req_beats))) begin""")

io.open(P, "w", encoding="utf-8").write(s)
print("requant stage shift applied")
