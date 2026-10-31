@echo off
rem ASCII only. Usage: run_sim.bat <top> <src1.sv> [src2.sv ...]
rem Environment is stripped in DSH sessions -> set ModelSim paths explicitly.
set "LM_LICENSE_FILE=D:\software\tools\Modelsim\win64\LICENSE.TXT"
set "PATH=D:\software\tools\Modelsim\win64;C:\Windows\System32;C:\Windows"
set "MODELSIM=D:\software\tools\Modelsim\win64"
set "WORKDIR=%~dp0work"
set TOP=%1
shift
set SRCS=
:loop
if "%~1"=="" goto done
set SRCS=%SRCS% "%~f1"
shift
goto loop
:done
if not exist "%WORKDIR%" mkdir "%WORKDIR%"
cd /d "%WORKDIR%"
"%MODELSIM%\vlib.exe" work >nul 2>&1
"%MODELSIM%\vlog.exe" -sv -work work %SRCS%
if errorlevel 1 exit /b 1
"%MODELSIM%\vsim.exe" -c -do "run -all; quit -f" work.%TOP%
if errorlevel 1 exit /b 1
exit /b 0
