@echo off
rem ASCII only. Run engine TB against the temporary stub nn_mem (isolation test).
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
  "%~dp0nn_mem_stub.sv" ^
  "%REPO%\nn_conv_engine.sv" ^
  "%REPO%\sim\tb_nn_engine.sv"
if errorlevel 1 exit /b 1
"%MODELSIM%\vsim.exe" -c -do "run -all; quit -f" work.tb_nn_engine +vec="%REPO%\results\ai-accel\proto\engine\vec"
exit /b %errorlevel%
