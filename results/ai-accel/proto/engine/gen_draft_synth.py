# -*- coding: utf-8 -*-
"""为任意 draft engine 生成 OOC 综合脚本 (在 proto/engine 下运行)。
用法: python gen_draft_synth.py nn_conv_engine_v2bc2 bc2
"""
import io
import sys

name = sys.argv[1]
tag = sys.argv[2] if len(sys.argv) > 2 else name.replace("nn_conv_engine_", "")

tpl = io.open("synth150.tcl", encoding="ascii").read()
t = tpl.replace(
    'read_verilog [list \\\n  "$repo/nn_pkg.sv" \\\n  "$repo/nn_mem.sv" \\\n  "$repo/nn_conv_engine.sv" \\\n  "$out/timing_wrap.sv"]',
    'read_verilog [list \\\n  "$repo/nn_pkg.sv" \\\n  "$repo/nn_mem.sv" \\\n  "$out/draft/' + name + '.sv" \\\n  "$out/timing_wrap.sv"]')
for k in ("util", "timing", "paths"):
    t = t.replace('$out/synth150_%s.rpt' % k, '$out/draft/synth150_%s_%s.rpt' % (tag, k))
assert name in t
io.open("draft/synth150_%s.tcl" % tag, "w", encoding="ascii").write(t)

bat = "\r\n".join([
    "@echo off",
    'set "XILINX_VIVADO=D:\\software\\Learn\\Xilinx\\Vivado\\2018.3"',
    'call "D:\\software\\Learn\\Xilinx\\Vivado\\2018.3\\settings64.bat" >nul 2>&1',
    'cd /d "%~dp0"',
    '"D:\\software\\Learn\\Xilinx\\Vivado\\2018.3\\bin\\vivado.bat" -mode batch -nojournal '
    + '-source "%~dp0synth150_TAG.tcl" -log "%~dp0synth150_TAG.log"',
    "exit /b %errorlevel%",
]) + "\r\n"
bat = bat.replace("TAG", tag)
io.open("draft/synth150_%s.bat" % tag, "w", encoding="ascii").write(bat)
print("written draft/synth150_%s.tcl/.bat for %s" % (tag, name))
