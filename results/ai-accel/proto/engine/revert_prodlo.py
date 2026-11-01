# -*- coding: utf-8 -*-
"""按 Lead 决定：恢复 LUT 友好版 —— 把 prod_lo 放回 DSP。
   目标版本: DSP 168 / LUT 32.6K / WNS@125 +1.371（其余改动保留: AD 5 拍、icb_more_r、q 打拍等）。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()
old = '  (* use_dsp = "no" *)  logic signed [31:0] prod_lo [0:OCL-1];'
new = '  (* use_dsp = "yes" *) logic signed [31:0] prod_lo [0:OCL-1];'
assert old in s, "prod_lo decl not found"
s = s.replace(old, new, 1)
io.open(P, "w", encoding="utf-8").write(s)
print("prod_lo back to DSP (LUT-friendly variant restored)")
