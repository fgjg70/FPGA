@echo off
REM ==========================================================================
REM run_synth.bat -- nn_mem v0.7 resource/mapping proof (Vivado 2018.3)
REM --------------------------------------------------------------------------
REM ASCII only. One non-project synthesis:
REM   W=320K(128b read) / Q=48K(LUTRAM 64b read) / A=96K+B=32K (128b read/write)
REM   expected: W ~75.5 BRAM36, Q ~7,000 LUT + 0 BRAM, A/B 32 BRAM36
REM            nn_mem total ~107.5 tiles (<=121.5 incl. core ~9.5 -> ~117/135)
REM Reports land in %TEMP%\nn_mem_v07_synth\v07_*.rpt
REM ==========================================================================
setlocal
set "PROCESSOR_ARCHITECTURE=AMD64"
call "D:\software\Learn\Xilinx\Vivado\2018.3\settings64.bat" >nul 2>&1
set "PY=C:\Users\19716\AppData\Local\Programs\Python\Python313\python.exe"
set "SCRIPT_DIR=%~dp0"
set "WORK=%TEMP%\nn_mem_v07_synth"
if not exist "%WORK%" mkdir "%WORK%"
echo [run_synth] work dir: %WORK%

"%PY%" "%SCRIPT_DIR%gen_wq_image.py" --split-prefix "%WORK%\yolo"
if errorlevel 1 goto :fail

cd /d "%WORK%"

echo [run_synth] === v0.7 config ===
call vivado -mode batch -source "%SCRIPT_DIR%synth_nn_mem.tcl" -tclargs proto_nn_mem_v07 "%WORK%\yolo_a.hex" "%WORK%\yolo_b.hex" "%WORK%\yolo_c.hex" "%WORK%\yolo_d.hex" "%WORK%\yolo_q.hex" "%WORK%\v07"
if errorlevel 1 goto :fail

echo RUN_SYNTH_OK
goto :eof

:fail
echo RUN_SYNTH_FAIL
exit /b 1
