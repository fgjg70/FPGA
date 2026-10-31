@echo off
rem ASCII only. OOC synth + 150MHz timing for nn_conv_engine + nn_mem.
set "PROCESSOR_ARCHITECTURE=AMD64"
set "XILINX_VIVADO=D:\software\Learn\Xilinx\Vivado\2018.3"
call "D:\software\Learn\Xilinx\Vivado\2018.3\settings64.bat" >nul 2>&1
cd /d "%~dp0"
"D:\software\Learn\Xilinx\Vivado\2018.3\bin\vivado.bat" -mode batch -nojournal ^
  -source "%~dp0synth150.tcl" -log "%~dp0synth150.log"
exit /b %errorlevel%
