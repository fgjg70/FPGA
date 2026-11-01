@echo off
REM ==========================================================================
REM run_synth_final.bat -- FINAL OOC: engine v3 (pre/post E1) + nn_mem v0.7
REM --------------------------------------------------------------------------
REM ASCII only. 用法:
REM   run_synth_final.bat        # 4 个: {pre,post} x {125MHz(8ns), 142.86MHz(7ns)}
REM   run_synth_final.bat 131    # 追加 {pre,post} x 131.25MHz(7.619ns)  -> 共 6 个
REM 变体:
REM   pre  = proto/mem/engine_pre_e1.sv (E1 前的根引擎快照; 2026-11-01 14:33, sha256 820AA34E...)
REM   post = 根目录 nn_conv_engine.sv  (E1 落地后的最终版, 由 T-accel/Lead 覆盖)
REM 报告: results/ai-accel/proto/mem/reports_final/<prefix>_{util,timing,paths}.rpt
REM 注意: 只在 Lead 宣布机器空闲后运行 (协作纪律, 避免抢 Vivado 资源)。
REM ==========================================================================
setlocal
set "PROCESSOR_ARCHITECTURE=AMD64"
call "D:\software\Learn\Xilinx\Vivado\2018.3\settings64.bat" >nul 2>&1
set "PY=C:\Users\19716\AppData\Local\Programs\Python\Python313\python.exe"
set "SCRIPT_DIR=%~dp0"
set "WQ=%SCRIPT_DIR%wq_init"
if not exist "%WQ%" mkdir "%WQ%"
if not exist "%SCRIPT_DIR%reports_final" mkdir "%SCRIPT_DIR%reports_final"

"%PY%" "%SCRIPT_DIR%gen_wq_image.py" --split-prefix "%WQ%\w" --seed 20261101
if errorlevel 1 goto :fail
copy /y "%WQ%\w_a.hex" "%WQ%\w_A.hex" >nul
copy /y "%WQ%\w_b.hex" "%WQ%\w_B.hex" >nul
copy /y "%WQ%\w_c.hex" "%WQ%\w_C.hex" >nul
copy /y "%WQ%\w_d.hex" "%WQ%\w_D.hex" >nul
copy /y "%WQ%\w_q.hex" "%WQ%\q_packed.hex" >nul

cd /d "%SCRIPT_DIR%"
for %%E in (pre post) do call :run %%E 8.000 125
for %%E in (pre post) do call :run %%E 7.000 142
if /i "%~1"=="131" (
  for %%E in (pre post) do call :run %%E 7.619 131
)
echo RUN_SYNTH_FINAL_OK
goto :eof

:run
echo [run_synth_final] === engine=%~1 period=%~2 ns (%~3 MHz) ===
call vivado -mode batch -source "%SCRIPT_DIR%synth_final.tcl" -tclargs %~1 %~2 "%~1_%~3"
if errorlevel 1 exit /b 1
goto :eof

:fail
echo RUN_SYNTH_FINAL_FAIL
exit /b 1
