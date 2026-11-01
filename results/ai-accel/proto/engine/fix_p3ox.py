# -*- coding: utf-8 -*-
"""修 packed3 的 ox 步长: p3_ox 应为"8 个输出像素 × stride × 3 字节" = st2?48:24,
   之前误写成 (iw*3)<<4 (依赖 iw) -> 每行第 2 个 tile 起输入地址错 (SoC op0 first=64 的证据)。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()
old = """              p3_oy       <= st2_r ? (p3_row << 1) : p3_row;
              p3_ox       <= st2_r ? (p3_row << 4) : (p3_row << 3);"""
new = """              p3_oy       <= st2_r ? (p3_row << 1) : p3_row;
              p3_ox       <= st2_r ? 24'd48 : 24'd24;   // 8 px * stride * 3B"""
assert old in s
s = s.replace(old, new, 1)
io.open(P, "w", encoding="utf-8").write(s)
print("p3_ox fixed")
