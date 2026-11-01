# -*- coding: utf-8 -*-
"""修 PACKED3 提取: 上窗口用当前 a_rdata (A1 数据), 不用上一位置的 p3w1。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


rep("""                  for (int k = 0; k < 8; k++) begin
                    w32[k]      = p3w0[k*8 +: 8];
                    w32[k + 8]  = p3w0[(k+8)*8 +: 8];
                    w32[k + 16] = p3w1[k*8 +: 8];
                    w32[k + 24] = p3w1[(k+8)*8 +: 8];
                  end""",
    """                  for (int k = 0; k < 8; k++) begin
                    w32[k]      = p3w0[k*8 +: 8];
                    w32[k + 8]  = p3w0[(k+8)*8 +: 8];
                    w32[k + 16] = a_rdata[k*8 +: 8];        // A1 = 本拍读回
                    w32[k + 24] = a_rdata[(k+8)*8 +: 8];
                  end""")
io.open(P, "w", encoding="utf-8").write(s)
print("packed3 extract fixed")
