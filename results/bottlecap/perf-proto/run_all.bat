@echo off
rem ASCII only. Run the approved OOC probe grid (task-12 item 5).
rem All outputs stay under results/bottlecap/perf-proto/. No repo RTL is touched.
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

rem ---- config grid: tag  period(ns)  PX LANE DSP_PX REQ_LANES ----
rem P128 = baseline calibration (8x16, 128 DSP + 16-lane requant)
call :RUN p128_150 6.667 8 16 8 16
call :RUN p128_122 8.182 8 16 8 16
call :RUN p128_100 10.000 8 16 8 16
rem OC24 = 192 MAC (120 DSP + 72 LUT), requant 16 lanes
call :RUN p192oc24_150 6.667 8 24 5 16
call :RUN p192oc24_122 8.182 8 24 5 16
rem OC32 = 256 MAC (160 DSP + 96 LUT), requant 16 lanes
call :RUN p256oc32_150 6.667 8 32 5 16
call :RUN p256oc32_122 8.182 8 32 5 16
call :RUN p256oc32_100 10.000 8 32 5 16
rem OC32 wide requant (32 lanes -> +64 DSP) : DSP-tight variant
call :RUN p256oc32req32_150 6.667 8 32 5 32
rem PX16 = 256 MAC (160 DSP + 96 LUT, 16-lane requant)
call :RUN p256px16_150 6.667 16 16 10 16
echo ALL_PROBE_RUNS_DONE
goto :eof

:RUN
set TAG=%~1
set PER=%~2
set PX=%~3
set LANE=%~4
set DPX=%~5
set REQ=%~6
echo === RUN %TAG% period=%PER% px=%PX% lane=%LANE% dsp_px=%DPX% req=%REQ% ===
call "%VIVADO%" -mode batch -notrace -source "%PROTO%\run_ooc.tcl" -tclargs %TAG% %PER% %PX% %LANE% %DPX% %REQ% > "%PROTO%\ooc_%TAG%.log" 2>&1
echo RUN_EXIT %TAG% = %ERRORLEVEL%
goto :eof
