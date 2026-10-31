# -*- coding: utf-8 -*-
"""为 B/C 草稿生成仿真/综合脚本 (proto/engine/draft/ 下, 不动根目录)。"""
import io
import os

OUT = "draft"
# ---- run_tb_draft.bat: 用法 run_tb_draft.bat <draft_engine.sv> ----
run_tb = r"""@echo off
rem ASCII only. TB against a DRAFT engine copy (root RTL untouched).
rem usage: run_tb_draft.bat draft\nn_conv_engine_v2b.sv
set "LM_LICENSE_FILE=D:\software\tools\Modelsim\win64\LICENSE.TXT"
set "PATH=D:\software\tools\Modelsim\win64;C:\Windows\System32;C:\Windows"
set "MODELSIM=D:\software\tools\Modelsim\win64"
set "WORKDIR=%~dp0work_draft"
set "REPO=%~dp0..\..\..\..\.."
if not exist "%WORKDIR%" mkdir "%WORKDIR%"
cd /d "%WORKDIR%"
"%MODELSIM%\vlib.exe" work >nul 2>&1
"%MODELSIM%\vlog.exe" -sv -work work ^
  "%REPO%\rv32_pkg.sv" ^
  "%REPO%\nn_pkg.sv" ^
  "%REPO%\nn_mem.sv" ^
  "%~dp0%1" ^
  "%REPO%\sim\tb_nn_engine.sv"
if errorlevel 1 exit /b 1
"%MODELSIM%\vsim.exe" -c -do "run -all; quit -f" work.tb_nn_engine +vec="%~dp0..\vec"
exit /b %errorlevel%
"""
io.open(os.path.join(OUT, "run_tb_draft.bat"), "w", encoding="ascii").write(run_tb)

# ---- synth tcl for draft ----
tpl = io.open("synth150.tcl", encoding="ascii").read()
for tag in ("b", "c"):
    t = tpl
    t = t.replace(
        'read_verilog [list \\\n  "$repo/nn_pkg.sv" \\\n  "$repo/nn_mem.sv" \\\n  "$repo/nn_conv_engine.sv" \\\n  "$out/timing_wrap.sv"]',
        'read_verilog [list \\\n  "$repo/nn_pkg.sv" \\\n  "$repo/nn_mem.sv" \\\n  "$out/draft/nn_conv_engine_v2' + tag + '.sv" \\\n  "$out/timing_wrap.sv"]')
    t = t.replace('$out/synth150_util.rpt', '$out/draft/synth150_' + tag + '_util.rpt')
    t = t.replace('$out/synth150_timing.rpt', '$out/draft/synth150_' + tag + '_timing.rpt')
    t = t.replace('$out/synth150_paths.rpt', '$out/draft/synth150_' + tag + '_paths.rpt')
    assert 'draft/nn_conv_engine_v2' + tag in t, "tcl replace failed"
    io.open(os.path.join(OUT, "synth150_" + tag + ".tcl"), "w", encoding="ascii").write(t)

    bat = r"""@echo off
rem ASCII only. OOC 150MHz synth of DRAFT engine (root RTL untouched).
set "XILINX_VIVADO=D:\software\Learn\Xilinx\Vivado\2018.3"
call "D:\software\Learn\Xilinx\Vivado\2018.3\settings64.bat" >nul 2>&1
cd /d "%~dp0"
"D:\software\Learn\Xilinx\Vivado\2018.3\bin\vivado.bat" -mode batch -nojournal ^
  -source "%~dp0synth150_""" + tag + r""".tcl" -log "%~dp0synth150_""" + tag + r""".log"
exit /b %errorlevel%
"""
    io.open(os.path.join(OUT, "synth150_" + tag + ".bat"), "w", encoding="ascii").write(bat)
print("draft scripts written: run_tb_draft.bat, synth150_{b,c}.{tcl,bat}")
