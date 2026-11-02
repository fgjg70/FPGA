# -*- coding: utf-8 -*-
"""生成 engine(W_RD_LAT=2) + nn_mem_wpipe 的 OOC wrapper 与 tcl/bat (@8.0ns)。"""
import io
import os

HERE = os.path.dirname(os.path.abspath(__file__))
MEM = os.path.abspath(os.path.join(HERE, "..", "mem"))

w = io.open(os.path.join(HERE, "timing_wrap_v3.sv"), encoding="utf-8").read()
w = w.replace("  nn_mem u_mem (", "  nn_mem_wpipe u_mem (")
w = w.replace("nn_conv_engine #(.OC_LANES(16), .PX_LANES(8)) u_eng (",
              "nn_conv_engine #(.OC_LANES(16), .PX_LANES(8), .W_RD_LAT(2)) u_eng (")
assert "nn_mem_wpipe" in w and ".W_RD_LAT(2)" in w
io.open(os.path.join(HERE, "timing_wrap_v3w.sv"), "w", encoding="utf-8").write(w)

t = io.open(os.path.join(HERE, "synth125_v3.tcl"), encoding="ascii").read()
t = t.replace('"$repo/nn_mem.sv"', '"%s/nn_mem_wpipe.sv"' % MEM.replace("\\", "/"))
t = t.replace("$out/timing_wrap_v3.sv", "$out/timing_wrap_v3w.sv")
t = t.replace("synth125_", "synth125w_")
t = t.replace("SYNTH125_V3_DONE", "SYNTH125W_V3_DONE")
io.open(os.path.join(HERE, "synth125w_v3.tcl"), "w", encoding="ascii").write(t)

b = io.open(os.path.join(HERE, "synth125_v3.bat"), encoding="ascii").read()
b = b.replace("synth125_v3.tcl", "synth125w_v3.tcl").replace("synth125_v3.log", "synth125w_v3.log")
io.open(os.path.join(HERE, "synth125w_v3.bat"), "w", encoding="ascii").write(b)
print("wpipe OOC wrapper/tcl/bat written")
