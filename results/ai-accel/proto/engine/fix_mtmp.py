# -*- coding: utf-8 -*-
"""把 mtmp (mpos*3277) 乘法从 DSP 挪到 LUT: DSP 169 -> ~153, LUT +~3K (可接受)。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()
old = "  logic signed [31:0] mtmp   [0:OCL-1];"
new = '  (* use_dsp = "no" *) logic signed [31:0] mtmp   [0:OCL-1];'
assert old in s, "mtmp decl not found"
s = s.replace(old, new, 1)
io.open(P, "w", encoding="utf-8").write(s)
print("mtmp use_dsp=no applied")
