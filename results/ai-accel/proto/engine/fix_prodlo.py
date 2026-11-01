# -*- coding: utf-8 -*-
"""DSP 168 -> ~152: 把 requant 的 prod_lo (16 路 16x16) 从 DSP 挪到 LUT。
   (prod_hi 保留 DSP: 128 MAC + 16 prod_hi = 144; prod_lo LUT 多 ~3K LUT)"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()
old = """  (* use_dsp = "yes" *) logic signed [31:0] prod_hi [0:OCL-1];
  (* use_dsp = "yes" *) logic signed [31:0] prod_lo [0:OCL-1];"""
new = """  (* use_dsp = "yes" *) logic signed [31:0] prod_hi [0:OCL-1];
  (* use_dsp = "no" *)  logic signed [31:0] prod_lo [0:OCL-1];"""
assert old in s, "prod declarations not found"
s = s.replace(old, new, 1)
io.open(P, "w", encoding="utf-8").write(s)
print("prod_lo -> LUT")
