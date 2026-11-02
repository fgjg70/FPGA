@echo off
REM ==========================================================================
REM run_joint_wpipe.bat -- joint TB: wpipe mem + engine (W_RD_LAT=2) 47+4 cases
REM --------------------------------------------------------------------------
REM ASCII only. 用法: run_joint_wpipe.bat [engine_sv]
REM   engine_sv 默认 .\nn_conv_engine.sv (根目录引擎)。若引擎改在 proto/engine，
REM   传入其路径即可。前置: nn_mem_wpipe.sv + tb_nn_engine_wpipe.sv 在本目录。
REM 说明: 引擎必须已实现 W 读时延 2 拍 (W_RD_LAT=2)，否则 W 数据会早 1 拍被消费;
REM       若 FAIL 先看是否拿到的是 1 拍引擎版本。
REM 输出: %TEMP%\nn_wpipe_joint\ 下 compile.log / vec47.log / v3extra.log
REM ==========================================================================
setlocal
set "PROCESSOR_ARCHITECTURE=AMD64"
set "REPO=D:\USER\Desktop\FPGA\FPGA"
set "PROTO=%REPO%\results\ai-accel\proto"
set "MEM=%PROTO%\mem"
set "WORK=%TEMP%\nn_wpipe_joint"
if not exist "%WORK%" mkdir "%WORK%"
set "ENGINE=%~1"
if "%ENGINE%"=="" set "ENGINE=%REPO%\nn_conv_engine.sv"
if not exist "%ENGINE%" ( echo ENGINE_NOT_FOUND %ENGINE% & exit /b 1 )

set "PATH=D:\software\tools\Modelsim\win64;%PATH%"
set "LM_LICENSE_FILE=D:\software\tools\Modelsim\win64\LICENSE.TXT"
cd /d "%WORK%"

vlib work >nul 2>&1
vlog -sv -work work "%REPO%\rv32_pkg.sv" "%REPO%\nn_pkg.sv" ^
  "%MEM%\nn_mem_wpipe.sv" "%ENGINE%" "%MEM%\tb_nn_engine_wpipe.sv" > compile.log 2>&1
if errorlevel 1 ( echo COMPILE_FAIL & type compile.log & exit /b 1 )
echo COMPILE_OK engine=%ENGINE%

vsim -c -do "run -all; quit -f" work.tb_nn_engine_wpipe "+vec=%PROTO%\engine\vec" > vec47.log 2>&1
findstr /C:"ENGINE_TB: PASS" /C:"ENGINE_TB: FAIL" vec47.log
findstr /C:"SUMMARY" vec47.log

vsim -c -do "run -all; quit -f" work.tb_nn_engine_wpipe "+vec=%PROTO%\engine\vec_v3extra" > v3extra.log 2>&1
findstr /C:"ENGINE_TB: PASS" /C:"ENGINE_TB: FAIL" v3extra.log
findstr /C:"SUMMARY" v3extra.log

echo RUN_JOINT_WPIPE_DONE
