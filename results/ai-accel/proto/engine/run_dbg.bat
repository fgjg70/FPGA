@echo off
rem ASCII only. Run debug TB.
set "LM_LICENSE_FILE=D:\software\tools\Modelsim\win64\LICENSE.TXT"
set "PATH=D:\software\tools\Modelsim\win64;C:\Windows\System32;C:\Windows"
set "MODELSIM=D:\software\tools\Modelsim\win64"
set "WORKDIR=%~dp0work"
set "REPO=%~dp0..\..\..\.."
if not exist "%WORKDIR%" mkdir "%WORKDIR%"
cd /d "%WORKDIR%"
"%MODELSIM%\vlib.exe" work >nul 2>&1
"%MODELSIM%\vlog.exe" -sv -work work ^
  "%REPO%\rv32_pkg.sv" ^
  "%REPO%\nn_pkg.sv" ^
  "%REPO%\nn_mem.sv" ^
  "%REPO%\nn_conv_engine.sv" ^
  "%~dp0debug_tb.sv"
if errorlevel 1 exit /b 1
"%MODELSIM%\vsim.exe" -c -do "run -all; quit -f" work.debug_tb %*
exit /b %errorlevel%
