@echo off
rem ASCII only. Compile-only: compile.bat <src1.sv> [src2.sv ...]
set "LM_LICENSE_FILE=D:\software\tools\Modelsim\win64\LICENSE.TXT"
set "PATH=D:\software\tools\Modelsim\win64;C:\Windows\System32;C:\Windows"
set "MODELSIM=D:\software\tools\Modelsim\win64"
set "WORKDIR=%~dp0work"
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
exit /b %errorlevel%
