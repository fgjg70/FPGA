@echo off
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
