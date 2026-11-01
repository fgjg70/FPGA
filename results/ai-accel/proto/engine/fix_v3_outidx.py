# -*- coding: utf-8 -*-
"""修 out_lo/out_hi 行索引: 存到 (c_p-4)。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


rep("""        if ((c_p >= 16'd4) && (c_p <= 16'd11)) begin
          out_lo[c_p[2:0]] <= rq_pack[63:0];
          out_hi[c_p[2:0]] <= rq_pack[127:64];
        end""",
    """        if ((c_p >= 16'd4) && (c_p <= 16'd11)) begin
          out_lo[c_p[2:0] - 3'd4] <= rq_pack[63:0];
          out_hi[c_p[2:0] - 3'd4] <= rq_pack[127:64];
        end""")
io.open(P, "w", encoding="utf-8").write(s)
print("out idx fixed")
