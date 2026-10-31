# -*- coding: utf-8 -*-
"""为 v2bc 叠加草稿生成 OOC 综合脚本 (在 proto/engine 下运行)。"""
import io

tpl = io.open("synth150.tcl", encoding="ascii").read()
t = tpl.replace(
    'read_verilog [list \\\n  "$repo/nn_pkg.sv" \\\n  "$repo/nn_mem.sv" \\\n  "$repo/nn_conv_engine.sv" \\\n  "$out/timing_wrap.sv"]',
    'read_verilog [list \\\n  "$repo/nn_pkg.sv" \\\n  "$repo/nn_mem.sv" \\\n  "$out/draft/nn_conv_engine_v2bc.sv" \\\n  "$out/timing_wrap.sv"]')
for tag in ("util", "timing", "paths"):
    t = t.replace('$out/synth150_%s.rpt' % tag, '$out/draft/synth150_bc_%s.rpt' % tag)
assert "draft/nn_conv_engine_v2bc" in t and "draft/synth150_bc_util" in t
io.open("draft/synth150_bc.tcl", "w", encoding="ascii").write(t)

bat = r"""@echo off
rem ASCII only. OOC 150MHz synth of v2bc combined draft (root RTL untouched).
set "XILINX_VIVADO=D:\software\Learn\Xilinx\Vivado\2018.3"
call "D:\software\Learn\Xilinx\Vivado\2018.3\settings64.bat" >nul 2>&1
cd /d "%~dp0"
"D:\software\Learn\Xilinx\Vivado\2018.3\bin\vivado.bat" -mode batch -nojournal ^
  -source "%~dp0synth150_bc.tcl" -log "%~dp0synth150_bc.log"
exit /b %errorlevel%
"""
io.open("draft/synth150_bc.bat", "w", encoding="ascii").write(bat)
print("bc synth scripts written")
