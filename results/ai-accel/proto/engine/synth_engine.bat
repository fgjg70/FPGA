@echo off
rem ASCII only. Run Vivado batch synthesis of nn_conv_engine for resource numbers.
set "PROCESSOR_ARCHITECTURE=AMD64"
set "XILINX_VIVADO=D:\software\Learn\Xilinx\Vivado\2018.3"
call "D:\software\Learn\Xilinx\Vivado\2018.3\settings64.bat" >nul 2>&1
cd /d "%~dp0"
"D:\software\Learn\Xilinx\Vivado\2018.3\bin\vivado.bat" -mode batch -nojournal ^
  -source "%~dp0synth_engine.tcl" -log "%~dp0synth_engine.log"
exit /b %errorlevel%
