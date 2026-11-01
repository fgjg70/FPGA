@echo off
REM ==========================================================================
REM run_synth_pipe.bat -- 方案 A/B/A+B OOC 自证 (engine v3 + nn_mem 变体)
REM --------------------------------------------------------------------------
REM ASCII only. 用法:
REM   run_synth_pipe.bat          # 8 个关键配置: {base,pipe,piperd,pipeab} x {125,150MHz}
REM   run_synth_pipe.bat full     # 再加 4 个 @100MHz 配置 (共 12 个)
REM 变体:
REM   base   = 根目录 nn_mem.sv (baseline)
REM   pipe   = 方案A (NPU b 写命令打一拍; 写延迟 1->2)
REM   piperd = 方案B (act 读地址打一拍; a/CPU 读延迟 1->2)
REM   pipeab = A+B
REM 报告: results/ai-accel/proto/mem/reports/<variant><mhz>_{util,timing,paths}.rpt
REM 注意: 跑之前确认 Lead 的 Vivado 大任务已结束 (避免抢资源; 见 PITFALLS 协作纪律)。
REM ==========================================================================
setlocal
set "PROCESSOR_ARCHITECTURE=AMD64"
call "D:\software\Learn\Xilinx\Vivado\2018.3\settings64.bat" >nul 2>&1
set "PY=C:\Users\19716\AppData\Local\Programs\Python\Python313\python.exe"
set "SCRIPT_DIR=%~dp0"
set "WQ=%SCRIPT_DIR%wq_init"
if not exist "%WQ%" mkdir "%WQ%"
if not exist "%SCRIPT_DIR%reports" mkdir "%SCRIPT_DIR%reports"

"%PY%" "%SCRIPT_DIR%gen_wq_image.py" --split-prefix "%WQ%\w" --seed 20261101
if errorlevel 1 goto :fail
copy /y "%WQ%\w_a.hex" "%WQ%\w_A.hex" >nul
copy /y "%WQ%\w_b.hex" "%WQ%\w_B.hex" >nul
copy /y "%WQ%\w_c.hex" "%WQ%\w_C.hex" >nul
copy /y "%WQ%\w_d.hex" "%WQ%\w_D.hex" >nul
copy /y "%WQ%\w_q.hex" "%WQ%\q_packed.hex" >nul

cd /d "%SCRIPT_DIR%"

if /i "%~1"=="full" (
  for %%V in (base pipe piperd pipeab) do call :run %%V 10.000 100
)
for %%V in (base pipe piperd pipeab) do call :run %%V 8.000 125
for %%V in (base pipe piperd pipeab) do call :run %%V 6.667 150

echo RUN_SYNTH_PIPE_OK
goto :eof

:run
echo [run_synth_pipe] === %~1 @ %~2 ns (%~3 MHz) ===
call vivado -mode batch -source "%SCRIPT_DIR%synth_pipe.tcl" -tclargs %~1 %~2 "%~1%~3"
if errorlevel 1 exit /b 1
goto :eof

:fail
echo RUN_SYNTH_PIPE_FAIL
exit /b 1
