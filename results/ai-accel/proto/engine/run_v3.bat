@echo off
rem ASCII only. v3 simulation: stub(v0.7 ports) + engine_v3 + tb_v3, reuse existing 46-case vectors.
set "LM_LICENSE_FILE=D:\software\tools\Modelsim\win64\LICENSE.TXT"
set "PATH=D:\software\tools\Modelsim\win64;C:\Windows\System32;C:\Windows"
set "MODELSIM=D:\software\tools\Modelsim\win64"
set "WORKDIR=%~dp0work_v3"
set "REPO=%~dp0..\..\..\.."
if not exist "%WORKDIR%" mkdir "%WORKDIR%"
cd /d "%WORKDIR%"
"%MODELSIM%\vlib.exe" work >nul 2>&1
"%MODELSIM%\vlog.exe" -sv -work work ^
  "%REPO%\rv32_pkg.sv" ^
  "%REPO%\nn_pkg.sv" ^
  "%~dp0nn_mem_v07_stub.sv" ^
  "%~dp0nn_conv_engine_v3.sv" ^
  "%~dp0tb_nn_engine_v3.sv"
if errorlevel 1 exit /b 1
"%MODELSIM%\vsim.exe" -c -do "run -all; quit -f" work.tb_nn_engine +vec="%~dp0vec"
exit /b %errorlevel%
