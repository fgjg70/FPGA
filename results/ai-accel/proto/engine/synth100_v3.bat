@echo off
rem ASCII only. OOC 100MHz synthesis of engine v3 + nn_mem v0.7 (proto only).
set "XILINX_VIVADO=D:\software\Learn\Xilinx\Vivado\2018.3"
call "D:\software\Learn\Xilinx\Vivado\2018.3\settings64.bat" >nul 2>&1
cd /d "%~dp0"
"D:\software\Learn\Xilinx\Vivado\2018.3\bin\vivado.bat" -mode batch -nojournal ^
  -source "%~dp0synth100_v3.tcl" -log "%~dp0synth100_v3.log"
exit /b %errorlevel%
