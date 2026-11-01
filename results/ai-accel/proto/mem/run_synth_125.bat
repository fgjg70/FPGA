@echo off
REM ==========================================================================
REM run_synth_125.bat -- nn_mem v0.7 OOC @125MHz (8.0ns constraint) proof
REM --------------------------------------------------------------------------
REM ASCII only. Same flow as run_synth.bat, but passes an 8th tclarg (period ns)
REM so the standalone nn_mem OOC has a 125MHz constraint. Reports:
REM   %TEMP%\nn_mem_v07_synth\v07_125_util.rpt / v07_125_timing.rpt
REM Expected: W 80 + A/B 32 = 112 RAMB36, Q ~7K LUT; WNS is the number Lead
REM needs to judge the machine fmax ceiling.
REM ==========================================================================
setlocal
set "PROCESSOR_ARCHITECTURE=AMD64"
call "D:\software\Learn\Xilinx\Vivado\2018.3\settings64.bat" >nul 2>&1
set "PY=C:\Users\19716\AppData\Local\Programs\Python\Python313\python.exe"
set "SCRIPT_DIR=%~dp0"
set "WORK=%TEMP%\nn_mem_v07_synth"
if not exist "%WORK%" mkdir "%WORK%"
echo [run_synth_125] work dir: %WORK%

"%PY%" "%SCRIPT_DIR%gen_wq_image.py" --split-prefix "%WORK%\yolo125" --seed 20261101
if errorlevel 1 goto :fail

cd /d "%WORK%"

echo [run_synth_125] === v0.7 config, 8.0ns (125MHz) ===
call vivado -mode batch -source "%SCRIPT_DIR%synth_nn_mem.tcl" -tclargs proto_nn_mem_v07 "%WORK%\yolo125_a.hex" "%WORK%\yolo125_b.hex" "%WORK%\yolo125_c.hex" "%WORK%\yolo125_d.hex" "%WORK%\yolo125_q.hex" "%WORK%\v07_125" 8.000
if errorlevel 1 goto :fail

echo RUN_SYNTH_125_OK
goto :eof

:fail
echo RUN_SYNTH_125_FAIL
exit /b 1
