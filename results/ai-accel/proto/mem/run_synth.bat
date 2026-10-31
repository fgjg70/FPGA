@echo off
REM ==========================================================================
REM run_synth.bat -- nn_mem BRAM inference proof (Vivado 2018.3)
REM --------------------------------------------------------------------------
REM ASCII only. Runs two non-project syntheses:
REM   v0.3.2 config : W=320K Q=48K A=96K B=32K  (expected 92+32 = 124 BRAM36)
REM   v0.2 config   : W=320K Q=16K A=B=128K     (expected 84+64 = 148 BRAM36, > 135)
REM Reports land in %TEMP%\nn_mem_synth\{v03,v02}_*.rpt
REM ==========================================================================
setlocal
set "PROCESSOR_ARCHITECTURE=AMD64"
call "D:\software\Learn\Xilinx\Vivado\2018.3\settings64.bat" >nul 2>&1
set "PY=C:\Users\19716\AppData\Local\Programs\Python\Python313\python.exe"
set "SCRIPT_DIR=%~dp0"
set "WORK=%TEMP%\nn_mem_synth"
if not exist "%WORK%" mkdir "%WORK%"
echo [run_synth] work dir: %WORK%

"%PY%" "%SCRIPT_DIR%gen_wq_image.py" --words 94208 --out "%WORK%\yolo_wq.hex" --split-prefix "%WORK%\wq_v03"
if errorlevel 1 goto :fail
"%PY%" "%SCRIPT_DIR%gen_wq_image.py" --words 86016 --split-prefix "%WORK%\wq_v02"
if errorlevel 1 goto :fail

cd /d "%WORK%"

echo [run_synth] === v0.3.2 config (expected 124 BRAM36) ===
call vivado -mode batch -source "%SCRIPT_DIR%synth_nn_mem.tcl" -tclargs proto_nn_mem_v03 "%WORK%\wq_v03_a.hex" "%WORK%\wq_v03_b.hex" "%WORK%\wq_v03_c.hex" "%WORK%\wq_v03_d.hex" "%WORK%\v03"
if errorlevel 1 goto :fail

echo [run_synth] === v0.2 config (expected 148 BRAM36; over 135) ===
call vivado -mode batch -source "%SCRIPT_DIR%synth_nn_mem.tcl" -tclargs proto_nn_mem_v02 "%WORK%\wq_v02_a.hex" "%WORK%\wq_v02_b.hex" "%WORK%\wq_v02_c.hex" "none" "%WORK%\v02"
if errorlevel 1 goto :fail

echo RUN_SYNTH_OK
goto :eof

:fail
echo RUN_SYNTH_FAIL
exit /b 1
