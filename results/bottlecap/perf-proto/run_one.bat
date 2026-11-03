@echo off
rem ASCII only. One-off retry for a single probe run (Vivado helper-process flake).
rem usage: run_one.bat <tag> <period> <PX> <LANE> <DSP_PX> <REQ_LANES>
setlocal
set VIVADO=D:\software\Learn\Xilinx\Vivado\2018.3\bin\vivado.bat
set PROTO=D:\USER\Desktop\FPGA\FPGA\results\bottlecap\perf-proto
set PROCESSOR_ARCHITECTURE=AMD64
set PROCESSOR_IDENTIFIER=AMD64
set SystemRoot=C:\Windows
set windir=C:\Windows
set SystemDrive=C:
set COMSPEC=C:\Windows\System32\cmd.exe
set PATHEXT=.COM;.EXE;.BAT;.CMD
set TEMP=%PROTO%\_tmp
set TMP=%PROTO%\_tmp
if not exist "%TEMP%" mkdir "%TEMP%"
cd /d "%PROTO%"
echo === RETRY %1 period=%2 px=%3 lane=%4 dsp_px=%5 req=%6 ===
call "%VIVADO%" -mode batch -notrace -source "%PROTO%\run_ooc.tcl" -tclargs %1 %2 %3 %4 %5 %6 > "%PROTO%\ooc_%1.log" 2>&1
echo RETRY_EXIT %1 = %ERRORLEVEL%
